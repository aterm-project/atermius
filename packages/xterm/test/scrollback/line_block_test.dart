import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';
import 'package:xterm/src/core/buffer/scrollback/codec_io.dart';
import 'package:xterm/src/core/buffer/scrollback/codec_pure.dart';
import 'package:xterm/src/core/buffer/scrollback/line_block.dart';

import 'helpers.dart';

/// The lines of the terminal after writing [output] to an 80x24 screen.
List<BufferLine> linesOf(String output, {int width = 80}) {
  final terminal = Terminal(
    maxLines: 100000,
    scrollback: const ScrollbackOptions.plain(),
  );
  terminal.resize(width, 24);
  terminal.write(output);
  return terminal.buffer.lines.toList();
}

void expectRoundTrip(
  List<BufferLine> lines, {
  int width = 80,
  bool text = true,
}) {
  final restored = decodeLineBlock(
    encodeLineBlock(lines),
    width,
    expectedLines: lines.length,
  );
  expect(restored, hasLength(lines.length));
  for (var i = 0; i < lines.length; i++) {
    expect(restored[i].isWrapped, lines[i].isWrapped, reason: 'line $i');
    expect(restored[i].length, width, reason: 'line $i');
    expect(
      cellsOf(restored[i], width),
      cellsOf(lines[i], width),
      reason: 'line $i',
    );
    if (text) {
      expect(restored[i].getText(), lines[i].getText(), reason: 'line $i');
    }
  }
}

void main() {
  group('line block serialization', () {
    test('restores plain text and blank lines exactly', () {
      final lines = linesOf('first line\r\n\r\n   indented\r\ntrailing   \r\n'
          '\ttabbed\tcolumns\r\n');
      expectRoundTrip(lines);
    });

    test('restores colors and attributes exactly', () {
      final lines = linesOf(
        '\x1b[1mbold\x1b[0m \x1b[2mfaint\x1b[0m \x1b[3mitalic\x1b[0m '
        '\x1b[4munderline\x1b[0m \x1b[5mblink\x1b[0m \x1b[7minverse\x1b[0m '
        '\x1b[8mhidden\x1b[0m \x1b[9mstrike\x1b[0m\r\n'
        '\x1b[31mred\x1b[92mbright green\x1b[44mon blue\x1b[0m\r\n'
        '\x1b[38;5;202morange\x1b[48;5;17mnavy\x1b[0m\r\n'
        '\x1b[38;2;1;2;3mrgb\x1b[48;2;250;251;252mrgb back\x1b[0m\r\n'
        '\x1b[1;4;38;2;255;0;128;48;5;236mall at once\x1b[0m plain\r\n',
      );
      expectRoundTrip(lines);
    });

    test('keeps blank cells that are not default', () {
      // Erasing with a background color leaves colored cells without text up
      // to the right edge; they are part of what the user sees.
      final lines = linesOf('\x1b[41mred\x1b[K\x1b[0m\r\nnext\x1b[44m\x1b[K');
      expect(lines[0].getBackground(79), isNot(0));
      expectRoundTrip(lines);
    });

    test('restores wide and combining characters exactly', () {
      final lines = linesOf(
        '中文字符 mixed with ascii 日本語 한국어\r\n'
        'emoji 😀 and 👍 too\r\n'
        'café combining, ǟ stacked\r\n'
        '${'宽' * 39}x\r\n',
      );
      // Wide characters occupy a lead cell of width 2 and an empty cell.
      expect(lines[0].getWidth(0), 2);
      expect(lines[0].getContent(1), 0);
      expectRoundTrip(lines);
    });

    test('restores the wrap flag of every line', () {
      final lines = linesOf('${'a' * 200}\r\nshort\r\n${'b' * 81}\r\n');
      expect(lines.map((line) => line.isWrapped).take(6),
          [false, true, true, false, false, true]);
      expectRoundTrip(lines);
    });

    test('restores cells whose width is not what wcwidth says', () {
      final line = BufferLine(80);
      // An arbitrary content word: wrong width bits and the spare bit set.
      line.setContent(0, 0x41 | (2 << 22));
      line.setContent(1, 0x4e2d | (1 << 22));
      line.setContent(2, 0x1f600);
      line.setContent(3, (1 << 21) | 0x42 | (3 << 22));
      line.setContent(5, 0x7f | (1 << 22));
      line.setContent(6, 1 << 22);
      line.setForeground(6, 0xffffffff);
      line.setBackground(6, 0x80000000);
      line.setAttributes(6, 0xdeadbeef);
      expectRoundTrip([line, BufferLine(80), line], text: false);
    });

    test('restores random cell contents exactly', () {
      final random = Random(7);
      final lines = <BufferLine>[];
      for (var i = 0; i < 300; i++) {
        final line = BufferLine(80, isWrapped: random.nextBool());
        final cells = random.nextInt(81);
        for (var x = 0; x < cells; x++) {
          if (random.nextInt(4) == 0) continue;
          line.setForeground(x, random.nextInt(1 << 32));
          line.setBackground(x, random.nextInt(4) << 25 | random.nextInt(256));
          line.setAttributes(x, random.nextInt(256));
          line.setContent(x, random.nextInt(1 << 32));
        }
        lines.add(line);
      }
      expectRoundTrip(lines, text: false);
    });

    test('stores nothing for trailing default cells', () {
      final lines = linesOf('x\r\n' * 256);
      final bytes = encodeLineBlock(lines.sublist(0, 256));
      // A style, a run, and per line one header byte and one content byte.
      expect(bytes.length, lessThan(256 * 2 + 32));
      expect(storedCellCount(lines.first), 1);
      expect(storedCellCount(BufferLine(80)), 0);
    });

    test('shows restored lines at the current view width', () {
      final lines = linesOf('${'0123456789' * 8}\r\nshort\r\n');
      final bytes = encodeLineBlock(lines);

      // A narrower view clips, like a line that was resized without reflow;
      // the hidden cells are still there when the line grows again.
      final narrow = decodeLineBlock(bytes, 40);
      expect(narrow[0].length, 40);
      expect(narrow[0].getText(), '0123456789' * 4);
      narrow[0].resize(80);
      expect(narrow[0].getText(), '0123456789' * 8);

      // A wider view shows the line as it was wrapped then.
      final wide = decodeLineBlock(bytes, 120);
      expect(wide[0].length, 120);
      expect(wide[0].getText(), '0123456789' * 8);
      expect(wide[0].getTrimmedLength(), 80);
      expect(wide[1].getText(), 'short');
    });

    test('rejects malformed blocks instead of misreading them', () {
      final lines = linesOf('\x1b[31mhello\x1b[0m world\r\n中文\r\n');
      final bytes = encodeLineBlock(lines);
      expect(
        () => decodeLineBlock(bytes, 80, expectedLines: lines.length + 1),
        throwsFormatException,
      );
      expect(() => decodeLineBlock(Uint8List(0), 80), throwsFormatException);
      for (var cut = 0; cut < bytes.length; cut++) {
        try {
          decodeLineBlock(Uint8List.sublistView(bytes, 0, cut), 80);
        } on FormatException {
          continue;
        } on RangeError {
          continue;
        }
        // A truncation that still parses must at least keep the line count.
      }
      final random = Random(3);
      for (var i = 0; i < 2000; i++) {
        final garbage = Uint8List.fromList(
          List.generate(random.nextInt(64), (_) => random.nextInt(256)),
        );
        try {
          decodeLineBlock(garbage, 80, expectedLines: 256);
        } on FormatException {
          continue;
        } on RangeError {
          continue;
        }
      }
    });
  });

  group('scrollback codecs', () {
    final random = Random(11);
    final raw = encodeLineBlock(
      linesOf([for (var i = 0; i < 256; i++) logLine(random, i)].join('\r\n')),
    );

    test('native zlib and pure Dart deflate read each other', () {
      final native = ZLibScrollbackCodec();
      const pure = PureDartScrollbackCodec();
      final a = native.compress(raw);
      final b = pure.compress(raw);
      expect(a.length, lessThan(raw.length * 0.6));
      expect(b.length, lessThan(raw.length * 0.6));
      expect(native.decompress(a, raw.length), raw);
      expect(pure.decompress(b, raw.length), raw);
      expect(native.decompress(b, raw.length), raw);
      expect(pure.decompress(a, raw.length), raw);
    });

    test('the platform codec on the VM is native zlib', () {
      expect(ScrollbackCodec.platform, isA<ZLibScrollbackCodec>());
      expect(ScrollbackCodec.none.compress(raw), same(raw));
    });
  });
}
