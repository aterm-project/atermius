// Real TLS on loopback: proves that the development-only insecure option
// accepts an untrusted certificate for exactly one host and port, on every
// kind of connection the client opens to the account server.
//
// The Flutter test binding is deliberately not initialised here: it replaces
// dart:io's HttpClient with a mock that never touches the network.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/api/insecure_server.dart';
import 'package:aterm_client/api/server_transport.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_relay_socket.dart';
import 'package:aterm_client/sync/sync_hint_socket_factory.dart';
import 'package:aterm_client/terminal/terminal_collaboration_websocket.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'support/self_signed_tls_server.dart';

const _ticket = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

Map<String, Object?>? _json(HttpRequest request) =>
    switch ('${request.method} ${request.uri.path}') {
      'GET /api/v1/ping' => {'ok': true},
      'POST /api/v1/relay/tickets' => {
        'ticket': _ticket,
        'expires_at': DateTime.now()
            .toUtc()
            .add(const Duration(seconds: 20))
            .toIso8601String(),
        'connect_path': '/relay/v1/connect',
      },
      _ => null,
    };

final _untrustedCertificate = throwsA(
  predicate<Object>(isUntrustedCertificateError, 'an untrusted certificate'),
);

void main() {
  SecurityContext? tls;
  late SelfSignedTlsServer server;
  late SelfSignedTlsServer other;

  setUpAll(() async {
    tls = await SelfSignedTlsServer.createSelfSignedContext();
  });

  /// False (and the test is reported as skipped) without `openssl`.
  Future<bool> start() async {
    final context = tls;
    if (context == null) {
      markTestSkipped('openssl is required to create the test certificate');
      return false;
    }
    server = await SelfSignedTlsServer.start(context, json: _json);
    other = await SelfSignedTlsServer.start(context, json: _json);
    addTearDown(server.close);
    addTearDown(other.close);
    return true;
  }

  InsecureServerPermission permissionFor(SelfSignedTlsServer target) =>
      InsecureServerPermission.forBaseUrl(target.origin, web: false)!;

  Uri socketUri(SelfSignedTlsServer target, String path) =>
      Uri.parse('wss://127.0.0.1:${target.port}$path');

  group('HTTP', () {
    test('option off: a self-signed server is refused before any request is '
        'sent', () async {
      if (!await start()) return;
      final api = ApiClient(baseUrl: server.origin);
      addTearDown(api.close);

      expect(api.insecureServer, isNull);
      await expectLater(
        api.get('/api/v1/ping', authenticated: false),
        _untrustedCertificate,
      );
      await expectLater(api.fetchInstance(), _untrustedCertificate);
      expect(server.requests, isEmpty);
    });

    test('option on: the same server is reached', () async {
      if (!await start()) return;
      final api = ApiClient(baseUrl: server.origin, allowInsecure: true);
      addTearDown(api.close);

      expect(api.insecureServer?.origin, server.origin);
      expect(await api.get('/api/v1/ping', authenticated: false), {'ok': true});
      expect(server.requests, ['GET /api/v1/ping']);
    });

    test('the permission accepts nothing but its own host and port', () async {
      if (!await start()) return;
      final client = createServerHttpClient(permissionFor(server));
      addTearDown(client.close);

      expect(
        (await client.get(Uri.parse('${server.origin}/api/v1/ping'))).body,
        jsonEncode({'ok': true}),
      );
      // Same certificate, same address, another port.
      await expectLater(
        client.get(Uri.parse('${other.origin}/api/v1/ping')),
        _untrustedCertificate,
      );
      // Same port, another host name for the same machine.
      await expectLater(
        client.get(Uri.parse('https://localhost:${server.port}/api/v1/ping')),
        _untrustedCertificate,
      );
      expect(other.requests, isEmpty);
      expect(server.requests, ['GET /api/v1/ping']);
    });

    test('an http:// permission never relaxes certificate checks', () async {
      if (!await start()) return;
      final plain = InsecureServerPermission.forBaseUrl(
        'http://127.0.0.2:${server.port}',
        web: false,
      )!;
      final http.Client client = createServerHttpClient(plain);
      addTearDown(client.close);

      await expectLater(
        client.get(Uri.parse('${server.origin}/api/v1/ping')),
        _untrustedCertificate,
      );
    });
  });

  group('WebSocket', () {
    test('generic server socket: refused without the permission, refused for '
        'another port, accepted for the permitted origin', () async {
      if (!await start()) return;
      final uri = socketUri(server, '/any/path');

      await expectLater(
        connectServerWebSocket(uri).ready,
        _untrustedCertificate,
      );
      await expectLater(
        connectServerWebSocket(uri, insecure: permissionFor(other)).ready,
        _untrustedCertificate,
      );
      await expectLater(
        connectServerWebSocket(
          socketUri(other, '/any/path'),
          insecure: permissionFor(server),
        ).ready,
        _untrustedCertificate,
      );
      expect(server.sockets, isEmpty);
      expect(other.sockets, isEmpty);

      final channel = connectServerWebSocket(
        uri,
        insecure: permissionFor(server),
      );
      await channel.ready;
      // The scoped HTTP client is released after the handshake; the upgraded
      // socket must keep working.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      channel.sink.add(Uint8List.fromList([1, 2, 3]));
      expect(await channel.stream.first, [1, 2, 3]);
      await channel.sink.close();
      expect(server.sockets.single.path, '/any/path');
    });

    test('sync-hint socket honours the permission and keeps its Origin '
        'header', () async {
      if (!await start()) return;
      final api = ApiClient(baseUrl: server.origin, allowInsecure: true);
      addTearDown(api.close);
      final uri = api.notificationsWebSocketUri();

      final refused = await connectSyncHintSocket(
        uri,
        origin: api.notificationsOrigin,
      );
      await expectLater(refused.ready, _untrustedCertificate);
      expect(server.sockets, isEmpty);

      final socket = await connectSyncHintSocket(
        uri,
        origin: api.notificationsOrigin,
        insecure: api.insecureServer,
      );
      await socket.ready;
      socket.sendText('hello');
      await server.sockets.single.waitForFrames(1);
      expect(server.sockets.single.path, '/api/v1/notifications');
      expect(server.sockets.single.origin, server.origin);
      expect(server.sockets.single.frames, ['hello']);
      await socket.close();
    });

    test('SSH relay socket honours the permission', () async {
      if (!await start()) return;
      final api = ApiClient(baseUrl: server.origin, allowInsecure: true);
      addTearDown(api.close);

      await expectLater(
        connectRelaySocket(api.relayUri(), _ticket),
        _untrustedCertificate,
      );
      expect(server.sockets, isEmpty);

      final socket = await connectRelaySocket(
        api.relayUri(),
        _ticket,
        insecure: api.insecureServer,
      );
      await server.sockets.single.waitForFrames(1);
      expect(server.sockets.single.path, '/relay/v1/connect');
      expect(server.sockets.single.frames.first, _ticket);
      await socket.close();
    });

    test('terminal collaboration socket honours the permission', () async {
      if (!await start()) return;
      final api = ApiClient(baseUrl: server.origin, allowInsecure: true);
      addTearDown(api.close);
      final uri = api.terminalCollaborationWebSocketUri(
        '/collaboration/v1/connect',
      );

      await expectLater(
        createTerminalCollaborationWebSocketChannel(uri).ready,
        _untrustedCertificate,
      );
      expect(server.sockets, isEmpty);

      final channel = createTerminalCollaborationWebSocketChannel(
        uri,
        insecure: api.insecureServer,
      );
      await channel.ready;
      expect(server.sockets.single.path, '/collaboration/v1/connect');
      await channel.sink.close();
    });

    test('remote-desktop gateway socket honours the permission', () async {
      if (!await start()) return;
      const host = HostRecord(
        id: 'host-1',
        name: 'Desktop',
        address: '10.0.0.5',
        protocol: HostProtocol.vnc,
      );

      // Option off: not even the ticket request gets through.
      final strictApi = ApiClient(baseUrl: server.origin);
      addTearDown(strictApi.close);
      final strict = DesktopSession();
      addTearDown(strict.dispose);
      await strict.connect(strictApi, 'device-1', host);
      expect(server.requests, isEmpty);
      expect(server.sockets, isEmpty);

      final api = ApiClient(baseUrl: server.origin, allowInsecure: true);
      addTearDown(api.close);
      final session = DesktopSession();
      addTearDown(session.dispose);
      await session.connect(api, 'device-1', host);

      expect(server.requests, ['POST /api/v1/relay/tickets']);
      await server.sockets.single.waitForFrames(2);
      expect(server.sockets.single.path, '/desktop/v1/connect');
      expect(server.sockets.single.frames.first, _ticket);
    });
  });
}
