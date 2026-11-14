package com.atermius.aterm_client

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import androidx.core.content.ContextCompat
import com.hoho.android.usbserial.driver.CdcAcmSerialDriver
import com.hoho.android.usbserial.driver.Ch34xSerialDriver
import com.hoho.android.usbserial.driver.Cp21xxSerialDriver
import com.hoho.android.usbserial.driver.FtdiSerialDriver
import com.hoho.android.usbserial.driver.ProlificSerialDriver
import com.hoho.android.usbserial.driver.SerialTimeoutException
import com.hoho.android.usbserial.driver.UsbSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * USB-to-serial adapters for the serial Console ("atermius/usb_serial"),
 * using the vendored usb-serial-for-android drivers (apps/client/android/usbserial).
 *
 * Nothing here runs on its own: no manifest intent filter, no auto-launch on
 * attach. Dart lists adapters, asks for USB access only after the user picked
 * one ([requestPermission]: Android's own consent dialog, one at a time, only
 * while the activity is visible and only for a device a serial driver claims)
 * and opens a port at 8N1 without flow control. A port is identified by
 * vendor/product id, the USB serial number when Android lets the app read it,
 * and the port index; Dart owns the `usb:VVVV:PPPP[:serial][#port]` string.
 *
 * Data flow mirrors the desktop serial Console: a reader thread forwards
 * device output with at most [MAX_UNACKED_OUTPUT] bytes in flight until Dart
 * acknowledges them ("ack"), and a writer thread sends at most [MAX_INPUT]
 * queued bytes, failing the session when the device makes no progress for
 * [WRITE_TIMEOUT_MS]. Unplugging (ACTION_USB_DEVICE_DETACHED or a failed
 * read on a vanished device) ends the session with reason "detached"; Dart
 * shows it in the tab. [close] ends every session with the Flutter engine.
 */
class UsbSerialBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
    private val visible: () -> Boolean,
) {
    private val channel = MethodChannel(messenger, "atermius/usb_serial")
    private val main = Handler(Looper.getMainLooper())
    private val usb: UsbManager? = activity.getSystemService(UsbManager::class.java)
    private val usbHost = activity.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)
    private val prober = UsbSerialProber.getDefaultProber()
    // Port setup issues control transfers with multi-second timeouts; keep
    // them off the main thread and one at a time.
    private val opener: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "atermius-usb-serial-open").apply { isDaemon = true }
    }
    private val permissionAction = "${activity.packageName}.USB_SERIAL_PERMISSION"

    // Main thread only.
    private val sessions = HashMap<Int, Session>()
    private val opening = HashSet<String>()
    private var nextSession = 1
    private var permission: PendingPermission? = null
    private var closed = false

    private class PendingPermission(
        val deviceName: String,
        val result: MethodChannel.Result,
        val timeout: Runnable,
    )

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                // The PendingIntent is immutable, so Android cannot fill in
                // EXTRA_PERMISSION_GRANTED / EXTRA_DEVICE; the request tracks
                // its device itself and the answer is always
                // UsbManager.hasPermission for that device.
                permissionAction -> finishPermission()
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    val name = detachedDevice(intent)?.deviceName ?: return
                    sessions.values.filter { it.device.deviceName == name }
                        .forEach { end(it, "detached") }
                    if (permission?.deviceName == name) finishPermission()
                }
            }
        }
    }

    init {
        val filter = IntentFilter().apply {
            addAction(permissionAction)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        // Not exported on every API level (androidx guards it with a
        // signature permission before 33): only our own PendingIntent and the
        // system's protected USB_DEVICE_DETACHED broadcast reach it.
        ContextCompat.registerReceiver(activity, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "list" -> result.success(list())
                "requestPermission" -> requestPermission(call, result)
                "open" -> open(call, result)
                "write" -> write(call, result)
                "ack" -> {
                    val bytes = call.int("bytes", 0..MAX_UNACKED_OUTPUT)
                    if (bytes == null) {
                        result.error("invalid", "Invalid acknowledgement", null)
                    } else {
                        call.int("session", 1..Int.MAX_VALUE)?.let { sessions[it] }?.ack(bytes)
                        result.success(null)
                    }
                }
                "close" -> {
                    call.int("session", 1..Int.MAX_VALUE)?.let { sessions[it] }?.let { end(it, null) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Ends every session and pending request; the Dart side dies with the engine. */
    fun close() {
        if (closed) return
        closed = true
        channel.setMethodCallHandler(null)
        sessions.values.toList().forEach { end(it, null) }
        permission?.let {
            permission = null
            main.removeCallbacks(it.timeout)
            it.result.success(false)
        }
        try {
            activity.unregisterReceiver(receiver)
        } catch (_: Exception) {
        }
        opener.shutdown()
    }

    private data class Target(val vendorId: Int, val productId: Int, val serial: String?, val port: Int)

    private sealed interface Resolved
    private class Found(val device: UsbDevice) : Resolved
    private object NotFound : Resolved
    private object Ambiguous : Resolved

    private fun MethodCall.int(name: String, range: IntRange): Int? {
        val value = (argument<Any?>(name) as? Number)?.toLong() ?: return null
        return if (value in range.first.toLong()..range.last.toLong()) value.toInt() else null
    }

    private fun target(call: MethodCall): Target? {
        val vendorId = call.int("vendorId", 0..0xffff) ?: return null
        val productId = call.int("productId", 0..0xffff) ?: return null
        val port = call.int("port", 0 until MAX_PORTS) ?: return null
        val serial = call.argument<Any?>("serial")
        if (serial != null && (serial !is String || !SERIAL.matches(serial))) return null
        return Target(vendorId, productId, serial, port)
    }

    private fun probe(device: UsbDevice): UsbSerialDriver? = try {
        prober.probeDevice(device)
    } catch (_: Exception) {
        // Malformed descriptors from an untrusted device: not an adapter.
        null
    }

    /** Readable only with USB permission on Android 10+; null when hidden or not usable in an id. */
    private fun serialOf(device: UsbDevice): String? = try {
        device.serialNumber?.takeIf { SERIAL.matches(it) }
    } catch (_: SecurityException) {
        null
    }

    private fun serialReadable(manager: UsbManager, device: UsbDevice) =
        Build.VERSION.SDK_INT < 29 || manager.hasPermission(device)

    private fun resolve(target: Target): Resolved {
        val manager = usb ?: return NotFound
        val candidates = manager.deviceList.values
            .filter { it.vendorId == target.vendorId && it.productId == target.productId }
        if (target.serial == null) {
            return when (candidates.size) {
                0 -> NotFound
                1 -> Found(candidates[0])
                else -> Ambiguous
            }
        }
        val known = candidates.filter { serialOf(it) == target.serial }
        if (known.size == 1) return Found(known[0])
        if (known.size > 1) return Ambiguous
        // Android 10+ hides serial numbers until USB access is granted. A
        // single such candidate is offered for permission; open() checks its
        // serial number again afterwards, so a different adapter never opens.
        val hidden = candidates.filter { !serialReadable(manager, it) }
        return when (hidden.size) {
            0 -> NotFound
            1 -> Found(hidden[0])
            else -> Ambiguous
        }
    }

    private fun clean(text: String?): String? =
        text?.replace(CONTROL, "")?.trim()?.take(MAX_NAME)?.takeIf { it.isNotEmpty() }

    private fun driverName(driver: UsbSerialDriver) = when (driver) {
        is CdcAcmSerialDriver -> "CDC-ACM"
        is FtdiSerialDriver -> "FTDI"
        is Cp21xxSerialDriver -> "CP210x"
        is Ch34xSerialDriver -> "CH34x"
        is ProlificSerialDriver -> "PL2303"
        else -> "serial"
    }

    private fun list(): Map<String, Any?> {
        val manager = usb ?: return mapOf("usbHost" to usbHost, "adapters" to emptyList<Any>())
        val adapters = manager.deviceList.values
            .sortedBy { it.deviceName }
            .mapNotNull { device ->
                val driver = probe(device) ?: return@mapNotNull null
                val granted = manager.hasPermission(device)
                fun name(read: () -> String?) = try {
                    clean(read())
                } catch (_: Exception) {
                    null
                }
                mapOf(
                    // Android's bus path: valid until unplugged, used only to
                    // ask for permission from the adapter list.
                    "device" to device.deviceName,
                    "vendorId" to device.vendorId,
                    "productId" to device.productId,
                    "manufacturer" to name { device.manufacturerName },
                    "product" to name { device.productName },
                    "serial" to if (serialReadable(manager, device)) serialOf(device) else null,
                    "driver" to driverName(driver),
                    "ports" to driver.ports.size.coerceIn(1, MAX_PORTS),
                    "permission" to granted,
                )
            }
            .take(MAX_ADAPTERS)
        return mapOf("usbHost" to usbHost, "adapters" to adapters)
    }

    private fun requestPermission(call: MethodCall, result: MethodChannel.Result) {
        val manager = usb ?: return result.error("noUsbHost", "USB host is unavailable", null)
        val device: UsbDevice = when (val name = call.argument<Any?>("device")) {
            null -> {
                val target = target(call) ?: return result.error("invalid", "Invalid USB serial port", null)
                when (val resolved = resolve(target)) {
                    is Found -> resolved.device
                    Ambiguous -> return result.error("ambiguous", "Several matching adapters", null)
                    NotFound -> return result.error("notFound", "Adapter not attached", null)
                }
            }
            is String -> manager.deviceList[name]
                ?: return result.error("notFound", "Adapter not attached", null)
            else -> return result.error("invalid", "Invalid USB device", null)
        }
        // Never a consent prompt for USB devices no serial driver claims.
        if (probe(device) == null) return result.error("unsupported", "Not a USB serial adapter", null)
        if (manager.hasPermission(device)) return result.success(true)
        if (!visible()) return result.error("background", "USB access needs the visible app", null)
        if (permission != null) return result.error("busy", "A USB permission request is already open", null)
        val timeout = Runnable { finishPermission() }
        permission = PendingPermission(device.deviceName, result, timeout)
        try {
            // Explicit (package-scoped) and immutable: the reply carries no
            // data we read, see the receiver.
            val intent = Intent(permissionAction).setPackage(activity.packageName)
            val pending = PendingIntent.getBroadcast(
                activity, REQUEST_PERMISSION, intent, PendingIntent.FLAG_IMMUTABLE,
            )
            manager.requestPermission(device, pending)
            // A lost broadcast must not wedge later requests; it fails closed.
            main.postDelayed(timeout, PERMISSION_TIMEOUT_MS)
        } catch (_: Exception) {
            permission = null
            result.success(false)
        }
    }

    private fun finishPermission() {
        val pending = permission ?: return
        permission = null
        main.removeCallbacks(pending.timeout)
        val manager = usb
        val device = manager?.deviceList?.get(pending.deviceName)
        pending.result.success(device != null && manager.hasPermission(device))
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        val target = target(call) ?: return result.error("invalid", "Invalid USB serial port", null)
        val baudRate = call.int("baudRate", MIN_BAUD..MAX_BAUD)
            ?: return result.error("invalid", "Invalid baud rate", null)
        val manager = usb ?: return result.error("noUsbHost", "USB host is unavailable", null)
        val device = when (val resolved = resolve(target)) {
            is Found -> resolved.device
            Ambiguous -> return result.error("ambiguous", "Several matching adapters", null)
            NotFound -> return result.error("notFound", "Adapter not attached", null)
        }
        if (!manager.hasPermission(device)) return result.error("permission", "USB access not granted", null)
        if (target.serial != null && serialOf(device) != target.serial) {
            return result.error("notFound", "Adapter not attached", null)
        }
        val driver = probe(device) ?: return result.error("unsupported", "Not a USB serial adapter", null)
        if (target.port >= driver.ports.size) return result.error("notFound", "No such port", null)
        val key = "${device.deviceName}#${target.port}"
        if (key in opening || sessions.values.any { it.key == key }) {
            return result.error("busy", "Port already open", null)
        }
        opening.add(key)
        val port = driver.ports[target.port]
        val task = Runnable {
            val outcome = openPort(manager, device, port, baudRate)
            main.post {
                opening.remove(key)
                if (outcome !is UsbSerialPort) {
                    result.error(outcome as String, "Couldn't open the USB serial port", null)
                } else if (closed) {
                    closeQuietly(outcome, null)
                    result.error("open", "Closed", null)
                } else {
                    val session = Session(nextSession++, key, device, outcome, baudRate)
                    sessions[session.id] = session
                    session.start()
                    result.success(mapOf("session" to session.id, "driver" to driverName(driver)))
                }
            }
        }
        try {
            opener.execute(task)
        } catch (_: Exception) {
            opening.remove(key)
            result.error("open", "Couldn't open the USB serial port", null)
        }
    }

    /** Background thread: the opened port, or an error code. */
    private fun openPort(manager: UsbManager, device: UsbDevice, port: UsbSerialPort, baudRate: Int): Any {
        var connection: UsbDeviceConnection? = null
        try {
            connection = manager.openDevice(device) ?: return "open"
            port.open(connection)
            try {
                port.setParameters(baudRate, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
            } catch (_: UnsupportedOperationException) {
                closeQuietly(port, connection)
                return "config"
            } catch (_: IllegalArgumentException) {
                closeQuietly(port, connection)
                return "config"
            }
            // Consoles (and adapters that gate their transmitter on them)
            // expect DTR/RTS asserted; not every chip can set them.
            try { port.setDTR(true) } catch (_: Exception) {}
            try { port.setRTS(true) } catch (_: Exception) {}
            return port
        } catch (_: Exception) {
            closeQuietly(port, connection)
            return "open"
        }
    }

    private fun closeQuietly(port: UsbSerialPort, connection: UsbDeviceConnection?) {
        try {
            if (port.isOpen) port.close()
        } catch (_: Exception) {
        }
        try {
            connection?.close()
        } catch (_: Exception) {
        }
    }

    private fun write(call: MethodCall, result: MethodChannel.Result) {
        val session = call.int("session", 1..Int.MAX_VALUE)?.let { sessions[it] }
            ?: return result.error("closed", "Session closed", null)
        val data = call.argument<Any?>("data") as? ByteArray
            ?: return result.error("invalid", "Expected bytes", null)
        if (data.isEmpty()) return result.success(0)
        if (data.size > MAX_INPUT || session.queuedBytes + data.size > MAX_INPUT) {
            return result.error("full", "Serial input queue is full", null)
        }
        session.queuedBytes += data.size
        session.writes.offer(Write(data, result))
    }

    /** Main thread. A null [reason] is a requested close (no event to Dart). */
    private fun end(session: Session, reason: String?) {
        if (sessions.remove(session.id) == null) return
        session.stop()
        if (reason != null && !closed) {
            channel.invokeMethod("closed", mapOf("session" to session.id, "reason" to reason))
        }
    }

    private fun attached(device: UsbDevice) = usb?.deviceList?.containsKey(device.deviceName) == true

    @Suppress("DEPRECATION")
    private fun detachedDevice(intent: Intent): UsbDevice? = if (Build.VERSION.SDK_INT >= 33) {
        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
    } else {
        intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
    }

    private class Write(val data: ByteArray, val result: MethodChannel.Result?)

    private inner class Session(
        val id: Int,
        val key: String,
        val device: UsbDevice,
        private val port: UsbSerialPort,
        baudRate: Int,
    ) {
        val writes = LinkedBlockingQueue<Write>()
        /** Main thread only: bytes queued for the writer, bounded by [MAX_INPUT]. */
        var queuedBytes = 0
        @Volatile private var ended = false
        private val lock = ReentrantLock()
        /** Signalled when an ack frees room or the session ends. */
        private val room = lock.newCondition()
        private var unacked = 0 // guarded by lock
        private val pending = ByteArrayOutputStream() // guarded by lock
        private var flushQueued = false // guarded by lock
        // About one second of line time per USB write, so the timeout below
        // measures a stalled device rather than a long paste at a low baud rate.
        private val writeChunk = (baudRate / 10).coerceIn(1, 4096)
        private val reader = Thread({ readLoop() }, "atermius-usb-serial-read-$id").apply { isDaemon = true }
        private val writer = Thread({ writeLoop() }, "atermius-usb-serial-write-$id").apply { isDaemon = true }

        fun start() {
            reader.start()
            writer.start()
        }

        /** Main thread; the writer closes the port once its current write ends. */
        fun stop() {
            ended = true
            lock.withLock { room.signalAll() }
            writes.offer(STOP)
        }

        fun ack(bytes: Int) = lock.withLock {
            unacked = (unacked - bytes).coerceAtLeast(0)
            room.signalAll()
        }

        private fun readLoop() {
            // Upstream's SerialInputOutputManager default: small adapter FIFOs
            // overflow if the reader is descheduled for long.
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
            } catch (_: Exception) {
            }
            val buffer = ByteArray((port.readEndpoint?.maxPacketSize ?: 64).coerceIn(64, 16384))
            try {
                while (!ended) {
                    // Timeout 0 queues a UsbRequest (upstream's recommendation
                    // against data loss); closing the port cancels it.
                    val count = port.read(buffer, 0)
                    if (count <= 0) continue
                    lock.withLock {
                        while (!ended && unacked + count > MAX_UNACKED_OUTPUT) room.await()
                        if (ended) return
                        unacked += count
                        pending.write(buffer, 0, count)
                        if (!flushQueued) {
                            flushQueued = true
                            main.post { flush() }
                        }
                    }
                }
            } catch (_: Exception) {
                if (ended) return
                // An unplugged adapter usually fails the read just before the
                // detach broadcast; give that a moment to report "detached".
                main.postDelayed({
                    if (sessions[id] === this) end(this, if (attached(device)) "read" else "detached")
                }, DETACH_GRACE_MS)
            }
        }

        /** Main thread: one platform message per batch of reads. */
        private fun flush() {
            val data = lock.withLock {
                flushQueued = false
                pending.toByteArray().also { pending.reset() }
            }
            if (data.isEmpty() || sessions[id] !== this) return
            channel.invokeMethod("data", mapOf("session" to id, "data" to data))
        }

        private fun writeLoop() {
            try {
                while (true) {
                    val item = writes.take()
                    if (item === STOP) break
                    if (ended) {
                        main.post { written(item, "closed") }
                        break
                    }
                    val error = try {
                        var offset = 0
                        while (offset < item.data.size) {
                            val next = minOf(item.data.size, offset + writeChunk)
                            port.write(item.data.copyOfRange(offset, next), WRITE_TIMEOUT_MS)
                            offset = next
                        }
                        null
                    } catch (_: SerialTimeoutException) {
                        "timeout"
                    } catch (_: Exception) {
                        "write"
                    }
                    main.post { written(item, error) }
                    if (error != null) break
                }
            } catch (_: InterruptedException) {
            } finally {
                // The writer owns the port's lifetime, so closing never races a
                // write in progress; it also cancels the reader's pending read.
                closeQuietly(port, null)
                ended = true
                lock.withLock { room.signalAll() }
                val left = ArrayList<Write>()
                writes.drainTo(left)
                left.filter { it !== STOP }.forEach { item -> main.post { written(item, "closed") } }
            }
        }

        /** Main thread: answers a write and ends the session on failure. */
        private fun written(item: Write, error: String?) {
            queuedBytes = (queuedBytes - item.data.size).coerceAtLeast(0)
            val result = item.result ?: return
            if (error == null) {
                result.success(item.data.size)
                return
            }
            result.error(error, "Serial write failed", null)
            if (error != "closed" && sessions[id] === this) {
                end(this, if (attached(device)) error else "detached")
            }
        }
    }

    companion object {
        private val STOP = Write(ByteArray(0), null)
        /** Same alphabet and length as the Dart port id (UsbSerialPortId). */
        private val SERIAL = Regex("[A-Za-z0-9._-]{1,64}")
        private val CONTROL = Regex("[\\p{Cntrl}\\p{Cf}]")
        private const val MAX_NAME = 64
        private const val MAX_PORTS = 16
        private const val MAX_ADAPTERS = 32
        private const val MIN_BAUD = 50
        private const val MAX_BAUD = 4_000_000
        /** Same bounds as the desktop serial Console (64 KiB). */
        private const val MAX_INPUT = 64 * 1024
        private const val MAX_UNACKED_OUTPUT = 64 * 1024
        private const val WRITE_TIMEOUT_MS = 2000
        private const val DETACH_GRACE_MS = 300L
        private const val PERMISSION_TIMEOUT_MS = 120_000L
        private const val REQUEST_PERMISSION = 0x5553
    }
}
