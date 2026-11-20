// Pure planning for "Put in Vault": what is copied into an EXISTING target
// Vault and what is reused there, and when a move must be refused.
import 'package:aterm_client/cloud/host_share_plan.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

HostRecord _host(
  String id, {
  String? address,
  String? jump,
  String? credential,
  String? group,
}) => HostRecord(
  id: id,
  name: id,
  address: address ?? '10.0.0.${id.codeUnitAt(id.length - 1) % 200}',
  port: 22,
  protocol: HostProtocol.ssh,
  username: 'ops',
  jumpHostId: jump,
  credentialId: credential,
  groupId: group,
  isFavorite: true,
);

CredentialRecord _credential(String id, {String secret = 's3cret'}) =>
    CredentialRecord(
      id: id,
      name: 'deploy',
      username: 'deploy',
      kind: AuthKind.password,
      secret: secret,
    );

void main() {
  final sourceGroups = [const GroupRecord(id: 'g-src', name: 'Prod', color: 1)];
  final bastion = _host('bastion', address: '192.0.2.1');
  final web = _host('web', jump: 'bastion', credential: 'c1', group: 'g-src');
  final db = _host('db', jump: 'bastion');
  final c1 = _credential('c1');

  HostSharePlan plan(List<HostRecord> selected) => planHostShare(
    selected: selected,
    vaultHosts: [bastion, web, db],
    vaultCredentials: [c1],
    vaultKnownHosts: const [],
    vaultGroups: sourceGroups,
    sourceVaultId: 'source',
  );

  var counter = 0;
  String newId() => 'new-${++counter}';
  setUp(() => counter = 0);

  test('into an empty Vault: Host, its jump Host and credential are copied '
      'with fresh IDs and remapped references', () {
    final copies = remapForVaultTransfer(
      plan([web]),
      newId,
      sourceGroups: sourceGroups,
      targetHosts: const [],
      targetCredentials: const [],
      targetGroups: const [],
    );
    expect(copies.credentials, hasLength(1));
    expect(copies.hosts.map((h) => h.name), ['bastion', 'web']);
    final copiedWeb = copies.hosts.last, copiedJump = copies.hosts.first;
    expect(copiedWeb.id, isNot('web'));
    expect(copiedWeb.jumpHostId, copiedJump.id);
    expect(copiedWeb.credentialId, copies.credentials.single.id);
    expect(copies.credentials.single.id, isNot('c1'));
    expect(copies.credentials.single.secret, 's3cret');
    expect(copiedWeb.groupId, isNull, reason: 'no group of that name there');
    expect(copiedWeb.isFavorite, isFalse);
  });

  test('reuses an identical credential, the same jump Host and a group of '
      'the same name already in the target', () {
    final existingJump = _host('t-bastion', address: '192.0.2.1');
    final copies = remapForVaultTransfer(
      plan([web]),
      newId,
      sourceGroups: sourceGroups,
      targetHosts: [existingJump],
      targetCredentials: [_credential('t-c')],
      targetGroups: [const GroupRecord(id: 'g-dst', name: 'Prod', color: 2)],
    );
    expect(copies.credentials, isEmpty);
    expect(copies.hosts.map((h) => h.name), ['web']);
    expect(copies.hosts.single.jumpHostId, 't-bastion');
    expect(copies.hosts.single.credentialId, 't-c');
    expect(copies.hosts.single.groupId, 'g-dst');
  });

  test('a credential with the same name but another secret is NOT reused', () {
    final copies = remapForVaultTransfer(
      plan([web]),
      newId,
      sourceGroups: sourceGroups,
      targetHosts: const [],
      targetCredentials: [_credential('t-c', secret: 'different')],
      targetGroups: const [],
    );
    expect(copies.credentials, hasLength(1));
    expect(copies.hosts.last.credentialId, copies.credentials.single.id);
  });

  test('a Host that others jump through pins a move', () {
    expect(
      hostsPinnedByJumpUsers(
        selected: [bastion],
        vaultHosts: [bastion, web, db],
      ).map((h) => h.id),
      ['web', 'db'],
    );
    expect(
      hostsPinnedByJumpUsers(
        selected: [bastion, web, db],
        vaultHosts: [bastion, web, db],
      ),
      isEmpty,
      reason: 'moving the whole chain together is fine',
    );
    expect(
      hostsPinnedByJumpUsers(selected: [web], vaultHosts: [bastion, web, db]),
      isEmpty,
    );
  });
}
