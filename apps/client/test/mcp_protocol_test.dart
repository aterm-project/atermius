import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/mcp_access_policy_store.dart';
import 'package:aterm_client/mcp/mcp_bind.dart';
import 'package:aterm_client/mcp/mcp_protocol.dart';
import 'package:aterm_client/mcp/mcp_service.dart';
import 'package:aterm_client/mcp/mcp_token_store.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Map<String, dynamic> rpc(
  String method, {
  Object id = 1,
  Map<String, dynamic> params = const {},
}) => {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params};
Map<String, dynamic> call(
  String name, [
  Map<String, dynamic> args = const {},
]) => rpc('tools/call', params: {'name': name, 'arguments': args});
Map result(McpReply reply) => reply.body!['result'] as Map;
Map content(McpReply reply) => result(reply)['structuredContent'] as Map;

void main() {
  test(
    'legacy handshake and modern discovery/list are interoperable',
    () async {
      final h = _Harness();
      final init = await h.protocol.handle(
        rpc(
          'initialize',
          params: {
            'protocolVersion': '2025-11-25',
            'capabilities': {},
            'clientInfo': {'name': 'test', 'version': '1'},
          },
        ),
      );
      expect(result(init)['protocolVersion'], '2025-11-25');
      expect(result(init)['capabilities'], contains('tools'));
      expect(
        (await h.protocol.handle({
          'jsonrpc': '2.0',
          'method': 'notifications/initialized',
        })).status,
        202,
      );
      final modern = rpc(
        'server/discover',
        params: {
          '_meta': {
            'io.modelcontextprotocol/protocolVersion': '2026-07-28',
            'io.modelcontextprotocol/clientCapabilities': {},
          },
        },
      );
      final response = await h.protocol.handle(
        modern,
        headers: {
          'mcp-protocol-version': '2026-07-28',
          'mcp-method': 'server/discover',
        },
      );
      expect(result(response)['resultType'], 'complete');
      expect(result(response)['supportedVersions'], contains('2026-07-28'));
      expect(
        (result(await h.protocol.handle(rpc('tools/list')))['tools'] as List)
            .length,
        17,
      );
      final bad = await h.protocol.handle(
        modern,
        headers: {
          'mcp-protocol-version': '2026-07-28',
          'mcp-method': 'tools/call',
        },
      );
      expect((bad.body!['error'] as Map)['code'], -32020);
    },
  );

  test('metadata excludes credentials and output is bounded', () async {
    final h = _Harness();
    final hosts = await h.protocol.handle(call('hosts_list'));
    final encoded = jsonEncode(hosts.body);
    expect(encoded, contains('fixture.example'));
    expect(encoded, isNot(contains('secret-sentinel')));
    expect(encoded, isNot(contains('privateKey')));
    h.terminal.write(List.generate(3000, (i) => '$i: line\r\n').join());
    final terminal = content(
      await h.protocol.handle(
        call('terminal_read', {'session_id': 's1', 'lines': 10}),
      ),
    );
    expect(terminal['truncated'], true);
    expect(
      utf8.encode(terminal['text'] as String).length,
      lessThanOrEqualTo(65536),
    );
  });

  test('read-only denies side effects and validates every argument', () async {
    final h = _Harness();
    final denied = await h.protocol.handle(
      call('terminal_write', {'session_id': 's1', 'text': 'whoami\n'}),
    );
    expect(content(denied)['error'], 'read_only');
    expect(h.input, isEmpty);
    h.operations = true;
    expect(
      (await h.protocol.handle(
        call('terminal_write', {
          'session_id': 's1',
          'text': 'x',
          'unexpected': true,
        }),
      )).status,
      400,
    );
    expect(
      (await h.protocol.handle({
        'jsonrpc': '2.0',
        'method': 'tools/call',
        'params': {'name': 'console_open'},
      })).status,
      400,
    );
    expect(h.consoleOpens, 0);
    expect(
      result(
        await h.protocol.handle(
          call('terminal_write', {'session_id': 's1', 'text': 'printf test\n'}),
        ),
      )['isError'],
      false,
    );
    expect(h.input, ['printf test\n']);
  });

  test('SSH exec uses its own cancellable bounded channel', () async {
    final h = _Harness()..operations = true;
    final response = await h.protocol.handle(
      call('ssh_exec', {
        'session_id': 's1',
        'command': 'printf test',
        'timeout_seconds': 5,
      }),
    );
    expect(h.connection.commands, ['printf test']);
    expect(h.connection.outputLimit, 65536);
    expect(h.connection.timeout, const Duration(seconds: 5));
    expect(content(response)['stdout'], 'test');
    expect(h.input, isEmpty);
    h.connection.waitForCancellation = true;
    final pending = h.protocol.handle(
      call('ssh_exec', {'session_id': 's1', 'command': 'sleep 60'}),
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      content(
        await h.protocol.handle(
          rpc('tools/call', id: 2, params: {'name': 'console_open'}),
        ),
      )['error'],
      'busy',
    );
    await h.protocol.handle({
      'jsonrpc': '2.0',
      'method': 'notifications/cancelled',
      'params': {'requestId': 1},
    });
    expect(content(await pending)['error'], 'cancelled');
    expect(h.connection.closed, false);
  });

  test(
    'lock/scope changes suppress results and prevent later actions',
    () async {
      final h = _Harness()..operations = true;
      h.connection.waitForCancellation = true;
      final pending = h.protocol.handle(
        call('ssh_exec', {'session_id': 's1', 'command': 'sleep 60'}),
      );
      await Future<void>.delayed(Duration.zero);
      h.unlocked = false;
      h.protocol.close();
      expect(result(await pending)['isError'], true);
      expect((await h.protocol.handle(call('console_open'))).status, 503);
      expect(h.consoleOpens, 0);
    },
  );

  test('live LAN MCP: a client on the network calls a tool and the terminal '
      'shows it', () async {
    final h = _Harness()..operations = true;
    final service = McpService(policyStore: MemoryMcpAccessPolicyStore())
      ..attach(h.workspace);
    try {
      await service.start(port: 0, bind: const McpBind.lan());
      await service.setDefaultAccess(McpAccessMode.readWrite);
      expect(service.bind, const McpBind.lan());
      final lan = service.endpoints
          .where((url) => url.host != '127.0.0.1')
          .firstOrNull;
      if (lan == null || !Platform.isLinux) {
        markTestSkipped('needs Linux with a private IPv4 interface');
        return;
      }
      // The copied configuration points at a network address, not loopback.
      final config = jsonDecode(service.connectionConfiguration()) as Map;
      expect(config['mcpServers']['atermius']['url'], '$lan');
      expect(service.endpoints.last.host, '127.0.0.1');
      final auth =
          config['mcpServers']['atermius']['headers']['Authorization']
              as String;
      final bridge = await Process.start(
        'python3',
        ['../../integration/mcp/stdio_bridge.py'],
        environment: {
          'ATERMIUS_MCP_URL': '$lan',
          'ATERMIUS_MCP_TOKEN': auth.substring(7),
        },
      );
      final stdout = utf8.decodeStream(bridge.stdout);
      final stderr = utf8.decodeStream(bridge.stderr);
      bridge.stdin.writeln(
        jsonEncode(
          rpc(
            'initialize',
            params: {
              'protocolVersion': '2025-11-25',
              'capabilities': {},
              'clientInfo': {'name': 'test', 'version': '1'},
            },
          ),
        ),
      );
      bridge.stdin.writeln(
        jsonEncode(
          call('ssh_exec', {'session_id': 's1', 'command': 'uname -a'}),
        ),
      );
      await bridge.stdin.close();
      expect(await bridge.exitCode.timeout(const Duration(seconds: 10)), 0);
      expect(await stderr, isEmpty);
      final replies = (await stdout)
          .trim()
          .split('\n')
          .map(jsonDecode)
          .toList();
      expect(replies.last['result']['structuredContent']['stdout'], 'test');
      expect(h.connection.commands, ['uname -a']);
      final screen = [
        for (var i = 0; i < h.terminal.buffer.lines.length; i++)
          h.terminal.buffer.lines[i].getText().trimRight(),
      ].where((line) => line.isNotEmpty).toList();
      expect(screen, [
        '[MCP] ssh_exec uname -a',
        '[MCP] ssh_exec → exit 0',
        '  test',
      ]);

      // The bridge refuses names and public addresses before sending a token.
      for (final url in ['http://evil.example:1/mcp', 'http://8.8.8.8:1/mcp']) {
        final refused = await Process.run(
          'python3',
          ['../../integration/mcp/stdio_bridge.py'],
          environment: {
            'ATERMIUS_MCP_URL': url,
            'ATERMIUS_MCP_TOKEN': auth.substring(7),
          },
        );
        expect(refused.exitCode, 2, reason: url);
      }
    } finally {
      await service.stop();
      service.dispose();
    }
  });

  test('live loopback MCP authenticates, rejects browser origins, keeps the '
      'token across a lock and changes it only on reset', () async {
    final h = _Harness();
    final service = McpService(
      policyStore: MemoryMcpAccessPolicyStore(),
      tokenStore: MemoryMcpTokenStore(),
    )..attach(h.workspace);
    var http = HttpClient();
    try {
      await service.start(port: 0);
      final config = jsonDecode(service.connectionConfiguration()) as Map;
      final auth =
          config['mcpServers']['atermius']['headers']['Authorization']
              as String;
      final endpoint = service.endpoint!;
      Future<({int status, String body})> post({
        String? authorization,
        String? origin,
        String? host,
        Object? body,
      }) async {
        final request = await http.postUrl(service.endpoint!);
        request.headers.contentType = ContentType.json;
        request.headers.set('Accept', 'application/json, text/event-stream');
        if (authorization != null)
          request.headers.set('Authorization', authorization);
        if (origin != null) request.headers.set('Origin', origin);
        if (host != null) request.headers.set('Host', host);
        request.write(jsonEncode(body ?? rpc('tools/list')));
        final response = await request.close();
        final data = await utf8.decodeStream(response);
        return (status: response.statusCode, body: data);
      }

      expect((await post()).status, 401);
      expect(
        (await post(
          authorization: auth,
          origin: 'https://evil.example',
        )).status,
        403,
      );
      expect(
        (await post(
          authorization: auth,
          host: 'evil.example:${endpoint.port}',
        )).status,
        403,
      );
      expect((await post(authorization: auth)).status, 200);
      if (Platform.isLinux) {
        final bridge = await Process.start(
          'python3',
          ['../../integration/mcp/stdio_bridge.py'],
          environment: {
            'ATERMIUS_MCP_URL': endpoint.toString(),
            'ATERMIUS_MCP_TOKEN': auth.substring(7),
          },
        );
        final stdout = utf8.decodeStream(bridge.stdout);
        final stderr = utf8.decodeStream(bridge.stderr);
        bridge.stdin.writeln(
          jsonEncode(
            rpc(
              'initialize',
              params: {
                'protocolVersion': '2025-11-25',
                'capabilities': {},
                'clientInfo': {'name': 'test', 'version': '1'},
              },
            ),
          ),
        );
        bridge.stdin.writeln(jsonEncode(call('sessions_list')));
        await bridge.stdin.close();
        expect(await bridge.exitCode.timeout(const Duration(seconds: 10)), 0);
        expect(await stderr, isEmpty);
        final replies = (await stdout)
            .trim()
            .split('\n')
            .map(jsonDecode)
            .toList();
        expect(replies.length, 2);
        expect(
          replies.last['result']['structuredContent']['items'][0]['id'],
          's1',
        );
      }
      final invalid = await post(
        authorization: auth,
        body: [rpc('tools/list')],
      );
      expect(invalid.status, 400);
      h.unlocked = false;
      expect((await post(authorization: auth)).status, 403);
      service.workspaceChanged();
      await service.stop();
      http.close(force: true);
      http = HttpClient();
      h.unlocked = true;
      await service.start(port: endpoint.port);
      expect(service.audit, isEmpty);
      // The workspace's token: the AI's configuration still works.
      expect((await post(authorization: auth)).status, 200);

      await service.resetToken();
      expect(service.running, isTrue);
      expect(service.endpoint!.port, endpoint.port);
      expect((await post(authorization: auth)).status, 401);
      expect(
        (await post(authorization: 'Bearer ${service.token}')).status,
        200,
      );
    } finally {
      http.close(force: true);
      await service.stop();
      service.dispose();
    }
  });
}

class _Harness {
  bool operations = false, unlocked = true;
  int consoleOpens = 0;
  final input = <String>[];
  final terminal = Terminal(maxLines: 4000);
  final connection = _Connection();
  late final workspace = McpWorkspace(
    scope: () => unlocked ? 'fixture:one' : null,
    describe: () => {'mode': 'fixture'},
    hosts: () => [
      const HostRecord(
        id: 'h1',
        name: 'test',
        address: 'fixture.example',
        username: 'test',
        manifest: {'privateKey': 'secret-sentinel'},
      ),
    ],
    sessions: () => [
      McpSession(
        id: 's1',
        name: 'test',
        kind: 'ssh',
        hostId: 'h1',
        state: 'connected',
        isAlive: () => unlocked,
        focus: () {},
        close: () async {},
        input: input.add,
        terminal: terminal,
        connection: connection,
      ),
    ],
    connect: (_) async {},
    openConsole: () async {
      consoleOpens++;
    },
  );
  late final protocol = McpProtocol(
    workspace: workspace,
    validateAccess: () {
      if (!unlocked) throw const McpToolException('locked', 'Locked');
    },
    access: (host) => host == null
        ? McpAccessMode.denied
        : operations
        ? McpAccessMode.readWrite
        : McpAccessMode.readOnly,
  );
}

class _Connection implements SshConnection {
  final commands = <String>[];
  int? outputLimit;
  Duration? timeout;
  bool waitForCancellation = false, closed = false;
  @override
  Future<SshExecResult> executeRemoteCommand(
    String command, {
    required SshExecCancellation cancellation,
    List<int>? stdinData,
    Duration timeout = const Duration(minutes: 2),
    int maxOutputBytes = 65536,
    String bashUnavailableMarker = '__ATERMIUS_BASH_UNAVAILABLE__',
  }) async {
    commands.add(command);
    outputLimit = maxOutputBytes;
    this.timeout = timeout;
    if (waitForCancellation) await cancellation.whenCancelled;
    return SshExecResult(
      stdout: 'test',
      stderr: '',
      exitCode: 0,
      exitSignal: null,
      cancelled: cancellation.isCancelled,
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
