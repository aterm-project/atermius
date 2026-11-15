import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/insecure_server.dart';
import 'terminal_collaboration_websocket_stub.dart'
    if (dart.library.js_interop) 'terminal_collaboration_websocket_web.dart'
    as platform;

/// Creates a browser-backed channel on Web so its transport buffer is
/// observable. Native builds use the account server transport, which applies
/// [insecure] (the server's development-only permission) to that origin only.
WebSocketChannel createTerminalCollaborationWebSocketChannel(
  Uri uri, {
  InsecureServerPermission? insecure,
}) => platform.createTerminalCollaborationWebSocketChannel(
  uri,
  insecure: insecure,
);

/// Returns the browser WebSocket's queued outbound byte count, or null when
/// the platform channel does not expose that value.
int? terminalCollaborationWebSocketBufferedAmount(WebSocketChannel channel) =>
    platform.terminalCollaborationWebSocketBufferedAmount(channel);
