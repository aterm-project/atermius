import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/insecure_server.dart';
import '../api/server_transport.dart';

WebSocketChannel createTerminalCollaborationWebSocketChannel(
  Uri uri, {
  InsecureServerPermission? insecure,
}) => connectServerWebSocket(uri, insecure: insecure);

int? terminalCollaborationWebSocketBufferedAmount(WebSocketChannel channel) =>
    null;
