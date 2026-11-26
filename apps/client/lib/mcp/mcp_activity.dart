import 'package:xterm/xterm.dart';

import 'mcp_workspace.dart';

/// Shows what an external AI client does in the session it does it to, so
/// nothing MCP starts happens out of sight: a terminal session gets a dimmed
/// `[MCP] …` line in its own scrollback (local text; nothing is sent to the
/// remote), a remote desktop a notice over its view.
///
/// Lines are plain tool names and arguments, the same in every language, and
/// are part of what `terminal_read` returns afterwards.
abstract final class McpActivity {
  /// Longest argument shown on one line; the rest is elided.
  static const maxValueLength = 240;

  /// Most command output echoed into the terminal after `ssh_exec`.
  static const maxEchoBytes = 4096;
  static const maxEchoLines = 60;

  /// At most one `terminal_read` line per session in this window: clients
  /// poll it while they wait for output.
  static const readInterval = Duration(seconds: 10);

  static final _pending = Expando<List<String>>('mcp activity');

  /// Start of every line [show] writes.
  static const linePrefix = '[MCP] ';

  /// Whether a terminal line is one of these announcements (or remote text
  /// that looks exactly like one). Pattern matching leaves such lines out, so
  /// a wait or search never matches what Atermius itself wrote, such as the
  /// announcement of the `terminal_write` it is waiting on.
  static bool isAnnouncement(String line) => line.startsWith(linePrefix);
  static final _lastRead = Expando<DateTime>('mcp read');

  /// [value] on one line: control characters become visible escapes so a
  /// tool argument can never drive the terminal, and long values are cut.
  static String printable(String value, {int max = maxValueLength}) {
    final buffer = StringBuffer();
    var length = 0;
    for (final rune in value.runes) {
      if (length >= max) {
        buffer.write('…');
        break;
      }
      final text = switch (rune) {
        0x0a => r'\n',
        0x0d => r'\r',
        0x09 => r'\t',
        0x1b => r'\e',
        < 0x20 || 0x7f => '\\x${rune.toRadixString(16).padLeft(2, '0')}',
        >= 0x80 && < 0xa0 => '\\x${rune.toRadixString(16)}',
        _ => String.fromCharCode(rune),
      };
      buffer.write(text);
      length += text.length;
    }
    return buffer.toString();
  }

  /// Announces one step of [tool] in [session]. [detail] is shown after the
  /// tool name; [output] (command output) is echoed below it, bounded.
  static void show(
    McpSession session,
    String tool, {
    String detail = '',
    String? output,
  }) {
    final line = detail.isEmpty
        ? '$linePrefix$tool'
        : '$linePrefix$tool $detail';
    final terminal = session.terminal;
    if (terminal == null) {
      session.notice?.call(line);
      return;
    }
    final lines = [line, ...?_echo(output)];
    // A full-screen program owns the alternate screen; drawing over it would
    // corrupt it. The lines are written once the normal screen is back.
    final queue = _pending[terminal] ??= [];
    queue.addAll(lines);
    if (queue.length > 400) queue.removeRange(0, queue.length - 400);
    flush(terminal);
  }

  /// Writes queued lines unless a full-screen program is active.
  static void flush(Terminal terminal) {
    final queue = _pending[terminal];
    if (queue == null || queue.isEmpty || terminal.isUsingAltBuffer) return;
    final text = StringBuffer();
    for (final line in queue) {
      // Own line, dim cyan, attributes restored; never moves the remote's
      // cursor state beyond a line feed.
      text.write('\r\n\x1b[0;2;36m$line\x1b[0m');
    }
    text.write('\r\n');
    queue.clear();
    terminal.write(text.toString());
  }

  /// Whether a `terminal_read` line is due for [session] (rate limited).
  static bool readDue(McpSession session) {
    final terminal = session.terminal;
    if (terminal == null) return true;
    final now = DateTime.now();
    final last = _lastRead[terminal];
    if (last != null && now.difference(last) < readInterval) return false;
    _lastRead[terminal] = now;
    return true;
  }

  static List<String>? _echo(String? output) {
    if (output == null || output.isEmpty) return null;
    final lines = <String>[];
    var bytes = 0;
    var clipped = false;
    for (final raw in output.split('\n')) {
      final line = printable(raw.replaceAll('\r', ''), max: 400);
      if (lines.length >= maxEchoLines || bytes + line.length > maxEchoBytes) {
        clipped = true;
        break;
      }
      bytes += line.length + 1;
      lines.add('  $line');
    }
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    if (clipped) lines.add('  … (more output was returned to the client)');
    return lines;
  }
}
