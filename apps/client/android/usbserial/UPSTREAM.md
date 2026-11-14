# usb-serial-for-android upstream and local patch

- Upstream: [mik3y/usb-serial-for-android](https://github.com/mik3y/usb-serial-for-android)
- Base release: tag `3.11.0` (2026-07-18). The newer 3.12.0 (2026-11-10) was
  only four days old when this was vendored; it adds CH34x RTS/CTS flow
  control, which the serial Console does not use, and lowers the CH34x baud
  rate deviation at 307200 baud. Pick it up with the next update.
- Source archive: https://github.com/mik3y/usb-serial-for-android/archive/refs/tags/3.11.0.tar.gz
  (sha256 `9fc12819db958e0e83bc3ec276600758e42e049ec528341c43954768a0793af4`,
  downloaded twice into fresh directories with identical hashes)
- Upstream license: MIT; the original `LICENSE.txt` is retained in this directory
- Vendored scope (verbatim from `usbSerialForAndroid/`): `proguard-rules.pro`,
  `src/main/AndroidManifest.xml` and these sources under
  `src/main/java/com/hoho/android/usbserial/`:
  - `driver/`: `UsbSerialDriver`, `UsbSerialPort`, `CommonUsbSerialPort`,
    `SerialTimeoutException`, `UsbId`, `ProbeTable`, `UsbSerialProber`,
    `CdcAcmSerialDriver`, `FtdiSerialDriver`, `Cp21xxSerialDriver`,
    `Ch34xSerialDriver`, `ProlificSerialDriver`
  - `util/`: `MonotonicClock`, `UsbUtils`, `HexDump` (CDC-ACM debug log only)
- Not vendored: `GsmModemSerialDriver`, `ChromeCcdSerialDriver`,
  `SerialInputOutputManager`, `XonXoffFilter`, tests, the example app, the
  upstream Gradle build (JitPack publishing) and the Gradle wrapper.
  Atermius has its own reader/writer threads with bounded buffers
  (`apps/client/android/app/src/main/kotlin/com/atermius/aterm_client/UsbSerialBridge.kt`).
- `build.gradle.kts` is ours: an Android library module `:usbserial` with the
  upstream namespace, `buildConfig` (Ch34x/Prolific read `BuildConfig.DEBUG`),
  the upstream consumer R8 rule and a compile-only `androidx.annotation`
  (`@IntDef`, source retention). It uses only the repositories the app build
  already has (google, mavenCentral); no JitPack.

## Local change

- `driver/UsbSerialProber.java`: `getDefaultProbeTable()` no longer registers
  `GsmModemSerialDriver` and `ChromeCcdSerialDriver`, which are not vendored.
  The default prober therefore matches CDC-ACM class devices and the FTDI,
  Silicon Labs CP210x, WCH CH340/CH341 and Prolific PL2303 IDs listed in each
  driver's `getSupportedDevices()`.

## Review notes (3.11.0)

The vendored code only issues USB control/bulk/interrupt transfers on a
`UsbDeviceConnection` the app opened after Android's USB permission prompt.
There is no file, network, process or native code; reflection is limited to
the probe table (`getSupportedDevices`/`probe` on the listed driver classes).
Device descriptors are untrusted input: drivers can throw unchecked exceptions
on malformed devices (for example a CDC control interface without endpoints),
so `UsbSerialBridge` catches every exception around probing, opening and I/O
and reports a failed open instead of crashing.

When updating, download the new tag's archive into an empty directory, record
its URL and SHA-256 here, diff the vendored files against it, re-apply the
`UsbSerialProber` change and re-run the Android compile check (Gradle task
`:app:compileDebugKotlin` from `apps/client/android`, for example with the
Gradle distribution a `flutter build apk --debug` downloaded, since no wrapper
script is checked in) and `apps/client/test/usb_serial_*_test.dart`.
