import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';

import 'helpers.dart';

const _mib = 1024 * 1024;

/// What the Dart heap spends on one plain [BufferLine] besides its cells:
/// the line object, the typed data header and the anchor list.
const _lineOverhead = 160;

/// Bytes held by the plain lines of [lines]: the hot window, or everything
/// for a buffer without an archive.
int plainBytes(BufferLines lines) {
  var bytes = 0;
  for (var y = lines.archivedLength; y < lines.length; y++) {
    bytes += lines[y].data.lengthInBytes + _lineOverhead;
  }
  return bytes;
}

/// Everything the scrollback of [terminal] holds in memory: plain lines and
/// the compressed archive (which includes a fixed charge per block).
int memoryBytes(Terminal terminal) {
  final lines = terminal.mainBuffer.lines;
  return plainBytes(lines) + lines.stats.memoryBytes;
}

typedef Generator = String Function(Random random, int i, {int width});

Terminal fill(
  Generator generator,
  int count, {
  required ScrollbackOptions scrollback,
  int width = 80,
  int lineWidth = 79,
}) {
  final terminal = Terminal(maxLines: 5000000, scrollback: scrollback)
    ..resize(width, 24);
  final random = Random(42);
  for (var i = 0; i < count; i++) {
    terminal.write('${generator(random, i, width: lineWidth)}\r\n');
  }
  return terminal;
}

void main() {
  // The numbers printed here are the ones quoted in docs/FEATURES.md. Run
  // with `flutter test test/scrollback/scrollback_budget_test.dart` to see
  // them.
  test('memory per line, plain versus archived', () {
    final rows = <String>[];
    void measure(String name, Generator generator,
        {int width = 80, int lineWidth = 79}) {
      const count = 20000;
      final plain = fill(
        generator,
        count,
        scrollback: const ScrollbackOptions.plain(),
        width: width,
        lineWidth: lineWidth,
      );
      final archived = fill(
        generator,
        count,
        scrollback: const ScrollbackOptions(),
        width: width,
        lineWidth: lineWidth,
      );
      final uncompressed = fill(
        generator,
        count,
        scrollback: const ScrollbackOptions(codec: ScrollbackCodec.none),
        width: width,
        lineWidth: lineWidth,
      );
      final stats = archived.mainBuffer.lines.stats;
      final plainPerLine = plainBytes(plain.mainBuffer.lines) / (count + 1);
      final archivedPerLine = stats.memoryBytes / stats.archivedLines;
      final serializedPerLine =
          uncompressed.mainBuffer.lines.stats.memoryBytes /
              uncompressed.mainBuffer.lines.stats.archivedLines;
      rows.add(
          '${name.padRight(34)} ${plainPerLine.toStringAsFixed(0).padLeft(6)}'
          ' ${serializedPerLine.toStringAsFixed(1).padLeft(10)}'
          ' ${archivedPerLine.toStringAsFixed(1).padLeft(10)}'
          ' ${(plainPerLine / archivedPerLine).toStringAsFixed(0).padLeft(6)}x');

      expect(plain.mainBuffer.lines.length, archived.mainBuffer.lines.length);
      // Even text that does not compress (random base64) must be far below
      // the 16 bytes per cell of a plain line.
      expect(archivedPerLine, lessThan(plainPerLine / 8), reason: name);
    }

    measure('log text, 80 columns', logLine);
    measure('colored output, 80 columns', coloredLine);
    measure('wide CJK text, 80 columns', cjkLine);
    measure('full-width base64, 80 columns', fullWidthLine, lineWidth: 80);
    measure('log text, 200 columns', logLine, width: 200);
    measure('full-width base64, 200 columns', fullWidthLine,
        width: 200, lineWidth: 200);

    // ignore: avoid_print
    print('bytes per line                      plain serialized compressed'
        '  ratio\n${rows.join('\n')}');
  });

  test('100,000 lines of log output stay well under 16 MiB', () {
    final terminal = fill(
      logLine,
      100000,
      scrollback: const ScrollbackOptions(),
    );
    final lines = terminal.mainBuffer.lines;
    final stats = lines.stats;
    final total = memoryBytes(terminal);
    // ignore: avoid_print
    print('100,000 lines: hot window ${stats.hotLines} lines = '
        '${(plainBytes(lines) / _mib).toStringAsFixed(2)} MiB, archive '
        '${stats.archivedLines} lines = '
        '${(stats.memoryBytes / _mib).toStringAsFixed(2)} MiB, total '
        '${(total / _mib).toStringAsFixed(2)} MiB; the same lines plain: '
        '${(100001 * (128 * 16 + _lineOverhead) / _mib).toStringAsFixed(0)}'
        ' MiB');

    expect(lines.length, 100001);
    expect(stats.archivedLines, greaterThan(97000));
    // The hot window: the viewport, 2048 lines, and less than a block more.
    expect(stats.hotLines, lessThan(24 + 2048 + 256));
    expect(plainBytes(lines), lessThan(6 * _mib));
    // Around 30 bytes per archived line; 48 leaves room for other content.
    expect(stats.memoryBytes / stats.archivedLines, lessThan(48));
    expect(total, lessThan(10 * _mib));
    expect(total, lessThan(16 * _mib ~/ 1.5), reason: 'well under 16 MiB');
  });

  test('1,000,000 lines of log output', () {
    final terminal = fill(
      logLine,
      1000000,
      scrollback: const ScrollbackOptions(),
    );
    final lines = terminal.mainBuffer.lines;
    final stats = lines.stats;
    final total = memoryBytes(terminal);
    // ignore: avoid_print
    print('1,000,000 lines without a store: archive '
        '${(stats.memoryBytes / _mib).toStringAsFixed(2)} MiB, total '
        '${(total / _mib).toStringAsFixed(2)} MiB, kept ${lines.length} '
        'lines');

    // Within the 32 MiB memory-only budget: when it is reached the oldest
    // blocks are dropped, like the line limit but far later.
    expect(stats.memoryBytes, lessThanOrEqualTo(32 * _mib));
    expect(total, lessThan(40 * _mib));
    expect(lines.length, greaterThan(900000));
    final last = lines[lines.length - 2].getText();
    expect(last, startsWith('2026-11-15T'));
    expect(lines[0].index, 0);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('writing 300,000 lines stays fast', () {
    final random = Random(5);
    final output = [
      for (var i = 0; i < 300000; i++) '${logLine(random, i)}\r\n',
    ];

    Duration write(ScrollbackOptions scrollback, int maxLines) {
      final terminal = Terminal(maxLines: maxLines, scrollback: scrollback)
        ..resize(80, 24);
      final stopwatch = Stopwatch()..start();
      for (final line in output) {
        terminal.write(line);
      }
      stopwatch.stop();
      expect(terminal.buffer.lines.length, min(maxLines, 300001));
      return stopwatch.elapsed;
    }

    // Warm up, then compare with what the terminal did before: a plain
    // buffer of 10,000 lines.
    write(const ScrollbackOptions(), 1000000);
    final before = write(const ScrollbackOptions.plain(), 10000);
    final archived = write(const ScrollbackOptions(), 1000000);
    // ignore: avoid_print
    print('300,000 lines: ${before.inMilliseconds} ms into a plain 10,000 '
        'line buffer, ${archived.inMilliseconds} ms archiving everything '
        '(${(archived.inMicroseconds / 300000).toStringAsFixed(1)} µs/line)');

    // Generous bounds: this must hold on a loaded CI machine too.
    expect(archived, lessThan(const Duration(seconds: 30)));
    expect(
      archived.inMicroseconds,
      lessThan(before.inMicroseconds * 3 + 2000000),
      reason: 'archiving must not dominate the cost of writing output',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('no single write pauses for long while archiving', () {
    final random = Random(6);
    final terminal = Terminal(maxLines: 1000000)..resize(80, 24);
    var worst = Duration.zero;
    final stopwatch = Stopwatch();
    for (var i = 0; i < 100000; i++) {
      final line = '${logLine(random, i)}\r\n';
      stopwatch
        ..reset()
        ..start();
      terminal.write(line);
      stopwatch.stop();
      if (stopwatch.elapsed > worst) {
        worst = stopwatch.elapsed;
      }
    }
    // ignore: avoid_print
    print('worst single line write while archiving: '
        '${worst.inMicroseconds} µs');
    // One block of 256 lines is serialized and compressed at a time, which
    // takes a fraction of a millisecond; a frame is 16 ms. The bound leaves
    // room for garbage collection pauses on a busy machine.
    expect(worst, lessThan(const Duration(milliseconds: 100)));
  });
}
