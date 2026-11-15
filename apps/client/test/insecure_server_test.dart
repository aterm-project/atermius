import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/api/insecure_server.dart';
import 'package:aterm_client/ssh/ssh_relay_socket.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _ticket = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _httpsMessage =
    'Remote server URLs must use HTTPS. HTTP is allowed only for localhost development.';

void main() {
  group('server URL validation', () {
    test('option off keeps today\'s rules and messages', () {
      for (final url in const [
        'http://192.168.1.20:8080',
        'http://172.19.99.1',
        'http://dev.example.test',
      ]) {
        expect(
          () => ApiClient(baseUrl: url),
          throwsA(
            isA<FormatException>()
                .having((e) => e.message, 'message', _httpsMessage)
                .having(
                  (e) => e.toString(),
                  'text',
                  'FormatException: $_httpsMessage',
                ),
          ),
          reason: url,
        );
      }
      expect(
        () => ApiClient(baseUrl: 'ftp://172.19.99.1'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Server URL must use https:// or a loopback http:// address.',
          ),
        ),
      );
      final https = ApiClient(baseUrl: 'https://172.19.99.1/');
      expect(https.baseUrl, 'https://172.19.99.1');
      expect(https.insecureServer, isNull);
      https.close();
    });

    test('option on accepts a non-loopback http:// address', () {
      final api = ApiClient(
        baseUrl: 'http://172.19.99.1:8080/',
        allowInsecure: true,
      );
      addTearDown(api.close);
      expect(api.baseUrl, 'http://172.19.99.1:8080');
      expect(api.insecureServer?.origin, 'http://172.19.99.1:8080');
      expect(api.insecureServer?.skipsCertificateValidation, isFalse);
    });

    test('option on marks an https:// address as unverified', () {
      final api = ApiClient(
        baseUrl: 'https://172.19.99.1',
        allowInsecure: true,
      );
      addTearDown(api.close);
      expect(api.baseUrl, 'https://172.19.99.1');
      expect(api.insecureServer?.origin, 'https://172.19.99.1');
      expect(api.insecureServer?.port, 443);
      expect(api.insecureServer?.skipsCertificateValidation, isTrue);
    });

    test('loopback http:// is unchanged with or without the option', () {
      for (final url in const [
        'http://localhost:8080',
        'http://127.0.0.1:8080',
        'http://[::1]:8080',
      ]) {
        for (final allowInsecure in const [false, true]) {
          final api = ApiClient(baseUrl: url, allowInsecure: allowInsecure);
          expect(api.baseUrl, url);
          // Nothing to permit: loopback http was always allowed.
          expect(api.insecureServer, isNull, reason: '$url $allowInsecure');
          expect(api.relayUri().scheme, 'ws');
          api.close();
        }
      }
    });

    test('the option never lifts the other URL rules', () {
      for (final url in const [
        'ftp://172.19.99.1',
        '172.19.99.1',
        'http://user:pw@172.19.99.1',
        'https://172.19.99.1/?token=1',
        'https://172.19.99.1/#fragment',
      ]) {
        expect(
          () => ApiClient(baseUrl: url, allowInsecure: true),
          throwsFormatException,
          reason: url,
        );
      }
    });

    test('a caller-supplied HTTP client is used as is', () async {
      var requests = 0;
      final api = ApiClient(
        baseUrl: 'http://172.19.99.1',
        allowInsecure: true,
        client: MockClient((request) async {
          requests++;
          expect(request.url.toString(), 'http://172.19.99.1/api/v1/ping');
          return http.Response('{"ok":true}', 200);
        }),
      );
      expect(await api.get('/api/v1/ping', authenticated: false), {'ok': true});
      expect(requests, 1);
    });
  });

  group('WebSocket endpoints derived from the base URL', () {
    test('option off: non-loopback http cannot exist, https maps to wss', () {
      final api = ApiClient(baseUrl: 'https://172.19.99.1/tenant');
      addTearDown(api.close);
      expect(
        api.relayUri().toString(),
        'wss://172.19.99.1/tenant/relay/v1/connect',
      );
      expect(
        api
            .terminalCollaborationWebSocketUri('/collaboration/v1/connect')
            .toString(),
        'wss://172.19.99.1/tenant/collaboration/v1/connect',
      );
      expect(
        api.notificationsWebSocketUri().toString(),
        'wss://172.19.99.1/tenant/api/v1/notifications',
      );
    });

    test('option on: a non-loopback http server maps to ws everywhere', () {
      final api = ApiClient(
        baseUrl: 'http://172.19.99.1:8080/tenant',
        allowInsecure: true,
      );
      addTearDown(api.close);
      final permission = api.insecureServer!;
      final endpoints = [
        api.relayUri(),
        api.terminalCollaborationWebSocketUri('/collaboration/v1/connect'),
        api.notificationsWebSocketUri(),
      ];
      expect(endpoints.map((uri) => uri.toString()), [
        'ws://172.19.99.1:8080/tenant/relay/v1/connect',
        'ws://172.19.99.1:8080/tenant/collaboration/v1/connect',
        'ws://172.19.99.1:8080/tenant/api/v1/notifications',
      ]);
      for (final uri in endpoints) {
        expect(permission.permitsUri(uri), isTrue, reason: '$uri');
      }
    });

    test('option on: every wss endpoint of an https server is covered', () {
      for (final base in const [
        'https://172.19.99.1',
        'https://172.19.99.1:8443/tenant',
      ]) {
        final api = ApiClient(baseUrl: base, allowInsecure: true);
        final permission = api.insecureServer!;
        for (final uri in [
          api.relayUri(),
          api.terminalCollaborationWebSocketUri('/collaboration/v1/connect'),
          api.notificationsWebSocketUri(),
        ]) {
          expect(uri.scheme, 'wss');
          expect(permission.permitsUri(uri), isTrue, reason: '$uri');
        }
        api.close();
      }
    });
  });

  group('InsecureServerPermission', () {
    test('is bound to scheme, host and port', () {
      final permission = InsecureServerPermission.forBaseUrl(
        'https://172.19.99.1/tenant',
        web: false,
      )!;
      expect(permission.origin, 'https://172.19.99.1');

      expect(permission.permitsCertificateFor('172.19.99.1', 443), isTrue);
      expect(permission.permitsCertificateFor('172.19.99.1', 8443), isFalse);
      expect(permission.permitsCertificateFor('172.19.99.2', 443), isFalse);
      expect(permission.permitsCertificateFor('example.com', 443), isFalse);

      expect(permission.permitsUri(Uri.parse('https://172.19.99.1/x')), isTrue);
      expect(permission.permitsUri(Uri.parse('wss://172.19.99.1/x')), isTrue);
      expect(
        permission.permitsUri(Uri.parse('wss://172.19.99.1:443/x')),
        isTrue,
      );
      expect(
        permission.permitsUri(Uri.parse('wss://172.19.99.1:8443/x')),
        isFalse,
      );
      expect(permission.permitsUri(Uri.parse('wss://172.19.99.2/x')), isFalse);
      // Another scheme is another origin.
      expect(permission.permitsUri(Uri.parse('http://172.19.99.1/x')), isFalse);
      expect(permission.permitsUri(Uri.parse('ws://172.19.99.1/x')), isFalse);
      expect(
        permission.permitsUri(Uri.parse('ws://172.19.99.1:443/x')),
        isFalse,
      );
    });

    test('compares hosts case-insensitively and handles IPv6 literals', () {
      final named = InsecureServerPermission.forBaseUrl(
        'https://Dev.Example.Test:8443',
        web: false,
      )!;
      expect(named.origin, 'https://dev.example.test:8443');
      expect(named.permitsCertificateFor('DEV.example.test', 8443), isTrue);

      final v6 = InsecureServerPermission.forBaseUrl(
        'https://[fd00::1]:8443',
        web: false,
      )!;
      expect(v6.origin, 'https://[fd00::1]:8443');
      expect(v6.permitsCertificateFor('fd00::1', 8443), isTrue);
      expect(v6.permitsCertificateFor('[fd00::1]', 8443), isTrue);
      expect(v6.permitsUri(Uri.parse('wss://[fd00::1]:8443/x')), isTrue);
    });

    test('an http permission never accepts a certificate', () {
      final permission = InsecureServerPermission.forBaseUrl(
        'http://172.19.99.1:8080',
        web: false,
      )!;
      expect(permission.permitsCertificateFor('172.19.99.1', 8080), isFalse);
      expect(
        permission.permitsUri(Uri.parse('ws://172.19.99.1:8080/x')),
        isTrue,
      );
      expect(
        permission.permitsUri(Uri.parse('wss://172.19.99.1:8080/x')),
        isFalse,
      );
    });

    test('grants nothing where the option cannot do anything', () {
      // Loopback http was always allowed.
      for (final url in const [
        'http://localhost',
        'http://127.0.0.1:8080',
        'http://[::1]:8080',
      ]) {
        expect(InsecureServerPermission.forBaseUrl(url, web: false), isNull);
        expect(InsecureServerPermission.forBaseUrl(url, web: true), isNull);
      }
      // A self-signed loopback https server does need it on native clients.
      expect(
        InsecureServerPermission.forBaseUrl(
          'https://localhost:8443',
          web: false,
        ),
        isNotNull,
      );
      // Not a server address.
      for (final url in const ['', 'ftp://172.19.99.1', '172.19.99.1', '::']) {
        expect(InsecureServerPermission.forBaseUrl(url, web: false), isNull);
      }
    });

    test('in a browser it can only permit http, never a certificate', () {
      expect(
        InsecureServerPermission.forBaseUrl('https://172.19.99.1', web: true),
        isNull,
      );
      final http = InsecureServerPermission.forBaseUrl(
        'http://172.19.99.1',
        web: true,
      );
      expect(http?.origin, 'http://172.19.99.1');
      expect(http?.skipsCertificateValidation, isFalse);
    });

    test('serverOriginOf normalises what the user typed', () {
      expect(serverOriginOf(' https://172.19.99.1/ '), 'https://172.19.99.1');
      expect(
        serverOriginOf('https://172.19.99.1:443/a/b'),
        'https://172.19.99.1',
      );
      expect(
        serverOriginOf('HTTP://Dev.Example.Test:8080'),
        'http://dev.example.test:8080',
      );
      expect(serverOriginOf('http://localhost:8080'), 'http://localhost:8080');
      expect(serverOriginOf('172.19.99.1'), isNull);
      expect(serverOriginOf(''), isNull);
    });
  });

  group('SSH relay endpoint check', () {
    final plainRelay = Uri.parse('ws://172.19.99.1:8080/relay/v1/connect');

    Future<Object?> connect(Uri uri, {InsecureServerPermission? insecure}) =>
        connectRelaySocket(
          uri,
          _ticket,
          insecure: insecure,
          channelFactory: (_) => _OpenChannel(),
        ).then<Object?>((socket) => socket, onError: (Object error) => error);

    test('option off: plain ws beyond loopback stays "insecure"', () async {
      final error = await connect(plainRelay);
      expect(
        error,
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          'Invalid or insecure SSH relay endpoint.',
        ),
      );
    });

    test('option on: plain ws is allowed for that origin only', () async {
      final permission = InsecureServerPermission.forBaseUrl(
        'http://172.19.99.1:8080',
        web: false,
      );
      expect(
        await connect(plainRelay, insecure: permission),
        isNot(isA<Exception>()),
      );

      for (final other in const [
        'ws://172.19.99.1:9090/relay/v1/connect',
        'ws://172.19.99.2:8080/relay/v1/connect',
        'ws://172.19.99.1/relay/v1/connect',
      ]) {
        expect(
          await connect(Uri.parse(other), insecure: permission),
          isA<FormatException>(),
          reason: other,
        );
      }
      // The path and credential rules are not relaxed.
      expect(
        await connect(
          Uri.parse('ws://172.19.99.1:8080/other/v1/connect'),
          insecure: permission,
        ),
        isA<FormatException>(),
      );
      expect(
        await connect(
          Uri.parse('ws://user@172.19.99.1:8080/relay/v1/connect'),
          insecure: permission,
        ),
        isA<FormatException>(),
      );
    });

    test('an https permission does not allow plain ws', () async {
      final permission = InsecureServerPermission.forBaseUrl(
        'https://172.19.99.1:8080',
        web: false,
      );
      expect(
        await connect(plainRelay, insecure: permission),
        isA<FormatException>(),
      );
    });
  });

  group('saved server selection', () {
    test('option off is stored exactly as before: the plain URL', () {
      const selection = SavedServerSelection(
        baseUrl: 'https://sync.example.test',
      );
      expect(selection.encode(), 'https://sync.example.test');
      final decoded = SavedServerSelection.decode('https://sync.example.test')!;
      expect(decoded.baseUrl, 'https://sync.example.test');
      expect(decoded.allowInsecure, isFalse);
    });

    test('option on travels with its URL in one value', () {
      const selection = SavedServerSelection(
        baseUrl: 'https://172.19.99.1',
        allowInsecure: true,
      );
      final decoded = SavedServerSelection.decode(selection.encode())!;
      expect(decoded.baseUrl, 'https://172.19.99.1');
      expect(decoded.allowInsecure, isTrue);
    });

    test('missing or damaged values never turn the option on', () {
      expect(SavedServerSelection.decode(null), isNull);
      expect(SavedServerSelection.decode(''), isNull);
      expect(SavedServerSelection.decode('{'), isNull);
      expect(SavedServerSelection.decode('{"allow_insecure":true}'), isNull);
      // Anything else is a plain address with the option off.
      expect(SavedServerSelection.decode('[]')?.allowInsecure, isFalse);
      for (final value in const [
        '{"url":"https://172.19.99.1"}',
        '{"url":"https://172.19.99.1","allow_insecure":"true"}',
        '{"url":"https://172.19.99.1","allow_insecure":1}',
        '{"url":"https://172.19.99.1","allow_insecure":false}',
      ]) {
        final decoded = SavedServerSelection.decode(value)!;
        expect(decoded.baseUrl, 'https://172.19.99.1');
        expect(decoded.allowInsecure, isFalse, reason: value);
      }
    });
  });
}

/// A channel whose handshake succeeds; the relay socket only needs `ready`
/// and a sink for the ticket frame.
class _OpenChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  final _controller = StreamChannelController<dynamic>();

  @override
  Future<void> get ready async {}

  @override
  Stream<dynamic> get stream => _controller.foreign.stream;

  @override
  WebSocketSink get sink => _Sink(_controller.foreign.sink);

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;
}

class _Sink implements WebSocketSink {
  _Sink(this._inner);

  final StreamSink<dynamic> _inner;

  @override
  void add(dynamic event) => _inner.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<dynamic> stream) => _inner.addStream(stream);

  @override
  Future<void> close([int? closeCode, String? closeReason]) => _inner.close();

  @override
  Future<void> get done => _inner.done;
}
