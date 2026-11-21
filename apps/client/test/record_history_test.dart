import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/record_history_dialog.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

const _spaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _vaultId = '22222222-2222-4222-8222-222222222222';
const _recordId = '33333333-3333-4333-8333-333333333333';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  test('history GET uses the per-record revisions route', () async {
    late http.Request captured;
    final api = ApiClient(
      baseUrl: 'https://history.example.test/prefix',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'vault_id': _vaultId,
            'record_id': _recordId,
            'record_history_limit': 20,
            'revisions': const <Object>[],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..accessToken = 'session-access-token';
    try {
      final response = await api.recordRevisions(_vaultId, _recordId);
      expect(captured.method, 'GET');
      expect(
        captured.url.path,
        '/prefix/api/v1/vaults/$_vaultId/records/$_recordId/revisions',
      );
      expect(captured.headers['authorization'], 'Bearer session-access-token');
      expect(response['record_history_limit'], 20);
    } finally {
      api.close();
    }
  });

  test('instance limits expose the per-record history limit', () {
    Map<String, dynamic> instance(Object? limits) => {
      'instance_id': _instanceId,
      'server_space_id': _spaceId,
      'generation': '1',
      'protocol_version': 1,
      'limits': ?limits,
    };
    expect(
      InstanceInfo.fromJson(instance({'record_history_limit': 35}))
          .recordHistoryLimit,
      35,
    );
    expect(InstanceInfo.fromJson(instance(null)).recordHistoryLimit, isNull);
    expect(
      InstanceInfo.fromJson(instance({'record_history_limit': '35'}))
          .recordHistoryLimit,
      isNull,
    );
  });

  test('history entries are verified like pulled events and the rest is unreadable', () async {
    final fixture = await _Fixture.create(sodium);
    try {
      final created = await fixture.encrypt(
        fixture.remote,
        operation: 'create',
        baseRevisionId: null,
        plaintext: _host(address: 'first.example'),
      );
      final createdId = _header(created)['revision_id'] as String;
      final untrusted = await fixture.encrypt(
        fixture.stranger,
        operation: 'update',
        baseRevisionId: createdId,
        plaintext: _host(address: 'stranger.example'),
      );
      final untrustedId = _header(untrusted)['revision_id'] as String;
      final tampered = await fixture.encrypt(
        fixture.remote,
        operation: 'update',
        baseRevisionId: untrustedId,
        plaintext: _host(address: 'tampered.example'),
      );
      final tamperedId = _header(tampered)['revision_id'] as String;
      final relabelled = await fixture.encrypt(
        fixture.remote,
        operation: 'update',
        baseRevisionId: tamperedId,
        plaintext: _host(address: 'relabelled.example'),
      );
      final relabelledId = _header(relabelled)['revision_id'] as String;
      final head = await fixture.encrypt(
        fixture.local,
        operation: 'update',
        baseRevisionId: relabelledId,
        plaintext: _host(address: 'head.example'),
      );
      final headId = _header(head)['revision_id'] as String;
      await fixture.database.storeRemoteEnvelope(
        vaultId: _vaultId,
        recordId: _recordId,
        revisionId: headId,
        envelope: head,
        commitSeq: '5',
        deleted: false,
        instanceId: _instanceId,
        serverSpaceId: _spaceId,
      );
      fixture.api.history = {
        'vault_id': _vaultId,
        'record_id': _recordId,
        'record_history_limit': 20,
        'revisions': [
          _listed(head, commitSeq: '5'),
          // The server claims another device made this version.
          {
            ..._listed(relabelled, commitSeq: '4'),
            'device_id': fixture.local.deviceId,
          },
          // The ciphertext was changed after signing.
          {
            ..._listed(tampered, commitSeq: '3'),
            'envelope': {...tampered, 'ciphertext': head['ciphertext']},
          },
          // Signed by a device that is not in the trusted directory.
          _listed(untrusted, commitSeq: '2'),
          _listed(created, commitSeq: '1'),
        ],
      };

      final history = await fixture.repository.loadRecordHistory(_recordId);

      expect(history.historyLimit, 20);
      expect(history.entries.map((entry) => entry.revisionId), [
        headId,
        relabelledId,
        tamperedId,
        untrustedId,
        createdId,
      ]);
      expect(history.entries.map((entry) => entry.verified), [
        true,
        false,
        false,
        false,
        true,
      ]);
      final current = history.entries.first;
      expect(current.isCurrent, isTrue);
      expect(current.deviceId, fixture.local.deviceId);
      expect(current.operation, 'update');
      expect(current.plaintext?['address'], 'head.example');
      expect(current.createdAt, DateTime.utc(2026, 11, 20, 8, 0, 5));
      for (final unreadable in history.entries.sublist(1, 4)) {
        expect(unreadable.plaintext, isNull);
        expect(unreadable.deviceId, isNull);
        expect(unreadable.operation, isNull);
        expect(unreadable.isCurrent, isFalse);
      }
      final first = history.entries.last;
      expect(first.operation, 'create');
      expect(first.deviceId, fixture.remote.deviceId);
      expect(first.plaintext?['address'], 'first.example');
    } finally {
      await fixture.dispose();
    }
  });

  test(
    'history reports a server without the route and rejects bad listings',
    () async {
      final fixture = await _Fixture.create(sodium);
      try {
        fixture.api.historyError = const ApiException(
          statusCode: 404,
          code: 'NOT_FOUND',
          message: 'No such route.',
        );
        await expectLater(
          fixture.repository.loadRecordHistory(_recordId),
          throwsA(isA<RecordHistoryUnavailableException>()),
        );

        fixture.api.historyError = const ApiException(
          statusCode: 403,
          code: 'VAULT_ACCESS_REVOKED',
          message: 'No access.',
        );
        await expectLater(
          fixture.repository.loadRecordHistory(_recordId),
          throwsA(isA<ApiException>()),
        );

        final first = await fixture.encrypt(
          fixture.remote,
          operation: 'create',
          baseRevisionId: null,
          plaintext: _host(address: 'first.example'),
        );
        final second = await fixture.encrypt(
          fixture.remote,
          operation: 'update',
          baseRevisionId: _header(first)['revision_id'] as String,
          plaintext: _host(address: 'second.example'),
        );
        fixture.api.historyError = null;
        // Oldest first is not the documented order.
        fixture.api.history = {
          'vault_id': _vaultId,
          'record_id': _recordId,
          'revisions': [
            _listed(first, commitSeq: '1'),
            _listed(second, commitSeq: '2'),
          ],
        };
        await expectLater(
          fixture.repository.loadRecordHistory(_recordId),
          throwsFormatException,
        );
        // A listing for another record is not shown under this one.
        fixture.api.history = {
          'vault_id': _vaultId,
          'record_id': '44444444-4444-4444-8444-444444444444',
          'revisions': const <Object>[],
        };
        await expectLater(
          fixture.repository.loadRecordHistory(_recordId),
          throwsFormatException,
        );
      } finally {
        await fixture.dispose();
      }
    },
  );

  test('changed fields are listed by name only', () {
    final fields = recordHistoryChangedFields(
      newer: {
        'id': _recordId,
        'type': 'credential',
        'name': 'Deploy key',
        'password': 'new-secret-value',
        'private_key': 'unchanged',
        'tags': ['a', 'b'],
      },
      older: {
        'id': _recordId,
        'type': 'credential',
        'name': 'Deploy key',
        'password': 'old-secret-value',
        'private_key': 'unchanged',
        'tags': ['a'],
        'passphrase': 'removed-secret',
      },
    );
    expect(fields, ['passphrase', 'password', 'tags']);
    expect(fields.join(' '), isNot(contains('secret')));
  });

  test(
    'restoring a version queues an update based on the current head',
    () async {
      final fixture = await _Fixture.create(sodium);
      final app = fixture.controller();
      try {
        const original = HostRecord(
          id: _recordId,
          name: 'Build host',
          address: 'first.example',
          username: 'ops',
        );
        await app.saveHost(original);
        final firstRevision = await fixture.acknowledgeHead('1');
        await app.saveHost(original.copyWith(address: 'second.example'));
        final headRevision = await fixture.acknowledgeHead('2');
        expect(await fixture.database.countPending(_vaultId), 0);

        await app.restoreRecordVersion(
          recordId: _recordId,
          version: RecordHistoryEntry(
            revisionId: firstRevision,
            commitSeq: '1',
            createdAt: DateTime.utc(2026, 11, 20),
            verified: true,
            isCurrent: false,
            deviceId: fixture.local.deviceId,
            operation: 'create',
            plaintext: Map<String, dynamic>.from(original.toJson()),
          ),
        );

        final pending = await fixture.database.queuedOperations(_vaultId);
        expect(pending, hasLength(1));
        expect(pending.single.baseRevisionId, headRevision);
        final envelope =
            jsonDecode(pending.single.envelopeJson) as Map<String, dynamic>;
        expect(_header(envelope)['operation'], 'update');
        expect(_header(envelope)['base_revision_id'], headRevision);
        expect(_header(envelope)['revision_id'], isNot(firstRevision));
        final content = await fixture.repository.crypto.decryptRecord(
          vaultKey: Uint8List.fromList(fixture.key),
          envelope: envelope,
          authorPublicKey: fixture.local.signing.publicKey,
        );
        expect(content['address'], 'first.example');
        expect(app.hosts.single.address, 'first.example');
      } finally {
        app.dispose();
        await fixture.dispose();
      }
    },
  );

  test('a read-only member and an unverified version cannot restore', () async {
    final fixture = await _Fixture.create(sodium);
    final app = fixture.controller();
    try {
      const original = HostRecord(
        id: _recordId,
        name: 'Build host',
        address: 'first.example',
        username: 'ops',
      );
      await app.saveHost(original);
      await fixture.acknowledgeHead('1');
      RecordHistoryEntry version({required bool verified}) =>
          RecordHistoryEntry(
            revisionId: '55555555-5555-4555-8555-555555555555',
            commitSeq: '1',
            createdAt: DateTime.utc(2026, 11, 20),
            verified: verified,
            isCurrent: false,
            plaintext: verified
                ? Map<String, dynamic>.from(
                    original.copyWith(address: 'old.example').toJson(),
                  )
                : null,
          );

      await expectLater(
        app.restoreRecordVersion(
          recordId: _recordId,
          version: version(verified: false),
        ),
        throwsStateError,
      );
      app.activeVault = const VaultDescriptor(
        id: _vaultId,
        role: 'viewer',
        activeKeyEpoch: '1',
        membershipVersion: '1',
        canWrite: false,
      );
      await expectLater(
        app.restoreRecordVersion(
          recordId: _recordId,
          version: version(verified: true),
        ),
        throwsStateError,
      );
      expect(await fixture.database.countPending(_vaultId), 0);
    } finally {
      app.dispose();
      await fixture.dispose();
    }
  });

  group('history dialog', () {
    RecordHistory sampleHistory(String localDeviceId) => RecordHistory(
      recordId: _recordId,
      historyLimit: 20,
      entries: [
        RecordHistoryEntry(
          revisionId: 'aaaaaaaa-0000-4000-8000-000000000003',
          commitSeq: '3',
          createdAt: DateTime.utc(2026, 11, 20, 10),
          verified: true,
          isCurrent: true,
          deviceId: localDeviceId,
          operation: 'update',
          plaintext: const {
            'id': _recordId,
            'type': 'credential',
            'name': 'Deploy',
            'password': 'current-secret',
          },
        ),
        RecordHistoryEntry(
          revisionId: 'aaaaaaaa-0000-4000-8000-000000000002',
          commitSeq: '2',
          createdAt: DateTime.utc(2026, 11, 20, 9),
          verified: false,
          isCurrent: false,
        ),
        RecordHistoryEntry(
          revisionId: 'aaaaaaaa-0000-4000-8000-000000000001',
          commitSeq: '1',
          createdAt: DateTime.utc(2026, 11, 20, 8),
          verified: true,
          isCurrent: false,
          deviceId: 'bbbbbbbb-1234-4000-8000-000000000000',
          operation: 'create',
          plaintext: const {
            'id': _recordId,
            'type': 'credential',
            'name': 'Deploy',
            'password': 'older-secret',
          },
        ),
      ],
    );

    Future<AppController> pumpDialog(
      WidgetTester tester, {
      required ClientDatabase database,
      required Future<RecordHistory> Function() load,
      Future<void> Function(RecordHistoryEntry version)? restore,
      bool canWrite = true,
    }) async {
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..activeVault = VaultDescriptor(
              id: _vaultId,
              role: canWrite ? 'owner' : 'viewer',
              activeKeyEpoch: '1',
              membershipVersion: '1',
              canWrite: canWrite,
            )
            ..devices = [
              {
                'device_id': 'bbbbbbbb-1234-4000-8000-000000000000',
                'name': 'Office laptop',
              },
            ];
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: RecordHistoryDialog(
              app: app,
              recordId: _recordId,
              recordName: 'Deploy',
              loadHistoryForTesting: load,
              restoreVersionForTesting: restore,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return app;
    }

    testWidgets('lists versions without secrets and restores after confirming', (
      tester,
    ) async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final restored = <String>[];
      final app = await pumpDialog(
        tester,
        database: database,
        load: () async => sampleHistory('local-device'),
        restore: (version) async => restored.add(version.revisionId),
      );
      try {
        expect(find.text('Version history · Deploy'), findsOneWidget);
        expect(
          find.text('The server keeps the latest 20 versions of each record.'),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey(
              'record_history_current_aaaaaaaa-0000-4000-8000-000000000003',
            ),
          ),
          findsOneWidget,
        );
        expect(find.text('Created · Office laptop'), findsOneWidget);
        expect(
          find.byKey(
            const ValueKey(
              'record_history_unreadable_aaaaaaaa-0000-4000-8000-000000000002',
            ),
          ),
          findsOneWidget,
        );
        expect(find.textContaining('secret'), findsNothing);
        // Only the older verified version can be restored: not the current
        // one and not the unverified one.
        expect(find.text('Restore this version'), findsOneWidget);

        await tester.tap(
          find.byKey(
            const ValueKey(
              'record_history_restore_aaaaaaaa-0000-4000-8000-000000000001',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Restore this version?'), findsOneWidget);
        expect(restored, isEmpty);
        await tester.tap(
          find.byKey(const ValueKey('record_history_restore_confirm')),
        );
        await tester.pumpAndSettle();
        expect(restored, ['aaaaaaaa-0000-4000-8000-000000000001']);
        expect(find.text('Restored as a new version.'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    });

    testWidgets('a read-only member sees the history without restore', (
      tester,
    ) async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app = await pumpDialog(
        tester,
        database: database,
        load: () async => sampleHistory('local-device'),
        canWrite: false,
      );
      try {
        expect(find.text('Created · Office laptop'), findsOneWidget);
        expect(find.text('Restore this version'), findsNothing);
        expect(
          find.byKey(const ValueKey('record_history_read_only')),
          findsOneWidget,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    });

    testWidgets('an older server shows a plain not-available state', (
      tester,
    ) async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app = await pumpDialog(
        tester,
        database: database,
        load: () async => throw const RecordHistoryUnavailableException(),
      );
      try {
        expect(
          find.text('Version history is not available on this server.'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('record_history_retry')),
          findsNothing,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      }
    });
  });
}

Map<String, dynamic> _header(Map<String, Object?> envelope) =>
    Map<String, dynamic>.from(envelope['header'] as Map);

Map<String, dynamic> _listed(
  Map<String, dynamic> envelope, {
  required String commitSeq,
}) {
  final header = _header(envelope);
  return {
    'revision_id': header['revision_id'],
    'base_revision_id': header['base_revision_id'],
    'commit_seq': commitSeq,
    'device_id': header['device_id'],
    'operation': header['operation'],
    'deleted': header['operation'] == 'delete',
    'created_at': '2026-11-20T08:00:0${commitSeq}Z',
    'restore_until': null,
    'envelope': envelope,
  };
}

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
    required this.stranger,
    required this.key,
  });

  final SodiumSumo sodium;
  final ClientDatabase database;
  final _HistoryApi api;
  final SyncRepository repository;
  final DeviceIdentity local;
  final DeviceIdentity remote;

  /// A device the Vault's signing directory does not list.
  final DeviceIdentity stranger;
  final Uint8List key;
  int _seq = 0;

  static Future<_Fixture> create(SodiumSumo sodium) async {
    final local = DeviceIdentity.create(sodium);
    final remote = DeviceIdentity.create(sodium);
    final stranger = DeviceIdentity.create(sodium);
    final key = sodium.randombytes.buf(32);
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _HistoryApi(local, remote);
    final repository = SyncRepository(
      api: api,
      database: database,
      crypto: VaultCrypto(sodium),
      identity: local,
      serverSpaceId: _spaceId,
      instanceId: _instanceId,
      vaultId: _vaultId,
      keyEpoch: '1',
      membershipVersion: '1',
      serverGeneration: _instanceId,
      vaultKey: Uint8List.fromList(key),
    );
    return _Fixture._(
      sodium: sodium,
      database: database,
      api: api,
      repository: repository,
      local: local,
      remote: remote,
      stranger: stranger,
      key: key,
    );
  }

  AppController controller() =>
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
          repositoryForTesting: repository,
        )
        ..activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: true,
        );

  Future<Map<String, dynamic>> encrypt(
    DeviceIdentity signer, {
    required String operation,
    required String? baseRevisionId,
    required Map<String, Object?> plaintext,
  }) async => Map<String, dynamic>.from(
    await repository.crypto.encryptRecord(
      vaultKey: Uint8List.fromList(key),
      serverSpaceId: _spaceId,
      vaultId: _vaultId,
      recordId: _recordId,
      baseRevisionId: baseRevisionId,
      deviceId: signer.deviceId,
      deviceSequence: '${++_seq}',
      keyEpoch: '1',
      membershipVersion: '1',
      operation: operation,
      plaintext: plaintext,
      identity: signer,
    ),
  );

  /// Marks the local head as committed, as a push receipt would.
  Future<String> acknowledgeHead(String commitSeq) async {
    final stored = await database.cachedEnvelope(
      _vaultId,
      _recordId,
      instanceId: _instanceId,
      serverSpaceId: _spaceId,
    );
    final envelope = jsonDecode(stored!.envelopeJson) as Map<String, dynamic>;
    await database.markCommitted(
      opId: _header(envelope)['op_id'] as String,
      commitSeq: commitSeq,
      authenticatedEventEnvelope: envelope,
    );
    return stored.revisionId;
  }

  Future<void> dispose() async {
    await database.close();
    api.close();
    local.dispose();
    remote.dispose();
    stranger.dispose();
    key.fillRange(0, key.length, 0);
  }
}

class _HistoryApi extends ApiClient {
  _HistoryApi(this.local, this.remote)
    : super(baseUrl: 'https://history.example.test');

  final DeviceIdentity local;
  final DeviceIdentity remote;
  Map<String, dynamic> history = const {};
  ApiException? historyError;

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
  Future<Map<String, dynamic>> recordRevisions(
    String vaultId,
    String recordId,
  ) async {
    if (historyError case final error?) throw error;
    return history;
  }
}
