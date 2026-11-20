// Team Vaults on the REAL AppController against the REAL server binary:
// create a Vault for an organization team, put Hosts in it (copy, move, a
// new unsaved Host), deliver the key to a member, and let that member add a
// Host as an editor.
//
// Run: ATERMIUS_TEST_SERVER_BINARY=<cargo target>/debug/atermius-server \
//      flutter test test/team_vault_real_server_test.dart
import 'dart:io';

import 'package:aterm_client/cloud/cloud_access_service.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/cloud_real_server.dart';

Matcher _code(String code) =>
    throwsA(isA<CloudAccessException>().having((e) => e.code, 'code', code));

void main() {
  if (realServerBinary == null || !File(realServerBinary!).existsSync()) {
    test(
      'team Vaults on a real server',
      () {},
      skip: 'set ATERMIUS_TEST_SERVER_BINARY to the built atermius-server',
    );
    return;
  }
  late SodiumSumo sodium;
  late TestServer server;
  late Party owner;
  late Party member;
  late String sourceVaultId;
  late String orgId;
  late String teamId;
  late String teamVaultId;
  late HostRecord h1;
  late HostRecord h2;
  late HostRecord bastion;
  late HostRecord inner;

  HostRecord live(Party p, String id) => p.app.hosts.firstWhere((h) => h.id == id);

  Future<void> select(Party p, String vaultId) async {
    await p.app.selectVault(vaultId);
    expect(p.app.activeVault?.id, vaultId);
    await idle(p.app);
  }

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    sodium = await SodiumSumoInit.init();
    server = await TestServer.start();
    owner = await party(sodium, server.baseUrl, username: 'owner@example.test', bootstrap: server.bootstrapToken());
    sourceVaultId = owner.app.activeVault!.id;
    h1 = testHost('H1');
    h2 = testHost('H2-two');
    bastion = testHost('Bastion-x');
    inner = HostRecord.fromJson({...testHost('Inner-host').toJson(), 'jump_host_id': bastion.id});
    for (final host in [h1, h2, bastion, inner]) {
      await owner.app.saveHost(host);
    }
    await owner.app.synchronize();
    await idle(owner.app);
    orgId = (await owner.service.api.createOrg('Ops org'))['org_id'] as String;

    const name = 'member@example.test';
    member = await party(sodium, server.baseUrl, username: name, storagePrefix: 'm.', invitation: server.accountInvitation(name));
    final invite = await owner.service.api.createInvitation(orgId, role: 'member', username: name);
    await member.service.api.acceptInvitation(invite['token'] as String);
    await member.service.publishDeviceCard();
    final team = await owner.service.api.createTeam(orgId, 'SRE');
    teamId = team['team_id'] as String;
    await owner.service.api.setTeamMembers(orgId, teamId, [member.app.account!.accountId], team['revision'] as int);
  });

  tearDownAll(() async {
    await server.stop();
  });

  test('a team Vault is created empty, attached to the organization and granted to the team', () async {
    expect(owner.app.vaultOrganization(sourceVaultId), isNull);
    teamVaultId = await owner.service.createTeamVault(
      name: 'SRE hosts',
      orgId: orgId,
      grants: [(type: 'team', id: teamId, role: 'editor')],
    );
    expect(owner.app.activeVault?.id, sourceVaultId, reason: 'the personal Vault stays selected');
    expect(owner.app.vaultOrganization(teamVaultId), (id: orgId, name: 'Ops org'));
    expect(owner.app.vaultOrganization(sourceVaultId), isNull);
    final grants = await owner.service.api.grants(teamVaultId);
    expect((grants['organization'] as Map)['org_id'], orgId);
    expect((grants['grants'] as List).cast<Map>().map((g) => '${g['principal_type']}:${g['principal_id']}:${g['role']}'), ['team:$teamId:editor']);
    expect(owner.service.transferTargets.map((v) => v.id), contains(teamVaultId));
    // Nobody received a key by this alone.
    expect(member.app.vaults.map((v) => v.id), isNot(contains(teamVaultId)));
    expect(await hostsIn(owner.app, teamVaultId), isEmpty);
    await select(owner, sourceVaultId);
  });

  test('copy keeps the original; the copy carries its login', () async {
    await owner.service.transferHostsToVault(owner.service.planShare([live(owner, h1.id)]), teamVaultId, move: false);
    expect(owner.app.activeVault?.id, sourceVaultId);
    expect(owner.app.hosts.map((h) => h.id), contains(h1.id));
    final inTeam = await hostsIn(owner.app, teamVaultId);
    expect(inTeam.map((h) => h.name), ['H1']);
    expect(inTeam.single.id, isNot(h1.id));
    expect(inTeam.single.login?.password, 'SENTINEL-H1');
    await select(owner, sourceVaultId);
  });

  test('move removes the original only from the source Vault', () async {
    await owner.service.transferHostsToVault(owner.service.planShare([live(owner, h2.id)]), teamVaultId, move: true);
    expect(owner.app.activeVault?.id, sourceVaultId);
    await owner.app.synchronize();
    await idle(owner.app);
    expect(owner.app.hosts.map((h) => h.id), isNot(contains(h2.id)));
    expect(owner.app.hosts.map((h) => h.id), containsAll([h1.id, bastion.id, inner.id]));
    expect((await hostsIn(owner.app, teamVaultId)).map((h) => h.name).toSet(), {'H1', 'H2-two'});
    await select(owner, sourceVaultId);
  });

  test('a jump Host that another Host still uses can be copied but not moved', () async {
    final plan = owner.service.planShare([live(owner, bastion.id)]);
    await expectLater(owner.service.transferHostsToVault(plan, teamVaultId, move: true), _code('transfer_move_blocked'));
    expect(owner.app.activeVault?.id, sourceVaultId);
    expect(owner.app.hosts.map((h) => h.id), contains(bastion.id));
    // Moving the dependant takes a copy of its jump Host along; the jump
    // Host itself stays in the source.
    await owner.service.transferHostsToVault(owner.service.planShare([live(owner, inner.id)]), teamVaultId, move: true);
    await owner.app.synchronize();
    await idle(owner.app);
    expect(owner.app.hosts.map((h) => h.id), contains(bastion.id));
    expect(owner.app.hosts.map((h) => h.id), isNot(contains(inner.id)));
    final inTeam = await hostsIn(owner.app, teamVaultId);
    final movedInner = inTeam.firstWhere((h) => h.name == 'Inner-host');
    final copiedBastion = inTeam.firstWhere((h) => h.name == 'Bastion-x');
    expect(movedInner.jumpHostId, copiedBastion.id);
    await select(owner, sourceVaultId);
    // Copying the bastion again reuses nothing as a selected Host (a second
    // copy is what was asked), but a later dependant reuses the bastion.
    expect(owner.service.movePinnedBy([live(owner, bastion.id)]), isEmpty);
  });

  test('a new, unsaved Host goes straight into the team Vault and never into the personal one', () async {
    final draft = testHost('Draft-only');
    await owner.service.transferHostsToVault(owner.service.planShare([draft]), teamVaultId, move: false);
    expect(owner.app.activeVault?.id, sourceVaultId);
    expect(owner.app.hosts.map((h) => h.name), isNot(contains('Draft-only')));
    expect((await hostsIn(owner.app, teamVaultId)).map((h) => h.name), contains('Draft-only'));
    await select(owner, sourceVaultId);
  });

  test('refuses the selected Vault itself and unknown Vaults', () async {
    final plan = owner.service.planShare([live(owner, h1.id)]);
    await expectLater(owner.service.transferHostsToVault(plan, sourceVaultId, move: false), _code('transfer_same_vault'));
    await expectLater(owner.service.transferHostsToVault(plan, '00000000-0000-4000-8000-000000000000', move: false), _code('transfer_target_read_only'));
  });

  test('a team member receives the key after owner confirmation and can add Hosts as an editor', () async {
    final pending = ((await owner.service.api.keyDistribution(teamVaultId))['pending_additions'] as List)
        .cast<Map>()
        .firstWhere((p) => p['user_id'] == member.app.account!.accountId);
    expect(pending['desired_role'], 'editor');
    final card = Map<String, dynamic>.from((pending['device_cards'] as List).first['card'] as Map);
    await owner.service.deliverKey(vaultId: teamVaultId, card: card, role: 'editor');
    await select(owner, sourceVaultId);

    final memberPersonal = member.app.activeVault!.id;
    expect(await member.service.acceptDeliveries(), 1);
    await idle(member.app);
    await member.app.refreshVaultOrganizations();
    expect(member.app.vaults.map((v) => v.id), contains(teamVaultId));
    expect(member.app.vaultOrganization(teamVaultId), (id: orgId, name: 'Ops org'));
    final seen = await hostsIn(member.app, teamVaultId);
    expect(seen.map((h) => h.name), containsAll(['H1', 'H2-two', 'Inner-host', 'Draft-only']));
    expect(seen.firstWhere((h) => h.name == 'H1').login?.password, 'SENTINEL-H1');

    // The member puts a Host of their own personal Vault into the team Vault.
    await select(member, memberPersonal);
    final mine = testHost('Member-host');
    await member.app.saveHost(mine);
    await member.app.synchronize();
    await idle(member.app);
    expect(member.service.transferTargets.map((v) => v.id), contains(teamVaultId));
    await member.service.transferHostsToVault(member.service.planShare([live(member, mine.id)]), teamVaultId, move: true);
    expect(member.app.activeVault?.id, memberPersonal);
    await member.app.synchronize();
    await idle(member.app);
    expect(member.app.hosts.map((h) => h.id), isNot(contains(mine.id)));

    expect((await hostsIn(owner.app, teamVaultId)).map((h) => h.name), contains('Member-host'));
    await select(owner, sourceVaultId);
  });
}
