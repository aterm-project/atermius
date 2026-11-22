import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/conflict_feed.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _spaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';
const _snapshotId = '77777777-7777-4777-8777-777777777777';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test(
    'pull-time collision keeps one pushable update based on the remote head',
    () async {
      final fixture = await _Fixture.create(sodium);
      try {
        await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: _host(address: 'local.example'),
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        final remote = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: _host(address: 'remote.example'),
        );
        final remoteRevisionId = _header(remote)['revision_id'] as String;

        // The pull converges locally even though nothing can be pushed yet.
        fixture.api.pushUnavailable = true;
        await expectLater(
          fixture.repository.synchronize(),
          throwsA(isA<ApiException>()),
        );

        expect(await fixture.openConflicts(), isEmpty);
        expect(fixture.api.conflictUploads, isEmpty);
        final pushable = await fixture.database.pushableOperations(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
        );
        expect(pushable, hasLength(1));
        expect(pushable.single.baseRevisionId, remoteRevisionId);
        expect(pushable.single.baseEnvelopeJson, jsonEncode(remote));
        final rebasedHeader = _header(
          jsonDecode(pushable.single.envelopeJson) as Map<String, dynamic>,
        );
        expect(rebasedHeader['operation'], 'update');
        expect(rebasedHeader['base_revision_id'], remoteRevisionId);
        expect(rebasedHeader['device_id'], fixture.local.deviceId);
        expect(await fixture.superseded(), hasLength(1));
        expect(
          (await fixture.repository.loadRecords()).single['address'],
          'local.example',
        );

        fixture.api.pushUnavailable = false;
        final result = await fixture.repository.synchronize();
        expect(result.status, 'idle');
        expect(result.conflictCount, 0);
        expect(result.pendingCount, 0);
        expect(fixture.api.heads[_recordId], rebasedHeader['revision_id']);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test('local delete wins over a concurrent remote update', () async {
    final fixture = await _Fixture.create(sodium);
    try {
      await fixture.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
        baseRevisionId: fixture.baseRevisionId,
        operation: 'delete',
      );
      final remote = await fixture.commitRemote(
        operation: 'update',
        baseRevisionId: fixture.baseRevisionId,
        plaintext: _host(address: 'remote.example'),
      );

      final result = await fixture.repository.synchronize();

      expect(result.status, 'idle');
      expect(result.conflictCount, 0);
      expect(fixture.api.conflictUploads, isEmpty);
      final pushed = _header(fixture.api.committed.last);
      expect(pushed['operation'], 'delete');
      expect(pushed['base_revision_id'], _header(remote)['revision_id']);
      final cached = await fixture.cached();
      expect(cached?.isDeleted, isTrue);
      expect(cached?.revisionId, pushed['revision_id']);
      expect(cached?.commitSeq, isNotNull);
      expect(await fixture.repository.loadRecords(), isEmpty);
      expect(await fixture.pending(), isEmpty);
    } finally {
      await fixture.dispose();
    }
  });

  test(
    'local update brings a remotely deleted record back with a restore',
    () async {
      final fixture = await _Fixture.create(sodium);
      try {
        await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: _host(address: 'local.example'),
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        final tombstone = await fixture.commitRemote(
          operation: 'delete',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
        );

        final result = await fixture.repository.synchronize();

        expect(result.status, 'idle');
        expect(result.conflictCount, 0);
        expect(fixture.api.conflictUploads, isEmpty);
        final pushed = _header(fixture.api.committed.last);
        expect(pushed['operation'], 'restore');
        expect(pushed['base_revision_id'], _header(tombstone)['revision_id']);
        final cached = await fixture.cached();
        expect(cached?.isDeleted, isFalse);
        expect(cached?.commitSeq, isNotNull);
        expect(
          (await fixture.repository.loadRecords()).single['address'],
          'local.example',
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'an expired restore of a local edit becomes a conflict branch, not a loss',
    () async {
      final fixture = await _Fixture.create(sodium);
      try {
        await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: _host(address: 'local.example'),
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        final tombstone = await fixture.commitRemote(
          operation: 'delete',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
        );
        fixture.api
          ..restoreWindowClosed = true
          ..snapshotItems = [
            {
              'record_id': _recordId,
              'revision_id': _header(tombstone)['revision_id'],
              'commit_seq': '2',
              'deleted': true,
              'envelope': tombstone,
            },
          ];

        final result = await fixture.repository.synchronize();

        expect(result.conflictCount, 1);
        final conflict = (await fixture.openConflicts()).single;
        expect(conflict.kind, 'delete_edit');
        expect(conflict.remoteEnvelopeJson, jsonEncode(tombstone));
        final branch =
            jsonDecode(conflict.branchEnvelopeJson) as Map<String, dynamic>;
        final branchContent = await fixture.crypto.decryptRecord(
          vaultKey: Uint8List.fromList(fixture.key),
          envelope: branch,
          authorPublicKey: fixture.local.signing.publicKey,
        );
        expect(branchContent['address'], 'local.example');
        expect(fixture.api.conflictUploads.single['envelope'], branch);
        final pending = await fixture.pending();
        expect(pending.single.status, 'conflict');
        final cached = await fixture.cached();
        expect(cached?.isDeleted, isTrue);
        expect(cached?.revisionId, _header(tombstone)['revision_id']);
        expect(fixture.api.heads[_recordId], _header(tombstone)['revision_id']);
      } finally {
        await fixture.dispose();
      }
    },
  );

  test('a record deleted on both sides adopts the remote tombstone', () async {
    final fixture = await _Fixture.create(sodium);
    try {
      await fixture.repository.saveRecord(
        recordId: _recordId,
        plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
        baseRevisionId: fixture.baseRevisionId,
        operation: 'delete',
      );
      final tombstone = await fixture.commitRemote(
        operation: 'delete',
        baseRevisionId: fixture.baseRevisionId,
        plaintext: const {'id': _recordId, 'type': 'host', 'deleted': true},
      );

      final result = await fixture.repository.synchronize();

      expect(result.status, 'idle');
      expect(result.conflictCount, 0);
      expect(result.pendingCount, 0);
      expect(fixture.api.pushRequests, isEmpty);
      expect(fixture.api.conflictUploads, isEmpty);
      final cached = await fixture.cached();
      expect(cached?.revisionId, _header(tombstone)['revision_id']);
      expect(cached?.isDeleted, isTrue);
      expect(cached?.commitSeq, '2');
      expect(await fixture.pending(), isEmpty);
      expect(await fixture.superseded(), hasLength(1));
    } finally {
      await fixture.dispose();
    }
  });

  test(
    'push-time conflicts are retried a bounded number of times per pass',
    () async {
      late _Fixture fixture;
      var competingCommits = 0;
      var keepCompeting = true;
      fixture = await _Fixture.create(
        sodium,
        beforePush: () async {
          if (!keepCompeting) return;
          competingCommits++;
          await fixture.commitRemote(
            operation: 'update',
            baseRevisionId: fixture.api.heads[_recordId],
            plaintext: _host(address: 'remote-$competingCommits.example'),
          );
        },
      );
      try {
        await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: _host(address: 'local.example'),
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );

        final result = await fixture.repository.synchronize();

        // One attempt plus three refresh-and-retry rounds, then the pass ends.
        expect(result.status, 'retry_wait');
        expect(fixture.api.pushRequests, hasLength(4));
        expect(competingCommits, 4);
        expect(result.conflictCount, 0);
        expect(await fixture.openConflicts(), isEmpty);
        // The outbox holds exactly one operation, already rebased three times.
        final pending = await fixture.pending();
        expect(pending, hasLength(1));
        expect(await fixture.superseded(), hasLength(3));
        expect(
          (await fixture.repository.loadRecords()).single['address'],
          'local.example',
        );

        keepCompeting = false;
        final next = await fixture.repository.synchronize();
        expect(next.status, 'idle');
        expect(next.conflictCount, 0);
        expect(next.pendingCount, 0);
        final committed = _header(fixture.api.committed.last);
        expect(committed['device_id'], fixture.local.deviceId);
        expect(fixture.api.heads[_recordId], committed['revision_id']);
        expect(
          (await fixture.repository.loadRecords()).single['address'],
          'local.example',
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'a replayed page of three remote revisions changes nothing after a rebase',
    () async {
      final fixture = await _Fixture.create(sodium);
      try {
        await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: _host(address: 'local.example'),
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        final first = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: _host(address: 'remote-1.example'),
        );
        final second = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: _header(first)['revision_id'] as String,
          plaintext: _host(address: 'remote-2.example'),
        );
        final third = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: _header(second)['revision_id'] as String,
          plaintext: _host(address: 'remote-3.example'),
        );
        fixture.api.pushUnavailable = true;
        await expectLater(
          fixture.repository.synchronize(),
          throwsA(isA<ApiException>()),
        );
        final rebased = (await fixture.pending()).single;
        expect(rebased.baseRevisionId, _header(third)['revision_id']);
        expect(rebased.baseCommitSeq, '4');
        final head = (await fixture.cached())!;

        // The same page is delivered again after a crash before its
        // checkpoint: the grandparent, the parent and the base itself.
        fixture.api.queueEvent(first, commitSeq: '2');
        fixture.api.queueEvent(second, commitSeq: '3');
        fixture.api.queueEvent(third, commitSeq: '4');
        await expectLater(
          fixture.repository.synchronize(),
          throwsA(isA<ApiException>()),
        );

        expect(await fixture.openConflicts(), isEmpty);
        final pending = await fixture.pending();
        expect(pending.single.opId, rebased.opId);
        expect(pending.single.status, isNot('conflict'));
        expect(pending.single.envelopeJson, rebased.envelopeJson);
        final cached = (await fixture.cached())!;
        expect(cached.revisionId, head.revisionId);
        expect(cached.envelopeJson, head.envelopeJson);

        // The edit is still pushable, and a revision committed after the
        // base is not mistaken for a replay.
        final fourth = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: _header(third)['revision_id'] as String,
          plaintext: _host(address: 'remote-4.example'),
        );
        fixture.api.pushUnavailable = false;
        final result = await fixture.repository.synchronize();
        expect(result.conflictCount, 0);
        expect(await fixture.pending(), isEmpty);
        final pushed = Map<String, dynamic>.from(
          (fixture.api.pushRequests.last['operations'] as List).single as Map,
        );
        expect(
          _header(pushed)['base_revision_id'],
          _header(fourth)['revision_id'],
        );
        expect(
          (await fixture.repository.loadRecords()).single['address'],
          'local.example',
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test(
    'a replayed page of three remote revisions changes nothing after a merge',
    () async {
      final fixture = await _Fixture.create(sodium);
      try {
        final base = _host(address: 'base.example');
        // Only display fields change, so each step is a field-wise merge.
        await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: {...base, 'name': 'Renamed here'},
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        final first = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: {
            ...base,
            'tags': ['one'],
          },
        );
        final second = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: _header(first)['revision_id'] as String,
          plaintext: {
            ...base,
            'tags': ['one'],
            'color': 3,
          },
        );
        final third = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: _header(second)['revision_id'] as String,
          plaintext: {
            ...base,
            'tags': ['one'],
            'color': 3,
            'is_favorite': true,
          },
        );
        fixture.api.pushUnavailable = true;
        await expectLater(
          fixture.repository.synchronize(),
          throwsA(isA<ApiException>()),
        );
        final merged = (await fixture.pending()).single;
        expect(merged.baseRevisionId, _header(third)['revision_id']);
        expect(merged.baseCommitSeq, '4');
        final head = (await fixture.cached())!;

        fixture.api.queueEvent(first, commitSeq: '2');
        fixture.api.queueEvent(second, commitSeq: '3');
        fixture.api.queueEvent(third, commitSeq: '4');
        await expectLater(
          fixture.repository.synchronize(),
          throwsA(isA<ApiException>()),
        );

        expect(await fixture.openConflicts(), isEmpty);
        final pending = await fixture.pending();
        expect(pending.single.opId, merged.opId);
        expect(pending.single.envelopeJson, merged.envelopeJson);
        expect((await fixture.cached())!.envelopeJson, head.envelopeJson);
        final visible = (await fixture.repository.loadRecords()).single;
        expect(visible['name'], 'Renamed here');
        expect(visible['tags'], ['one']);
        expect(visible['color'], 3);
        expect(visible['is_favorite'], true);
      } finally {
        await fixture.dispose();
      }
    },
  );

  group('a stale edit only overrides the fields it changed', () {
    const credential = <String, Object?>{
      'id': _recordId,
      'type': 'credential',
      'name': 'Deploy',
      'username': 'ops',
      'kind': 'password',
      'secret': 'first-password',
    };
    final rdpHost = <String, Object?>{
      ..._host(address: 'desk.example'),
      'port': 3389,
      'protocol': 'rdp',
    };

    /// Pulls the remote revision, pushes the converged edit and returns
    /// what the server ends up with.
    Future<Map<String, dynamic>> converge(_Fixture fixture) async {
      final result = await fixture.repository.synchronize();
      expect(result.conflictCount, 0);
      expect(result.pendingCount, 0);
      expect(await fixture.openConflicts(), isEmpty);
      final pushed = fixture.api.committed.last;
      expect(_header(pushed)['device_id'], fixture.local.deviceId);
      expect(fixture.api.heads[_recordId], _header(pushed)['revision_id']);
      return fixture.crypto.decryptRecord(
        vaultKey: Uint8List.fromList(fixture.key),
        envelope: pushed,
        authorPublicKey: fixture.local.signing.publicKey,
      );
    }

    test('a credential rename does not revert a password rotation', () async {
      final fixture = await _Fixture.create(sodium, basePlaintext: credential);
      try {
        await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: {...credential, 'name': 'Deploy (renamed)'},
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        final remote = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: {...credential, 'secret': 'rotated-password'},
        );

        final pushed = await converge(fixture);
        expect(pushed, {
          ...credential,
          'name': 'Deploy (renamed)',
          'secret': 'rotated-password',
        });
        expect(
          _header(fixture.api.committed.last)['base_revision_id'],
          _header(remote)['revision_id'],
        );
        expect(
          (await fixture.repository.loadRecords()).single['secret'],
          'rotated-password',
        );
      } finally {
        await fixture.dispose();
      }
    });

    test(
      'a stale host tag edit keeps the certificate pin changed elsewhere',
      () async {
        final pinned = {...rdpHost, 'rdp_cert_sha256': 'a' * 64};
        final fixture = await _Fixture.create(sodium, basePlaintext: pinned);
        try {
          await fixture.repository.saveRecord(
            recordId: _recordId,
            plaintext: {
              ...pinned,
              'tags': ['office'],
            },
            baseRevisionId: fixture.baseRevisionId,
            operation: 'update',
          );
          await fixture.commitRemote(
            operation: 'update',
            baseRevisionId: fixture.baseRevisionId,
            plaintext: {...pinned, 'rdp_cert_sha256': 'b' * 64},
          );

          final pushed = await converge(fixture);
          expect(pushed['rdp_cert_sha256'], 'b' * 64);
          expect(pushed['tags'], ['office']);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test('both sides changed one unit: the local unit wins intact', () async {
      final fixture = await _Fixture.create(sodium, basePlaintext: credential);
      try {
        const localKey = <String, Object?>{
          'id': _recordId,
          'type': 'credential',
          'name': 'Deploy',
          'username': 'deploy',
          'kind': 'privateKey',
          'private_key': 'local-private-key',
        };
        await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: localKey,
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: {
            ...credential,
            'name': 'Deploy, rotated',
            'secret': 'rotated-password',
          },
        );

        final pushed = await converge(fixture);
        // No remote password next to the local key; the remote rename stays.
        expect(pushed, {...localKey, 'name': 'Deploy, rotated'});
      } finally {
        await fixture.dispose();
      }
    });

    test('an invalid merge falls back to the whole local record', () async {
      final sshHost = {..._host(address: 'ssh.example')};
      final fixture = await _Fixture.create(sodium, basePlaintext: sshHost);
      try {
        // Valid on its own: an SSH host with a port forward.
        final local = {
          ...sshHost,
          'port_forward_profiles': [
            {
              'id': 'forward-1',
              'name': 'Database',
              'type': 'local',
              'bind_address': '127.0.0.1',
              'bind_port': 15432,
              'destination_address': '127.0.0.1',
              'destination_port': 5432,
            },
          ],
        };
        await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: local,
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        // Valid on its own: the host became an RDP desktop. Together with a
        // port forward it would not be a valid host.
        await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: {...sshHost, 'protocol': 'rdp', 'port': 3389, 'color': 6},
        );

        final pushed = await converge(fixture);
        expect(pushed, local);
      } finally {
        await fixture.dispose();
      }
    });

    test('unknown fields from both sides survive', () async {
      final base = {..._host(address: 'base.example'), 'future_shared': 'base'};
      final fixture = await _Fixture.create(sodium, basePlaintext: base);
      try {
        await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: {
            ...base,
            'name': 'Renamed here',
            'future_local': {'added': 'here'},
          },
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: {
            ...base,
            'address': 'remote.example',
            'future_shared': 'remote',
            'future_remote': [1, 2],
          },
        );

        final pushed = await converge(fixture);
        expect(pushed, {
          ...base,
          'name': 'Renamed here',
          'address': 'remote.example',
          'future_shared': 'remote',
          'future_local': {'added': 'here'},
          'future_remote': [1, 2],
        });
      } finally {
        await fixture.dispose();
      }
    });

    test(
      'a base that does not authenticate keeps the whole local record',
      () async {
        final fixture = await _Fixture.create(
          sodium,
          basePlaintext: credential,
        );
        try {
          final local = {...credential, 'name': 'Deploy (renamed)'};
          await fixture.repository.saveRecord(
            recordId: _recordId,
            plaintext: local,
            baseRevisionId: fixture.baseRevisionId,
            operation: 'update',
          );
          // The stored copy of the base no longer carries a valid signature.
          final row = (await fixture.pending()).single;
          final tampered =
              jsonDecode(row.baseEnvelopeJson!) as Map<String, dynamic>;
          tampered['signature'] = base64Url.encode(List<int>.filled(64, 7));
          await fixture.database.customStatement(
            'UPDATE pending_operations SET base_envelope_json = ? '
            'WHERE op_id = ?',
            [jsonEncode(tampered), row.opId],
          );
          await fixture.commitRemote(
            operation: 'update',
            baseRevisionId: fixture.baseRevisionId,
            plaintext: {...credential, 'secret': 'rotated-password'},
          );

          final pushed = await converge(fixture);
          expect(pushed, local);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test('a workspace is still replaced as a whole', () async {
      const workspace = <String, Object?>{
        'id': _recordId,
        'type': 'workspace',
        'name': 'Layout',
        'layout': {'kind': 'pane', 'host': 'a'},
      };
      final fixture = await _Fixture.create(sodium, basePlaintext: workspace);
      try {
        final local = {...workspace, 'name': 'Layout, renamed'};
        await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: local,
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: {
            ...workspace,
            'layout': {'kind': 'pane', 'host': 'b'},
          },
        );

        final pushed = await converge(fixture);
        expect(pushed, local);
      } finally {
        await fixture.dispose();
      }
    });
  });

  group('an outbox row an older client left on a never-sent base', () {
    const otherId = '44444444-4444-4444-8444-444444444444';

    test(
      'is signed again on its real base and no longer blocks the push',
      () async {
        final fixture = await _Fixture.create(sodium);
        try {
          final legacy = await fixture.writeLegacyCompactedRow(
            firstPlaintext: _host(address: 'one.example'),
            secondPlaintext: _host(address: 'two.example'),
          );
          // What the old client wrote: the row and its signed header disagree.
          expect(legacy.row.baseRevisionId, fixture.baseRevisionId);
          expect(
            _header(
              jsonDecode(legacy.row.envelopeJson) as Map<String, dynamic>,
            )['base_revision_id'],
            legacy.unsentRevisionId,
          );
          expect(legacy.row.baseCommitSeq, isNull);
          await fixture.repository.saveRecord(
            recordId: otherId,
            plaintext: {
              ..._host(address: 'other.example'),
              'id': otherId,
            },
          );

          final result = await fixture.repository.synchronize();
          expect(result.status, 'idle');
          expect(result.pendingCount, 0);
          expect(result.conflictCount, 0);
          expect(fixture.api.revisionLookups, [legacy.unsentRevisionId]);
          // One accepted batch; the unacceptable envelope was never sent.
          expect(fixture.api.pushRequests, hasLength(1));
          final pushed = fixture.api.committed.firstWhere(
            (envelope) =>
                _header(envelope)['record_id'] == _recordId &&
                _header(envelope)['device_id'] == fixture.local.deviceId,
          );
          expect(_header(pushed)['operation'], 'update');
          expect(_header(pushed)['base_revision_id'], fixture.baseRevisionId);
          expect(_header(pushed)['op_id'], isNot(legacy.row.opId));
          expect(
            (await fixture.crypto.decryptRecord(
              vaultKey: Uint8List.fromList(fixture.key),
              envelope: pushed,
              authorPublicKey: fixture.local.signing.publicKey,
            ))['address'],
            'two.example',
          );
          expect(fixture.api.heads.containsKey(otherId), isTrue);
          expect((await fixture.superseded()).single.opId, legacy.row.opId);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test('an already attempted row is repaired too', () async {
      final fixture = await _Fixture.create(sodium);
      try {
        final legacy = await fixture.writeLegacyCompactedRow(
          firstPlaintext: _host(address: 'one.example'),
          secondPlaintext: _host(address: 'two.example'),
        );
        // The old client had pushed it and was refused.
        await fixture.database.customStatement(
          "UPDATE pending_operations SET status = 'sent', attempt_count = 6 "
          'WHERE op_id = ?',
          [legacy.row.opId],
        );

        final result = await fixture.repository.synchronize();
        expect(result.pendingCount, 0);
        expect(fixture.api.pushRequests, hasLength(1));
        expect(
          (await fixture.repository.loadRecords()).single['address'],
          'two.example',
        );
      } finally {
        await fixture.dispose();
      }
    });

    test(
      'then merges with a revision another device committed meanwhile',
      () async {
        final fixture = await _Fixture.create(sodium);
        try {
          await fixture.writeLegacyCompactedRow(
            firstPlaintext: {
              ..._host(address: 'base.example'),
              'name': 'One',
            },
            secondPlaintext: {
              ..._host(address: 'base.example'),
              'name': 'Two',
            },
          );
          final remote = await fixture.commitRemote(
            operation: 'update',
            baseRevisionId: fixture.baseRevisionId,
            plaintext: _host(address: 'remote.example'),
          );

          final result = await fixture.repository.synchronize();
          expect(result.pendingCount, 0);
          expect(result.conflictCount, 0);
          expect(await fixture.openConflicts(), isEmpty);
          final pushed = fixture.api.committed.last;
          expect(
            _header(pushed)['base_revision_id'],
            _header(remote)['revision_id'],
          );
          final visible = (await fixture.repository.loadRecords()).single;
          expect(visible['name'], 'Two');
          expect(visible['address'], 'remote.example');
        } finally {
          await fixture.dispose();
        }
      },
    );

    test('an update of a never-sent record becomes its create', () async {
      final fixture = await _Fixture.create(sodium);
      try {
        Map<String, Object?> record(String name) => {
          ..._host(address: 'new.example'),
          'id': otherId,
          'name': name,
        };
        final legacy = await fixture.writeLegacyCompactedRow(
          recordId: otherId,
          firstOperation: 'create',
          firstPlaintext: record('New'),
          secondPlaintext: record('New, renamed'),
        );
        expect(legacy.row.baseRevisionId, isNull);

        final result = await fixture.repository.synchronize();
        expect(result.pendingCount, 0);
        final pushed = fixture.api.committed.last;
        expect(_header(pushed)['record_id'], otherId);
        expect(_header(pushed)['operation'], 'create');
        expect(_header(pushed)['base_revision_id'], isNull);
        expect(fixture.api.heads[otherId], _header(pushed)['revision_id']);
      } finally {
        await fixture.dispose();
      }
    });

    test('a delete of a never-sent record forgets the record', () async {
      final fixture = await _Fixture.create(sodium);
      try {
        await fixture.writeLegacyCompactedRow(
          recordId: otherId,
          firstOperation: 'create',
          firstPlaintext: {
            ..._host(address: 'new.example'),
            'id': otherId,
          },
          secondOperation: 'delete',
          secondPlaintext: const {
            'id': otherId,
            'type': 'host',
            'deleted': true,
          },
        );

        final result = await fixture.repository.synchronize();
        expect(result.status, 'idle');
        expect(result.pendingCount, 0);
        expect(fixture.api.pushRequests, isEmpty);
        expect(fixture.api.heads.containsKey(otherId), isFalse);
        expect(
          await fixture.database.cachedEnvelope(
            _vaultId,
            otherId,
            instanceId: _instanceId,
            serverSpaceId: _spaceId,
          ),
          isNull,
        );
        expect(
          (await fixture.repository.loadRecords(includeDeleted: true))
              .map((row) => row['id']),
          [_recordId],
        );
      } finally {
        await fixture.dispose();
      }
    });

    test(
      'a row that cannot be read is kept and held out of the batch',
      () async {
        final fixture = await _Fixture.create(sodium);
        try {
          final legacy = await fixture.writeLegacyCompactedRow(
            firstPlaintext: _host(address: 'one.example'),
            secondPlaintext: _host(address: 'two.example'),
          );
          final broken =
              jsonDecode(legacy.row.envelopeJson) as Map<String, dynamic>;
          broken['signature'] = base64Url.encode(List<int>.filled(64, 7));
          await fixture.database.customStatement(
            'UPDATE pending_operations SET envelope_json = ? WHERE op_id = ?',
            [jsonEncode(broken), legacy.row.opId],
          );
          await fixture.repository.saveRecord(
            recordId: otherId,
            plaintext: {
              ..._host(address: 'other.example'),
              'id': otherId,
            },
          );

          final result = await fixture.repository.synchronize();
          // Still pending and reported as such, but the other record went out.
          expect(result.pendingCount, 1);
          expect(result.status, isNot('idle'));
          expect(fixture.api.heads.containsKey(otherId), isTrue);
          final kept = (await fixture.pending()).single;
          expect(kept.opId, legacy.row.opId);
          expect(kept.envelopeJson, jsonEncode(broken));
          expect(kept.status, 'queued');
          expect(await fixture.superseded(), isEmpty);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test('a row whose signed base the server knows is left alone', () async {
      final fixture = await _Fixture.create(sodium);
      try {
        final legacy = await fixture.writeLegacyCompactedRow(
          firstPlaintext: _host(address: 'one.example'),
          secondPlaintext: _host(address: 'two.example'),
        );
        fixture.api.knownRevisionIds.add(legacy.unsentRevisionId);

        await fixture.repository.synchronize();
        final row = (await fixture.pending()).single;
        expect(row.opId, legacy.row.opId);
        expect(row.envelopeJson, legacy.row.envelopeJson);
        expect(await fixture.superseded(), isEmpty);
      } finally {
        await fixture.dispose();
      }
    });
  });

  group('saves of one record before its first push', () {
    const credentialBase = <String, Object?>{
      'id': _recordId,
      'type': 'credential',
      'name': 'Deploy',
      'username': 'ops',
      'kind': 'password',
      'secret': 'first-password',
    };

    Future<void> expectRowsMatchSignedHeaders(_Fixture fixture) async {
      for (final operation in await fixture.pending()) {
        final header = _header(
          jsonDecode(operation.envelopeJson) as Map<String, dynamic>,
        );
        expect(operation.baseRevisionId, header['base_revision_id']);
      }
    }

    test('two quick credential saves become one accepted push', () async {
      final fixture = await _Fixture.create(
        sodium,
        basePlaintext: credentialBase,
      );
      try {
        // As saveCredential does: the second save names the revision of the
        // first, which the server has never seen.
        final first = await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: {...credentialBase, 'name': 'Deploy 1'},
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        final second = await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: {...credentialBase, 'name': 'Deploy 2'},
          baseRevisionId: _header(first)['revision_id'] as String,
          operation: 'update',
        );

        final pending = (await fixture.pending()).single;
        expect(pending.opId, _header(second)['op_id']);
        expect(_header(second)['base_revision_id'], fixture.baseRevisionId);
        expect(pending.baseRevisionId, fixture.baseRevisionId);
        expect(pending.baseCommitSeq, '1');
        await expectRowsMatchSignedHeaders(fixture);

        final result = await fixture.repository.synchronize();
        expect(result.pendingCount, 0);
        expect(result.conflictCount, 0);
        expect(fixture.api.pushRequests, hasLength(1));
        expect(await fixture.pending(), isEmpty);
        expect(fixture.api.heads[_recordId], _header(second)['revision_id']);
        expect(
          (await fixture.repository.loadRecords()).single['name'],
          'Deploy 2',
        );
      } finally {
        await fixture.dispose();
      }
    });

    test(
      'a new record edited before its first push is still one create',
      () async {
        final fixture = await _Fixture.create(sodium);
        const newId = '44444444-4444-4444-8444-444444444444';
        Map<String, Object?> credential(String name) => {
          ...credentialBase,
          'id': newId,
          'name': name,
        };
        try {
          final created = await fixture.repository.saveRecord(
            recordId: newId,
            plaintext: credential('New'),
          );
          final edited = await fixture.repository.saveRecord(
            recordId: newId,
            plaintext: credential('New, renamed'),
            baseRevisionId: _header(created)['revision_id'] as String,
            operation: 'update',
          );
          expect(_header(edited)['operation'], 'create');
          expect(_header(edited)['base_revision_id'], isNull);
          expect((await fixture.pending()).single.baseRevisionId, isNull);

          final result = await fixture.repository.synchronize();
          expect(result.pendingCount, 0);
          expect(fixture.api.pushRequests, hasLength(1));
          expect(fixture.api.heads[newId], _header(edited)['revision_id']);
        } finally {
          await fixture.dispose();
        }
      },
    );

    test('a delete after an unsent create stays a second operation', () async {
      final fixture = await _Fixture.create(sodium);
      const newId = '44444444-4444-4444-8444-444444444444';
      try {
        final created = await fixture.repository.saveRecord(
          recordId: newId,
          plaintext: {...credentialBase, 'id': newId},
        );
        final deleted = await fixture.repository.saveRecord(
          recordId: newId,
          plaintext: const {'id': newId, 'type': 'credential', 'deleted': true},
          baseRevisionId: _header(created)['revision_id'] as String,
          operation: 'delete',
        );
        expect(
          _header(deleted)['base_revision_id'],
          _header(created)['revision_id'],
        );
        expect(await fixture.pending(), hasLength(2));
        await expectRowsMatchSignedHeaders(fixture);
      } finally {
        await fixture.dispose();
      }
    });

    test('an envelope signed on the unsent revision is never stored on another base', () async {
      final fixture = await _Fixture.create(sodium);
      try {
        final first = await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: _host(address: 'one.example'),
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        final firstRevision = _header(first)['revision_id'] as String;
        // A caller that goes straight to the database with such an envelope.
        final second = await fixture.encryptLocal(
          operation: 'update',
          baseRevisionId: firstRevision,
          plaintext: _host(address: 'two.example'),
        );
        await fixture.database.putLocalOperation(
          vaultId: _vaultId,
          recordId: _recordId,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
          baseRevisionId: firstRevision,
          envelope: second,
          deleted: false,
        );
        final pending = await fixture.pending();
        expect(pending, hasLength(2));
        await expectRowsMatchSignedHeaders(fixture);
        // Signed to replace an operation that is no longer the newest one.
        final third = await fixture.encryptLocal(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: _host(address: 'three.example'),
        );
        await expectLater(
          fixture.database.putLocalOperation(
            vaultId: _vaultId,
            recordId: _recordId,
            instanceId: _instanceId,
            serverSpaceId: _spaceId,
            baseRevisionId: fixture.baseRevisionId,
            envelope: third,
            deleted: false,
            expectedCompactedOpId: _header(first)['op_id'] as String,
          ),
          throwsA(isA<LocalRecordHeadChangedException>()),
        );
        expect(await fixture.pending(), hasLength(2));
      } finally {
        await fixture.dispose();
      }
    });
  });

  group('falls back to a conflict branch when the rebase is not safe', () {
    Future<void> expectConflict(
      _Fixture fixture, {
      required Map<String, Object?> localEnvelope,
      required Map<String, dynamic> remoteEnvelope,
    }) async {
      final result = await fixture.repository.synchronize();
      expect(result.conflictCount, 1);
      final conflict = (await fixture.openConflicts()).single;
      expect(conflict.kind, 'concurrent_edit');
      // Both versions are kept byte for byte.
      expect(conflict.branchEnvelopeJson, jsonEncode(localEnvelope));
      expect(conflict.remoteEnvelopeJson, jsonEncode(remoteEnvelope));
      expect(fixture.api.conflictUploads.single['envelope'], localEnvelope);
      expect(fixture.api.pushRequests, isEmpty);
      expect((await fixture.pending()).single.status, 'conflict');
      expect(await fixture.superseded(), isEmpty);
      expect(
        (await fixture.cached())?.revisionId,
        _header(remoteEnvelope)['revision_id'],
      );
    }

    test('a KnownHost trust decision is never overwritten', () async {
      final fixture = await _Fixture.create(
        sodium,
        basePlaintext: const {
          'id': _recordId,
          'type': 'knownHost',
          'state': 'trusted',
        },
      );
      try {
        final local = await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: const {
            'id': _recordId,
            'type': 'knownHost',
            'state': 'trusted',
            'fingerprint': 'local',
          },
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        final remote = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: const {
            'id': _recordId,
            'type': 'knownHost',
            'state': 'revoked',
          },
        );
        await expectConflict(
          fixture,
          localEnvelope: local,
          remoteEnvelope: remote,
        );
      } finally {
        await fixture.dispose();
      }
    });

    test('the remote revision uses another key epoch', () async {
      final fixture = await _Fixture.create(sodium, olderEpochKey: true);
      try {
        final local = await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: _host(address: 'local.example'),
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        final remote = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: _host(address: 'remote.example'),
          keyEpoch: '1',
        );
        await expectConflict(
          fixture,
          localEnvelope: local,
          remoteEnvelope: remote,
        );
      } finally {
        await fixture.dispose();
      }
    });

    test('the remote revision is not a sibling of the local edit', () async {
      final fixture = await _Fixture.create(sodium);
      try {
        final local = await fixture.repository.saveRecord(
          recordId: _recordId,
          plaintext: _host(address: 'local.example'),
          baseRevisionId: fixture.baseRevisionId,
          operation: 'update',
        );
        // A revision whose parent this device never saw: the local edit and
        // the remote one do not share a base, so there is no linear history.
        final unseen = await fixture.encryptRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: _host(address: 'unseen.example'),
        );
        final remote = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: _header(unseen)['revision_id'] as String,
          plaintext: _host(address: 'remote.example'),
        );
        await expectConflict(
          fixture,
          localEnvelope: local,
          remoteEnvelope: remote,
        );
      } finally {
        await fixture.dispose();
      }
    });

    test('the local operation was signed by another device', () async {
      final fixture = await _Fixture.create(sodium);
      try {
        // An outbox row this device cannot re-sign as its own edit.
        final foreign = await fixture.encryptRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: _host(address: 'foreign.example'),
        );
        await fixture.database.putLocalOperation(
          vaultId: _vaultId,
          recordId: _recordId,
          instanceId: _instanceId,
          serverSpaceId: _spaceId,
          baseRevisionId: fixture.baseRevisionId,
          envelope: foreign,
          deleted: false,
        );
        final remote = await fixture.commitRemote(
          operation: 'update',
          baseRevisionId: fixture.baseRevisionId,
          plaintext: _host(address: 'remote.example'),
        );
        await expectConflict(
          fixture,
          localEnvelope: foreign,
          remoteEnvelope: remote,
        );
      } finally {
        await fixture.dispose();
      }
    });
  });
}

Map<String, dynamic> _header(Map<String, Object?> envelope) =>
    Map<String, dynamic>.from(envelope['header'] as Map);

Map<String, Object?> _host({required String address}) => {
  'id': _recordId,
  'type': 'host',
  'name': 'Host',
  'address': address,
  'port': 22,
  'username': 'ops',
  'group_id': null,
  'credential_id': null,
  'jump_host_id': null,
  'auth_kind': 'password',
  'color': 0,
  'tags': const <String>[],
  'is_favorite': false,
};

class _Fixture {
  _Fixture._({
    required this.sodium,
    required this.database,
    required this.api,
    required this.repository,
    required this.local,
    required this.remote,
    required this.key,
    required this.currentEpoch,
  });

  final SodiumSumo sodium;
  final ClientDatabase database;
  final _Api api;
  final SyncRepository repository;
  final DeviceIdentity local;
  final DeviceIdentity remote;
  final Uint8List key;
  final String currentEpoch;
  late final String baseRevisionId;
  int _remoteSeq = 0;

  VaultCrypto get crypto => repository.crypto;

  static Future<_Fixture> create(
    SodiumSumo sodium, {
    Future<void> Function()? beforePush,
    Map<String, Object?>? basePlaintext,
    bool olderEpochKey = false,
  }) async {
    final local = DeviceIdentity.create(sodium);
    final remote = DeviceIdentity.create(sodium);
    final key = sodium.randombytes.buf(32);
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _Api(local, remote)..beforePush = beforePush;
    final currentEpoch = olderEpochKey ? '2' : '1';
    final repository = SyncRepository(
      api: api,
      database: database,
      crypto: VaultCrypto(sodium),
      identity: local,
      serverSpaceId: _spaceId,
      instanceId: _instanceId,
      vaultId: _vaultId,
      keyEpoch: currentEpoch,
      membershipVersion: '1',
      serverGeneration: _instanceId,
      vaultKey: Uint8List.fromList(key),
      vaultKeysByVersion: olderEpochKey
          ? {'1:1': Uint8List.fromList(key)}
          : const {},
    );
    final fixture = _Fixture._(
      sodium: sodium,
      database: database,
      api: api,
      repository: repository,
      local: local,
      remote: remote,
      key: key,
      currentEpoch: currentEpoch,
    );
    final base = await fixture.encryptRemote(
      operation: 'create',
      baseRevisionId: null,
      plaintext: basePlaintext ?? _host(address: 'base.example'),
    );
    fixture.baseRevisionId = _header(base)['revision_id'] as String;
    api.seed(base);
    await database.storeRemoteEnvelope(
      vaultId: _vaultId,
      recordId: _recordId,
      revisionId: fixture.baseRevisionId,
      envelope: base,
      commitSeq: '1',
      deleted: false,
      instanceId: _instanceId,
      serverSpaceId: _spaceId,
    );
    return fixture;
  }

  Future<Map<String, dynamic>> encryptRemote({
    required String operation,
    required String? baseRevisionId,
    required Map<String, Object?> plaintext,
    String? keyEpoch,
  }) async => Map<String, dynamic>.from(
    await crypto.encryptRecord(
      vaultKey: Uint8List.fromList(key),
      serverSpaceId: _spaceId,
      vaultId: _vaultId,
      recordId: _recordId,
      baseRevisionId: baseRevisionId,
      deviceId: remote.deviceId,
      deviceSequence: '${++_remoteSeq}',
      keyEpoch: keyEpoch ?? currentEpoch,
      membershipVersion: '1',
      operation: operation,
      plaintext: plaintext,
      identity: remote,
    ),
  );

  /// An envelope this device signs, without going through the repository.
  Future<Map<String, dynamic>> encryptLocal({
    required String operation,
    required String? baseRevisionId,
    required Map<String, Object?> plaintext,
  }) async => Map<String, dynamic>.from(
    await crypto.encryptRecord(
      vaultKey: Uint8List.fromList(key),
      serverSpaceId: _spaceId,
      vaultId: _vaultId,
      recordId: _recordId,
      baseRevisionId: baseRevisionId,
      deviceId: local.deviceId,
      deviceSequence: '${1000 + ++_remoteSeq}',
      keyEpoch: currentEpoch,
      membershipVersion: '1',
      operation: operation,
      plaintext: plaintext,
      identity: local,
    ),
  );

  /// Leaves the outbox as the client before schema 15 left it after two
  /// saves of one record without a push in between: the first operation is
  /// gone, and the row of the second keeps the first one's base while its
  /// signed header names the first one's never-sent revision.
  Future<({PendingOperation row, String unsentRevisionId})>
  writeLegacyCompactedRow({
    required Map<String, Object?> firstPlaintext,
    required Map<String, Object?> secondPlaintext,
    String firstOperation = 'update',
    String secondOperation = 'update',
    String recordId = _recordId,
  }) async {
    final first = await repository.saveRecord(
      recordId: recordId,
      plaintext: firstPlaintext,
      baseRevisionId: firstOperation == 'create' ? null : baseRevisionId,
      operation: firstOperation,
    );
    final unsentRevisionId = _header(first)['revision_id'] as String;
    final replaced = (await pending()).singleWhere(
      (row) => row.recordId == recordId,
    );
    final second = Map<String, dynamic>.from(
      await crypto.encryptRecord(
        vaultKey: Uint8List.fromList(key),
        serverSpaceId: _spaceId,
        vaultId: _vaultId,
        recordId: recordId,
        baseRevisionId: unsentRevisionId,
        deviceId: local.deviceId,
        deviceSequence: '${1000 + ++_remoteSeq}',
        keyEpoch: currentEpoch,
        membershipVersion: '1',
        operation: secondOperation,
        plaintext: secondPlaintext,
        identity: local,
      ),
    );
    final header = _header(second);
    await database.customStatement(
      'DELETE FROM pending_operations WHERE op_id = ?',
      [replaced.opId],
    );
    await database.customStatement(
      'INSERT INTO pending_operations '
      '(op_id, vault_id, record_id, instance_id, server_space_id, '
      'base_revision_id, base_envelope_json, envelope_json, status, '
      'attempt_count, created_at) '
      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'queued', 0, ?)",
      [
        header['op_id'],
        _vaultId,
        recordId,
        _instanceId,
        _spaceId,
        replaced.baseRevisionId,
        replaced.baseEnvelopeJson,
        jsonEncode(second),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    await database.customStatement(
      'UPDATE encrypted_records SET revision_id = ?, envelope_json = ?, '
      'is_deleted = ?, commit_seq = NULL '
      'WHERE vault_id = ? AND record_id = ?',
      [
        header['revision_id'],
        jsonEncode(second),
        secondOperation == 'delete' ? 1 : 0,
        _vaultId,
        recordId,
      ],
    );
    final row = (await pending()).singleWhere(
      (item) => item.recordId == recordId,
    );
    return (row: row, unsentRevisionId: unsentRevisionId);
  }

  /// Another device commits a revision; the event is queued for the next pull.
  Future<Map<String, dynamic>> commitRemote({
    required String operation,
    required String? baseRevisionId,
    required Map<String, Object?> plaintext,
    String? keyEpoch,
  }) async {
    final envelope = await encryptRemote(
      operation: operation,
      baseRevisionId: baseRevisionId,
      plaintext: plaintext,
      keyEpoch: keyEpoch,
    );
    api.queueEvent(envelope, commitSeq: api.commit(envelope));
    return envelope;
  }

  Future<List<ConflictBranche>> openConflicts() => database.openConflicts(
    _vaultId,
    instanceId: _instanceId,
    serverSpaceId: _spaceId,
  );

  Future<List<PendingOperation>> pending() => database.allPendingOperations(
    _vaultId,
    instanceId: _instanceId,
    serverSpaceId: _spaceId,
  );

  Future<List<PendingOperation>> superseded() => database.supersededOperations(
    _vaultId,
    instanceId: _instanceId,
    serverSpaceId: _spaceId,
  );

  Future<EncryptedRecord?> cached() => database.cachedEnvelope(
    _vaultId,
    _recordId,
    instanceId: _instanceId,
    serverSpaceId: _spaceId,
  );

  Future<void> dispose() async {
    await database.close();
    api.close();
    local.dispose();
    remote.dispose();
    key.fillRange(0, key.length, 0);
  }
}

/// A server with compare-and-set on the record head and an ordered feed.
class _Api extends ApiClient {
  _Api(this.local, this.remote)
    : super(baseUrl: 'https://latest-wins.example.test');

  final DeviceIdentity local;
  final DeviceIdentity remote;
  final Map<String, String> heads = {};
  final List<Map<String, dynamic>> committed = [];
  final List<Map<String, Object?>> pushRequests = [];
  final List<Map<String, Object?>> conflictUploads = [];
  final List<Map<String, dynamic>> _events = [];
  List<Map<String, dynamic>> snapshotItems = const [];
  Future<void> Function()? beforePush;
  bool pushUnavailable = false;
  bool restoreWindowClosed = false;
  int commitCount = 0;

  void seed(Map<String, dynamic> envelope) => commit(envelope);

  String commit(Map<String, dynamic> envelope) {
    final header = _header(envelope);
    heads[header['record_id'] as String] = header['revision_id'] as String;
    committed.add(envelope);
    return '${++commitCount}';
  }

  void queueEvent(Map<String, dynamic> envelope, {required String commitSeq}) {
    final header = _header(envelope);
    _events.add({
      'commit_seq': commitSeq,
      'event_type': header['operation'],
      'record_id': header['record_id'],
      'revision_id': header['revision_id'],
      'envelope': envelope,
    });
  }

  final List<String> revisionLookups = [];

  /// Revisions the server answers for besides the committed ones.
  final Set<String> knownRevisionIds = {};

  @override
  Future<Map<String, dynamic>> revision(
    String vaultId,
    String revisionId,
  ) async {
    revisionLookups.add(revisionId);
    final envelope = committed
        .where((item) => _header(item)['revision_id'] == revisionId)
        .firstOrNull;
    if (envelope == null && !knownRevisionIds.contains(revisionId)) {
      throw const ApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'Revision not found.',
      );
    }
    return {
      'record_id': envelope == null
          ? _recordId
          : _header(envelope)['record_id'],
      'envelope': envelope,
    };
  }

  @override
  Future<InstanceInfo> fetchInstance() async => const InstanceInfo(
    instanceId: _instanceId,
    serverSpaceId: _spaceId,
    generation: _instanceId,
    protocolVersion: 1,
    setupRequired: false,
    capabilities: ['snapshots'],
  );

  @override
  Future<List<Map<String, dynamic>>> devices() async => [
    for (final device in [local, remote])
      {
        'device_id': device.deviceId,
        'signing_public_key': device.signingPublicKey,
        'status': 'active',
      },
  ];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async =>
      devices();

  @override
  Future<ConflictChangesPage> conflictChanges(
    String vaultId, {
    required String? afterSeq,
    String? serverGeneration,
    int limit = 100,
  }) async => ConflictChangesPage(
    vaultId: vaultId,
    afterSeq: afterSeq ?? '0',
    highWatermark: afterSeq ?? '0',
    events: const [],
    nextAfterSeq: afterSeq ?? '0',
    hasMore: false,
    serverGeneration: serverGeneration ?? _instanceId,
  );

  @override
  Future<SyncPage> changes(
    String vaultId, {
    String? cursor,
    int limit = 500,
  }) async {
    final events = List<Map<String, dynamic>>.from(_events);
    _events.clear();
    return SyncPage(
      events: events,
      nextCursor: events.isEmpty ? cursor : 'cursor-$commitCount',
      hasMore: false,
      serverGeneration: _instanceId,
    );
  }

  @override
  Future<Map<String, dynamic>> uploadConflict(
    String vaultId,
    Map<String, Object?> body,
  ) async {
    conflictUploads.add(body);
    return {
      'conflict_id': '66666666-6666-4666-8666-666666666666',
      'status': 'stored',
    };
  }

  @override
  Future<Map<String, dynamic>> push(
    String vaultId,
    Map<String, Object?> batch,
  ) async {
    await beforePush?.call();
    pushRequests.add(batch);
    if (pushUnavailable) {
      throw const ApiException(
        statusCode: 503,
        code: 'SERVICE_UNAVAILABLE',
        message: 'The test server is not accepting pushes.',
      );
    }
    final operations = (batch['operations'] as List<dynamic>)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList(growable: false);
    for (final envelope in operations) {
      final header = _header(envelope);
      if (header['base_revision_id'] != heads[header['record_id']]) {
        throw const ApiException(
          statusCode: 409,
          code: 'REVISION_CONFLICT',
          message: 'The record head changed.',
        );
      }
      if (restoreWindowClosed && header['operation'] == 'restore') {
        throw const ApiException(
          statusCode: 409,
          code: 'RECORD_RESTORE_EXPIRED',
          message: 'The restore window closed.',
        );
      }
    }
    return {
      'batch_id': batch['batch_id'],
      'results': [
        for (final envelope in operations)
          {
            'op_id': _header(envelope)['op_id'],
            'revision_id': _header(envelope)['revision_id'],
            'commit_seq': commit(envelope),
            'already_committed': false,
          },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> createSnapshot(String vaultId) async => {
    'snapshot_id': _snapshotId,
    'high_watermark': '$commitCount',
    'conflict_high_watermark': '0',
    'next_cursor': 'checkpoint-cursor',
    'expires_at': '2099-01-01T00:00:00Z',
    'item_count': snapshotItems.length,
  };

  @override
  Future<Map<String, dynamic>> snapshot(
    String snapshotId, {
    int? limit,
    String? pageCursor,
  }) async => {
    'snapshot_id': _snapshotId,
    'high_watermark': '$commitCount',
    'conflict_high_watermark': '0',
    'next_cursor': 'checkpoint-cursor',
    'expires_at': '2099-01-01T00:00:00Z',
    'item_count': snapshotItems.length,
    'manifest': snapshotItems,
    'has_more': false,
    'next_page_cursor': null,
    'server_generation': _instanceId,
  };
}
