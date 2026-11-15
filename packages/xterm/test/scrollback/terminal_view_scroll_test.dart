import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

import 'helpers.dart';

void main() {
  testWidgets('a view scrolls deep into archived history and back',
      (tester) async {
    final terminal = Terminal(maxLines: 100000);
    final controller = TerminalController();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 480,
            child: TerminalView(
              terminal,
              controller: controller,
              scrollController: scroll,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final random = Random(1);
    for (var i = 0; i < 30000; i++) {
      terminal.write(
          '${i.toString().padLeft(5, '0')} ${coloredLine(random, i, width: 40)}\r\n');
    }
    await tester.pump();

    final lines = terminal.buffer.lines;
    final stats = lines.stats;
    expect(stats.archivedLines, greaterThan(27000));
    expect(stats.cachedBlocks, 0, reason: 'the live screen is all plain lines');

    // The scroll extent covers the whole history, archived or not.
    final position = scroll.position;
    final rowHeight =
        (position.maxScrollExtent + position.viewportDimension) / lines.length;
    expect(rowHeight, greaterThan(5));
    expect(position.pixels, position.maxScrollExtent);

    // To the very top.
    scroll.jumpTo(0);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(lines.stats.cachedBlocks, inInclusiveRange(1, 2));
    expect(lines[0].getText(), startsWith('00000 '));

    // Painting again reads the same restored block, nothing is inflated
    // per frame.
    final cached = lines.stats.cachedBlocks;
    for (var frame = 0; frame < 10; frame++) {
      tester.renderObject(find.byType(TerminalView)).markNeedsPaint();
      await tester.pump();
    }
    expect(lines.stats.cachedBlocks, cached);

    // Through the middle, a screen at a time, across many blocks.
    for (var row = 9000; row < 12000; row += 37) {
      scroll.jumpTo(row * rowHeight);
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    expect(lines.stats.cachedBlocks, lessThanOrEqualTo(4));

    // A selection made in the archive is painted and copied from there.
    final base = terminal.buffer.createAnchor(0, 11000);
    final extent = terminal.buffer.createAnchor(5, 11002);
    controller.setSelection(base, extent);
    scroll.jumpTo(10990 * rowHeight);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(controller.selection, isNotNull);
    final copied = terminal.buffer.getText(controller.selection);
    expect(copied, startsWith('11000 '));
    expect(copied, endsWith('\n11002'));

    // Output keeps arriving while the view stays in the history; the
    // selected text does not move because nothing has been dropped.
    for (var i = 30000; i < 34000; i++) {
      terminal.write('${i.toString().padLeft(5, '0')} more output\r\n');
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(terminal.buffer.getText(controller.selection), copied);
    expect(controller.selection!.begin.y, 11000);

    // And back to the live screen.
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(lines[lines.length - 2].getText(), '33999 more output');

    controller.clearSelection();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the oldest lines are dropped under a view in the history',
      (tester) async {
    final terminal = Terminal(maxLines: 5000);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal, scrollController: scroll),
        ),
      ),
    );
    for (var i = 0; i < 5000; i++) {
      terminal.write('line $i\r\n');
    }
    await tester.pump();
    scroll.jumpTo(0);
    await tester.pump();

    // Every new line drops the line at the top of the view.
    for (var i = 0; i < 3000; i++) {
      terminal.write('later $i\r\n');
      if (i % 250 == 0) {
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
    }
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(terminal.buffer.lines.length, 5000);

    terminal.write('\x1b[3J');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(terminal.buffer.lines.length, terminal.viewHeight);
  });
}
