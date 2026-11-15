import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';

import 'fuzz_differential_test.dart' show randomOutput;
import 'helpers.dart';

// Resize fuzz: random output mixed with random resizes. Archived lines are
// deliberately not wrapped again, so the content is not compared with a plain
// buffer here; what must hold is that an archived terminal never throws where
// the plain one does not, and that every line stays readable at its index.

void main() {
  for (var seed = 0; seed < 40; seed++) {
    test('resize fuzz seed $seed', () {
      final r = Random(5000 + seed);
      final rr = Random(seed);
      final limit = seed % 4 == 3 ? 150 + r.nextInt(400) : 1000000;
      final store = FakeBlockStore(synchronous: true);
      final variants = <Terminal>[
        Terminal(
            maxLines: limit,
            scrollback: const ScrollbackOptions(hotLines: 40, blockLines: 16)),
        Terminal(
          maxLines: limit,
          scrollback: ScrollbackOptions(
              hotLines: 40, blockLines: 16, maxMemoryBytes: 600, store: store),
        ),
        Terminal(
            maxLines: limit,
            scrollback: const ScrollbackOptions(
                hotLines: 3, blockLines: 2, cachedBlocks: 1)),
      ];
      final plain = Terminal(
          maxLines: limit, scrollback: const ScrollbackOptions.plain());
      final all = [...variants, plain];
      for (final t in all) {
        t.resize(80, 24);
      }
      for (var i = 0; i < 3000; i++) {
        final resize = r.nextInt(40) == 0;
        final w = 2 + r.nextInt(r.nextBool() ? 20 : 200), h = 1 + r.nextInt(60);
        final s = randomOutput(r);
        final errors = <String>[];
        for (final t in all) {
          try {
            if (resize) {
              t.resize(w, h);
            } else {
              t.write(s);
            }
            errors.add('');
          } catch (e, st) {
            errors.add(
                '${e.runtimeType} ${st.toString().split('\n').take(3).join(' | ')}');
          }
        }
        if (errors.last.isEmpty) {
          expect(errors.toSet().length, 1,
              reason: 'seed $seed op $i resize=$resize ${w}x$h $errors');
        }
        if (i % 53 == 0 || i == 2999) {
          for (final t in variants) {
            final lines = t.mainBuffer.lines;
            expect(lines.archivedLength + lines.hotLength, lines.length);
            expect(lines.length, greaterThanOrEqualTo(t.viewHeight));
            if (plain.buffer.cursorY < plain.viewHeight)
              expect(t.buffer.cursorY, inInclusiveRange(0, t.viewHeight - 1));
            for (var y = 0; y < lines.length; y++) {
              final line = lines[y];
              expect(line.index, y);
              line.getText();
            }
            for (var k = 0; k < 10; k++) {
              final y = rr.nextInt(lines.length);
              lines[y].getText();
              t.buffer.getText();
            }
          }
        }
      }
    });
  }
}
