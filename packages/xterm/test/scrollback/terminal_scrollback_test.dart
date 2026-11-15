import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';
import 'package:xterm/src/core/buffer/scrollback/codec_pure.dart';

import 'helpers.dart';

/// Small tiers, so that a few hundred lines already cross every boundary.
const smallTiers = ScrollbackOptions(hotLines: 40, blockLines: 16);

Terminal terminalWith(
  ScrollbackOptions scrollback, {
  int maxLines = 1000000,
  int width = 80,
  int height = 24,
}) {
  return Terminal(maxLines: maxLines, scrollback: scrollback)
    ..resize(width, height);
}

/// Mixed output: logs, colors, wide text, lines that wrap, blank lines.
String mixedLine(Random random, int i) {
  switch (random.nextInt(8)) {
    case 0:
      return coloredLine(random, i);
    case 1:
      return cjkLine(random, i);
    case 2:
      return fullWidthLine(random, i, width: 80 + random.nextInt(200));
    case 3:
      return '';
    case 4:
      return 'line $i café \x1b[7m inverse \x1b[0m 😀';
    default:
      return 'line $i ${logLine(random, i, width: 60)}';
  }
}

/// Feeds the same [count] lines to every terminal.
void writeMixed(List<Terminal> terminals, int count, {int seed = 1}) {
  final random = Random(seed);
  for (var i = 0; i < count; i++) {
    final line = '${mixedLine(random, i)}\r\n';
    for (final terminal in terminals) {
      terminal.write(line);
    }
  }
}

void main() {
  group('archived scrollback is transparent', () {
    test('every line reads back identical to an unarchived terminal', () {
      final archived = terminalWith(smallTiers);
      final plain = terminalWith(const ScrollbackOptions.plain());
      writeMixed([archived, plain], 3000);

      final stats = archived.mainBuffer.lines.stats;
      expect(stats.archivedLines, greaterThan(2500));
      expect(stats.hotLines, lessThan(24 + 40 + 16));
      expect(plain.mainBuffer.lines.stats.archivedLines, 0);
      expectSameLines(archived.buffer, plain.buffer);
    });

    test('with the default tiers and with pure Dart compression', () {
      final archived = terminalWith(const ScrollbackOptions());
      final pure = terminalWith(
        const ScrollbackOptions(codec: PureDartScrollbackCodec()),
      );
      final stored = terminalWith(
        const ScrollbackOptions(codec: ScrollbackCodec.none),
      );
      final plain = terminalWith(const ScrollbackOptions.plain());
      writeMixed([archived, pure, stored, plain], 12000, seed: 2);

      expect(archived.mainBuffer.lines.stats.archivedLines, greaterThan(9000));
      // The viewport and at least 2048 lines above it stay plain.
      expect(
        archived.mainBuffer.lines.stats.hotLines,
        inInclusiveRange(24 + 2048, 24 + 2048 + 256),
      );
      expectSameLines(archived.buffer, plain.buffer);
      expectSameLines(pure.buffer, plain.buffer);
      expectSameLines(stored.buffer, plain.buffer);
      expect(
        archived.mainBuffer.lines.stats.memoryBytes,
        lessThan(stored.mainBuffer.lines.stats.memoryBytes),
      );
    });

    test('random access, iteration and length across the boundary', () {
      final archived = terminalWith(smallTiers);
      final plain = terminalWith(const ScrollbackOptions.plain());
      writeMixed([archived, plain], 1500, seed: 3);

      final lines = archived.buffer.lines;
      final expected = plain.buffer.lines;
      expect(lines.length, expected.length);
      expect(archived.buffer.height, plain.buffer.height);
      expect(archived.buffer.scrollBack, plain.buffer.scrollBack);
      expect(lines.archivedLength + lines.hotLength, lines.length);

      // Jumping around evicts and restores blocks all the time.
      final random = Random(4);
      for (var k = 0; k < 5000; k++) {
        final y = random.nextInt(lines.length);
        expect(lines[y].getText(), expected[y].getText(), reason: 'line $y');
        expect(lines[y].index, y);
        expect(lines[y].attached, isTrue);
      }

      // Backwards, and right at the boundary.
      for (var y = lines.length - 1; y >= 0; y--) {
        expect(lines[y].isWrapped, expected[y].isWrapped);
        expect(lines[y].index, y);
      }
      final boundary = lines.archivedLength;
      expect(lines[boundary - 1].getText(), expected[boundary - 1].getText());
      expect(lines[boundary].getText(), expected[boundary].getText());

      var visited = 0;
      lines.forEach((line) {
        expect(line.index, visited);
        visited++;
      });
      expect(visited, lines.length);
      expect(
        lines.toList().map((line) => line.getText()),
        expected.toList().map((line) => line.getText()),
      );

      expect(() => lines[-1], throwsRangeError);
      expect(() => lines[lines.length], throwsRangeError);
      expect(lines.stats.cachedBlocks, lessThanOrEqualTo(4));
    });

    test('text ranges and word boundaries span the boundary', () {
      final archived = terminalWith(smallTiers);
      final plain = terminalWith(const ScrollbackOptions.plain());
      writeMixed([archived, plain], 800, seed: 5);

      final boundary = archived.buffer.lines.archivedLength;
      expect(boundary, greaterThan(100));

      // Everything, as "select all" then copy would read it.
      expect(archived.buffer.getText(), plain.buffer.getText());

      // A selection that starts in the archive and ends in the hot window.
      for (final mode in [BufferRangeLine.new, BufferRangeBlock.new]) {
        final range = mode(
          CellOffset(3, boundary - 37),
          CellOffset(41, boundary + 12),
        );
        final text = archived.buffer.getText(range);
        expect(text, plain.buffer.getText(range));
        expect(text.split('\n').length, greaterThan(10));
      }

      for (var y = boundary - 40; y < boundary + 10; y++) {
        for (final x in [0, 7, 30]) {
          final a = archived.buffer.getWordBoundary(CellOffset(x, y));
          final e = plain.buffer.getWordBoundary(CellOffset(x, y));
          expect(a, e, reason: 'word at $x,$y');
        }
      }
    });
  });

  group('indexes and anchors', () {
    test('anchors follow their lines into the archive', () {
      final terminal = terminalWith(smallTiers);
      writeMixed([terminal], 30);
      final buffer = terminal.buffer;

      terminal.write('needle one\r\n');
      final y1 = buffer.absoluteCursorY - 1;
      final first = buffer.createAnchor(7, y1);
      terminal.write('filler\r\nneedle two\r\n');
      final y2 = buffer.absoluteCursorY - 1;
      final second = buffer.createAnchor(3, y2);
      final anchoredLine = first.line;

      writeMixed([terminal], 2000, seed: 6);

      // Both lines are archived now; nothing was dropped, so the absolute
      // positions held by the UI are still the same.
      expect(buffer.lines.archivedLength, greaterThan(y2));
      expect(first.attached, isTrue);
      expect(second.attached, isTrue);
      expect(first.offset, CellOffset(7, y1));
      expect(second.offset, CellOffset(3, y2));
      expect(buffer.lines[y1].getText(), 'needle one');
      expect(buffer.lines[y2].getText(), 'needle two');

      // The anchored object is the line at that index, however often the
      // surrounding blocks are restored and evicted.
      for (var y = 0; y < buffer.lines.archivedLength; y += 7) {
        buffer.lines[y];
      }
      expect(identical(buffer.lines[y1], anchoredLine), isTrue);
      expect(identical(first.line, buffer.lines[y1]), isTrue);
      expect(
        buffer.getText(BufferRangeLine(first.offset, second.offset)),
        'one\nfiller\nnee',
      );

      // Releasing the anchors releases the pinned lines again.
      first.dispose();
      second.dispose();
      expect(buffer.lines[y1].getText(), 'needle one');
    });

    test('anchors on restored lines survive eviction', () {
      final terminal = terminalWith(smallTiers);
      writeMixed([terminal], 2000, seed: 7);
      final lines = terminal.buffer.lines;

      final anchors = <int, CellAnchor>{
        for (var y = 5; y < lines.archivedLength; y += 97)
          y: terminal.buffer.createAnchor(2, y),
      };
      expect(anchors.length, greaterThan(15));

      // Read everything else, twice, so every block is evicted in between.
      for (var pass = 0; pass < 2; pass++) {
        for (var y = lines.length - 1; y >= 0; y--) {
          lines[y];
        }
      }
      for (final entry in anchors.entries) {
        expect(entry.value.attached, isTrue);
        expect(entry.value.offset, CellOffset(2, entry.key));
        expect(identical(entry.value.line, lines[entry.key]), isTrue);
      }
      expect(lines.stats.pinnedLines, lessThanOrEqualTo(anchors.length));

      for (final anchor in anchors.values) {
        anchor.dispose();
      }
      // Pinned lines without anchors are let go once enough pile up.
      for (var y = 0; y < lines.archivedLength; y++) {
        terminal.buffer.createAnchor(0, y).dispose();
      }
      for (var y = lines.length - 1; y >= 0; y--) {
        lines[y];
      }
      expect(lines.stats.pinnedLines, lessThan(200));
    });

    test('indexes shift together when the oldest lines are dropped', () {
      final terminal = terminalWith(smallTiers, maxLines: 500);
      final plain = terminalWith(
        const ScrollbackOptions.plain(),
        maxLines: 500,
      );
      for (var i = 0; i < 350; i++) {
        terminal.write('row $i\r\n');
        plain.write('row $i\r\n');
      }
      final buffer = terminal.buffer;
      expect(buffer.lines.length, 351);

      final doomed = buffer.createAnchor(0, 2);
      final kept = buffer.createAnchor(5, 300);
      final keptText = buffer.lines[300].getText();
      final before = buffer.lines.length;

      // Fill up to the limit and 60 lines beyond it.
      var written = 0;
      while (buffer.lines.length < 500) {
        terminal.write('fill\r\n');
        plain.write('fill\r\n');
        written++;
      }
      expect(kept.offset, CellOffset(5, 300));
      for (var i = 0; i < 60; i++) {
        terminal.write('more $i\r\n');
        plain.write('more $i\r\n');
        // Exactly like the plain buffer: one line out for every line in.
        expect(buffer.lines.length, 500);
      }
      expect(before + written, 500);

      expect(doomed.attached, isFalse);
      expect(kept.attached, isTrue);
      expect(kept.offset, CellOffset(5, 240));
      expect(buffer.lines[240].getText(), keptText);
      expect(identical(kept.line, buffer.lines[240]), isTrue);
      for (var y = 0; y < 500; y++) {
        expect(buffer.lines[y].index, y);
      }
      expectSameLines(buffer, plain.buffer);
    });

    test('selection stays on its text while output keeps arriving', () {
      final terminal = terminalWith(smallTiers, maxLines: 2000);
      writeMixed([terminal], 100, seed: 9);
      terminal.write('select from here\r\nto here\r\n');
      final buffer = terminal.buffer;
      final y = buffer.absoluteCursorY - 2;
      final base = buffer.createAnchor(7, y);
      final extent = buffer.createAnchor(2, y + 1);

      String selected() => buffer.getText(
            BufferRangeLine(base.offset, extent.offset),
          );
      expect(selected(), 'from here\nto');

      // Into the archive, then up to the limit and past it.
      for (var i = 0; i < 2500; i++) {
        terminal.write('output $i\r\n');
        if (i % 50 == 0 && base.attached) {
          expect(selected(), 'from here\nto');
        }
      }
      expect(base.attached, isFalse, reason: 'its line was dropped');
      expect(extent.attached, isFalse);
    });
  });

  group('limits', () {
    test('the line limit drops the oldest lines one by one', () {
      final terminal = terminalWith(smallTiers, maxLines: 1000);
      final plain = terminalWith(
        const ScrollbackOptions.plain(),
        maxLines: 1000,
      );
      for (var i = 0; i < 5000; i++) {
        terminal.write('line $i\r\n');
        plain.write('line $i\r\n');
        if (i % 500 == 499) {
          expect(terminal.buffer.lines.length, plain.buffer.lines.length);
          expect(
            terminal.buffer.lines[0].getText(),
            plain.buffer.lines[0].getText(),
          );
        }
      }
      expect(terminal.buffer.lines.length, 1000);
      expect(terminal.buffer.lines[0].getText(), 'line 4001');
      expect(terminal.buffer.lines.stats.archivedLines, greaterThan(800));
      expectSameLines(terminal.buffer, plain.buffer);
    });

    test('a limit below the hot window behaves like the plain buffer', () {
      final terminal = terminalWith(const ScrollbackOptions(), maxLines: 300);
      final plain = terminalWith(
        const ScrollbackOptions.plain(),
        maxLines: 300,
      );
      writeMixed([terminal, plain], 2000, seed: 10);
      expect(terminal.buffer.lines.stats.archivedLines, 0);
      expect(terminal.buffer.lines.length, 300);
      expectSameLines(terminal.buffer, plain.buffer);
    });

    test('the memory budget drops the oldest blocks', () {
      const budget = 24 * 1024;
      final terminal = terminalWith(
        const ScrollbackOptions(
          hotLines: 40,
          blockLines: 16,
          maxMemoryBytes: budget,
        ),
      );
      final plain = terminalWith(const ScrollbackOptions.plain());
      final random = Random(11);
      var maxSeen = 0;
      for (var i = 0; i < 6000; i++) {
        final line = '${logLine(random, i)}\r\n';
        terminal.write(line);
        plain.write(line);
        maxSeen = max(maxSeen, terminal.buffer.lines.stats.memoryBytes);
      }

      final lines = terminal.buffer.lines;
      expect(maxSeen, lessThanOrEqualTo(budget + 2048));
      expect(lines.stats.memoryBytes, lessThanOrEqualTo(budget));
      expect(lines.length, lessThan(3000));
      expect(lines.length, greaterThan(300));

      // What is left is the newest part, without holes, and still exact.
      final offset = plain.buffer.lines.length - lines.length;
      for (var y = 0; y < lines.length; y++) {
        expect(
          lines[y].getText(),
          plain.buffer.lines[y + offset].getText(),
          reason: 'line $y',
        );
        expect(lines[y].index, y);
      }
      // Whole blocks are dropped, so the count stays a multiple of a block
      // away from the unlimited one.
      expect(offset % 16, 0);
    });

    test('ED 3 clears the archive too', () {
      final terminal = terminalWith(smallTiers);
      writeMixed([terminal], 1000, seed: 12);
      final lines = terminal.buffer.lines;
      final anchor = terminal.buffer.createAnchor(0, 10);
      final onScreen = terminal.buffer.createAnchor(
        1,
        terminal.buffer.absoluteCursorY - 1,
      );
      final screen = [
        for (var y = lines.length - 24; y < lines.length; y++)
          lines[y].getText(),
      ];
      expect(lines.stats.memoryBytes, greaterThan(0));

      terminal.write('\x1b[3J');

      expect(lines.length, 24);
      expect(lines.archivedLength, 0);
      expect(lines.stats.memoryBytes, 0);
      expect(lines.stats.memoryBlocks, 0);
      expect(lines.stats.cachedBlocks, 0);
      expect(lines.stats.pinnedLines, 0);
      expect([for (var y = 0; y < 24; y++) lines[y].getText()], screen);
      expect(anchor.attached, isFalse);
      // What remains keeps its anchors, at its new index.
      expect(onScreen.attached, isTrue);
      expect(onScreen.offset, CellOffset(1, terminal.buffer.cursorY - 1));
      for (var y = 0; y < 24; y++) {
        expect(lines[y].index, y);
      }

      // The scrollback fills up again afterwards.
      writeMixed([terminal], 500, seed: 13);
      expect(lines.archivedLength, greaterThan(300));
      expect(lines[0].index, 0);
    });

    test('the alternate screen has no scrollback and no archive', () {
      final terminal = terminalWith(smallTiers);
      final plain = terminalWith(const ScrollbackOptions.plain());
      writeMixed([terminal, plain], 600, seed: 14);
      final archivedBefore = terminal.mainBuffer.lines.archivedLength;

      for (final t in [terminal, plain]) {
        t.write('\x1b[?1049h');
      }
      expect(terminal.isUsingAltBuffer, isTrue);
      writeMixed([terminal, plain], 2000, seed: 15);
      expect(terminal.altBuffer.lines.length, 24);
      expect(terminal.altBuffer.lines.archivedLength, 0);
      expect(terminal.altBuffer.scrollback.archive, isFalse);
      expect(terminal.mainBuffer.lines.archivedLength, archivedBefore);
      expectSameLines(terminal.altBuffer, plain.altBuffer);

      for (final t in [terminal, plain]) {
        t.write('\x1b[?1049l');
      }
      expectSameLines(terminal.buffer, plain.buffer);
      writeMixed([terminal, plain], 200, seed: 16);
      expectSameLines(terminal.buffer, plain.buffer);
    });

    test('scroll regions and line insertion on the main screen', () {
      // A status line below a scroll region, as some shells and progress
      // bars use it: lines leave the region into the scrollback through
      // insert() instead of push().
      final terminal = terminalWith(smallTiers, maxLines: 700);
      final plain = terminalWith(
        const ScrollbackOptions.plain(),
        maxLines: 700,
      );
      final random = Random(17);
      for (final t in [terminal, plain]) {
        t.write('\x1b[1;22r\x1b[24;1Hstatus line\x1b[22;1H');
      }
      for (var i = 0; i < 1500; i++) {
        final line = '${logLine(random, i, width: 70)}\r\n';
        final extra = switch (i % 97) {
          0 => '\x1b[5;1H\x1b[2L\x1b[22;1H',
          1 => '\x1b[7;1H\x1b[3M\x1b[22;1H',
          2 => '\x1b[10;1H\x1bM\x1bM\x1b[22;1H',
          _ => '',
        };
        for (final t in [terminal, plain]) {
          t.write(line + extra);
        }
      }
      expect(terminal.buffer.lines.length, 700);
      expectSameLines(terminal.buffer, plain.buffer);
    });
  });

  group('resize with an archive', () {
    test('a taller view uncovers archived lines as plain lines', () {
      final terminal = terminalWith(
        const ScrollbackOptions(hotLines: 0, blockLines: 8),
      );
      final plain = terminalWith(const ScrollbackOptions.plain());
      writeMixed([terminal, plain], 500, seed: 18);
      expect(terminal.buffer.lines.hotLength, lessThan(40));

      for (final height in [60, 200, 10, 24]) {
        terminal.resize(80, height);
        plain.resize(80, height);
        expect(terminal.buffer.lines.hotLength, greaterThanOrEqualTo(height));
        expectSameLines(terminal.buffer, plain.buffer, reason: 'at $height');
        // The uncovered lines can be written to.
        for (final t in [terminal, plain]) {
          t.write('\x1b[H\x1b[2Kedited at $height\x1b[$height;1H\r\n');
        }
        expectSameLines(terminal.buffer, plain.buffer, reason: 'at $height');
      }
    });

    test('only the hot window is wrapped again', () {
      final terminal = terminalWith(smallTiers);
      final random = Random(19);
      final written = <String>[];
      for (var i = 0; i < 600; i++) {
        // Unique, without spaces at the end, 60 to 80 columns.
        final text = 'L$i:${fullWidthLine(random, i, width: 56 + i % 20)}';
        written.add(text);
        terminal.write('$text\r\n');
      }
      final lines = terminal.buffer.lines;
      final archived = lines.archivedLength;
      final lengthBefore = lines.length;
      expect(archived, greaterThan(500));

      // Narrower. Hot lines wrap again and take more rows; archived lines
      // keep their rows and are clipped to the new width.
      terminal.resize(40, 24);
      expect(lines.length, greaterThan(lengthBefore));
      for (var y = 0; y < archived; y++) {
        expect(lines[y].length, 40);
        expect(lines[y].isWrapped, isFalse);
        expect(lines[y].getText(), written[y].substring(0, 40));
      }
      // Nothing of the hot window is lost: joined over its wraps it is the
      // text that was written.
      String hotText() {
        final text = StringBuffer();
        for (var y = lines.archivedLength; y < lines.length; y++) {
          if (y > lines.archivedLength && !lines[y].isWrapped) {
            text.write('\n');
          }
          text.write(lines[y].getText());
        }
        return text.toString().trimRight();
      }

      final hotWritten = written.sublist(archived).join('\n');
      expect(lines.archivedLength, greaterThanOrEqualTo(archived));
      expect(
        hotWritten,
        endsWith(hotText()),
        reason: 'the hot window is the tail of what was written',
      );
      expect(terminal.buffer.getText(), contains(written.last));

      // Wide again: the clipped cells of the archived lines are back.
      terminal.resize(80, 24);
      for (var y = 0; y < archived; y++) {
        expect(lines[y].length, 80);
        expect(lines[y].getText(), written[y]);
      }

      // Wider than when archived: lines are shown as they were wrapped then.
      terminal.resize(132, 30);
      for (var y = 0; y < archived; y++) {
        expect(lines[y].length, 132);
        expect(lines[y].getText(), written[y]);
        expect(lines[y].getTrimmedLength(), written[y].length);
      }
      for (var y = 0; y < lines.length; y++) {
        expect(lines[y].index, y);
      }
      expect(terminal.buffer.getText(), contains(written.last));
    });

    test('rows wrapped when archived stay wrapped rows', () {
      final terminal = terminalWith(smallTiers, width: 40);
      final long = [
        for (var i = 0; i < 300; i++) 'W$i:${'x' * 90}',
      ];
      for (final text in long) {
        terminal.write('$text\r\n');
      }
      final lines = terminal.buffer.lines;
      final archived = lines.archivedLength;
      expect(archived, greaterThan(700));

      terminal.resize(100, 24);
      // Three rows of 40 columns per line, still joined by their wrap flags,
      // so copied text has no line breaks inside a line.
      expect(lines[0].getText(), long[0].substring(0, 40));
      expect(lines[1].isWrapped, isTrue);
      expect(lines[2].isWrapped, isTrue);
      expect(lines[3].isWrapped, isFalse);
      final copied = terminal.buffer.getText(
        BufferRangeLine(CellOffset(0, 0), CellOffset(100, 5)),
      );
      expect(copied, '${long[0]}\n${long[1]}');

      // The hot window was wrapped again: its lines fit in one row now.
      expect(lines[lines.length - 2].getText(), long.last);
    });

    test('a line split between archive and hot window stays one line', () {
      final terminal = terminalWith(
        const ScrollbackOptions(hotLines: 0, blockLines: 4),
        width: 20,
        height: 6,
      );
      // One logical line of 400 columns: 20 rows, most of them archived.
      final text = [
        for (var i = 0; i < 40; i++) 'chunk${i.toString().padLeft(4, '0')}!'
      ].join();
      terminal.write(text);
      final lines = terminal.buffer.lines;
      expect(lines.archivedLength, greaterThan(4));
      expect(lines[lines.archivedLength].isWrapped, isTrue);

      terminal.resize(30, 6);
      expect(lines[lines.archivedLength].isWrapped, isTrue);
      expect(terminal.buffer.getText().trimRight(), text);

      // Narrower than the archived rows: they are clipped, the hot window is
      // wrapped again. Back at the old width everything is there again.
      terminal.resize(10, 6);
      expect(lines[0].getText(), text.substring(0, 10));
      terminal.resize(20, 6);
      // (The default range of getText() stops one cell short of the end.)
      final everything = BufferRangeLine(
        CellOffset(0, 0),
        CellOffset(20, lines.length - 1),
      );
      expect(terminal.buffer.getText(everything).trimRight(), text);
    });

    test('anchors survive a resize in both tiers', () {
      final terminal = terminalWith(smallTiers);
      for (var i = 0; i < 400; i++) {
        terminal.write('row $i ${'=' * 60}\r\n');
      }
      final buffer = terminal.buffer;
      final inArchive = buffer.createAnchor(4, 100);
      final inHot = buffer.createAnchor(4, buffer.lines.length - 30);
      expect(buffer.lines.archivedLength, greaterThan(100));
      expect(buffer.lines[inHot.y].getText(), startsWith('row 371 '));

      terminal.resize(50, 24);
      expect(inArchive.attached, isTrue);
      expect(inArchive.offset, CellOffset(4, 100));
      expect(buffer.lines[100].getText(), startsWith('row 100 '));
      expect(inHot.attached, isTrue);
      expect(buffer.lines[inHot.y].getText(), startsWith('row 371 '));

      terminal.resize(80, 24);
      expect(inArchive.offset, CellOffset(4, 100));
      expect(buffer.lines[100].getText(), 'row 100 ${'=' * 60}');
      expect(buffer.lines[inHot.y].getText(), startsWith('row 371 '));
    });

    test('without reflow every tier is clipped the same way', () {
      final terminal = Terminal(
        maxLines: 100000,
        reflowEnabled: false,
        scrollback: smallTiers,
      )..resize(80, 24);
      final plain = Terminal(
        maxLines: 100000,
        reflowEnabled: false,
        scrollback: const ScrollbackOptions.plain(),
      )..resize(80, 24);
      writeMixed([terminal, plain], 500, seed: 20);
      for (final width in [40, 120, 80]) {
        terminal.resize(width, 24);
        plain.resize(width, 24);
        final a = terminal.buffer.lines;
        final e = plain.buffer.lines;
        expect(a.length, e.length);
        for (var y = 0; y < a.length; y++) {
          expect(a[y].length, width);
          expect(a[y].getText(), e[y].getText(), reason: 'line $y at $width');
        }
      }
    });
  });
}
