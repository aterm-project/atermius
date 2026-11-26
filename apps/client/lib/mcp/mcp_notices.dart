import 'dart:async';

/// How a message an AI client posts with `ui_notify` is presented.
enum McpNoticeLevel { info, success, warning, error }

/// A message an external AI client asked Atermius to show the user.
class McpNotice {
  McpNotice(this.message, this.level, {this.source}) : at = DateTime.now();

  /// Plain text, already bounded by the tool schema. Never markup.
  final String message;
  final McpNoticeLevel level;

  /// Session the message is about, if the client named one.
  final String? source;
  final DateTime at;
}

/// Carries `ui_notify` messages from the tool runner to whatever UI is
/// showing MCP activity. Nothing is stored; a message with no listener is
/// simply not shown.
abstract final class McpNotices {
  static final _controller = StreamController<McpNotice>.broadcast(sync: false);

  static Stream<McpNotice> get stream => _controller.stream;

  static bool get hasListener => _controller.hasListener;

  static void post(McpNotice notice) => _controller.add(notice);
}
