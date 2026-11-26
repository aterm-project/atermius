import 'dart:convert';

import 'mcp_activity.dart';
import 'mcp_tools.dart';

/// Longest argument summary kept for one call.
const mcpSummaryLength = 160;

/// Arguments that identify what a call acts on; the target name is shown
/// instead of the ID.
const _identifiers = {'session_id', 'host_id'};

/// Arguments that say nothing a person needs to see.
const _noise = {'expected_sha256', 'timeout_seconds'};

/// Arguments that carry file or document contents: only their size is
/// shown. `terminal_write` text is what the AI types, so it is shown.
const _contents = {'text', 'content', 'contents', 'data', 'body'};

/// Shown first and bare (without `name=`), in this order.
const _primary = [
  'command',
  'path',
  'pattern',
  'query',
  'keys',
  'message',
  'topic',
  'text',
];

/// The human-readable title of [tool] (its MCP `title`), or the tool name
/// for tools this build does not describe.
String mcpToolTitle(String tool) {
  for (final definition in mcpTools) {
    if (definition.name == tool) return definition.title;
  }
  return tool;
}

/// What a call asks for on one printable line: the command, path, keys or
/// message first, then the remaining arguments as `name=value`. Session and
/// host IDs are left out (the target is shown by name) and file contents are
/// never included, only their size. Control characters become visible
/// escapes and the line is cut at [max] characters.
String summarizeArguments(
  String tool,
  Map<String, dynamic> arguments, {
  int max = mcpSummaryLength,
}) {
  final parts = <String>[];
  final shown = <String>{..._identifiers, ..._noise};
  bool isContent(String key) => _contents.contains(key) && !_typed(tool);
  for (final key in _primary) {
    if (!arguments.containsKey(key) || isContent(key)) continue;
    final value = _value(key, arguments[key]);
    shown.add(key);
    if (value != null && value.isNotEmpty) parts.add(value);
  }
  if (arguments['from'] case final Object from) {
    final to = arguments['to'];
    parts.add(
      '${_value('from', from)} → ${to == null ? '?' : _value('to', to)}',
    );
    shown.addAll(const ['from', 'to']);
  }
  for (final entry in arguments.entries) {
    if (shown.contains(entry.key) || entry.value == null) continue;
    if (_contents.contains(entry.key)) {
      parts.add(_size(entry.value));
      continue;
    }
    final value = _value(entry.key, entry.value);
    if (value != null) parts.add('${entry.key}=$value');
  }
  return printableSummary(parts.join(' · '), max: max);
}

/// A short outcome of a successful call (`exit 0`, `timed out`, `12 items`,
/// `matched`, `4096 bytes`, `saved` …), or null when there is nothing worth
/// showing beyond "done". Never includes output text.
String? summarizeResult(String tool, Map<String, Object?>? output) {
  if (output == null) return null;
  if (output['timed_out'] == true) return 'timed out';
  if (output['cancelled'] == true) return 'cancelled';
  if (output['exit_signal'] case final String signal when signal.isNotEmpty) {
    return printableSummary('signal $signal', max: 40);
  }
  if (output['exit_code'] case final int code) return 'exit $code';
  if (output['matched'] == true) return 'matched';
  if (output['idle'] == true) return 'idle';
  if (output['items'] case final List items) {
    final total = output['total'];
    if (total is int && total != items.length) {
      return '${items.length} of ${_count(total, 'item')}';
    }
    final more = output['next_offset'] != null ? ' (more)' : '';
    return '${_count(items.length, 'item')}$more';
  }
  switch (output['matches']) {
    case final List matches:
      return _count(matches.length, 'match', 'matches');
    case final int matches:
      return _count(matches, 'match', 'matches');
  }
  if (output['sessions'] case final List sessions) {
    return sessions.length == 1 ? 'opened' : '${sessions.length} opened';
  }
  if (output['line_count'] case final int lines) return _count(lines, 'line');
  if (output['count'] case final int count) {
    return tool == 'ssh_process_snapshot'
        ? _count(count, 'process', 'processes')
        : _count(count, 'item');
  }
  if (output['bytes'] case final int bytes) return _count(bytes, 'byte');
  for (final flag in _flags) {
    if (output[flag] == true) return flag;
  }
  if (tool.startsWith('terminal_') && output['text'] is String) {
    final text = output['text']! as String;
    if (text.isEmpty) return _count(0, 'line');
    return _count('\n'.allMatches(text.trimRight()).length + 1, 'line');
  }
  if (output['hostname'] case final String host when host.isNotEmpty) {
    return printableSummary(host, max: 60);
  }
  return null;
}

/// [McpActivity.printable], also making invisible direction overrides
/// visible so a summary cannot be shown in a misleading order.
String printableSummary(String value, {int max = mcpSummaryLength}) {
  final visible = value.replaceAllMapped(
    _bidi,
    (m) => '\\u{${m[0]!.runes.single.toRadixString(16).padLeft(4, '0')}}',
  );
  return McpActivity.printable(visible, max: max);
}

final _bidi = RegExp('[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]');

const _flags = [
  'saved',
  'sent',
  'shown',
  'written',
  'created',
  'renamed',
  'removed',
  'closed',
  'focused',
];

/// Tools whose `text` argument is typed input rather than file contents.
bool _typed(String tool) => tool == 'terminal_write';

String _count(int count, String one, [String? many]) =>
    '$count ${count == 1 ? one : many ?? '${one}s'}';

String _size(Object? value) => value is String
    ? _count(utf8.encode(value).length, 'byte')
    : value is List
    ? _count(value.length, 'byte')
    : '…';

String? _value(String key, Object? value) => switch (value) {
  null => null,
  final String text => text,
  final List list when key == 'keys' => list.join(' '),
  final List list => list.map((item) => _value(key, item) ?? '').join(', '),
  final Map map => jsonEncode(map),
  _ => value.toString(),
};
