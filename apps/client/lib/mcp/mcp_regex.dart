import 'mcp_regex_stub.dart'
    if (dart.library.io) 'mcp_regex_io.dart'
    as platform;

/// Matches a regular expression an AI client supplied against terminal text.
///
/// Dart's regular expressions backtrack, so a pattern such as `(a+)+$` can
/// take practically forever on the wrong line. On native platforms matching
/// therefore runs in its own isolate that is killed when it overruns its
/// time; the application never waits on it.
abstract interface class McpRegexEngine {
  /// Throws [FormatException] for an invalid expression.
  static Future<McpRegexEngine> start(
    String pattern, {
    required bool caseSensitive,
  }) {
    // Syntax errors are reported here, synchronously and cheaply.
    RegExp(pattern, caseSensitive: caseSensitive);
    return platform.startRegexEngine(pattern, caseSensitive);
  }

  /// The newest lines of [lines] that match, newest first, as flat pairs of
  /// line index and match offset; at most [max] pairs. Throws a
  /// `TimeoutException` (and stops the engine) after [timeout].
  Future<List<int>> newest(List<String> lines, int max, Duration timeout);

  void close();
}

/// The matching loop shared by every engine.
List<int> mcpNewestRegexHits(RegExp regex, List<String> lines, int max) {
  final hits = <int>[];
  for (var i = lines.length - 1; i >= 0 && hits.length < max * 2; i--) {
    final match = regex.firstMatch(lines[i]);
    if (match != null) hits.addAll([i, match.start]);
  }
  return hits;
}
