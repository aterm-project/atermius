import 'package:web_socket_channel/web_socket_channel.dart';

import '../api/insecure_server.dart';
import 'sync_hint_socket.dart';

Future<SyncHintSocket> connectSyncHintSocket(
  Uri uri, {
  required String origin,
  InsecureServerPermission? insecure,
}) async {
  // A browser decides certificate trust itself; [insecure] changes nothing.
  // Browsers set Origin from the page URL and do not let JavaScript override
  // it. The server checks the exact configured public origin.
  return WebSocketChannelSyncHintSocket(WebSocketChannel.connect(uri));
}
