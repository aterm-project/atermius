import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'insecure_server.dart';

// Browser implementation. Page scripts cannot influence certificate
// validation or mixed-content blocking, so the permission changes nothing
// here; it only relaxes the client's own URL checks.

http.Client createServerHttpClient(InsecureServerPermission? insecure) =>
    http.Client();

WebSocketChannel connectServerWebSocket(
  Uri uri, {
  InsecureServerPermission? insecure,
}) => WebSocketChannel.connect(uri);

bool isUntrustedCertificateError(Object error) => false;
