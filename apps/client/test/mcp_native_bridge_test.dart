import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/mcp_access_policy_store.dart';
import 'package:aterm_client/mcp/mcp_service.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('McpNativeGateway & McpNativeBridge', () {
    test('works in-process without starting an HTTP listener', () async {
      final harness = _NativeHarness();
      final service = McpService(policyStore: MemoryMcpAccessPolicyStore())
        ..attach(harness.workspace);
      addTearDown(service.dispose);

      expect(service.nativeBridgeSupported, isTrue);
      expect(service.running, isFalse);

      final gateway = service.createNativeGateway(callerId: 'apple_ai');
      addTearDown(gateway.close);

      final discovery = await gateway.discover();
      expect(discovery['supportedVersions'], isNotEmpty);

      final tools = await gateway.listTools();
      expect(tools.length, 17);
      expect(
        tools.map((t) => t['name']),
        containsAll([
          'workspace_status',
          'hosts_list',
          'ssh_system_overview',
          'ssh_network_probe',
          'ssh_process_snapshot',
          'ssh_service_logs',
        ]),
      );

      final hostsReply = await gateway.callTool('hosts_list');
      expect(hostsReply['isError'], isFalse);
      final hostItems =
          ((hostsReply['structuredContent'] as Map)['items'] as List);
      expect(hostItems.single['id'], 'h1');
      expect(hostItems.single['access'], 'read_only');

      // 默认仅只读：写入类工具应返回 read_only，但只读诊断小工具可直接使用。
      final blockedWrite = await gateway.callTool('terminal_write', {
        'session_id': 's1',
        'text': 'echo hi\n',
      });
      expect(blockedWrite['isError'], isTrue);
      expect(
        (blockedWrite['structuredContent'] as Map)['error'],
        'read_only',
      );

      final diag = await gateway.callTool('ssh_system_overview', {
        'session_id': 's1',
      });
      expect(diag['isError'], isFalse);
      expect((diag['structuredContent'] as Map)['hostname'], 'edge-tokyo-01');

      // 开启单机读写权限后，允许调用交互命令并记录至审计表。
      await service.setHostAccess('h1', McpAccessMode.readWrite);
      final writeOk = await gateway.callTool('terminal_write', {
        'session_id': 's1',
        'text': 'uptime\n',
      });
      expect(writeOk['isError'], isFalse);
      expect(harness.inputs, ['uptime\n']);
      expect(service.audit.first.tool, 'terminal_write');
      expect(service.audit.first.success, isTrue);
    });

    test('rejects calls when locked and revokes gateway + cancels in-flight calls on workspace switch', () async {
      final harness = _NativeHarness()..unlocked = false;
      final service = McpService(policyStore: MemoryMcpAccessPolicyStore())
        ..attach(harness.workspace);
      addTearDown(service.dispose);

      final lockedGateway = service.createNativeGateway();
      expect(lockedGateway.ready, isFalse);
      await expectLater(
        lockedGateway.callTool('workspace_status'),
        throwsA(isA<McpToolException>()),
      );
      final rpcReply = await lockedGateway.handleJsonRpc({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      });
      expect(rpcReply.status, 403);

      // 解锁并允许读写后，发起一个慢请求，并在中途切换工作区。
      harness.unlocked = true;
      harness.scopeId = 'local:workspace-a';
      service.workspaceChanged();
      await service.reloadPermissions();
      await service.setDefaultAccess(McpAccessMode.readWrite);

      final activeGateway = service.createNativeGateway();
      harness.connection.hold = true;
      final pending = activeGateway.callTool('ssh_exec', {
        'session_id': 's1',
        'command': 'sleep 60',
      });
      await harness.connection.started.future;

      harness.scopeId = 'local:workspace-b';
      service.workspaceChanged();

      expect(activeGateway.closed, isTrue);
      expect(activeGateway.ready, isFalse);
      final res = await pending;
      expect(res['isError'], isTrue);
      expect(
        (res['structuredContent'] as Map)['error'],
        anyOf('access_revoked', 'workspace_changed', 'cancelled', 'operation_failed'),
      );
      await expectLater(
        activeGateway.listTools(),
        throwsA(isA<McpToolException>()),
      );
    });

    test('exposes atermius/mcp_native MethodChannel for native Swift/AI callers', () async {
      final harness = _NativeHarness();
      final service = McpService(policyStore: MemoryMcpAccessPolicyStore())
        ..attach(harness.workspace);
      await service.reloadPermissions();
      const channel = MethodChannel('atermius/mcp_native_test');
      final bridge = McpNativeBridge(service: service, channel: channel)
        ..bind();
      addTearDown(() {
        bridge.dispose();
        service.dispose();
      });

      Future<Object?> sendPlatformMessage(String method, [Object? args]) async {
        const codec = StandardMethodCodec();
        final encoded = codec.encodeMethodCall(MethodCall(method, args));
        ByteData? rawReply;
        await TestDefaultBinaryMessengerBinding
            .instance
            .defaultBinaryMessenger
            .handlePlatformMessage(channel.name, encoded, (data) {
              rawReply = data;
            });
        return codec.decodeEnvelope(rawReply!);
      }

      final status = Map<String, Object?>.from(
        await sendPlatformMessage('status') as Map,
      );
      expect(status['supported'], isTrue);
      expect(status['workspace_ready'], isTrue);
      expect(status['http_running'], isFalse);

      final list = Map<String, Object?>.from(
        await sendPlatformMessage('listTools') as Map,
      );
      expect((list['tools'] as List).length, 17);

      final call = Map<String, Object?>.from(
        await sendPlatformMessage('callTool', {
          'name': 'ssh_system_overview',
          'arguments': {'session_id': 's1'},
        }) as Map,
      );
      expect(call['isError'], isFalse);
      expect(
        jsonDecode((call['content'] as List).first['text'] as String)['hostname'],
        'edge-tokyo-01',
      );
    });
  });
}

class _NativeHarness {
  bool unlocked = true;
  String scopeId = 'local:native-test';
  final inputs = <String>[];
  final terminal = Terminal(maxLines: 500);
  final connection = _HoldableSshConnection();

  late final workspace = McpWorkspace(
    scope: () => unlocked ? scopeId : null,
    describe: () => {'mode': 'local'},
    hosts: () => const [
      HostRecord(
        id: 'h1',
        name: 'edge-tokyo-01',
        address: '198.51.100.11',
        username: 'ops',
      ),
    ],
    sessions: () => [
      McpSession(
        id: 's1',
        name: 'edge-tokyo-01',
        kind: 'ssh',
        hostId: 'h1',
        state: 'connected',
        isAlive: () => unlocked,
        focus: () {},
        close: () async {},
        input: inputs.add,
        terminal: terminal,
        connection: connection,
      ),
    ],
    connect: (_) async {},
    openConsole: () async {},
  );
}

class _HoldableSshConnection implements SshConnection {
  bool hold = false;
  final started = Completer<void>();

  @override
  Future<SshExecResult> executeRemoteCommand(
    String command, {
    required SshExecCancellation cancellation,
    List<int>? stdinData,
    Duration timeout = const Duration(minutes: 2),
    int maxOutputBytes = 65536,
    String bashUnavailableMarker = '__ATERMIUS_BASH_UNAVAILABLE__',
  }) async {
    if (hold) {
      if (!started.isCompleted) started.complete();
      await cancellation.whenCancelled;
      return const SshExecResult(
        stdout: '',
        stderr: '',
        exitCode: null,
        exitSignal: null,
        cancelled: true,
      );
    }
    return const SshExecResult(
      stdout: '__AT_HOST__=edge-tokyo-01\n__AT_KERNEL__=6.8.0\n',
      stderr: '',
      exitCode: 0,
      exitSignal: null,
    );
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
