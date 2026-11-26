import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:xterm/xterm.dart';

import 'mcp_activity.dart';
import 'mcp_regex.dart';
import 'mcp_workspace.dart';

/// Text of one terminal row as it is shown: blank cells inside the row are
/// spaces (tab stops, cursor jumps), blank cells at its end are dropped and a
/// wide glyph appears once. [from] skips the cells before that column.
String mcpRowText(BufferLine line, {int from = 0}) {
  final length = line.getTrimmedLength(line.length);
  final text = StringBuffer();
  for (var column = from; column < length; column++) {
    final codePoint = line.getCodePoint(column);
    if (codePoint != 0) {
      text.writeCharCode(codePoint);
    } else if (!(line.getWidth(column) == 0 &&
        column > 0 &&
        line.getWidth(column - 1) == 2)) {
      text.writeCharCode(0x20);
    }
  }
  return text.toString();
}

int _utf8Length(String text) {
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xd800 && unit < 0xdc00 && i + 1 < text.length) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

/// A tail of terminal text: [text] starts at absolute line [first].
typedef McpTerminalSlice = ({String text, int first, bool clipped});

/// One terminal screen buffer addressed by absolute line numbers.
///
/// A row keeps its number for as long as it is retained, also while older
/// rows are dropped, so a client can continue reading where it stopped. The
/// normal and the alternate screen (full-screen programs) number their rows
/// independently.
class McpTerminalView {
  McpTerminalView(this.terminal, [Buffer? buffer])
    : buffer = buffer ?? terminal.buffer;
  final Terminal terminal;
  final Buffer buffer;

  /// Number of the oldest retained row.
  int get start => buffer.lines.absoluteStartIndex;

  /// Number of the row that holds the cursor.
  int get cursor => start + buffer.absoluteCursorY;

  /// One past the last row with text, and never before the cursor row: the
  /// empty rows of the screen below the cursor are left out.
  int get end {
    final lines = buffer.lines;
    final cursorRow = buffer.absoluteCursorY;
    var row = lines.length - 1;
    while (row > cursorRow && lines[row].getTrimmedLength() == 0) {
      row--;
    }
    return start + (row > cursorRow ? row : cursorRow) + 1;
  }

  /// Number of the top row of the screen.
  int get screenTop =>
      start + math.max(0, buffer.lines.length - buffer.viewHeight);

  BufferLine row(int line) => buffer.lines[line - start];

  /// Rows [from, to) as text, keeping at most the newest [maxRows] rows and
  /// [maxBytes] UTF-8 bytes. Rows that continue a soft-wrapped line are
  /// joined to it; [joinWrapped] false keeps one text line per row.
  McpTerminalSlice slice(
    int from,
    int to, {
    required int maxRows,
    required int maxBytes,
    bool joinWrapped = true,
  }) {
    from = math.max(from, start);
    to = math.max(from, to);
    final lowest = math.max(from, to - maxRows);
    // Newest first, so an early start never reads more than the budget.
    final rows = <String>[];
    final wrapped = <bool>[];
    var bytes = 0;
    var first = to;
    while (first > lowest) {
      final row = this.row(first - 1);
      final text = mcpRowText(row);
      final size = _utf8Length(text) + 1;
      if (rows.isNotEmpty && bytes + size > maxBytes) break;
      rows.add(text);
      wrapped.add(joinWrapped && row.isWrapped);
      bytes += size;
      first--;
    }
    final text = StringBuffer();
    for (var i = rows.length - 1; i >= 0; i--) {
      text.write(rows[i]);
      if (i > 0 && !wrapped[i - 1]) text.write('\n');
    }
    var result = text.toString();
    var cut = false;
    if (bytes > maxBytes + 1) {
      // One row wider than the budget (an extremely wide terminal).
      var at = result.length - maxBytes ~/ 4;
      if ((result.codeUnitAt(at) & 0xfc00) == 0xdc00) at++;
      result = result.substring(at);
      cut = true;
    }
    return (text: result, first: first, clipped: first > from || cut);
  }

  /// Lines of rows [from, to) with soft-wrapped rows joined: the number of
  /// the first row of each and its text.
  /// [firstColumn] skips the cells of row [from] before that column.
  ({List<int> numbers, List<String> texts}) logicalLines(
    int from,
    int to, {
    int firstColumn = 0,
  }) {
    final numbers = <int>[];
    final texts = <String>[];
    StringBuffer? current;
    for (var line = math.max(from, start); line < to; line++) {
      final row = this.row(line);
      if (current == null || !row.isWrapped) {
        if (current != null) texts.add(current.toString());
        numbers.add(line);
        current = StringBuffer();
      }
      current.write(mcpRowText(row, from: line == from ? firstColumn : 0));
    }
    if (current != null) texts.add(current.toString());
    return (numbers: numbers, texts: texts);
  }

  /// Text of the visible screen, one entry per row from its top.
  List<String> screenRows() {
    final lines = buffer.lines;
    final top = math.max(0, lines.length - buffer.viewHeight);
    return [for (var i = top; i < lines.length; i++) mcpRowText(lines[i])];
  }
}

/// Named keys for `terminal_send_keys`, in the order they are documented.
const mcpTerminalKeys = [
  'enter',
  'tab',
  'shift_tab',
  'escape',
  'backspace',
  'delete',
  'insert',
  'up',
  'down',
  'left',
  'right',
  'home',
  'end',
  'page_up',
  'page_down',
  'space',
  'f1',
  'f2',
  'f3',
  'f4',
  'f5',
  'f6',
  'f7',
  'f8',
  'f9',
  'f10',
  'f11',
  'f12',
  'ctrl_a',
  'ctrl_b',
  'ctrl_c',
  'ctrl_d',
  'ctrl_e',
  'ctrl_f',
  'ctrl_g',
  'ctrl_h',
  'ctrl_i',
  'ctrl_j',
  'ctrl_k',
  'ctrl_l',
  'ctrl_m',
  'ctrl_n',
  'ctrl_o',
  'ctrl_p',
  'ctrl_q',
  'ctrl_r',
  'ctrl_s',
  'ctrl_t',
  'ctrl_u',
  'ctrl_v',
  'ctrl_w',
  'ctrl_x',
  'ctrl_y',
  'ctrl_z',
  'ctrl_backslash',
  'ctrl_bracket_right',
  'ctrl_at',
];

/// What a key sends, as xterm's default key table does. [cursorKeysMode]
/// (DECCKM, set by full-screen programs) switches arrows, Home and End to
/// their application sequences.
String mcpKeySequence(String key, {required bool cursorKeysMode}) {
  final cursor = cursorKeysMode ? '\x1bO' : '\x1b[';
  if (key.startsWith('ctrl_') && key.length == 6) {
    return String.fromCharCode(key.codeUnitAt(5) - 0x60);
  }
  return switch (key) {
    'enter' => '\r',
    'tab' => '\t',
    'shift_tab' => '\x1b[Z',
    'escape' => '\x1b',
    'backspace' => '\x7f',
    'delete' => '\x1b[3~',
    'insert' => '\x1b[2~',
    'up' => '${cursor}A',
    'down' => '${cursor}B',
    'right' => '${cursor}C',
    'left' => '${cursor}D',
    'home' => '${cursor}H',
    'end' => '${cursor}F',
    'page_up' => '\x1b[5~',
    'page_down' => '\x1b[6~',
    'space' => ' ',
    'f1' => '\x1bOP',
    'f2' => '\x1bOQ',
    'f3' => '\x1bOR',
    'f4' => '\x1bOS',
    'f5' => '\x1b[15~',
    'f6' => '\x1b[17~',
    'f7' => '\x1b[18~',
    'f8' => '\x1b[19~',
    'f9' => '\x1b[20~',
    'f10' => '\x1b[21~',
    'f11' => '\x1b[23~',
    'f12' => '\x1b[24~',
    'ctrl_backslash' => '\x1c',
    'ctrl_bracket_right' => '\x1d',
    'ctrl_at' => '\x00',
    _ => throw ArgumentError.value(key, 'key'),
  };
}

/// Longest a regular expression may run on one batch of lines.
const mcpPatternTimeout = Duration(seconds: 3);

/// A literal or regular-expression pattern from an AI client, matched line
/// by line. Literal patterns are matched here; regular expressions in a
/// [McpRegexEngine]. [close] it when done.
class McpTextPattern {
  McpTextPattern._(this.source, this.regex, this.caseSensitive);

  /// Throws `invalid_arguments` for an invalid regular expression.
  factory McpTextPattern(
    String source, {
    bool regex = false,
    bool caseSensitive = false,
  }) {
    if (regex) {
      try {
        RegExp(source, caseSensitive: caseSensitive);
      } on FormatException {
        throw const McpToolException(
          'invalid_arguments',
          'The pattern is not a valid regular expression (JavaScript syntax).',
        );
      }
    }
    return McpTextPattern._(source, regex, caseSensitive);
  }

  final String source;
  final bool regex, caseSensitive;
  Future<McpRegexEngine>? _engine;
  bool _closed = false;

  /// The newest matching lines of [lines], at most [max], oldest first, as
  /// (line index, match offset); [more] when older matches were left out.
  Future<({List<(int, int)> hits, bool more})> newest(
    List<String> lines,
    int max,
  ) async {
    final List<int> flat;
    if (regex) {
      try {
        if (_closed) throw StateError('closed');
        final engine = await (_engine ??= McpRegexEngine.start(
          source,
          caseSensitive: caseSensitive,
        ));
        flat = await engine.newest(lines, max + 1, mcpPatternTimeout);
      } on TimeoutException {
        throw const McpToolException(
          'pattern_timeout',
          'The regular expression took too long. Use a literal pattern or a simpler expression without nested repetition.',
        );
      } on StateError {
        // The worker stopped (for example a stack overflow on deep nesting).
        throw const McpToolException(
          'pattern_failed',
          'The regular expression could not be evaluated. Use a literal pattern or a simpler expression.',
        );
      }
    } else {
      flat = [];
      final needle = caseSensitive ? source : source.toLowerCase();
      for (
        var i = lines.length - 1;
        i >= 0 && flat.length < (max + 1) * 2;
        i--
      ) {
        final at = (caseSensitive ? lines[i] : lines[i].toLowerCase()).indexOf(
          needle,
        );
        if (at >= 0) flat.addAll([i, at]);
      }
    }
    final hits = [
      for (var i = 0; i + 1 < flat.length; i += 2) (flat[i], flat[i + 1]),
    ];
    final more = hits.length > max;
    return (hits: hits.take(max).toList().reversed.toList(), more: more);
  }

  void close() {
    _closed = true;
    _engine?.then((engine) => engine.close(), onError: (_) {});
  }
}

/// Outcome of [mcpWaitForTerminal].
typedef McpWaitResult = ({
  bool matched,
  bool idle,
  bool timedOut,
  McpTerminalSlice slice,

  /// Lines after `since` were left out (no longer retained, or over the
  /// byte budget).
  bool truncated,
  int cursor,
  int waitedMs,
});

/// Most rows after the starting line a pattern is matched against.
const mcpWaitMatchRows = 2000;

/// Waits until [pattern] appears after line [since] of the screen that is
/// active now, or, without a pattern, until nothing has changed for [idle];
/// at most [timeout]. Polls every [poll] and wakes as soon as the call is
/// cancelled ([check] then throws).
///
/// [sinceColumn] leaves out what row [since] held before that column (the
/// prompt the cursor was at). [echo] is a command just typed: its echo on
/// the first line is not matched, so a pattern that is part of the command
/// cannot match it.
Future<McpWaitResult> mcpWaitForTerminal(
  Terminal terminal, {
  required int since,
  int sinceColumn = 0,
  required McpTextPattern? pattern,
  required Duration idle,
  required Duration timeout,
  required void Function() check,
  required void Function(void Function()) onCancel,
  required int maxBytes,
  String? echo,
  Duration poll = const Duration(milliseconds: 100),
}) async {
  final view = McpTerminalView(terminal);
  final started = clock.now();
  var lastChange = started;
  String? lastSignature;
  var matched = false, idled = false, timedOut = false;
  Completer<void>? sleeping;
  Timer? timer;
  onCancel(() {
    timer?.cancel();
    final current = sleeping;
    if (current != null && !current.isCompleted) current.complete();
  });
  while (true) {
    check();
    final now = clock.now();
    final signature = _signature(terminal);
    final changed = signature != lastSignature;
    if (changed) {
      lastSignature = signature;
      lastChange = now;
    }
    if (pattern != null) {
      if (changed &&
          await _patternFound(view, since, sinceColumn, pattern, echo)) {
        check();
        matched = true;
        break;
      }
      check();
    } else if (!changed && clock.now().difference(lastChange) >= idle) {
      idled = true;
      break;
    }
    if (clock.now().difference(started) >= timeout) {
      timedOut = true;
      break;
    }
    final wake = sleeping = Completer<void>();
    timer = Timer(poll, () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
  }
  final slice = view.slice(
    math.min(since, view.cursor),
    view.end,
    maxRows: 1 << 30,
    maxBytes: maxBytes,
  );
  return (
    matched: matched,
    idle: idled,
    timedOut: timedOut,
    slice: slice,
    truncated: slice.clipped || since < view.start,
    cursor: view.cursor,
    waitedMs: clock.now().difference(started).inMilliseconds,
  );
}

/// Changes whenever the active screen does: its rows, its scrollback and
/// the cursor.
String _signature(Terminal terminal) {
  final buffer = terminal.buffer;
  final lines = buffer.lines;
  return [
    terminal.isUsingAltBuffer,
    lines.absoluteStartIndex,
    lines.length,
    buffer.cursorX,
    buffer.absoluteCursorY,
    ...McpTerminalView(terminal).screenRows(),
  ].join('\u0000');
}

Future<bool> _patternFound(
  McpTerminalView view,
  int since,
  int sinceColumn,
  McpTextPattern pattern,
  String? echo,
) async {
  final from = math.max(
    math.min(since, view.cursor),
    view.end - mcpWaitMatchRows,
  );
  final lines = view.logicalLines(
    from,
    view.end,
    firstColumn: from == since ? sinceColumn : 0,
  );
  final texts = lines.texts;
  if (echo != null && texts.isNotEmpty && lines.numbers.first == since) {
    final at = texts.first.indexOf(echo);
    if (at >= 0) texts[0] = texts.first.substring(at + echo.length);
  }
  for (var i = 0; i < texts.length; i++) {
    if (McpActivity.isAnnouncement(texts[i])) texts[i] = '';
  }
  // A full-screen program that took over meanwhile is matched as well.
  final terminal = view.terminal;
  if (!identical(terminal.buffer, view.buffer)) {
    texts.addAll(McpTerminalView(terminal).screenRows());
  }
  return (await pattern.newest(texts, 1)).hits.isNotEmpty;
}
