import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/console/local_console.dart';
import 'package:aterm_client/console/usb_serial_console.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/terminal/connect_progress.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/l10n_fixture.dart';

/// Console tabs over the real Android USB serial console, with the Kotlin
/// bridge replaced by a fake method channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('test/usb_serial_tab');
  late ClientDatabase database;
  late AppController app;
  late UsbSerialBridge bridge;
  late List<MethodCall> calls;
  late Map<String, FutureOr<Object?> Function(MethodCall)> handlers;

  List<String> methods() => calls.map((call) => call.method).toList();

  Future<void> fromNative(String method, Map<String, Object?> args) =>
      messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );

  setUp(() async {
    calls = [];
    handlers = {};
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final handler = handlers[call.method];
      if (handler != null) return handler(call);
      return switch (call.method) {
        'requestPermission' => true,
        'open' => {'session': 3, 'driver': 'CH34x'},
        'write' => ((call.arguments as Map)['data'] as Uint8List).length,
        _ => null,
      };
    });
    bridge = UsbSerialBridge(channel: channel);
    database = ClientDatabase.forTesting(NativeDatabase.memory());
    app = AppController(
      sodium: await SodiumSumoInit.init(),
      database: database,
      secureStore: ClientSecureStore(),
    )..stage = ClientStage.workspace;
    app.localConsoleOpenerForTesting = ({
      LocalShellLaunch? shell,
      String? serialPort,
      int baudRate = 115200,
    }) => openUsbSerialConsole(serialPort!, baudRate: baudRate, bridge: bridge);
  });

  tearDown(() async {
    await app.disconnectAllTerminalTabs();
    app.dispose();
    await database.close();
    messenger.setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
  });

  test('opens after access, routes I/O and shows why an unplugged adapter '
      'ended the tab', () async {
    await app.openConsoleTab(serialPort: 'usb:1a86:7523', baudRate: 9600);
    final tab = app.terminalTabs.single;
    expect(tab.state, 'connected');
    expect(tab.host?.name, 'usb:1a86:7523 · 9600');
    expect(tab.consoleSerialPort, 'usb:1a86:7523');
    expect(methods(), ['requestPermission', 'open']);

    await fromNative('data', {
      'session': 3,
      'data': Uint8List.fromList(utf8.encode('U-Boot> ')),
    });
    await pumpEventQueue();
    expect(tab.terminal.buffer.lines[1].toString(), contains('U-Boot>'));
    expect(methods(), contains('ack'));

    app.sendTerminalInputFor(tab.id, 'help\r');
    await pumpEventQueue();
    final write = calls.lastWhere((call) => call.method == 'write');
    expect(
      utf8.decode((write.arguments as Map)['data'] as Uint8List),
      'help\r',
    );

    await fromNative('closed', {'session': 3, 'reason': 'detached'});
    await pumpEventQueue();
    expect(tab.state, 'disconnected');
    final text = [
      for (var i = 0; i < tab.terminal.buffer.lines.length; i++)
        tab.terminal.buffer.lines[i].toString(),
    ].join('\n');
    expect(text, contains('The USB serial adapter was disconnected.'));
  });

  test('declined access leaves a failed tab with the reason; retry asks '
      'again', () async {
    handlers['requestPermission'] = (_) => false;
    await app.openConsoleTab(serialPort: 'usb:1a86:7523', baudRate: 115200);
    final tab = app.terminalTabs.single;
    expect(tab.console, isNull);
    expect(tab.state, 'disconnected');
    expect(tab.connectProgress.phase, ConnectPhase.failed);
    expect(
      tab.errorMessage,
      startsWith('USB access to the adapter was denied.'),
    );
    expect(methods(), ['requestPermission']);

    handlers.remove('requestPermission');
    expect(app.canRetryTerminalConnect(tab.id), isTrue);
    await app.retryTerminalConnect(tab.id);
    expect(app.terminalTabs, [tab]);
    expect(tab.state, 'connected');
    expect(tab.console, isNotNull);
    expect(methods(), ['requestPermission', 'requestPermission', 'open']);
  });

  test('closing the tab while Android asks for access never opens the '
      'port', () async {
    final permission = Completer<bool>();
    handlers['requestPermission'] = (_) => permission.future;
    final opening = app.openConsoleTab(serialPort: 'usb:1a86:7523');
    await pumpEventQueue();
    final tab = app.terminalTabs.single;
    expect(tab.state, 'connecting');
    await app.closeTerminalTab(tab.id);
    permission.complete(true);
    await opening;
    await pumpEventQueue();
    expect(methods(), ['requestPermission']);
    expect(app.terminalTabs, isEmpty);
  });

  test('Stop while Android asks for access ends the attempt', () async {
    final permission = Completer<bool>();
    handlers['requestPermission'] = (_) => permission.future;
    final opening = app.openConsoleTab(serialPort: 'usb:1a86:7523');
    await pumpEventQueue();
    final tab = app.terminalTabs.single;
    await app.cancelTerminalConnect(tab.id);
    permission.complete(true);
    await opening;
    await pumpEventQueue();
    expect(methods(), ['requestPermission']);
    expect(tab.console, isNull);
    expect(tab.state, 'disconnected');
  });

  test(
    'duplicating a USB serial tab reopens the same id, never a shell',
    () async {
      await app.openConsoleTab(serialPort: 'usb:1a86:7523', baudRate: 9600);
      handlers['open'] = (_) => throw PlatformException(code: 'busy');
      final copyId = await app.duplicateConsoleTab(app.terminalTabs.single.id);
      final copy = app.terminalTabFor(copyId)!;
      expect(copy.consoleSerialPort, 'usb:1a86:7523');
      expect(copy.consoleBaudRate, 9600);
      expect(copy.consoleShell, isNull);
      expect(
        copy.errorMessage,
        'This serial port is already open in another tab.',
      );
    },
  );
}
