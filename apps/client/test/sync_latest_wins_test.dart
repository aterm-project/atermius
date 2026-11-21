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

  test('a replayed parent of the rebased head changes nothing', () async {
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
      fixture.api.pushUnavailable = true;
      await expectLater(
        fixture.repository.synchronize(),
        throwsA(isA<ApiException>()),
      );
      final rebased = (await fixture.pending()).single;
      expect(rebased.baseRevisionId, _header(second)['revision_id']);

      // The same page is delivered again after a crash before its checkpoint.
      fixture.api.queueEvent(first, commitSeq: '2');
      await expectLater(
        fixture.repository.synchronize(),
        throwsA(isA<ApiException>()),
      );

      expect(await fixture.openConflicts(), isEmpty);
      final pending = await fixture.pending();
      expect(pending.single.opId, rebased.opId);
      expect(pending.single.status, isNot('conflict'));
    } finally {
      await fixture.dispose();
    }
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
