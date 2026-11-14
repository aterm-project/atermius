import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'local_console_contract.dart';
import 'usb_serial_port_id.dart';

/// Android serial Console through USB-to-serial adapters (USB host / OTG),
/// backed by UsbSerialBridge.kt and the vendored usb-serial-for-android
/// drivers. The desktop COM and /dev/cu.* consoles live in
/// serial_console_io.dart; this file has no dart:io dependency so it can be
/// tested on any host.

const usbSerialChannel = MethodChannel('atermius/usb_serial');

/// Same bound as the desktop serial Console: typed or pasted bytes queued for
/// the adapter, and adapter output in flight before the tab took it.
const usbSerialMaxInputBytes = 64 * 1024;
const usbSerialMaxUnackedOutputBytes = 64 * 1024;

const _minBaud = 50, _maxBaud = 4000000;

/// Why a USB serial adapter could not be listed, asked for or used. The
/// Android bridge reports these as error codes; [usbSerialIssueMessage]
/// turns them into the text shown in the dialog and the Console tab.
enum UsbSerialIssue {
  noUsbHost,
  notAttached,
  ambiguous,
  unsupported,
  permissionDenied,
  background,
  permissionBusy,
  portBusy,
  invalid,
  configuration,
  openFailed,
  detached,
  readFailed,
  writeFailed,
  writeTimeout,
  inputFull,
  failed;

  /// [code] is a UsbSerialBridge.kt error code or session end reason. "busy"
  /// means another USB access prompt is open when asking for permission, and
  /// the port being open in another tab when opening it.
  static UsbSerialIssue fromCode(String? code, {bool permission = false}) =>
      switch (code) {
        'noUsbHost' => noUsbHost,
        'notFound' => notAttached,
        'ambiguous' => ambiguous,
        'unsupported' => unsupported,
        'permission' => permissionDenied,
        'background' => background,
        'busy' => permission ? permissionBusy : portBusy,
        'invalid' => invalid,
        'config' => configuration,
        'open' => openFailed,
        'detached' => detached,
        'read' => readFailed,
        'write' => writeFailed,
        'timeout' => writeTimeout,
        'full' => inputFull,
        _ => failed,
      };
}

String usbSerialIssueMessage(
  AppLocalizations l10n,
  UsbSerialIssue issue, {
  required String port,
}) => switch (issue) {
  UsbSerialIssue.noUsbHost => l10n.usbSerialNoUsbHost,
  UsbSerialIssue.notAttached => l10n.usbSerialNotAttached(port),
  UsbSerialIssue.ambiguous => l10n.usbSerialAmbiguous,
  UsbSerialIssue.unsupported => l10n.usbSerialUnsupported,
  UsbSerialIssue.permissionDenied => l10n.usbSerialPermissionDenied,
  UsbSerialIssue.background => l10n.usbSerialBackground,
  UsbSerialIssue.permissionBusy => l10n.usbSerialPermissionBusy,
  UsbSerialIssue.portBusy => l10n.usbSerialPortBusy,
  UsbSerialIssue.invalid => l10n.invalidSerialPortOrBaudRate,
  UsbSerialIssue.configuration => l10n.theSerialPortDoesntSupportThis,
  UsbSerialIssue.openFailed => l10n.usbSerialOpenFailed,
  UsbSerialIssue.detached => l10n.usbSerialDetached,
  UsbSerialIssue.readFailed => l10n.serialReadFailedOrTheDevice,
  UsbSerialIssue.writeFailed => l10n.serialWriteFailedOrTheDevice,
  UsbSerialIssue.writeTimeout => l10n.serialWriteTimedOut,
  UsbSerialIssue.inputFull => l10n.serialInputExceedsTheLimit,
  UsbSerialIssue.failed => l10n.theSerialConsoleFailedToStart,
};

class UsbSerialException implements Exception {
  const UsbSerialException(this.issue);
  final UsbSerialIssue issue;

  @override
  String toString() => 'UsbSerialException(${issue.name})';
}

final _controlCharacters = RegExp(r'[\p{Cc}\p{Cf}]', unicode: true);
final _driverPattern = RegExp(r'^[A-Za-z0-9 -]{1,16}$');

/// Device descriptor strings come from the adapter (untrusted): the bridge
/// already strips control and format characters; this keeps a second guard
/// so a name can never reorder or hide text in the dialog.
String? _displayText(Object? value) {
  if (value is! String) return null;
  final text = value.replaceAll(_controlCharacters, '').trim();
  if (text.isEmpty) return null;
  return text.length > 64 ? text.substring(0, 64) : text;
}

/// One attached adapter as listed by the Android bridge.
class UsbSerialAdapter {
  const UsbSerialAdapter({
    required this.device,
    required this.vendorId,
    required this.productId,
    required this.driver,
    this.manufacturer,
    this.product,
    this.serial,
    this.ports = 1,
    this.permission = false,
  });

  /// Android's device path for this attachment (changes on every replug).
  /// Only used to ask for access to exactly the adapter the user picked.
  final String device;
  final int vendorId, productId, ports;
  final String driver;
  final String? manufacturer, product;

  /// Readable once Android granted access (Android 10+ hides it before).
  final String? serial;
  final bool permission;

  static UsbSerialAdapter? tryParse(Map<Object?, Object?> map) {
    final device = map['device'],
        vendorId = map['vendorId'],
        productId = map['productId'],
        driver = map['driver'],
        ports = map['ports'],
        serial = map['serial'];
    if (device is! String ||
        device.isEmpty ||
        device.length > 128 ||
        device.contains(_controlCharacters) ||
        vendorId is! int ||
        vendorId < 0 ||
        vendorId > 0xffff ||
        productId is! int ||
        productId < 0 ||
        productId > 0xffff ||
        driver is! String ||
        !_driverPattern.hasMatch(driver) ||
        ports is! int ||
        ports < 1 ||
        ports > UsbSerialPortId.maxPort + 1) {
      return null;
    }
    return UsbSerialAdapter(
      device: device,
      vendorId: vendorId,
      productId: productId,
      driver: driver,
      manufacturer: _displayText(map['manufacturer']),
      product: _displayText(map['product']),
      // A serial number a port id cannot carry is left out; the adapter is
      // still listed and identified by vendor/product id alone.
      serial: serial is String && UsbSerialPortId.isValidSerial(serial)
          ? serial
          : null,
      ports: ports,
      permission: map['permission'] == true,
    );
  }

  UsbSerialPortId portId([int port = 0]) => UsbSerialPortId(
    vendorId: vendorId,
    productId: productId,
    serial: serial,
    port: port,
  );
}

class UsbSerialAdapterList {
  const UsbSerialAdapterList({required this.usbHost, required this.adapters});

  /// False when the device has no USB host (OTG) support.
  final bool usbHost;
  final List<UsbSerialAdapter> adapters;
}

/// What the serial Console dialog needs from the platform; a fake in tests.
abstract interface class UsbSerialAccess {
  Future<UsbSerialAdapterList> list();

  /// Shows Android's USB access prompt for one adapter, either the listed
  /// [device] the user picked or the adapter a saved [port] id resolves to.
  /// True when access is granted (also when it already was), false when the
  /// user declined. Throws [UsbSerialException] when the adapter cannot be
  /// asked for (not attached, ambiguous, not a serial adapter, app in the
  /// background). Requests are asked one at a time.
  Future<bool> requestPermission({String? device, UsbSerialPortId? port});
}

/// Dart side of UsbSerialBridge.kt. One instance owns the channel's incoming
/// calls ("data" and "closed" for open sessions).
class UsbSerialBridge implements UsbSerialAccess {
  UsbSerialBridge({this.channel = usbSerialChannel}) {
    channel.setMethodCallHandler(_handle);
  }

  static UsbSerialBridge? _instance;
  static UsbSerialBridge get instance => _instance ??= UsbSerialBridge();

  final MethodChannel channel;
  final _sessions = <int, _UsbSerialConsole>{};

  /// Completes when the previous permission request finished: Android shows
  /// one USB prompt at a time and the bridge rejects a second one, so a
  /// window combination with two adapters asks for them in turn.
  Future<void> _permissionTurn = Future<void>.value();

  Future<Object?> _handle(MethodCall call) async {
    final args = call.arguments;
    if (args is! Map) return null;
    final session = args['session'];
    final console = session is int ? _sessions[session] : null;
    if (console == null) return null;
    switch (call.method) {
      case 'data':
        final data = args['data'];
        if (data is Uint8List && data.isNotEmpty) console._received(data);
      case 'closed':
        final reason = args['reason'];
        console._ended(
          UsbSerialIssue.fromCode(reason is String ? reason : null),
        );
    }
    return null;
  }

  static Map<String, Object?> _portArguments(UsbSerialPortId port) => {
    'vendorId': port.vendorId,
    'productId': port.productId,
    'serial': port.serial,
    'port': port.port,
  };

  Future<T?> _invoke<T>(
    String method, [
    Object? arguments,
    bool permission = false,
  ]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw UsbSerialException(
        UsbSerialIssue.fromCode(error.code, permission: permission),
      );
    } on MissingPluginException {
      throw const UsbSerialException(UsbSerialIssue.failed);
    }
  }

  @override
  Future<UsbSerialAdapterList> list() async {
    final result = await _invoke<Object?>('list');
    if (result is! Map) throw const UsbSerialException(UsbSerialIssue.failed);
    final raw = result['adapters'];
    return UsbSerialAdapterList(
      usbHost: result['usbHost'] == true,
      adapters: List.unmodifiable(
        (raw is List ? raw : const [])
            .whereType<Map<Object?, Object?>>()
            .map(UsbSerialAdapter.tryParse)
            .whereType<UsbSerialAdapter>(),
      ),
    );
  }

  @override
  Future<bool> requestPermission({
    String? device,
    UsbSerialPortId? port,
  }) async {
    if ((device == null) == (port == null)) {
      throw ArgumentError('Pass exactly one of device and port');
    }
    final previous = _permissionTurn;
    final turn = Completer<void>();
    _permissionTurn = turn.future;
    try {
      await previous;
      final granted = await _invoke<bool>(
        'requestPermission',
        device != null ? {'device': device} : _portArguments(port!),
        true,
      );
      return granted == true;
    } finally {
      turn.complete();
    }
  }

  /// Opens [port] at 8N1 without flow control. The returned console asks for
  /// USB access first when Android has not granted it (see
  /// [LocalConsoleStartup.ready]).
  LocalConsole open(UsbSerialPortId port, {required int baudRate}) {
    if (baudRate < _minBaud || baudRate > _maxBaud) {
      throw FormatException(currentL10n.invalidSerialPortOrBaudRate);
    }
    return _UsbSerialConsole(this, port, baudRate);
  }

  Future<({int session, String? driver})> _open(
    UsbSerialPortId port,
    int baudRate,
  ) async {
    final result = await _invoke<Object?>('open', {
      ..._portArguments(port),
      'baudRate': baudRate,
    });
    final session = result is Map ? result['session'] : null;
    if (session is! int || session <= 0) {
      throw const UsbSerialException(UsbSerialIssue.openFailed);
    }
    final driver = (result as Map)['driver'];
    return (
      session: session,
      driver: driver is String && _driverPattern.hasMatch(driver)
          ? driver
          : null,
    );
  }

  Future<void> _write(int session, Uint8List data) =>
      _invoke<Object?>('write', {'session': session, 'data': data});

  void _ack(int session, int bytes) {
    unawaited(
      _invoke<Object?>('ack', {
        'session': session,
        'bytes': bytes,
      }).catchError((Object _) => null),
    );
  }

  Future<void> _close(int session) =>
      _invoke<Object?>('close', {'session': session});
}

/// Opens the Android USB serial Console for a `usb:` port id (see
/// [UsbSerialPortId]); anything else is rejected before touching USB.
LocalConsole openUsbSerialConsole(
  String port, {
  int baudRate = 115200,
  UsbSerialBridge? bridge,
}) {
  final id = UsbSerialPortId.tryParse(port);
  if (id == null || baudRate < _minBaud || baudRate > _maxBaud) {
    throw FormatException(currentL10n.invalidSerialPortOrBaudRate);
  }
  return (bridge ?? UsbSerialBridge.instance).open(id, baudRate: baudRate);
}

class _UsbSerialConsole implements LocalConsole, LocalConsoleStartup {
  _UsbSerialConsole(this._bridge, this._port, this._baudRate) {
    _output = StreamController<List<int>>(
      onListen: _acknowledge,
      onResume: _acknowledge,
    );
    // Callers that never await [ready] must not see an unhandled error.
    unawaited(_ready.future.then<void>((_) {}, onError: (Object _) {}));
    unawaited(_start());
  }

  final UsbSerialBridge _bridge;
  final UsbSerialPortId _port;
  final int _baudRate;
  late final StreamController<List<int>> _output;
  final _exit = Completer<int>();
  final _ready = Completer<void>();

  /// Input typed while Android's USB prompt is open, sent once the port is.
  final _waiting = <Uint8List>[];

  /// Input bytes queued or in flight to the adapter (bounded like desktop).
  int _inputBytes = 0;

  /// Adapter output received but not yet acknowledged. The bridge stops
  /// reading at [usbSerialMaxUnackedOutputBytes], so output nobody consumes
  /// (no listener yet, or a paused one) backs up into the adapter instead of
  /// memory.
  int _unacked = 0;
  int? _session;
  bool _closed = false;

  @override
  Stream<String> get output =>
      _output.stream.transform(const Utf8Decoder(allowMalformed: true));

  @override
  Future<int> get exitCode => _exit.future;

  @override
  Future<void> get ready => _ready.future;

  Future<void> _start() async {
    try {
      if (!await _bridge.requestPermission(port: _port)) {
        throw const UsbSerialException(UsbSerialIssue.permissionDenied);
      }
      if (_closed) return;
      final opened = await _bridge._open(_port, _baudRate);
      if (_closed) {
        // Closed (tab closed, Stop) while the port was opening.
        unawaited(_bridge._close(opened.session).catchError((Object _) {}));
        return;
      }
      _session = opened.session;
      _bridge._sessions[opened.session] = this;
      final driver = opened.driver == null ? '' : ' · ${opened.driver}';
      _output.add(utf8.encode('[$_port · $_baudRate baud · 8N1$driver]\r\n'));
      _ready.complete();
      final waiting = List.of(_waiting);
      _waiting.clear();
      waiting.forEach(_send);
    } on UsbSerialException catch (error) {
      _fail(error.issue);
    } catch (_) {
      _fail(UsbSerialIssue.failed);
    }
  }

  void _fail(UsbSerialIssue issue) {
    final message = usbSerialIssueMessage(currentL10n, issue, port: '$_port');
    if (!_ready.isCompleted) {
      _ready.completeError(LocalConsoleStartException(message));
    }
    _finish(1, message);
  }

  void _finish(int code, [String? message]) {
    final session = _session;
    if (session != null && identical(_bridge._sessions[session], this)) {
      _bridge._sessions.remove(session);
    }
    _waiting.clear();
    _inputBytes = 0;
    if (_exit.isCompleted) return;
    if (message != null) _output.add(utf8.encode('\r\n[$message]\r\n'));
    _exit.complete(code);
    unawaited(_output.close());
  }

  /// The adapter ended the session (unplugged, read/write failure).
  void _ended(UsbSerialIssue issue) => _fail(issue);

  void _received(Uint8List data) {
    if (_exit.isCompleted) return;
    _unacked += data.length;
    _output.add(data);
    _acknowledge();
  }

  void _acknowledge() {
    final session = _session;
    if (session == null ||
        _unacked == 0 ||
        _exit.isCompleted ||
        !_output.hasListener ||
        _output.isPaused) {
      return;
    }
    final bytes = math.min(_unacked, usbSerialMaxUnackedOutputBytes);
    _unacked -= bytes;
    _bridge._ack(session, bytes);
  }

  @override
  void input(String text) {
    if (_closed || _exit.isCompleted) return;
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (bytes.isEmpty) return;
    if (bytes.length > usbSerialMaxInputBytes ||
        _inputBytes + bytes.length > usbSerialMaxInputBytes) {
      _output.add(utf8.encode(currentL10n.theSerialInputQueueIsFull));
      return;
    }
    _inputBytes += bytes.length;
    if (_session == null) {
      _waiting.add(bytes);
      return;
    }
    _send(bytes);
  }

  void _send(Uint8List bytes) {
    final session = _session;
    if (session == null || _exit.isCompleted) return;
    unawaited(
      _bridge
          ._write(session, bytes)
          .then<void>(
            (_) {},
            onError: (Object error) {
              // A failed or timed-out write ends the session on the Android
              // side, which reports why through "closed". Only a full native
              // queue (not expected: both sides use the same bound) is
              // reported here; that input was dropped whole.
              if (error is UsbSerialException &&
                  error.issue == UsbSerialIssue.inputFull &&
                  !_exit.isCompleted) {
                _output.add(utf8.encode(currentL10n.theSerialInputQueueIsFull));
              }
            },
          )
          .whenComplete(() {
            if (_session == session && !_exit.isCompleted) {
              _inputBytes = math.max(0, _inputBytes - bytes.length);
            }
          }),
    );
  }

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final session = _session;
    if (!_ready.isCompleted) {
      _ready.completeError(
        LocalConsoleStartException(currentL10n.theSerialConsoleFailedToStart),
      );
    }
    _finish(0);
    if (session == null) return;
    try {
      await _bridge._close(session).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}
