@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/mcp/mcp_bind.dart';
import 'package:aterm_client/mcp/mcp_listen_settings_store_io.dart';
import 'package:aterm_client/mcp/mcp_listener_contract.dart';
import 'package:aterm_client/mcp/mcp_listener_io.dart' as io;
import 'package:aterm_client/mcp/mcp_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const _token = 'tok_0123456789abcdefghijklmnopqrstuvwxyzABCDEF';
const _rpc = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}';

Future<int> _post(
  InternetAddress target,
  int port, {
  String? host,
  String? origin,
  String authorization = 'Bearer $_token',
}) async {
  final socket = await Socket.connect(target, port);
  final body = utf8.encode(_rpc);
  socket.write('POST /mcp HTTP/1.1\r\n');
  socket.write('Host: ${host ?? '${target.address}:$port'}\r\n');
  socket.write('Authorization: $authorization\r\n');
  if (origin != null) socket.write('Origin: $origin\r\n');
  socket.write('Content-Type: application/json\r\n');
  socket.write('Accept: application/json, text/event-stream\r\n');
  socket.write('Content-Length: ${body.length}\r\nConnection: close\r\n\r\n');
  socket.add(body);
  await socket.flush();
  final text = await utf8.decoder
      .bind(socket)
      .join()
      .timeout(const Duration(seconds: 5))
      .whenComplete(socket.destroy);
  return int.parse(text.split(' ')[1]);
}

Future<McpReply> _ok(
  Object? body, {
  Map<String, String> headers = const {},
}) async => const McpReply(200, {'jsonrpc': '2.0', 'id': 1});

/// A private, non-loopback IPv4 address of this machine, if it has one.
Future<InternetAddress?> _lanAddress() async {
  for (final interface in await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  )) {
    for (final address in interface.addresses) {
      if (!address.isLoopback && mcpPeerAllowed(address.rawAddress)) {
        return address;
      }
    }
  }
  return null;
}

void main() {
  group('addresses', () {
    test('only IP literals are bind addresses', () {
      expect(normalizeMcpAddress(' 192.168.1.20 '), '192.168.1.20');
      expect(normalizeMcpAddress('0.0.0.0'), '0.0.0.0');
      expect(normalizeMcpAddress('FE80::1'), 'fe80::1');
      expect(normalizeMcpAddress('::'), '::');
      for (final bad in [
        '',
        'localhost',
        'my-pc.local',
        '192.168.1',
        '192.168.1.256',
        '1.2.3.4:8765',
        'fe80::1%eth0',
        'http://10.0.0.1',
        '1' * 60,
      ]) {
        expect(normalizeMcpAddress(bad), isNull, reason: bad);
      }
    });

    test('exposed listeners serve this device and private networks only', () {
      List<int> v4(String text) => InternetAddress(text).rawAddress;
      for (final allowed in [
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.0.9',
        '169.254.10.10',
        '100.64.0.1', // overlay VPNs
        '100.127.255.254',
        '::1',
        'fd12:3456::1',
        'fe80::1',
        '::ffff:192.168.1.5',
      ]) {
        expect(mcpPeerAllowed(v4(allowed)), isTrue, reason: allowed);
      }
      for (final refused in [
        '8.8.8.8',
        '172.15.0.1',
        '172.32.0.1',
        '192.169.0.1',
        '100.63.255.255',
        '100.128.0.1',
        '203.0.113.9',
        '2001:db8::1',
        '::ffff:8.8.8.8',
        '::',
      ]) {
        expect(mcpPeerAllowed(v4(refused)), isFalse, reason: refused);
      }
      expect(mcpPeerAllowed(const [1, 2, 3]), isFalse);
    });

    test('which choices other devices can reach', () {
      expect(const McpBind.loopback().exposed, isFalse);
      expect(const McpBind.lan().exposed, isTrue);
      expect(const McpBind.custom('192.168.1.20').exposed, isTrue);
      expect(const McpBind.custom('127.0.0.1').exposed, isFalse);
      expect(const McpBind.custom('::1').exposed, isFalse);
    });
  });

  group('listen settings', () {
    test('round trip and sanitizing parse', () {
      const lan = McpListenSettings(port: 9000, bind: McpBind.lan());
      expect(McpListenSettings.parse(lan.encode()).bind, const McpBind.lan());
      expect(McpListenSettings.parse(lan.encode()).port, 9000);
      const custom = McpListenSettings(bind: McpBind.custom('10.0.0.7'));
      expect(
        McpListenSettings.parse(custom.encode()).bind,
        const McpBind.custom('10.0.0.7'),
      );
      expect(const McpListenSettings().encode(), isNot(contains('address')));
      for (final raw in [
        null,
        '',
        'not json',
        '[]',
        '{"v":2,"bind":"lan"}',
        '{"v":1,"bind":"everywhere","port":80}',
        '{"v":1,"bind":"custom","address":"evil.example"}',
        '{"v":1,"bind":"custom"}',
        'x' * 400,
      ]) {
        final parsed = McpListenSettings.parse(raw);
        expect(parsed.bind, const McpBind.loopback(), reason: '$raw');
        expect(parsed.port, mcpDefaultPort, reason: '$raw');
      }
    });

    test('device file store', () async {
      final directory = await Directory.systemTemp.createTemp('mcp-listen-');
      addTearDown(() => directory.delete(recursive: true));
      final store = FileMcpListenSettingsStore(
        directory: () async => directory,
      );
      expect(await store.read(), isNull);
      const settings = McpListenSettings(port: 9100, bind: McpBind.lan());
      await store.write(settings.encode());
      expect(McpListenSettings.parse(await store.read()).port, 9100);
      expect(await directory.list().length, 1, reason: 'no temporary files');
    });
  });

  group('exposed listener', () {
    late McpListener listener;
    tearDown(() => listener.close());

    test('local network: advertised addresses and Host rules', () async {
      listener = await io.bindMcpListener(
        port: 0,
        token: _token,
        handler: _ok,
        bind: const McpBind.lan(),
        localAddresses: (_) async => [
          InternetAddress('8.8.4.4'),
          InternetAddress('127.0.0.1'),
          InternetAddress('192.168.1.20'),
          InternetAddress('169.254.3.3'),
        ],
      );
      final port = listener.endpoint.port;
      expect(
        [
          for (final url in (listener as McpAddressedListener).endpoints)
            '$url',
        ],
        [
          'http://192.168.1.20:$port/mcp',
          'http://8.8.4.4:$port/mcp',
          'http://127.0.0.1:$port/mcp',
        ],
      );
      expect(listener.endpoint.host, '192.168.1.20');
      final loopback = InternetAddress.loopbackIPv4;
      // A client on the network addresses this device by IP.
      expect(await _post(loopback, port, host: '192.168.1.20:$port'), 200);
      expect(await _post(loopback, port, host: 'localhost:$port'), 200);
      expect(await _post(loopback, port, host: '[fd00::5]:$port'), 200);
      expect(
        await _post(
          loopback,
          port,
          host: '192.168.1.20:$port',
          origin: 'http://192.168.1.20:$port',
        ),
        200,
      );
      // DNS rebinding and other pages: a name, another port or origin.
      expect(await _post(loopback, port, host: 'evil.example:$port'), 403);
      expect(await _post(loopback, port, host: 'my-pc.local:$port'), 403);
      expect(
        await _post(loopback, port, host: '192.168.1.20:${port + 1}'),
        403,
      );
      expect(await _post(loopback, port, host: '192.168.1.20'), 403);
      expect(
        await _post(
          loopback,
          port,
          host: '192.168.1.20:$port',
          origin: 'http://evil.example',
        ),
        403,
      );
      // The token is still required.
      expect(
        await _post(loopback, port, authorization: 'Bearer ${'x' * 44}'),
        401,
      );
    });

    test('local network: reachable on a LAN address; repeated wrong tokens '
        'lock that peer out', () async {
      final lan = await _lanAddress();
      listener = await io.bindMcpListener(
        port: 0,
        token: _token,
        handler: _ok,
        bind: const McpBind.lan(),
      );
      if (lan == null) {
        markTestSkipped('this machine has no private IPv4 interface');
        return;
      }
      final port = listener.endpoint.port;
      expect(
        (listener as McpAddressedListener).endpoints.map((url) => url.host),
        contains(lan.address),
      );
      expect(await _post(lan, port), 200);
      for (var i = 0; i < 20; i++) {
        expect(
          await _post(lan, port, authorization: 'Bearer ${'y' * 44}'),
          401,
        );
      }
      // Even the right token is refused for the rest of the window...
      expect(await _post(lan, port), 429);
      // ...but only for that peer: this device itself is unaffected.
      expect(await _post(InternetAddress.loopbackIPv4, port), 200);
    });

    test('a specific address is the only one served', () async {
      final lan = await _lanAddress();
      if (lan == null) {
        listener = await io.bindMcpListener(
          port: 0,
          token: _token,
          handler: _ok,
        );
        markTestSkipped('this machine has no private IPv4 interface');
        return;
      }
      listener = await io.bindMcpListener(
        port: 0,
        token: _token,
        handler: _ok,
        bind: McpBind.custom(lan.address),
      );
      final port = listener.endpoint.port;
      expect('${listener.endpoint}', 'http://${lan.address}:$port/mcp');
      expect((listener as McpAddressedListener).endpoints, hasLength(1));
      expect(await _post(lan, port), 200);
      await expectLater(
        Socket.connect(
          InternetAddress.loopbackIPv4,
          port,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<SocketException>()),
        reason: 'not bound to loopback',
      );
    });

    test('a custom loopback address stays a loopback listener', () async {
      listener = await io.bindMcpListener(
        port: 0,
        token: _token,
        handler: _ok,
        bind: const McpBind.custom('127.0.0.1'),
      );
      final port = listener.endpoint.port;
      expect('${listener.endpoint}', 'http://127.0.0.1:$port/mcp');
      final loopback = InternetAddress.loopbackIPv4;
      expect(await _post(loopback, port), 200);
      // Loopback keeps the strict names: no other Host is accepted.
      expect(await _post(loopback, port, host: '192.168.1.20:$port'), 403);
    });

    test('an address this device does not have cannot be bound', () async {
      listener = await io.bindMcpListener(port: 0, token: _token, handler: _ok);
      await expectLater(
        io.bindMcpListener(
          port: 0,
          token: _token,
          handler: _ok,
          bind: const McpBind.custom('203.0.113.77'),
        ),
        throwsA(isA<SocketException>()),
      );
      await expectLater(
        io.bindMcpListener(
          port: 0,
          token: _token,
          handler: _ok,
          bind: const McpBind.custom('not-an-ip'),
        ),
        throwsArgumentError,
      );
    });
  });
}
