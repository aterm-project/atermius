import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/console/local_console.dart';
import 'package:aterm_client/console/usb_serial_console.dart';
import 'package:aterm_client/console/usb_serial_port_id.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';

/// Android bridge stand-in on a private channel name: records every call
/// and answers through overridable handlers, like UsbSerialBridge.kt.
class _Native {
  _Native(this.channel) {
    _messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final handler = handlers[call.method];
      if (handler != null) return handler(call);
      return switch (call.method) {
        'requestPermission' => true,
        'open' => {'session': 7, 'driver': 'FTDI'},
        'write' => ((call.arguments as Map)['data'] as Uint8List).length,
        _ => null,
      };
    });
  }

  final MethodChannel channel;
  final calls = <MethodCall>[];
  final handlers = <String, FutureOr<Object?> Function(MethodCall)>{};

  static TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  List<MethodCall> named(String method) =>
      calls.where((call) => call.method == method).toList();

  /// A call from Kotlin to Dart ("data", "closed").
  Future<void> send(String method, Map<String, Object?> arguments) =>
      _messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  Future<void> data(int session, String text) => send('data', {
    'session': session,
    'data': Uint8List.fromList(utf8.encode(text)),
  });

  void dispose() => _messenger.setMockMethodCallHandler(channel, null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');

  late _Native native;
  late UsbSerialBridge bridge;
  var channelCount = 0;
  final port = UsbSerialPortId.tryParse('usb:0403:6001:A1')!;

  setUp(() {
    final channel = MethodChannel('test/usb_serial_${channelCount++}');
    native = _Native(channel);
    bridge = UsbSerialBridge(channel: channel);
  });
  tearDown(() {
    native.dispose();
    bridge.channel.setMethodCallHandler(null);
  });

  Future<String> readAll(Stream<String> output) => output.join();

  test(
    'asks for access, opens 8N1 at the baud rate and shows a banner',
    () async {
      final console = bridge.open(port, baudRate: 9600);
      await (console as LocalConsoleStartup).ready;
      expect(native.calls.map((c) => c.method), ['requestPermission', 'open']);
      expect(native.calls.first.arguments, {
        'vendorId': 0x0403,
        'productId': 0x6001,
        'serial': 'A1',
        'port': 0,
      });
      expect((native.calls.last.arguments as Map)['baudRate'], 9600);
      final text = readAll(console.output);
      await console.close();
      expect(await text, '[usb:0403:6001:A1 · 9600 baud · 8N1 · FTDI]\r\n');
      expect(await console.exitCode, 0);
      expect(native.named('close').single.arguments, {'session': 7});
    },
  );

  test('output is acknowledged only once the tab listens and while it is '
      'not paused', () async {
    final console = bridge.open(port, baudRate: 115200);
    await (console as LocalConsoleStartup).ready;
    await native.data(7, 'boot');
    expect(native.named('ack'), isEmpty, reason: 'nobody consumes it yet');

    final received = StringBuffer();
    final subscription = console.output.listen(received.write);
    await pumpEventQueue();
    expect(native.named('ack').single.arguments, {'session': 7, 'bytes': 4});

    subscription.pause();
    await native.data(7, 'login: ');
    await pumpEventQueue();
    expect(native.named('ack'), hasLength(1), reason: 'paused: hold the ack');
    subscription.resume();
    await pumpEventQueue();
    expect(native.named('ack').last.arguments, {'session': 7, 'bytes': 7});
    expect(received.toString(), endsWith('bootlogin: '));
    await subscription.cancel();
    await console.close();
  });

  test('input typed before the port opens is sent once it is open', () async {
    final permission = Completer<bool>();
    native.handlers['requestPermission'] = (_) => permission.future;
    final console = bridge.open(port, baudRate: 115200);
    console.input('root\r');
    await pumpEventQueue();
    expect(native.named('write'), isEmpty);
    permission.complete(true);
    await (console as LocalConsoleStartup).ready;
    await pumpEventQueue();
    final write = native.named('write').single.arguments as Map;
    expect(write['session'], 7);
    expect(utf8.decode(write['data'] as Uint8List), 'root\r');
    await console.close();
  });

  test('queued input is bounded to 64 KiB like the desktop Console', () async {
    final pending = Completer<Object?>();
    native.handlers['write'] = (_) => pending.future;
    final console = bridge.open(port, baudRate: 115200);
    await (console as LocalConsoleStartup).ready;
    final text = StringBuffer();
    final subscription = console.output.listen(text.write);

    console.input('x' * (usbSerialMaxInputBytes + 1));
    await pumpEventQueue();
    expect(native.named('write'), isEmpty, reason: 'rejected whole');
    expect(text.toString(), contains('The serial input queue is full'));

    console.input('a' * 40000);
    console.input('b' * 30000);
    await pumpEventQueue();
    expect(native.named('write'), hasLength(1), reason: '70000 > 64 KiB');
    pending.complete(40000);
    await pumpEventQueue();
    console.input('b' * 30000);
    await pumpEventQueue();
    expect(native.named('write'), hasLength(2));
    await subscription.cancel();
    await console.close();
  });

  test(
    'declined access fails startup with a clear message and never opens',
    () async {
      native.handlers['requestPermission'] = (_) => false;
      final console = bridge.open(port, baudRate: 115200);
      await expectLater(
        (console as LocalConsoleStartup).ready,
        throwsA(
          isA<LocalConsoleStartException>().having(
            (e) => e.message,
            'message',
            startsWith('USB access to the adapter was denied.'),
          ),
        ),
      );
      expect(await console.exitCode, 1);
      expect(native.named('open'), isEmpty);
    },
  );

  test('bridge error codes become localized startup messages', () async {
    Future<String> failure(String method, String code) async {
      native.handlers.clear();
      native.handlers[method] = (_) =>
          throw PlatformException(code: code, message: 'native detail');
      final console = bridge.open(port, baudRate: 115200);
      try {
        await (console as LocalConsoleStartup).ready;
        fail('startup should fail');
      } on LocalConsoleStartException catch (error) {
        return error.message;
      }
    }

    expect(
      await failure('requestPermission', 'notFound'),
      "The USB serial adapter usb:0403:6001:A1 isn't attached. Connect it, "
      'or choose an attached adapter in Add → Serial Console.',
    );
    expect(
      await failure('requestPermission', 'busy'),
      'Another USB access request is still open. Answer it first.',
    );
    expect(
      await failure('requestPermission', 'background'),
      startsWith('Android only asks for USB access while Atermius'),
    );
    expect(
      await failure('requestPermission', 'unsupported'),
      startsWith("This USB device isn't a supported serial adapter"),
    );
    expect(
      await failure('open', 'busy'),
      'This serial port is already open in another tab.',
    );
    expect(
      await failure('open', 'config'),
      "The serial port doesn't support this configuration.",
    );
    expect(
      await failure('open', 'unexpected'),
      'The serial Console failed to start.',
    );
  });

  test('unplugging ends the session with a visible message', () async {
    final console = bridge.open(port, baudRate: 115200);
    await (console as LocalConsoleStartup).ready;
    final text = readAll(console.output);
    await native.send('closed', {'session': 7, 'reason': 'detached'});
    expect(await console.exitCode, 1);
    expect(
      await text,
      endsWith('\r\n[The USB serial adapter was disconnected.]\r\n'),
    );
    console.input('ignored');
    await pumpEventQueue();
    expect(native.named('write'), isEmpty);
  });

  test('a failed write is reported through the session end reason', () async {
    native.handlers['write'] = (_) => throw PlatformException(code: 'timeout');
    final console = bridge.open(port, baudRate: 115200);
    await (console as LocalConsoleStartup).ready;
    final text = readAll(console.output);
    console.input('x');
    await pumpEventQueue();
    await native.send('closed', {'session': 7, 'reason': 'timeout'});
    expect(await console.exitCode, 1);
    expect(await text, endsWith('[Serial write timed out.]\r\n'));
  });

  test('events for other or closed sessions are ignored', () async {
    final console = bridge.open(port, baudRate: 115200);
    await (console as LocalConsoleStartup).ready;
    final text = readAll(console.output);
    await native.data(8, 'not mine');
    await native.send('closed', {'session': 8, 'reason': 'detached'});
    await console.close();
    await native.data(7, 'late');
    expect(await text, isNot(contains('not mine')));
    expect(await text, isNot(contains('late')));
    expect(await console.exitCode, 0);
  });

  test('closing while Android asks for access never opens the port', () async {
    final permission = Completer<bool>();
    native.handlers['requestPermission'] = (_) => permission.future;
    final console = bridge.open(port, baudRate: 115200);
    await pumpEventQueue();
    await console.close();
    expect(await console.exitCode, 0);
    await expectLater(
      (console as LocalConsoleStartup).ready,
      throwsA(isA<LocalConsoleStartException>()),
    );
    permission.complete(true);
    await pumpEventQueue();
    expect(native.named('open'), isEmpty);
  });

  test('closing while the port opens closes the session it gets', () async {
    final opened = Completer<Object?>();
    native.handlers['open'] = (_) => opened.future;
    final console = bridge.open(port, baudRate: 115200);
    await pumpEventQueue();
    await console.close();
    opened.complete({'session': 9, 'driver': 'CP210x'});
    await pumpEventQueue();
    expect(native.named('close').single.arguments, {'session': 9});
  });

  test('access is asked for one adapter at a time', () async {
    final first = Completer<bool>();
    var asked = 0;
    native.handlers['requestPermission'] = (_) {
      asked++;
      return asked == 1 ? first.future : true;
    };
    final a = bridge.open(port, baudRate: 115200);
    final b = bridge.open(
      UsbSerialPortId.tryParse('usb:1a86:7523')!,
      baudRate: 115200,
    );
    await pumpEventQueue();
    expect(native.named('requestPermission'), hasLength(1));
    native.handlers['open'] = (call) => {
      'session': (call.arguments as Map)['vendorId'] == 0x1a86 ? 2 : 1,
    };
    first.complete(true);
    await (a as LocalConsoleStartup).ready;
    await (b as LocalConsoleStartup).ready;
    expect(native.named('requestPermission'), hasLength(2));
    expect(
      (native.named('requestPermission').last.arguments as Map)['vendorId'],
      0x1a86,
    );
    await a.close();
    await b.close();
  });

  test('list keeps well-formed adapters and drops unsafe text', () async {
    native.handlers['list'] = (_) => {
      'usbHost': true,
      'adapters': [
        {
          'device': '/dev/bus/usb/001/004',
          'vendorId': 0x0403,
          'productId': 0x6010,
          'manufacturer': 'FTDI\u202e',
          'product': '  Dual RS232\u0000 ',
          'serial': 'FT 12',
          'driver': 'FTDI',
          'ports': 2,
          'permission': true,
        },
        {'device': '/dev/bus/usb/001/005', 'vendorId': 0x10000},
        {
          'device': '/dev/bus/usb/001/006',
          'vendorId': 0x10c4,
          'productId': 0xea60,
          'driver': 'CP210x<script>',
          'ports': 1,
        },
        'not a map',
      ],
    };
    final list = await bridge.list();
    expect(list.usbHost, isTrue);
    final adapter = list.adapters.single;
    expect(adapter.manufacturer, 'FTDI');
    expect(adapter.product, 'Dual RS232');
    expect(adapter.serial, isNull, reason: 'not representable in an id');
    expect(adapter.ports, 2);
    expect(adapter.permission, isTrue);
    expect(adapter.portId(1).toString(), 'usb:0403:6010#1');
  });

  test('openUsbSerialConsole rejects bad ports and baud rates up front', () {
    for (final (port, baud) in [
      ('COM3', 9600),
      ('usb:0403', 9600),
      ('usb:0403:6001', 49),
      ('usb:0403:6001', 4000001),
    ]) {
      expect(
        () => openUsbSerialConsole(port, baudRate: baud, bridge: bridge),
        throwsFormatException,
      );
    }
    expect(native.calls, isEmpty);
  });
}
