import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/utils/unicode_v11.dart';

/// Compact, lossless serialization of a run of [BufferLine]s.
///
/// A hot [BufferLine] spends 16 bytes on every cell of its capacity. Here a
/// block of lines is stored column-wise instead, which is already 20 to 40
/// times smaller for ordinary text before any general-purpose compression:
///
/// ```
/// varint  format version (1)
/// varint  line count
/// varint  total cell count
/// lines   one varint per line: storedCells << 1 | wrapped
/// varint  style count
/// styles  per style: varint foreground, varint background, varint attributes
/// varint  byte length of the run section
/// runs    (varint style index, varint run length)..., covering all cells in
///         order; runs continue across line boundaries
/// varint  width exception count
/// varint  byte length of the exception section
/// excs    (varint cell index delta, varint width bits)...
/// content one varint per cell: the low 22 bits of the content word
/// ```
///
/// What is stored per line are the visible cells without the trailing cells
/// that are completely default (no character, default colors, no attributes).
/// Every stored cell is restored bit for bit: the three style words through
/// the style table, the code point from the content section, and the width
/// bits of the content word either from `wcwidth` (what the terminal writes)
/// or, when a cell deviates from that, from the exception section.
const _formatVersion = 1;

const _cellSize = 4;

/// Low bits of the content word: the code point and the one unused bit above
/// it. The remaining high bits hold the cell width.
const _contentMask = 0x3fffff;

const _widthShift = 22;

/// Number of visible cells of [line] up to and including the last one that is
/// not completely default.
int storedCellCount(BufferLine line) {
  final data = line.data;
  var cells = min(line.length, data.length ~/ _cellSize);
  var offset = cells * _cellSize;
  while (cells > 0 &&
      data[offset - 1] == 0 &&
      data[offset - 2] == 0 &&
      data[offset - 3] == 0 &&
      data[offset - 4] == 0) {
    cells--;
    offset -= _cellSize;
  }
  return cells;
}

class _ByteWriter {
  Uint8List bytes = Uint8List(1024);

  int length = 0;

  @pragma('vm:prefer-inline')
  void reserve(int extra) {
    if (length + extra > bytes.length) {
      _grow(length + extra);
    }
  }

  void _grow(int needed) {
    var capacity = bytes.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    bytes = Uint8List(capacity)..setRange(0, length, bytes);
  }

  @pragma('vm:prefer-inline')
  void varint(int value) {
    reserve(5);
    while (value >= 0x80) {
      bytes[length++] = (value & 0x7f) | 0x80;
      value >>= 7;
    }
    bytes[length++] = value;
  }
}

// Scratch space shared by every terminal of the isolate. Encoding is
// synchronous and never re-entered.
final _lineSection = _ByteWriter();
final _styleSection = _ByteWriter();
final _runSection = _ByteWriter();
final _exceptionSection = _ByteWriter();
final _contentSection = _ByteWriter();
final _header = _ByteWriter();
final _styleIndexByHash = <int, int>{};
var _styleForeground = Uint32List(64);
var _styleBackground = Uint32List(64);
var _styleAttributes = Uint32List(64);

/// Serializes the first [count] lines of [lines].
Uint8List encodeLineBlock(List<BufferLine> lines, [int? count]) {
  count ??= lines.length;

  final lineSection = _lineSection..length = 0;
  final styleSection = _styleSection..length = 0;
  final runSection = _runSection..length = 0;
  final exceptionSection = _exceptionSection..length = 0;
  final contentSection = _contentSection..length = 0;
  final styleIndexByHash = _styleIndexByHash..clear();

  var styleCount = 0;
  var totalCells = 0;
  var exceptionCount = 0;
  var lastException = 0;

  var foreground = -1;
  var background = -1;
  var attributes = -1;
  var style = 0;
  var run = 0;

  for (var i = 0; i < count; i++) {
    final line = lines[i];
    final data = line.data;
    final cells = storedCellCount(line);
    lineSection.varint(cells << 1 | (line.isWrapped ? 1 : 0));

    // At most three bytes per code point below 2^22, plus one of slack.
    contentSection.reserve(cells * 4);
    final content = contentSection.bytes;
    var contentLength = contentSection.length;

    final end = cells * _cellSize;
    for (var offset = 0; offset < end; offset += _cellSize) {
      final fg = data[offset];
      final bg = data[offset + 1];
      final attrs = data[offset + 2];
      if (fg != foreground || bg != background || attrs != attributes) {
        if (run > 0) {
          runSection.varint(style);
          runSection.varint(run);
          run = 0;
        }
        foreground = fg;
        background = bg;
        attributes = attrs;

        // Exact below 2^53, so it behaves the same compiled to JavaScript.
        final hash = (fg * 31 + bg) * 31 + attrs;
        final known = styleIndexByHash[hash];
        if (known != null &&
            _styleForeground[known] == fg &&
            _styleBackground[known] == bg &&
            _styleAttributes[known] == attrs) {
          style = known;
        } else {
          // A hash collision only costs a duplicate table entry.
          if (styleCount == _styleForeground.length) {
            _styleForeground = Uint32List(styleCount * 2)
              ..setRange(0, styleCount, _styleForeground);
            _styleBackground = Uint32List(styleCount * 2)
              ..setRange(0, styleCount, _styleBackground);
            _styleAttributes = Uint32List(styleCount * 2)
              ..setRange(0, styleCount, _styleAttributes);
          }
          style = styleCount++;
          _styleForeground[style] = fg;
          _styleBackground[style] = bg;
          _styleAttributes[style] = attrs;
          styleIndexByHash[hash] = style;
          styleSection.varint(fg);
          styleSection.varint(bg);
          styleSection.varint(attrs);
        }
      }
      run++;

      final word = data[offset + 3];
      var codePoint = word & _contentMask;
      final width = word >> _widthShift;
      final expected = codePoint >= 32 && codePoint < 127
          ? 1
          : unicodeV11.wcwidth(codePoint);
      if (width != expected) {
        exceptionSection.varint(totalCells - lastException);
        exceptionSection.varint(width);
        lastException = totalCells;
        exceptionCount++;
      }

      while (codePoint >= 0x80) {
        content[contentLength++] = (codePoint & 0x7f) | 0x80;
        codePoint >>= 7;
      }
      content[contentLength++] = codePoint;
      totalCells++;
    }
    contentSection.length = contentLength;
  }

  if (run > 0) {
    runSection.varint(style);
    runSection.varint(run);
  }

  final header = _header..length = 0;
  header.varint(_formatVersion);
  header.varint(count);
  header.varint(totalCells);

  final result = Uint8List(
    header.length +
        lineSection.length +
        styleSection.length +
        runSection.length +
        exceptionSection.length +
        contentSection.length +
        20,
  );
  var length = 0;

  void append(_ByteWriter section) {
    result.setRange(length, length + section.length, section.bytes);
    length += section.length;
  }

  void appendVarint(int value) {
    header
      ..length = 0
      ..varint(value);
    append(header);
  }

  append(header);
  append(lineSection);
  appendVarint(styleCount);
  append(styleSection);
  appendVarint(runSection.length);
  append(runSection);
  appendVarint(exceptionCount);
  appendVarint(exceptionSection.length);
  append(exceptionSection);
  append(contentSection);

  return Uint8List.sublistView(result, 0, length);
}

class _ByteReader {
  _ByteReader(this.bytes, this.position, this.end);

  final Uint8List bytes;

  int position;

  final int end;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (position >= end || shift > 28) {
        throw const FormatException('Malformed scrollback block');
      }
      final byte = bytes[position++];
      result |= (byte & 0x7f) << shift;
      if (byte < 0x80) {
        return result;
      }
      shift += 7;
    }
  }
}

/// Restores the lines written by [encodeLineBlock].
///
/// Every line shows [viewWidth] cells, like any other line of the buffer. A
/// line that was stored with more cells than that (the view was wider when it
/// was archived) keeps them in its data, the same way [BufferLine.resize]
/// keeps the cells of a line that is made shorter, so they come back when the
/// view is widened again.
///
/// Throws a [FormatException] when [bytes] is not a block of exactly
/// [expectedLines] lines.
List<BufferLine> decodeLineBlock(
  Uint8List bytes,
  int viewWidth, {
  int? expectedLines,
}) {
  final reader = _ByteReader(bytes, 0, bytes.length);
  if (reader.varint() != _formatVersion) {
    throw const FormatException('Unknown scrollback block version');
  }
  final lineCount = reader.varint();
  final totalCells = reader.varint();
  if (expectedLines != null && lineCount != expectedLines) {
    throw const FormatException('Unexpected scrollback block size');
  }
  // Every line and every cell takes at least one byte.
  if (lineCount > bytes.length || totalCells > bytes.length) {
    throw const FormatException('Malformed scrollback block');
  }

  final lineHeaders = Uint32List(lineCount);
  var cellSum = 0;
  for (var i = 0; i < lineCount; i++) {
    final header = reader.varint();
    lineHeaders[i] = header;
    cellSum += header >> 1;
  }
  if (cellSum != totalCells) {
    throw const FormatException('Malformed scrollback block');
  }

  final styleCount = reader.varint();
  if (styleCount > bytes.length) {
    throw const FormatException('Malformed scrollback block');
  }
  final styleForeground = Uint32List(styleCount);
  final styleBackground = Uint32List(styleCount);
  final styleAttributes = Uint32List(styleCount);
  for (var i = 0; i < styleCount; i++) {
    styleForeground[i] = reader.varint();
    styleBackground[i] = reader.varint();
    styleAttributes[i] = reader.varint();
  }

  final runLength = reader.varint();
  final runs = _ByteReader(bytes, reader.position, reader.position + runLength);
  reader.position += runLength;

  var exceptionsLeft = reader.varint();
  final exceptionLength = reader.varint();
  final exceptions = _ByteReader(
    bytes,
    reader.position,
    reader.position + exceptionLength,
  );
  reader.position += exceptionLength;
  if (runs.end > bytes.length ||
      exceptions.end > bytes.length ||
      reader.position > bytes.length) {
    throw const FormatException('Malformed scrollback block');
  }

  var nextException = -1;
  var exceptionWidth = 0;
  if (exceptionsLeft > 0) {
    nextException = exceptions.varint();
    exceptionWidth = exceptions.varint();
    exceptionsLeft--;
  }

  final end = bytes.length;
  var position = reader.position;
  var cell = 0;
  var runLeft = 0;
  var foreground = 0;
  var background = 0;
  var attributes = 0;

  final lines = List<BufferLine>.filled(lineCount, _placeholder);
  for (var i = 0; i < lineCount; i++) {
    final header = lineHeaders[i];
    final cells = header >> 1;
    final data = Uint32List(
      BufferLine.capacityFor(max(cells, viewWidth)) * _cellSize,
    );

    for (var offset = 0; offset < cells * _cellSize; offset += _cellSize) {
      if (runLeft == 0) {
        final style = runs.varint();
        runLeft = runs.varint();
        if (style >= styleCount || runLeft == 0) {
          throw const FormatException('Malformed scrollback block');
        }
        foreground = styleForeground[style];
        background = styleBackground[style];
        attributes = styleAttributes[style];
      }
      runLeft--;

      var codePoint = 0;
      var shift = 0;
      while (true) {
        if (position >= end || shift > 21) {
          throw const FormatException('Malformed scrollback block');
        }
        final byte = bytes[position++];
        codePoint |= (byte & 0x7f) << shift;
        if (byte < 0x80) {
          break;
        }
        shift += 7;
      }

      int width;
      if (cell == nextException) {
        width = exceptionWidth;
        if (exceptionsLeft > 0) {
          nextException += exceptions.varint();
          exceptionWidth = exceptions.varint();
          exceptionsLeft--;
        } else {
          nextException = -1;
        }
      } else {
        width = codePoint >= 32 && codePoint < 127
            ? 1
            : unicodeV11.wcwidth(codePoint);
      }

      data[offset] = foreground;
      data[offset + 1] = background;
      data[offset + 2] = attributes;
      data[offset + 3] = codePoint | (width << _widthShift);
      cell++;
    }

    lines[i] = BufferLine.fromData(data, viewWidth, isWrapped: header & 1 == 1);
  }

  return lines;
}

final _placeholder = BufferLine(0);
