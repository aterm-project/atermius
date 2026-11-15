import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'insecure_server.dart';
import 'server_transport_stub.dart'
    if (dart.library.io) 'server_transport_io.dart'
    as platform;

/// HTTP client for one account server.
///
/// Without a permission this is the platform default client. With one, native
/// clients accept a certificate that fails validation for exactly the
/// permitted host and port; every other connection made through the returned
/// client is validated as usual. Browsers cannot skip certificate validation,
/// so there the permission never changes the client.
http.Client createServerHttpClient(InsecureServerPermission? insecure) =>
    platform.createServerHttpClient(insecure);

/// Opens a WebSocket to the account server, honouring the same origin-scoped
/// permission as [createServerHttpClient].
WebSocketChannel connectServerWebSocket(
  Uri uri, {
  InsecureServerPermission? insecure,
}) => platform.connectServerWebSocket(uri, insecure: insecure);

/// Whether [error] is a TLS certificate validation failure. Always false in a
/// browser, which does not expose the reason a request failed.
bool isUntrustedCertificateError(Object error) =>
    platform.isUntrustedCertificateError(error);
