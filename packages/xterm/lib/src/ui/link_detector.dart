import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';

const _maxTokenCells = 4096;
final _separator = RegExp(
  r'''[\s\x00-\x20\x7f-\x9f<>"'`|，。；：！？、“”‘’《》【】（）'''
  r'\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
);
final _urlStart =
    RegExp(r'(?:^|[([{])((?:https?://|www\.).+)', caseSensitive: false);

/// Finds a web URL at [cell] in the displayed buffer, joining soft wraps.
Uri? terminalLinkAt(Buffer buffer, CellOffset cell) {
  final width = buffer.viewWidth;
  final lines = buffer.lines;
  final line = lines[cell.y];
  if (cell.x >= line.length) return null;

  // A wide glyph can put its second cell at the start of a wrapped row.
  // Unlike an erased cell, that continuation does not break a token.
  bool isWideContinuation(int row, int col) {
    if (col > 0) return lines[row].getWidth(col - 1) == 2;
    if (row == 0 || !lines[row].isWrapped) return false;
    final previous = lines[row - 1];
    return previous.length >= width && previous.getWidth(width - 1) == 2;
  }

  var center = cell.y * width + cell.x;
  var glyph = line.getCodePoint(cell.x);
  if (glyph == 0 && isWideContinuation(cell.y, cell.x)) {
    center--;
    glyph = lines[center ~/ width].getCodePoint(center % width);
  }
  if (glyph == 0 || _separator.hasMatch(String.fromCharCode(glyph)))
    return null;

  // Read only the token around the pointer. A very long token is ignored
  // rather than turning a truncated prefix into a different destination.
  final end = lines.length * width;
  List<int>? scan(int step) {
    final runes = <int>[];
    var previousRow = center ~/ width;
    for (var index = center + step; index >= 0 && index < end; index += step) {
      final row = index ~/ width;
      if (row != previousRow &&
          !lines[row > previousRow ? row : previousRow].isWrapped) {
        break;
      }
      previousRow = row;
      final current = lines[row];
      final col = index % width;
      if (col >= current.length) break;
      final rune = current.getCodePoint(col);
      if (rune == 0) {
        if (isWideContinuation(row, col)) continue;
        break;
      }
      if (_separator.hasMatch(String.fromCharCode(rune))) break;
      if ((index - center).abs() >= _maxTokenCells) return null;
      runes.add(rune);
    }
    return runes;
  }

  final before = scan(-1);
  if (before == null) return null;
  final after = scan(1);
  if (after == null) return null;
  final prefix = String.fromCharCodes(before.reversed);
  final token = '$prefix${String.fromCharCode(glyph)}'
      '${String.fromCharCodes(after)}';
  if (token.length > _maxTokenCells) return null;
  final match = _urlStart.firstMatch(token);
  if (match == null) return null;
  final candidate = match.group(1)!;
  final url = _trimTrailingPunctuation(candidate);
  final start = match.end - candidate.length;
  if (prefix.length < start || prefix.length >= start + url.length) return null;
  if (url.contains('\\')) return null;

  final uri = Uri.tryParse(
    url.toLowerCase().startsWith('www.') ? 'https://$url' : url,
  );
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.authority.contains('@')) {
    return null;
  }
  return uri;
}

String _trimTrailingPunctuation(String text) {
  const closing = {'(': ')', '[': ']', '{': '}'};
  final remaining = {')': 0, ']': 0, '}': 0};
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    final close = closing[char];
    if (close != null) {
      remaining[close] = remaining[close]! - 1;
    } else if (remaining.containsKey(char)) {
      remaining[char] = remaining[char]! + 1;
    }
  }
  var end = text.length;
  while (end > 0) {
    final char = text[end - 1];
    if ('.:,;!?'.contains(char)) {
      end--;
    } else if ((remaining[char] ?? 0) > 0) {
      remaining[char] = remaining[char]! - 1;
      end--;
    } else {
      break;
    }
  }
  return text.substring(0, end);
}
