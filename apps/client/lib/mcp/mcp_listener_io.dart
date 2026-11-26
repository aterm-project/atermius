import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'mcp_bind.dart';
import 'mcp_listener_contract.dart';
import 'mcp_protocol.dart';

/// Platforms with a supported local listener. iOS listens in the foreground.
@visibleForTesting
bool mcpListenerPlatformSupported(String operatingSystem) => const {
  'windows',
  'linux',
  'macos',
  'android',
  'ios',
}.contains(operatingSystem);

bool get supported => mcpListenerPlatformSupported(Platform.operatingSystem);

const _maxRequestBytes = 512 * 1024;
const _maxActiveRequests = 4;

/// Upper bound on simultaneously open HTTP connections, authenticated or not.
/// On Android every installed app may reach 127.0.0.1, so unauthenticated
/// peers must not be able to hold an unbounded number of sockets.
const _maxOpenConnections = 16;
const _minTokenLength = 32;

/// A peer other than this device that keeps presenting a wrong token is
/// refused for the rest of the window (other devices can reach an exposed
/// listener; the token itself is far beyond guessing).
const _maxAuthFailures = 20;
const _authFailureWindow = Duration(minutes: 1);
const _maxTrackedPeers = 256;

Future<McpListener> start({
  required int port,
  required String token,
  required McpRequestHandler handler,
  McpBind bind = const McpBind.loopback(),
}) async {
  if (!supported) throw UnsupportedError('MCP listener is unavailable.');
  return bindMcpListener(
    port: port,
    token: token,
    handler: handler,
    bind: bind,
  );
}

/// Binds the authenticated listener on IPv4 loopback. Exposed for transport
/// tests so the platform gate above stays the only production entry point.
@visibleForTesting
Future<McpListener> bindMcpLoopbackListener({
  required int port,
  required String token,
  required McpRequestHandler handler,
  Duration bodyTimeout = const Duration(seconds: 10),
}) => bindMcpListener(
  port: port,
  token: token,
  handler: handler,
  bodyTimeout: bodyTimeout,
);

/// Binds the authenticated listener where [bind] says: IPv4 loopback (the
/// default), every IPv4 interface, or one address of this device. A listener
/// other devices can reach only serves this device and private networks (see
/// [mcpPeerAllowed]). [localAddresses] lists this device's addresses for the
/// advertised endpoints (tests replace it).
@visibleForTesting
Future<McpListener> bindMcpListener({
  required int port,
  required String token,
  required McpRequestHandler handler,
  McpBind bind = const McpBind.loopback(),
  Duration bodyTimeout = const Duration(seconds: 10),
  Future<List<InternetAddress>> Function(InternetAddressType type)?
  localAddresses,
}) async {
  _checkToken(token);
  if (port < 0 || port > 65535) throw RangeError.range(port, 0, 65535, 'port');
  final InternetAddress address;
  switch (bind.mode) {
    case McpBindMode.loopback:
      address = InternetAddress.loopbackIPv4;
    case McpBindMode.lan:
      address = InternetAddress.anyIPv4;
    case McpBindMode.custom:
      final literal = normalizeMcpAddress(bind.address ?? '');
      final parsed = literal == null ? null : InternetAddress.tryParse(literal);
      if (parsed == null) throw ArgumentError('Not an IP address.');
      address = parsed;
  }
  final server = await HttpServer.bind(address, port, shared: false);
  server.idleTimeout = const Duration(seconds: 15);
  server.autoCompress = false;
  var hosts = <InternetAddress>[address];
  if (address == InternetAddress.anyIPv4 ||
      address == InternetAddress.anyIPv6) {
    // Reachable at every address of this device: advertise them, private
    // networks first and loopback last.
    final loopback = address.type == InternetAddressType.IPv4
        ? InternetAddress.loopbackIPv4
        : InternetAddress.loopbackIPv6;
    List<InternetAddress> found;
    try {
      found = await (localAddresses ?? _localAddresses)(address.type);
    } catch (_) {
      found = const [];
    }
    final usable =
        [
          for (final candidate in found)
            if (!candidate.isLoopback && !candidate.isLinkLocal) candidate,
        ]..sort(
          (a, b) =>
              (mcpPeerAllowed(b.rawAddress) ? 1 : 0) -
              (mcpPeerAllowed(a.rawAddress) ? 1 : 0),
        );
    hosts = [...usable, loopback];
  }
  return _Listener(
    server,
    token,
    handler,
    bodyTimeout,
    exposed: !address.isLoopback,
    hosts: hosts,
  );
}

void _checkToken(String token) {
  if (token.length < _minTokenLength ||
      token.codeUnits.any((c) => c < 0x21 || c > 0x7e)) {
    throw ArgumentError('MCP token is too short or malformed.');
  }
}

Future<List<InternetAddress>> _localAddresses(InternetAddressType type) async =>
    [
      for (final interface in await NetworkInterface.list(type: type))
        ...interface.addresses,
    ];

class _Listener
    implements
        McpObservableListener,
        McpAddressedListener,
        McpRekeyableListener {
  _Listener(
    this.server,
    this._token,
    this.handler,
    this.bodyTimeout, {
    required this.exposed,
    required List<InternetAddress> hosts,
  }) : endpoints = List.unmodifiable([
         for (final host in hosts)
           Uri(
             scheme: 'http',
             host: host.address,
             port: server.port,
             path: '/mcp',
           ),
       ]) {
    server.listen(
      (request) => unawaited(_serve(request)),
      onError: (Object _) {},
      // The socket can be closed underneath us (process teardown, network
      // stack reset). Report it so the owner revokes the bound token.
      onDone: _markClosed,
      cancelOnError: false,
    );
  }
  final HttpServer server;
  String _token;
  final McpRequestHandler handler;
  final Duration bodyTimeout;

  /// Other devices can reach this listener (not bound to loopback).
  final bool exposed;
  final _done = Completer<void>();
  final _authFailures = <String, ({int count, DateTime since})>{};
  int _active = 0;
  bool _closed = false;

  @override
  final List<Uri> endpoints;

  @override
  Uri get endpoint => endpoints.first;

  @override
  Future<void> get done => _done.future;

  @override
  bool get closed => _closed;

  void _markClosed() {
    _closed = true;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    _closed = true;
    try {
      await server.close(force: true);
    } finally {
      _markClosed();
    }
  }

  @override
  void replaceToken(String token) {
    _checkToken(token);
    _token = token;
    // Earlier failures were against the old token.
    _authFailures.clear();
  }

  bool _authorized(String? header) {
    final expected = 'Bearer $_token';
    if (header == null || header.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ header.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// DNS rebinding sends a page's own host name. A loopback listener accepts
  /// only its two loopback names; an exposed one any IP literal (a client on
  /// the network addresses this device by IP) or localhost, never a name.
  bool _allowedHost(String? host) {
    if (host == '127.0.0.1:${server.port}' ||
        host == 'localhost:${server.port}') {
      return true;
    }
    if (!exposed || host == null || host.length > 80) return false;
    final uri = Uri.tryParse('http://$host');
    return uri != null &&
        uri.port == server.port &&
        uri.authority == host &&
        InternetAddress.tryParse(uri.host) != null;
  }

  bool _allowedOrigin(String? origin, String? host) =>
      origin == null || (_allowedHost(host) && origin == 'http://$host');

  bool _throttled(InternetAddress peer) {
    final entry = _authFailures[peer.address];
    if (entry == null) return false;
    if (DateTime.now().difference(entry.since) >= _authFailureWindow) {
      _authFailures.remove(peer.address);
      return false;
    }
    return entry.count >= _maxAuthFailures;
  }

  void _authFailed(InternetAddress peer) {
    if (peer.isLoopback) return;
    final now = DateTime.now();
    final entry = _authFailures[peer.address];
    if (entry != null && now.difference(entry.since) < _authFailureWindow) {
      _authFailures[peer.address] = (
        count: entry.count + 1,
        since: entry.since,
      );
      return;
    }
    if (_authFailures.length >= _maxTrackedPeers) {
      _authFailures.remove(_authFailures.keys.first);
    }
    _authFailures[peer.address] = (count: 1, since: now);
  }

  Future<void> _serve(HttpRequest request) async {
    var counted = false;
    // The token this request is checked against; a reset while its tool runs
    // withholds the result like a stop does.
    final token = _token;
    try {
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.headers.set('X-Content-Type-Options', 'nosniff');
      final host = request.headers.value('host');
      final origin = request.headers.value('origin');
      final peer = request.connectionInfo?.remoteAddress;
      if (_closed || request.uri.path != '/mcp' || request.uri.hasQuery) {
        request.response.statusCode = 404;
      } else if (exposed &&
          (peer == null || !mcpPeerAllowed(peer.rawAddress))) {
        // Only this device and private networks, whatever the interface.
        request.response.statusCode = 403;
      } else if (!_allowedHost(host) || !_allowedOrigin(origin, host)) {
        // DNS rebinding and browser pages are rejected before credentials
        // are examined.
        request.response.statusCode = 403;
      } else if (server.connectionsInfo().total > _maxOpenConnections) {
        request.response.statusCode = 503;
        request.response.headers.set('Retry-After', '1');
      } else if (peer != null && _throttled(peer)) {
        request.response.statusCode = 429;
        request.response.headers.set('Retry-After', '60');
      } else if (!_authorized(request.headers.value('authorization'))) {
        if (peer != null) _authFailed(peer);
        request.response.statusCode = 401;
        request.response.headers.set(
          'WWW-Authenticate',
          'Bearer realm="Atermius MCP"',
        );
      } else if (request.method != 'POST') {
        request.response.statusCode = 405;
        request.response.headers.set('Allow', 'POST');
      } else if (request.headers.contentType?.mimeType != 'application/json') {
        request.response.statusCode = 415;
      } else if (!(request.headers.value('accept') ?? '').contains(
            'application/json',
          ) ||
          !(request.headers.value('accept') ?? '').contains(
            'text/event-stream',
          )) {
        request.response.statusCode = 406;
      } else if (_active >= _maxActiveRequests) {
        request.response.statusCode = 429;
      } else if (request.contentLength > _maxRequestBytes) {
        request.response.statusCode = 413;
      } else {
        _active++;
        counted = true;
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in request.timeout(bodyTimeout)) {
          if (bytes.length + chunk.length > _maxRequestBytes) {
            throw const _BodyTooLarge();
          }
          bytes.add(chunk);
        }
        Object? body;
        try {
          body = jsonDecode(utf8.decode(bytes.takeBytes()));
        } on FormatException {
          await _write(
            request,
            const McpReply(400, {
              'jsonrpc': '2.0',
              'id': null,
              'error': {'code': -32700, 'message': 'Invalid JSON.'},
            }),
          );
          return;
        }
        final headers = <String, String>{};
        for (final name in ['mcp-protocol-version', 'mcp-method', 'mcp-name']) {
          final value = request.headers.value(name);
          if (value != null) headers[name] = value;
        }
        final reply = await handler(body, headers: headers);
        if (_closed || !identical(token, _token)) {
          // Revoked or reset while the tool ran: the result must not be
          // delivered under a token that is no longer valid.
          try {
            request.response.statusCode = 503;
            request.response.persistentConnection = false;
            await request.response.close();
          } catch (_) {}
          return;
        }
        await _write(request, reply);
        return;
      }
      request.response.persistentConnection = false;
      // Consume a bounded rejected body so HTTP clients can receive the status
      // without a TCP reset while their request body is still being written.
      var rejectedBytes = 0;
      try {
        await for (final chunk in request.timeout(const Duration(seconds: 2))) {
          rejectedBytes += chunk.length;
          if (rejectedBytes > _maxRequestBytes) break;
        }
      } catch (_) {}
      await request.response.close();
    } on _BodyTooLarge {
      request.response.statusCode = 413;
      request.response.persistentConnection = false;
      await request.response.close();
    } on TimeoutException {
      request.response.statusCode = 408;
      request.response.persistentConnection = false;
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = 400;
        request.response.persistentConnection = false;
        await request.response.close();
      } catch (_) {}
    } finally {
      if (counted) _active--;
    }
  }

  Future<void> _write(HttpRequest request, McpReply reply) async {
    request.response.statusCode = reply.status;
    if (reply.body != null) {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(reply.body));
    }
    await request.response.close();
  }
}

class _BodyTooLarge {
  const _BodyTooLarge();
}
