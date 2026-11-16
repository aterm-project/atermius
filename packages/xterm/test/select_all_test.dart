import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Future<(Terminal, TerminalController)> _pump(
  WidgetTester tester, {
  int lines = 0,
  ScrollbackOptions scrollback = const ScrollbackOptions(),
}) async {
  final terminal = Terminal(maxLines: 100000, scrollback: scrollback);
  final controller = TerminalController();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TerminalView(terminal, controller: controller, autofocus: true),
      ),
    ),
  );
  await tester.pump();
  for (var i = 0; i < lines; i++) {
    terminal.write('line $i\r\n');
  }
  terminal.write('prompt\$ ');
  await tester.pump();
  return (terminal, controller);
}

/// Ctrl+Shift+A, or Command+A on Apple platforms.
Future<void> _selectAll(WidgetTester tester) async {
  final apple = defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;
  final modifiers = apple
      ? [LogicalKeyboardKey.metaLeft]
      : [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft];
  for (final key in modifiers) {
    await tester.sendKeyDownEvent(key);
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
  for (final key in modifiers.reversed) {
    await tester.sendKeyUpEvent(key);
  }
  await tester.pump();
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets('select all takes the scrollback too on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final (terminal, controller) = await _pump(tester, lines: 300);
      expect(terminal.buffer.scrollBack, greaterThan(200));

      await _selectAll(tester);
      final selection = controller.selection!;
      expect(selection.begin.y, 0, reason: 'starts at the very first line');
      expect(selection.begin.x, 0);
      expect(selection.end.y, terminal.buffer.height - 1);

      final text = terminal.buffer.getText(selection);
      expect(text, startsWith('line 0\n'));
      expect(text, contains('\nline 150\n'));
      expect(text, contains('\nline 299\n'));
      expect(text, contains('prompt\$'));
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('and copies it, including lines held in the archive', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    // Small tiers: most of the 1,000 lines are archived, not plain lines.
    final (terminal, controller) = await _pump(
      tester,
      lines: 1000,
      scrollback: const ScrollbackOptions(hotLines: 40, blockLines: 16),
    );
    expect(terminal.mainBuffer.lines.stats.archivedLines, greaterThan(800));

    await _selectAll(tester);
    expect(controller.selection!.begin.y, 0);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(copied, hasLength(1));
    final lines = copied.single.split('\n');
    expect(lines.first, 'line 0');
    for (var i = 0; i < 1000; i++) {
      expect(lines[i], 'line $i');
    }

    // The selection stays on the same text while more output arrives.
    terminal.write('more\r\n');
    await tester.pump();
    expect(controller.selection!.begin.y, 0);
  });

  testWidgets('a full-screen program selects its screen', (tester) async {
    final (terminal, controller) = await _pump(tester, lines: 100);
    terminal.write('\x1b[?1049h\x1b[Hfull screen');
    await tester.pump();
    expect(terminal.isUsingAltBuffer, isTrue);

    await _selectAll(tester);
    final selection = controller.selection!;
    expect(selection.begin.y, 0);
    expect(selection.end.y, terminal.viewHeight - 1);
    final text = terminal.buffer.getText(selection);
    expect(text, contains('full screen'));
    expect(text, isNot(contains('line 5')));
  });
}
