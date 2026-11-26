import 'dart:convert';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/mcp_access_policy_store.dart';
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

String _configured(McpService service) =>
    ((jsonDecode(service.connectionConfiguration()) as Map)['mcpServers']
            as Map)['atermius']['headers']['Authorization']
        as String;

void main() {
  late MemoryMcpAccessPolicyStore policies;
  late MemoryMcpTokenStore tokens;
  final services = <McpService>[];

  setUp(() {
    policies = MemoryMcpAccessPolicyStore();
    tokens = MemoryMcpTokenStore();
  });

  tearDown(() async {
    for (final service in services) {
      await service.stop();
      service.dispose();
    }
    services.clear();
  });

  Future<McpService> loaded(String? Function() scope) async {
    final service = McpService(policyStore: policies, tokenStore: tokens)
      ..attach(_workspace(scope));
    services.add(service);
    await service.reloadPermissions();
    return service;
  }

  test(
    'one saved token per workspace, kept across stops and launches',
    () async {
      var scope = 'local:one';
      final service = await loaded(() => scope);
      final first = service.token;
      expect(mcpTokenValid(first), isTrue);
      expect(service.tokenSaved, isTrue);
      expect(tokens.values, {'local:one': first});

      await service.start(port: 0);
      expect(_configured(service), 'Bearer $first');
      await service.stop();
      expect(service.token, first);
      await service.start(port: 0);
      expect(_configured(service), 'Bearer $first');
      await service.stop();

      // The next launch reads the same token.
      final again = await loaded(() => 'local:one');
      expect(again.token, first);
      expect(tokens.writes, 1);

      // Another workspace has its own; locked shows none.
      scope = 'local:two';
      service.workspaceChanged();
      await service.reloadPermissions();
      expect(service.token, allOf(isNotNull, isNot(first)));
      final locked = await loaded(() => null);
      expect(locked.token, isNull);
    },
  );

  test('reset replaces the token, also for the running listener', () async {
    final service = await loaded(() => 'local:one');
    final first = service.token!;
    await service.start(port: 0);
    final port = service.endpoint!.port;

    await service.resetToken();
    final second = service.token!;
    expect(second, isNot(first));
    expect(tokens.values['local:one'], second);
    expect(service.running, isTrue);
    expect(service.endpoint!.port, port);
    expect(_configured(service), 'Bearer $second');
  });

  test('an unreadable store never overwrites the saved token', () async {
    tokens.values['local:one'] = 'S' * 43;
    tokens.readError = StateError('keyring locked');
    final service = await loaded(() => 'local:one');
    expect(mcpTokenValid(service.token), isTrue);
    expect(service.token, isNot('S' * 43));
    expect(service.tokenSaved, isFalse);
    expect(tokens.values['local:one'], 'S' * 43);
    expect(tokens.writes, 0);
    // MCP still works for this run.
    await service.start(port: 0);
    expect(_configured(service), 'Bearer ${service.token}');
  });

  test('a malformed stored value is replaced', () async {
    tokens.values['local:one'] = 'short';
    final service = await loaded(() => 'local:one');
    expect(mcpTokenValid(service.token), isTrue);
    expect(tokens.values['local:one'], service.token);
  });

  test('a reset that cannot be saved keeps the saved token', () async {
    final service = await loaded(() => 'local:one');
    final first = service.token;
    tokens.writeError = StateError('keyring locked');
    await expectLater(service.resetToken(), throwsStateError);
    expect(service.token, first);
    expect(tokens.values['local:one'], first);
  });

  test(
    'without a usable store a reset still changes this run\'s token',
    () async {
      tokens.writeError = StateError('no keyring');
      final service = await loaded(() => 'local:one');
      final first = service.token;
      expect(service.tokenSaved, isFalse);
      await service.resetToken();
      expect(service.token, allOf(isNotNull, isNot(first)));
      expect(service.tokenSaved, isFalse);
    },
  );

  test('resume listens again only for the same workspace', () async {
    var scope = 'local:one';
    final service = await loaded(() => scope);
    await service.start(port: 0);
    final port = service.endpoint!.port;
    final auth = _configured(service);

    await service.stop();
    await service.resume();
    expect(service.running, isTrue);
    expect(service.endpoint!.port, port);
    expect(_configured(service), auth);

    await service.stop();
    scope = 'local:two';
    service.workspaceChanged();
    await service.reloadPermissions();
    await service.resume();
    expect(service.running, isFalse);
  });
}
