import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'insecure_server.dart';

/// A dart:io client whose only relaxation is accepting a certificate that
/// failed validation for the permitted host and port. The callback is asked
/// per connection, so a redirect or any other host is still rejected.
HttpClient _scopedHttpClient(InsecureServerPermission permission) =>
    HttpClient()
      ..badCertificateCallback = (_, host, port) =>
          permission.permitsCertificateFor(host, port);

http.Client createServerHttpClient(InsecureServerPermission? insecure) =>
    insecure == null || !insecure.skipsCertificateValidation
    ? http.Client()
    : IOClient(_scopedHttpClient(insecure));

WebSocketChannel connectServerWebSocket(
  Uri uri, {
  InsecureServerPermission? insecure,
}) => _needsScopedClient(uri, insecure)
    ? connectServerIoWebSocket(uri, insecure: insecure)
    : WebSocketChannel.connect(uri);

/// dart:io variant that can also set handshake headers (native clients send
/// an explicit `Origin`).
IOWebSocketChannel connectServerIoWebSocket(
  Uri uri, {
  InsecureServerPermission? insecure,
  Map<String, dynamic>? headers,
}) {
  if (insecure == null || !_needsScopedClient(uri, insecure)) {
    return IOWebSocketChannel.connect(uri, headers: headers);
  }
  final client = _scopedHttpClient(insecure);
  final channel = IOWebSocketChannel.connect(
    uri,
    headers: headers,
    customClient: client,
  );
  // The upgraded socket is detached from the client during the handshake, so
  // the client can be released as soon as the handshake has settled.
  unawaited(
    channel.ready
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(client.close),
  );
  return channel;
}

bool _needsScopedClient(Uri uri, InsecureServerPermission? insecure) =>
    insecure != null &&
    insecure.skipsCertificateValidation &&
    insecure.permitsUri(uri);

bool isUntrustedCertificateError(Object error) {
  if (error is TlsException ||
      error is http.ClientException ||
      error is WebSocketChannelException) {
    return error.toString().contains('CERTIFICATE_VERIFY_FAILED');
  }
  return false;
}
