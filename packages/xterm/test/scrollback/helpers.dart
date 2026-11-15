import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';

const _words = [
  'accepted',
  'connection',
  'from',
  'worker',
  'request',
  'finished',
  'in',
  'cache',
  'miss',
  'for',
  'key',
  'retrying',
  'upstream',
  'timeout',
  'after',
  'scheduled',
  'job',
  'started',
  'completed',
  'with',
  'status',
  'user',
  'session',
  'opened',
  'closed',
  'bytes',
  'written',
  'to',
  'disk',
  'queue',
  'depth',
  'is',
  'above',
  'threshold',
  'reloading',
  'configuration',
  'file',
  'health',
  'check',
  'passed',
  'failed',
  'node',
  'joined',
  'left',
  'cluster',
  'compaction',
  'of',
  'segment',
  'took',
  'replica',
  'lag',
  'seconds',
  'tls',
  'handshake',
  'with',
  'peer',
  'renewed',
  'lease',
  'until',
  'dropping',
  'packet',
  'checksum',
  'mismatch',
  'on',
  'interface',
  'route',
  'updated',
];

/// One line of realistic service log text, at most [width] columns: a
/// timestamp, a level, a component and a message of random words and
/// numbers. The randomness matters: repeating one line would compress to
/// almost nothing and make every measurement meaningless.
String logLine(Random random, int i, {int width = 79}) {
  String two(int v) => v.toString().padLeft(2, '0');
  final buffer = StringBuffer()
    ..write('2026-11-15T${two(i ~/ 3600 % 24)}:${two(i ~/ 60 % 60)}:')
    ..write(
        '${two(i % 60)}.${random.nextInt(1000).toString().padLeft(3, '0')}Z ')
    ..write(const ['INFO ', 'WARN ', 'DEBUG', 'ERROR'][random.nextInt(4)])
    ..write(
        ' [${_words[random.nextInt(_words.length)]}-${random.nextInt(64)}] ');
  final count = 3 + random.nextInt(6);
  for (var k = 0; k < count; k++) {
    buffer
      ..write(_words[random.nextInt(_words.length)])
      ..write(' ');
  }
  buffer.write('id=${random.nextInt(1 << 30).toRadixString(16)}');
  final line = buffer.toString();
  return line.length > width ? line.substring(0, width) : line;
}

/// Colored output in the style of `ls --color`, compiler diagnostics and
/// colored logs: several SGR changes per line, 16/256/RGB colors.
String coloredLine(Random random, int i, {int width = 79}) {
  final buffer = StringBuffer();
  var columns = 0;
  while (columns < width - 12) {
    final word = _words[random.nextInt(_words.length)];
    switch (random.nextInt(6)) {
      case 0:
        buffer.write('\x1b[1;${31 + random.nextInt(6)}m');
      case 1:
        buffer.write('\x1b[38;5;${random.nextInt(256)}m');
      case 2:
        buffer.write('\x1b[38;2;${random.nextInt(256)};${random.nextInt(256)};'
            '${random.nextInt(256)}m');
      case 3:
        buffer.write(
            '\x1b[4;${90 + random.nextInt(8)};${40 + random.nextInt(8)}m');
      default:
        buffer.write('\x1b[0m');
    }
    buffer
      ..write(word)
      ..write(' ');
    columns += word.length + 1;
  }
  buffer.write('\x1b[0m');
  return buffer.toString();
}

/// Wide (CJK) text: every character takes two cells.
String cjkLine(Random random, int i, {int width = 79}) {
  final buffer = StringBuffer();
  final count = (width ~/ 2) - random.nextInt(6);
  for (var k = 0; k < count; k++) {
    buffer.writeCharCode(0x4e00 + random.nextInt(0x51a5));
  }
  return buffer.toString();
}

/// A line that fills every column, as `base64` or a hex dump would.
String fullWidthLine(Random random, int i, {int width = 80}) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final buffer = StringBuffer();
  for (var k = 0; k < width; k++) {
    buffer.write(alphabet[random.nextInt(alphabet.length)]);
  }
  return buffer.toString();
}

/// The words of every visible cell of [line], which is everything a reader
/// can observe of it.
List<int> cellsOf(BufferLine line, int width) {
  return [
    for (var x = 0; x < width; x++) ...[
      line.getForeground(x),
      line.getBackground(x),
      line.getAttributes(x),
      line.getContent(x),
    ],
  ];
}

/// Asserts that [actual] and [expected] hold the same lines, cell for cell.
void expectSameLines(Buffer actual, Buffer expected, {String? reason}) {
  expect(actual.lines.length, expected.lines.length, reason: reason);
  final width = expected.viewWidth;
  for (var y = 0; y < expected.lines.length; y++) {
    final a = actual.lines[y];
    final e = expected.lines[y];
    if (a.isWrapped != e.isWrapped || a.length != e.length) {
      fail('line $y: wrapped ${a.isWrapped}/${e.isWrapped}, '
          'length ${a.length}/${e.length} ${reason ?? ''}');
    }
    final actualCells = cellsOf(a, width);
    final expectedCells = cellsOf(e, width);
    for (var k = 0; k < expectedCells.length; k++) {
      if (actualCells[k] != expectedCells[k]) {
        fail('line $y differs at cell ${k ~/ 4} word ${k % 4}: '
            '${actualCells[k]} != ${expectedCells[k]} ${reason ?? ''}\n'
            'actual:   "$a"\nexpected: "$e"');
      }
    }
  }
}

/// A [ScrollbackBlockStore] that keeps blocks in a map and lets a test decide
/// when and how writes finish.
class FakeBlockStore implements ScrollbackBlockStore {
  FakeBlockStore({this.synchronous = false});

  /// Whether [put] stores immediately instead of waiting for [flush].
  final bool synchronous;

  final blocks = <int, Uint8List>{};

  final pending = <int, (Uint8List, Completer<bool>)>{};

  final putIds = <int>[];

  final removedIds = <int>[];

  var gets = 0;

  var clears = 0;

  var disposed = false;

  /// When set, writes complete with `false` from now on.
  var failWrites = false;

  /// When set, [get] throws instead of returning.
  var throwOnGet = false;

  @override
  Future<bool> put(int id, Uint8List bytes) {
    putIds.add(id);
    if (disposed) {
      return Future.value(false);
    }
    if (synchronous) {
      if (failWrites) {
        return Future.value(false);
      }
      blocks[id] = bytes;
      return Future.value(true);
    }
    final completer = Completer<bool>();
    pending[id] = (bytes, completer);
    return completer.future;
  }

  /// Finishes every write that is still in flight.
  Future<void> flush() async {
    final writes = Map.of(pending);
    pending.clear();
    for (final entry in writes.entries) {
      final (bytes, completer) = entry.value;
      if (failWrites || disposed) {
        completer.complete(false);
      } else {
        blocks[entry.key] = bytes;
        completer.complete(true);
      }
    }
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Uint8List? get(int id) {
    gets++;
    if (throwOnGet) {
      throw StateError('read failed');
    }
    return blocks[id];
  }

  @override
  void remove(int id) {
    removedIds.add(id);
    blocks.remove(id);
    pending.remove(id)?.$2.complete(false);
  }

  @override
  void clear() {
    clears++;
    blocks.clear();
    for (final write in pending.values) {
      write.$2.complete(false);
    }
    pending.clear();
  }

  @override
  void dispose() {
    clear();
    disposed = true;
  }
}
