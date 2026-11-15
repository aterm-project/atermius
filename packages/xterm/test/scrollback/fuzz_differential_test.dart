import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';

import 'helpers.dart';

// Differential fuzz: the same random stream of text and control sequences is
// written to terminals with an archived scrollback and to one with a plain
// buffer. Without resizes every cell of every line must stay identical.
// Sequences that make the plain terminal throw must throw the same way.

/// One random piece of terminal output.
String randomOutput(Random r) {
  int n([int max = 30]) => 1 + r.nextInt(max);
  switch (r.nextInt(34)) {
    case 0:
    case 1:
    case 2:
    case 3:
    case 4:
    case 5:
    case 6:
      final len = r.nextInt(r.nextBool() ? 30 : 220);
      final sb = StringBuffer();
      for (var i = 0; i < len; i++) {
        final k = r.nextInt(40);
        if (k == 0) {
          sb.write('中');
        } else if (k == 1) {
          sb.write('😀');
        } else if (k == 2) {
          sb.write('é');
        } else {
          sb.writeCharCode(0x20 + r.nextInt(95));
        }
      }
      return sb.toString();
    case 7:
    case 8:
    case 9:
    case 10:
    case 11:
    case 12:
      return '\r\n';
    case 13:
      return '\n';
    case 14:
      return '\r';
    case 15:
      return '\x1b[${n()};${n(90)}H';
    case 16:
      return '\x1b[${n(10)}${'ABCD'[r.nextInt(4)]}';
    case 17:
      final a = n(20);
      return r.nextInt(3) == 0 ? '\x1b[r' : '\x1b[$a;${a + n(10)}r';
    case 18:
      return '\x1b[${n(5)}${'LM'[r.nextInt(2)]}';
    case 19:
      return '\x1b[${n(5)}${'ST'[r.nextInt(2)]}';
    case 20:
      return ['\x1bM', '\x1bD', '\x1bE'][r.nextInt(3)];
    case 21:
      return '\x1b[${r.nextInt(3)}J';
    case 22:
      return r.nextInt(6) == 0 ? '\x1b[3J' : '';
    case 23:
      return '\x1b[${r.nextInt(3)}K';
    case 24:
      return '\x1b[${n(10)}${'@PX'[r.nextInt(3)]}';
    case 25:
    case 26:
      return '\x1b[${[0, 1, 4, 7, 31, 42, 91, 100][r.nextInt(8)]}m';
    case 27:
      return '\x1b[38;5;${r.nextInt(256)}m\x1b[48;2;${r.nextInt(256)};3;4m';
    case 28:
      return r.nextInt(4) == 0
          ? '\x1b[?${[1049, 47, 1047][r.nextInt(3)]}${'hl'[r.nextInt(2)]}'
          : '';
    case 29:
      return '\t';
    case 30:
      return '\b';
    case 31:
      return ['\x1b7', '\x1b8'][r.nextInt(2)];
    case 32:
      return '\x1b[?${[6, 7][r.nextInt(2)]}${'hl'[r.nextInt(2)]}';
    default:
      // A burst of plain log lines so the archive fills quickly.
      final sb = StringBuffer();
      for (var i = 0; i < 40; i++) {
        sb.write('burst $i ${r.nextInt(1 << 30)}\r\n');
      }
      return sb.toString();
  }
}

void main() {
  const small = ScrollbackOptions(hotLines: 40, blockLines: 16);
  for (var seed = 0; seed < 60; seed++) {
    test('fuzz seed $seed', () {
      final r = Random(1000 + seed);
      final limit = seed % 4 == 3 ? 150 + r.nextInt(400) : 1000000;
      final store = FakeBlockStore(synchronous: true);
      final variants = <Terminal>[
        Terminal(maxLines: limit, scrollback: small),
        Terminal(
          maxLines: limit,
          scrollback: ScrollbackOptions(
            hotLines: 40,
            blockLines: 16,
            maxMemoryBytes: 600,
            store: store,
          ),
        ),
        Terminal(
            maxLines: limit,
            scrollback: const ScrollbackOptions(
                hotLines: 3, blockLines: 2, cachedBlocks: 1)),
      ];
      final plain = Terminal(
          maxLines: limit, scrollback: const ScrollbackOptions.plain());
      final w = 20 + r.nextInt(100), h = 5 + r.nextInt(40);
      for (final t in [...variants, plain]) {
        t.resize(w, h);
      }
      final thrown = <String>{};
      var maxArchived = 0;
      for (var i = 0; i < 4000; i++) {
        final s = randomOutput(r);
        final errors = <String>[];
        for (final t in [...variants, plain]) {
          try {
            t.write(s);
            errors.add('');
          } catch (e, st) {
            errors.add('${e.runtimeType} ${st.toString().split('\n').first}');
          }
        }
        // Upstream bugs throw in the plain terminal too; all must agree.
        expect(errors.toSet().length, 1, reason: 'seed $seed op $i $errors');
        if (errors.first.isNotEmpty) thrown.add(errors.first);
        maxArchived =
            max(maxArchived, variants[0].mainBuffer.lines.stats.archivedLines);
        if (i % 97 == 0 || i == 3999) {
          for (var v = 0; v < variants.length; v++) {
            final t = variants[v];
            expectSameLines(t.mainBuffer, plain.mainBuffer,
                reason: 'seed $seed op $i variant $v main');
            expectSameLines(t.altBuffer, plain.altBuffer,
                reason: 'seed $seed op $i variant $v alt');
            expect(t.buffer.cursorX, plain.buffer.cursorX);
            expect(t.buffer.cursorY, plain.buffer.cursorY);
            expect(t.buffer.absoluteCursorY, plain.buffer.absoluteCursorY);
            // Random reads in between must not disturb anything.
            final lines = t.mainBuffer.lines;
            for (var k = 0; k < 20; k++) {
              final y = r.nextInt(lines.length);
              expect(lines[y].getText(), plain.mainBuffer.lines[y].getText());
            }
          }
        }
      }
      // ignore: avoid_print
      if (thrown.isNotEmpty) print('upstream throws: $thrown');
      if (limit == 1000000) {
        expect(maxArchived, greaterThan(0));
      }
    });
  }
}
