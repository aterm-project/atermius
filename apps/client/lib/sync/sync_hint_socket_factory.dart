import '../api/insecure_server.dart';
import 'sync_hint_socket.dart';
import 'sync_hint_socket_stub.dart'
    if (dart.library.io) 'sync_hint_socket_io.dart'
    as platform;

/// [insecure] is the account server's development-only permission; it is
/// applied to that origin only.
Future<SyncHintSocket> connectSyncHintSocket(
  Uri uri, {
  required String origin,
  InsecureServerPermission? insecure,
}) => platform.connectSyncHintSocket(uri, origin: origin, insecure: insecure);
