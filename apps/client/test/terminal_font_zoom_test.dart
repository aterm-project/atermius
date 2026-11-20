import 'package:aterm_client/ui/terminal_font_zoom.dart';
import 'package:aterm_client/ui/terminal_keybar.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  const mobile = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

  testWidgets(
    'white pane handle exposes text-size reset for its terminal',
    variant: mobile,
    (tester) async {
      final terminal = Terminal();
      final workspace = SessionWorkspaceController()..activate('test-terminal');
      addTearDown(workspace.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionWorkspaceView(
              controller: workspace,
              terminalBuilder: (context, _) => TerminalFontZoom(
                terminal: terminal,
                builder: (context, scale) => TerminalView(
                  terminal,
                  textStyle: TerminalStyle(fontSize: 16 * scale),
                  showKeyboardOnTap: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _pinch(tester, 100, 200);
      expect(_fontSize(tester), 32);
      await tester.tap(find.byKey(const ValueKey('pane-handle-test-terminal')));
      await tester.pumpAndSettle();
      final reset = find.byKey(const ValueKey('terminal-font-zoom-reset'));
      expect(reset, findsOneWidget);
      await tester.tap(reset);
      await tester.pump();
      expect(_fontSize(tester), 16);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'pinching changes glyph size and terminal dimensions without remote input; '
    'expanded keybar restores the configured size',
    variant: mobile,
    (tester) async {
      final terminal = Terminal();
      final output = <String>[];
      terminal.onOutput = output.add;
      terminal.write('\x1b[?1049h\x1b[?1000hhello');
      await _mount(tester, terminal);
      final originalColumns = terminal.viewWidth;

      await _pinch(tester, 100, 200);
      expect(_fontSize(tester), closeTo(26, .01));
      expect(terminal.viewWidth, lessThan(originalColumns));
      expect(output, isEmpty);

      await _pinch(tester, 200, 100);
      expect(_fontSize(tester), closeTo(13, .01));
      await _pinch(tester, 100, 150);
      expect(_fontSize(tester), closeTo(19.5, .01));

      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      final reset = find.text('Reset text size');
      await tester.ensureVisible(reset);
      await tester.tap(reset);
      await tester.pump();
      expect(_fontSize(tester), 13);
      expect(terminal.viewWidth, originalColumns);
      expect(output, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scale is bounded, survives rebuilds and cancellation, and is per terminal',
    variant: mobile,
    (tester) async {
      final first = Terminal();
      final second = Terminal();
      await _mount(tester, first);
      await _pinch(tester, 40, 400);
      expect(_fontSize(tester), 39);
      await _pinch(tester, 400, 20);
      expect(_fontSize(tester), 6.5);

      final center = tester.getCenter(find.byType(TerminalView));
      final left = await tester.startGesture(
        center - const Offset(50, 0),
        pointer: 1,
      );
      final right = await tester.startGesture(
        center + const Offset(50, 0),
        pointer: 2,
      );
      await left.moveTo(center - const Offset(100, 0));
      await tester.pump();
      await _mount(tester, first, fontSize: 16);
      await right.moveTo(center + const Offset(100, 0));
      await tester.pump();
      expect(
        _fontSize(tester),
        closeTo(16, .01),
        reason: 'a rebuild must not compound the gesture scale',
      );
      await left.cancel();
      await right.cancel();
      await tester.pump();

      await _mount(tester, second);
      expect(_fontSize(tester), 13);
      await _mount(tester, first, fontSize: 16);
      expect(_fontSize(tester), closeTo(16, .01));
      await _pinch(tester, 100, 150);
      expect(_fontSize(tester), closeTo(24, .01));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'single finger scroll and long press selection still work',
    variant: mobile,
    (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      final scroll = ScrollController();
      addTearDown(controller.dispose);
      addTearDown(scroll.dispose);
      terminal.write(
        List.generate(100, (i) => 'line $i alpha beta\r\n').join(),
      );
      await _mount(tester, terminal, controller: controller, scroll: scroll);
      final original = scroll.offset;
      final center = tester.getCenter(find.byType(TerminalView));
      final drag = await tester.startGesture(center);
      await drag.moveBy(const Offset(0, 30));
      await tester.pump();
      await drag.moveBy(const Offset(0, 120));
      await tester.pump();
      await drag.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(original));
      expect(_fontSize(tester), 13);

      final view = tester.state<TerminalViewState>(find.byType(TerminalView));
      final render = view.renderTerminal;
      final cell = render.localToGlobal(
        Offset(render.cellSize.width * 1.5, render.cellSize.height * 3.5),
      );
      final press = await tester.startGesture(cell);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(controller.selection, isNotNull);
      await press.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'desktop terminal keeps its saved font size',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      await _mount(tester, Terminal());
      await _pinch(tester, 100, 200);
      expect(_fontSize(tester), 13);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _mount(
  WidgetTester tester,
  Terminal terminal, {
  double fontSize = 13,
  TerminalController? controller,
  ScrollController? scroll,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: TerminalFontZoom(
                terminal: terminal,
                builder: (context, scale) => TerminalView(
                  terminal,
                  controller: controller,
                  scrollController: scroll,
                  autofocus: false,
                  showKeyboardOnTap: false,
                  textStyle: TerminalStyle(fontSize: fontSize * scale),
                ),
              ),
            ),
            TerminalKeybar(terminal: terminal),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _fontSize(WidgetTester tester) =>
    tester.widget<TerminalView>(find.byType(TerminalView)).textStyle.fontSize;

Future<void> _pinch(WidgetTester tester, double from, double to) async {
  final center = tester.getCenter(find.byType(TerminalView));
  final left = await tester.startGesture(
    center - Offset(from / 2, 0),
    pointer: 1,
  );
  final right = await tester.startGesture(
    center + Offset(from / 2, 0),
    pointer: 2,
  );
  await left.moveTo(center - Offset(to / 2, 0));
  await right.moveTo(center + Offset(to / 2, 0));
  await tester.pump();
  await left.up();
  await right.up();
  await tester.pumpAndSettle();
}
