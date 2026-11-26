import 'package:aterm_client/mcp/mcp_service.dart';
import 'package:aterm_client/platform/application_windows.dart';
import 'package:aterm_client/platform/mcp_background_host.dart';
import 'package:aterm_client/platform/window_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Only what the host reads: whether MCP runs, and change notifications.
class _Mcp extends ChangeNotifier implements McpService {
  bool isRunning = true;
  @override
  bool get running => isRunning;
  @override
  bool get starting => false;
  void set(bool value) {
    isRunning = value;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('atermius/window_chrome_test');
  late List<MethodCall> calls;
  late bool trayAvailable;
  late WindowChromeController chrome;
  late ApplicationWindows windows;
  late _Mcp mcp;
  late McpBackgroundHost host;

  Future<void> fromNative(String method) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
      (_) {},
    );
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<String> methods() => [
    for (final call in calls)
      if (call.method != 'enable' && call.method != 'enableCloseGuard')
        call.method,
  ];

  setUp(() async {
    calls = [];
    trayAvailable = true;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      switch (call.method) {
        case 'enable':
          return {
            'enabled': true,
            'maximized': false,
            'minimized': false,
            'focused': true,
          };
        case 'showTray':
          return trayAvailable;
      }
      return null;
    });
    chrome = WindowChromeController(channel: channel, supported: true);
    windows = ApplicationWindows(windowChrome: chrome);
    await windows.start();
    mcp = _Mcp();
    host = McpBackgroundHost(
      service: mcp,
      chrome: chrome,
      windows: windows,
      texts: () => const McpBackgroundTexts(
        tooltip: 'Atermius — MCP 8765',
        open: 'Open',
        quit: 'Quit',
        noticeTitle: 'Still running',
        notice: 'Click the icon',
      ),
    );
  });

  tearDown(() {
    host.dispose();
    chrome.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'closing with MCP running hides to the tray instead of quitting',
    () async {
      await fromNative('closeRequested');
      expect(methods(), ['showTray', 'hide']);
      expect(host.hidden, isTrue);
      final tray = calls.firstWhere((call) => call.method == 'showTray');
      expect(tray.arguments, {
        'tooltip': 'Atermius — MCP 8765',
        'open': 'Open',
        'quit': 'Quit',
        'noticeTitle': 'Still running',
        'notice': 'Click the icon',
      });

      // The tray icon opens the window again.
      await fromNative('trayOpen');
      expect(methods(), ['showTray', 'hide', 'hideTray', 'show']);
      expect(host.hidden, isFalse);

      // The notification is shown only the first time.
      calls.clear();
      await fromNative('closeRequested');
      final again = calls.firstWhere((call) => call.method == 'showTray');
      expect((again.arguments as Map)['notice'], '');
      expect(methods(), ['showTray', 'hide']);
    },
  );

  test('Quit from the tray closes for real', () async {
    await fromNative('closeRequested');
    calls.clear();
    await fromNative('trayQuit');
    expect(methods(), ['hideTray', 'closeNow']);
  });

  test(
    'without MCP, or without a tray icon, closing quits as before',
    () async {
      mcp.isRunning = false;
      await fromNative('closeRequested');
      expect(methods(), ['closeNow']);
      expect(host.hidden, isFalse);

      // A fresh window controller: the first one is closing.
      host.dispose();
      chrome.dispose();
      calls.clear();
      chrome = WindowChromeController(channel: channel, supported: true);
      windows = ApplicationWindows(windowChrome: chrome);
      await windows.start();
      mcp = _Mcp();
      trayAvailable = false;
      host = McpBackgroundHost(
        service: mcp,
        chrome: chrome,
        windows: windows,
        texts: () => const McpBackgroundTexts(
          tooltip: 't',
          open: 'o',
          quit: 'q',
          noticeTitle: '',
          notice: '',
        ),
      );
      await fromNative('closeRequested');
      expect(methods(), ['showTray', 'closeNow']);
      expect(host.hidden, isFalse);
    },
  );

  test('when MCP stops in the background the window comes back', () async {
    await fromNative('closeRequested');
    calls.clear();
    mcp.set(false);
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(methods(), ['hideTray', 'show']);
    expect(host.hidden, isFalse);
  });

  test('a quit while hidden (another window updating) stays out of sight',
      () async {
    await fromNative('closeRequested');
    calls.clear();
    var exits = 0;
    // MCP stops as the workspace closes during the quit.
    windows.registerOwnerCloser(Object(), () async => mcp.set(false));
    windows.beforeExit = () async => exits++;
    await windows.requestParentClose(quit: true);
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(methods(), isNot(contains('show')));
    expect(methods().last, 'closeNow');
    expect(exits, 1);
  });
}
