import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/ui/terminal_link_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('hover and mouse click on a wrapped URL show its destination', (
    tester,
  ) async {
    const url = 'https://example.test:8443/path_(a)?x=1#part';
    final terminal = Terminal()..resize(24, 5);
    terminal.write('日志：\x1b[32m($url),\x1b[0m');
    final launches = <String>[];
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'launch');
      expect(call.arguments['useSafariVC'], isFalse);
      launches.add(call.arguments['url'] as String);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final view = await _mountTerminal(tester, terminal, showTerminalLink);
    final render = view.renderTerminal;
    final link = render.localToGlobal(
      render.cellRect(const CellOffset(5, 1)).center,
    );
    final gap = render.localToGlobal(
      render.cellRect(const CellOffset(15, 2)).center,
    );
    const mouseDevice = 1;
    final mouse = TestGesture(
      dispatcher: tester.sendEventToBinding,
      kind: PointerDeviceKind.mouse,
      device: mouseDevice,
    );
    await mouse.addPointer(location: link);
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(
        mouseDevice,
      ),
      SystemMouseCursors.click,
    );
    expect(launches, isEmpty);

    await mouse.moveTo(gap);
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(
        mouseDevice,
      ),
      SystemMouseCursors.text,
    );
    await mouse.down(link);
    await mouse.up();
    await tester.pumpAndSettle();

    expect(find.text('Open terminal link?'), findsOneWidget);
    expect(find.text(url), findsOneWidget);
    expect(launches, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(launches, isEmpty);
    await mouse.down(link);
    await mouse.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open in browser'));
    await tester.pumpAndSettle();
    expect(launches, [url]);
    await mouse.removePointer();
    await tester.pumpAndSettle();
  });

  testWidgets('touch can open plain web links in a read-only terminal', (
    tester,
  ) async {
    const columns = 64;
    const prefix = 'http://[::1]:8080/';
    // Place the first wide path character across a soft wrap.
    final padding = ' ' * (columns - prefix.length - 1);
    final terminal = Terminal()..resize(columns, 6);
    terminal.write(
      'www.example.test/path\r\n'
      '$padding$prefix路径\r\n'
      'https://user@example.test\r\n'
      'javascript:void(0)\r\n'
      '\x1b]8;;https://example.test\x07hidden target\x1b]8;;\x07',
    );
    final links = <Uri>[];
    final view = await _mountTerminal(
      tester,
      terminal,
      (_, uri) => links.add(uri),
      readOnly: true,
    );
    final render = view.renderTerminal;
    for (final cell in const [
      CellOffset(5, 0),
      CellOffset(0, 2),
      CellOffset(5, 3),
      CellOffset(5, 4),
      CellOffset(5, 5),
    ]) {
      await tester.tapAt(render.localToGlobal(render.cellRect(cell).center));
      await tester.pumpAndSettle();
      await tester.pump(kDoubleTapTimeout);
    }
    expect(links, [
      Uri.parse('https://www.example.test/path'),
      Uri.parse('http://[::1]:8080/路径'),
    ]);
    expect(view.hasInputConnection, isFalse);
  });

  testWidgets(
    'live mouse reporting takes precedence and dragging selects text',
    (tester) async {
      final terminal = Terminal()..resize(50, 5);
      terminal.write('https://example.test');
      final output = <String>[];
      terminal.onOutput = output.add;
      final links = <Uri>[];
      final controller = TerminalController();
      addTearDown(controller.dispose);

      final view = await _mountTerminal(
        tester,
        terminal,
        (_, uri) => links.add(uri),
        controller: controller,
      );
      final render = view.renderTerminal;
      final start = render.localToGlobal(
        render.cellRect(const CellOffset(0, 0)).center,
      );
      final end = render.localToGlobal(
        render.cellRect(const CellOffset(19, 0)).center,
      );

      terminal.write('\x1b[?1000h\x1b[?1006h');
      await tester.pump();
      await tester.tapAt(start, kind: PointerDeviceKind.mouse);
      await tester.pump(kDoubleTapTimeout);
      expect(output, ['\x1b[<0;1;1M', '\x1b[<0;1;1m']);
      expect(links, isEmpty);

      terminal.write('\x1b[?1000l');
      await tester.pump();
      final drag = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await drag.moveTo(end);
      await drag.up();
      await tester.pumpAndSettle();
      expect(
        terminal.buffer.getText(controller.selection!),
        startsWith('https://'),
      );
      expect(links, isEmpty);
    },
  );
}

Future<TerminalViewState> _mountTerminal(
  WidgetTester tester,
  Terminal terminal,
  void Function(BuildContext, Uri) onLinkTap, {
  bool readOnly = false,
  TerminalController? controller,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: TerminalView(
          terminal,
          autoResize: false,
          controller: controller,
          readOnly: readOnly,
          onLinkTap: onLinkTap,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<TerminalViewState>(find.byType(TerminalView));
}
