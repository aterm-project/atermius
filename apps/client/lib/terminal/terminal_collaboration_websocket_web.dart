import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/insecure_server.dart';

// A browser decides certificate trust itself; [insecure] changes nothing here.
WebSocketChannel createTerminalCollaborationWebSocketChannel(
  Uri uri, {
  InsecureServerPermission? insecure,
}) => HtmlWebSocketChannel.connect(uri);

int? terminalCollaborationWebSocketBufferedAmount(WebSocketChannel channel) =>
    channel is HtmlWebSocketChannel ? channel.bufferedAmount : null;
