import 'mcp_regex.dart';

/// Without isolates (web) matching runs inline; MCP is not served there.
Future<McpRegexEngine> startRegexEngine(
  String pattern,
  bool caseSensitive,
) async => _InlineRegexEngine(RegExp(pattern, caseSensitive: caseSensitive));

class _InlineRegexEngine implements McpRegexEngine {
  _InlineRegexEngine(this._regex);
  final RegExp _regex;

  @override
  Future<List<int>> newest(
    List<String> lines,
    int max,
    Duration timeout,
  ) async => mcpNewestRegexHits(_regex, lines, max);

  @override
  void close() {}
}
