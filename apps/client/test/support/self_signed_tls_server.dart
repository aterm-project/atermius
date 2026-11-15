import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A real loopback HTTPS + WebSocket server with a certificate no trust store
/// accepts. The certificate is created with `openssl` for each test run, so no
/// key material is committed.
class SelfSignedTlsServer {
  SelfSignedTlsServer._(this._server, this._json);

  final HttpServer _server;
  final Map<String, Object?>? Function(HttpRequest request)? _json;

  /// One entry per accepted WebSocket: its request path, `Origin` header and
  /// the frames received so far.
  final sockets = <AcceptedSocket>[];

  /// `METHOD path` of every plain HTTP request that reached the handler.
  final requests = <String>[];

  bool _closing = false;

  int get port => _server.port;
  String get origin => 'https://127.0.0.1:$port';

  /// Returns null when `openssl` is not available on this machine.
  static Future<SecurityContext?> createSelfSignedContext() async {
    final directory = await Directory.systemTemp.createTemp('atermius-tls-');
    try {
      final key = '${directory.path}/key.pem';
      final cert = '${directory.path}/cert.pem';
      final ProcessResult result;
      try {
        result = await Process.run('openssl', [
          'req',
          '-x509',
          '-newkey',
          'ec',
          '-pkeyopt',
          'ec_paramgen_curve:prime256v1',
          '-nodes',
          '-keyout',
          key,
          '-out',
          cert,
          '-days',
          '2',
          '-subj',
          '/CN=Atermius test loopback (self-signed)',
          '-addext',
          'subjectAltName=IP:127.0.0.1,DNS:localhost',
        ]);
      } on ProcessException {
        return null;
      }
      if (result.exitCode != 0) return null;
      return SecurityContext()
        ..useCertificateChainBytes(await File(cert).readAsBytes())
        ..usePrivateKeyBytes(await File(key).readAsBytes());
    } finally {
      await directory.delete(recursive: true);
    }
  }

  /// [json] answers plain HTTP requests; WebSocket upgrades are accepted on
  /// every path and echo binary frames.
  static Future<SelfSignedTlsServer> start(
    SecurityContext context, {
    Map<String, Object?>? Function(HttpRequest request)? json,
  }) async {
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final result = SelfSignedTlsServer._(server, json);
    server.listen(result._handle);
    return result;
  }

  Future<void> _handle(HttpRequest request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final accepted = AcceptedSocket(
        path: request.uri.path,
        origin: request.headers.value('origin'),
      );
      sockets.add(accepted);
      final socket = await WebSocketTransformer.upgrade(request);
      accepted._socket = socket;
      socket.listen((frame) {
        accepted.frames.add(frame);
        if (frame is List<int> && !_closing) socket.add(frame);
      });
      return;
    }
    requests.add('${request.method} ${request.uri.path}');
    await request.drain<void>();
    final body = _json?.call(request);
    request.response
      ..statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body ?? const {'error': 'not found'}));
    await request.response.close();
  }

  Future<void> close() async {
    _closing = true;
    for (final socket in sockets) {
      await socket._socket?.close();
    }
    await _server.close(force: true);
  }
}

class AcceptedSocket {
  AcceptedSocket({required this.path, required this.origin});

  final String path;
  final String? origin;
  final frames = <Object?>[];
  WebSocket? _socket;

  /// Waits until [count] frames arrived (the client sends asynchronously).
  Future<void> waitForFrames(int count) async {
    for (var attempt = 0; frames.length < count && attempt < 200; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}
