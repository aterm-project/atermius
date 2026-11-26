import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/mcp_access_policy_store.dart';
import 'package:aterm_client/mcp/mcp_listen_settings_store.dart';
import 'package:aterm_client/mcp/mcp_listener.dart';
import 'package:aterm_client/mcp/mcp_service.dart';
import 'package:aterm_client/mcp/mcp_token_store.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

McpWorkspace _workspace(String? Function() scope) => McpWorkspace(
  scope: scope,
  describe: () => {'mode': 'fixture'},
  hosts: () => const <HostRecord>[],
  sessions: () => const <McpSession>[],
  connect: (_) async {},
  openConsole: () async {},
);

Future<int> _freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late MemoryMcpListenSettingsStore listen;
  final services = <McpService>[];

  setUp(() => listen = MemoryMcpListenSettingsStore());

  tearDown(() async {
    for (final service in services) {
      await service.stop();
      service.dispose();
    }
    services.clear();
  });

  McpService create({bool autoStart = true}) {
    final service = McpService(
      policyStore: MemoryMcpAccessPolicyStore(),
      tokenStore: MemoryMcpTokenStore(),
      listenStore: listen,
    )..autoStart = autoStart;
    services.add(service);
    return service;
  }

  test('enable remembers MCP on this device; disable forgets it', () async {
    final service = create()..attach(_workspace(() => 'local:one'));
    await service.reloadPermissions();
    final port = await _freePort();
    await service.enable(port: port, bind: const McpBind.loopback());
    expect(service.running, isTrue);
    var saved = McpListenSettings.parse(listen.value);
    expect(saved.enabled, isTrue);
    expect(saved.port, port);

    // A lock, a restart or the platform pausing it is not the user stopping.
    await service.stop();
    expect(McpListenSettings.parse(listen.value).enabled, isTrue);

    await service.enable(port: port, bind: const McpBind.loopback());
    await service.disable();
    expect(service.running, isFalse);
    saved = McpListenSettings.parse(listen.value);
    expect(saved.enabled, isFalse);
    expect(saved.port, port, reason: 'the port choice is kept');
  });

  test(
    'an enabled MCP starts by itself when a workspace is unlocked',
    () async {
      final port = await _freePort();
      listen.value = McpListenSettings(port: port, enabled: true).encode();
      String? scope;
      final service = create()..attach(_workspace(() => scope));
      await service.reloadPermissions();
      expect(service.running, isFalse, reason: 'locked: nothing to serve');

      scope = 'local:one';
      service.workspaceChanged();
      await _until(() => service.running);
      expect(service.running, isTrue);
      expect(service.endpoint!.port, port);

      // Locking stops it; unlocking brings it back on the same port.
      scope = null;
      service.workspaceChanged();
      await _until(() => !service.running);
      expect(service.running, isFalse);
      scope = 'local:one';
      service.workspaceChanged();
      await _until(() => service.running);
      expect(service.endpoint!.port, port);
    },
  );

  test(
    'nothing starts by itself when MCP is off or in other windows',
    () async {
      final port = await _freePort();
      listen.value = McpListenSettings(port: port).encode();
      final off = create()..attach(_workspace(() => 'local:one'));
      await off.reloadPermissions();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(off.running, isFalse);

      listen.value = McpListenSettings(port: port, enabled: true).encode();
      final child = create(autoStart: false)
        ..attach(_workspace(() => 'local:one'));
      await child.reloadPermissions();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(child.running, isFalse);
    },
  );

  test('a taken port is reported instead of failing silently', () async {
    final taken = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(taken.close);
    listen.value = McpListenSettings(port: taken.port, enabled: true).encode();
    final service = create()..attach(_workspace(() => 'local:one'));
    await service.reloadPermissions();
    await _until(() => service.autoStartFailed);
    expect(service.autoStartFailed, isTrue);
    expect(service.running, isFalse);

    await taken.close();
    await service.enable(port: taken.port);
    expect(service.autoStartFailed, isFalse);
  });
}
