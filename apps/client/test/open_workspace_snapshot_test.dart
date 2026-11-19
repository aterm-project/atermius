import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/open_workspace_snapshot.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/domain/window_placement.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/platform/server_hosted.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/open_workspace_store.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/ui/open_workspace_restore.dart';
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/l10n_fixture.dart';

// The browser client remembers its open tabs by itself: what the snapshot
// holds, how it is stored in the Vault, and when it is stored and opened.

const _serverSpaceId = '11111111-1111-4111-8111-111111111111';
const _instanceId = '22222222-2222-4222-8222-222222222222';
const _vaultId = '33333333-3333-4333-8333-333333333333';
const _accountId = '44444444-4444-4444-8444-444444444444';
const _hostA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _hostB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _scope = 'server|$_accountId|$_vaultId';

/// Host A left of Host B, B active; with [third], another tab of Host A.
WindowCombination _layout({
  double ratio = .4,
  int active = 1,
  bool third = false,
}) => WindowCombination(
  id: OpenWorkspaceSnapshot.layoutId,
  name: OpenWorkspaceSnapshot.layoutId,
  panes: [
    CombinationPane(kind: 'ssh', hostId: _hostA),
    CombinationPane(kind: 'rdp', hostId: _hostB),
    if (third) CombinationPane(kind: 'ssh', hostId: _hostA),
  ],
  tree: {
    'axis': 'horizontal',
    'ratio': ratio,
    'first': {'pane': 0},
    'second': {'pane': 1},
  },
  activePane: active,
  groups: [
    CombinationGroup(
      tree: {
        'axis': 'horizontal',
        'ratio': ratio,
        'first': {'pane': 0},
        'second': {'pane': 1},
      },
      activePane: active,
    ),
  ],
);

OpenWorkspaceSnapshot _snapshot(WindowCombination? layout, {int at = 1000}) =>
    OpenWorkspaceSnapshot(savedAtMs: at, layout: layout);

void main() {
  useAppLocaleFixture('en');
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });
  setUp(() => debugServerHostedOverride = true);
  tearDown(() {
    debugServerHostedOverride = null;
    debugOpenWorkspaceStore = null;
  });

  group('snapshot', () {
    test('survives encoding with order, split, ratio and active pane', () {
      final decoded = OpenWorkspaceSnapshot.decode(
        _snapshot(_layout(third: true), at: 42).encode(),
      );
      expect(decoded.savedAtMs, 42);
      final layout = decoded.layout!;
      expect(layout.panes.map((p) => '${p.kind}:${p.hostId}'), [
        'ssh:$_hostA',
        'rdp:$_hostB',
        'ssh:$_hostA',
      ]);
      expect(layout.tree['axis'], 'horizontal');
      expect(layout.tree['ratio'], .4);
      expect(layout.activePane, 1);
      expect(layout.groups.single.activePane, 1);
      expect(decoded.contentKey, _snapshot(_layout(third: true)).contentKey);

      final closed = OpenWorkspaceSnapshot.decode(_snapshot(null).encode());
      expect(closed.layout, isNull);
    });

    test('the time is not part of what it shows; the layout is', () {
      expect(
        _snapshot(_layout(), at: 1).contentKey,
        _snapshot(_layout(), at: 2).contentKey,
      );
      final key = _snapshot(_layout()).contentKey;
      expect(_snapshot(_layout(ratio: .5)).contentKey, isNot(key));
      expect(_snapshot(_layout(active: 0)).contentKey, isNot(key));
      expect(_snapshot(_layout(third: true)).contentKey, isNot(key));
      expect(_snapshot(null).contentKey, isNot(key));
    });

    test('holds Host tabs only: no files, consoles, paths or window '
        'positions', () {
      WindowCombination only(CombinationPane pane, {bool placed = false}) =>
          WindowCombination(
            id: OpenWorkspaceSnapshot.layoutId,
            name: OpenWorkspaceSnapshot.layoutId,
            panes: [
              CombinationPane(kind: 'ssh', hostId: _hostA),
              pane,
            ],
            tree: const {'pane': 0},
            activePane: 0,
            mainPlacement: placed
                ? SavedWindowPlacement(x: 0, y: 0, width: 800, height: 600)
                : null,
          );
      for (final layout in [
        only(CombinationPane(kind: 'console')),
        only(
          CombinationPane(
            kind: 'sftp',
            hostId: _hostA,
            remotePath: '/etc',
            ownerPane: 0,
          ),
        ),
        only(CombinationPane(kind: 'ssh', hostId: _hostB), placed: true),
        WindowCombination(
          id: 'named',
          name: 'A window set',
          panes: [CombinationPane(kind: 'ssh', hostId: _hostA)],
          tree: const {'pane': 0},
          activePane: 0,
        ),
      ]) {
        expect(() => _snapshot(layout), throwsFormatException);
      }
      expect(() => _snapshot(_layout(), at: -1), throwsFormatException);
    });

    test('anything else is not a snapshot', () {
      final good = _snapshot(_layout()).encode();
      expect(OpenWorkspaceSnapshot.tryDecode(good), isNotNull);
      for (final bad in [
        null,
        '',
        'not json',
        '[]',
        '{"version":2,"saved_at_ms":1,"layout":null}',
        '{"version":1,"saved_at_ms":"1","layout":null}',
        '{"version":1,"saved_at_ms":1}',
        '{"version":1,"saved_at_ms":1,"layout":null,"scrollback":"x"}',
        '{"version":1,"saved_at_ms":1,"layout":{"version":1}}',
        good.replaceFirst('"ssh"', '"console"'),
      ]) {
        expect(OpenWorkspaceSnapshot.tryDecode(bad), isNull, reason: '$bad');
      }
    });

    test('of two copies the later one is used', () {
      final early = _snapshot(_layout(), at: 1), late = _snapshot(null, at: 2);
      expect(newerOpenWorkspaceSnapshot(early, late), same(late));
      expect(newerOpenWorkspaceSnapshot(late, early), same(late));
      expect(newerOpenWorkspaceSnapshot(null, early), same(early));
      expect(newerOpenWorkspaceSnapshot(early, null), same(early));
      expect(newerOpenWorkspaceSnapshot(null, null), isNull);
    });
  });

  group('synced record', () {
    test('every browser derives the same record for an account and Vault', () {
      final id = openWorkspaceRecordId(
        accountId: _accountId,
        vaultId: _vaultId,
      );
      expect(
        id,
        openWorkspaceRecordId(accountId: _accountId, vaultId: _vaultId),
      );
      expect(
        id,
        matches(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      );
      expect(
        openWorkspaceRecordId(accountId: _hostA, vaultId: _vaultId),
        isNot(id),
      );
      expect(
        openWorkspaceRecordId(accountId: _accountId, vaultId: _hostA),
        isNot(id),
      );
    });

    test('is a workspace record older clients read, carrying the '
        'snapshot', () {
      final id = openWorkspaceRecordId(
        accountId: _accountId,
        vaultId: _vaultId,
      );
      final snapshot = _snapshot(_layout(third: true));
      final record = openWorkspaceRecord(
        id: id,
        name: 'Open tabs',
        snapshot: snapshot,
        previous: null,
      )!;
      // What a client that predates the snapshot does with the record.
      final read = WorkspaceRecord.fromJson({
        ...record.toJson(),
        '_record_id': id,
      });
      expect(read.name, 'Open tabs');
      expect(read.panes.map((pane) => pane.hostId), [_hostA, _hostB, _hostA]);
      // What this client does with it.
      expect(isOpenWorkspaceRecord(read), isTrue);
      expect(openWorkspaceSnapshotOf(read)!.contentKey, snapshot.contentKey);

      // The last tab was closed: the record keeps its Hosts, the snapshot
      // says that nothing is open.
      final closed = openWorkspaceRecord(
        id: id,
        name: 'Open tabs',
        snapshot: _snapshot(null, at: 2000),
        previous: read,
      )!;
      expect(closed.panes.map((pane) => pane.hostId), [_hostA, _hostB, _hostA]);
      expect(openWorkspaceSnapshotOf(closed)!.layout, isNull);
      expect(
        openWorkspaceRecord(
          id: id,
          name: 'Open tabs',
          snapshot: _snapshot(null),
          previous: null,
        ),
        isNull,
      );

      // A workspace the user saved is not one.
      final saved = WorkspaceRecord.fromHostIds(
        name: 'Mine',
        hostIds: [_hostA],
      );
      expect(isOpenWorkspaceRecord(saved), isFalse);
      expect(openWorkspaceSnapshotOf(saved), isNull);
    });

    test('is stored encrypted as one record, kept out of the saved '
        'workspaces, and read back', () async {
      final (app, database) = await _vaultApp(sodium);
      try {
        final id = openWorkspaceRecordId(
          accountId: _accountId,
          vaultId: _vaultId,
        );
        expect(app.syncedOpenWorkspaceSnapshot, isNull);
        expect(
          await app.saveOpenWorkspaceSnapshot(_snapshot(_layout(), at: 10)),
          isTrue,
        );
        expect(
          await app.saveOpenWorkspaceSnapshot(
            _snapshot(_layout(ratio: .6), at: 20),
          ),
          isTrue,
        );
        final rows = await database.cachedEnvelopes(
          _vaultId,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
        );
        expect(rows.map((row) => row.recordId), [id]);
        expect(rows.single.envelopeJson, isNot(contains(_hostA)));
        expect(rows.single.envelopeJson, isNot(contains('open_workspace')));

        await app.reloadRecords();
        expect(app.vaultRecordsLoadedFor, _vaultId);
        expect(app.savedWorkspaces, isEmpty);
        expect(app.windowCombinations, isEmpty);
        expect(app.unavailableRecordCount, 0);
        expect(app.preferenceError, isNull);
        expect(app.errorMessage, isNull);
        expect(app.noticeMessage, isNull);
        final synced = app.syncedOpenWorkspaceSnapshot!;
        expect(synced.savedAtMs, 20);
        expect(synced.layout!.tree['ratio'], .6);

        // Closing the last tab keeps the record and empties the snapshot.
        expect(
          await app.saveOpenWorkspaceSnapshot(_snapshot(null, at: 30)),
          isTrue,
        );
        await app.reloadRecords();
        expect(app.syncedOpenWorkspaceSnapshot!.layout, isNull);
        expect(app.savedWorkspaces, isEmpty);
      } finally {
        app.dispose();
        await database.close();
      }
    });

    test('two browsers storing at the same time never put a conflict in '
        'front of the user', () async {
      final (app, database) = await _vaultApp(sodium);
      try {
        final id = openWorkspaceRecordId(
          accountId: _accountId,
          vaultId: _vaultId,
        );
        Future<Map<String, dynamic>> head() async => jsonDecode(
          (await database.cachedEnvelope(
            _vaultId,
            id,
            instanceId: _instanceId,
            serverSpaceId: _serverSpaceId,
          ))!.envelopeJson,
        ) as Map<String, dynamic>;
        await app.saveOpenWorkspaceSnapshot(_snapshot(_layout(), at: 10));
        final remote = await head();
        await app.saveOpenWorkspaceSnapshot(
          _snapshot(_layout(active: 0), at: 20),
        );
        final local = await head();
        await database.markConflicted(
          (local['header'] as Map<String, dynamic>)['op_id'] as String,
        );
        await database.saveConflict(
          conflictId: '88888888-8888-4888-8888-888888888888',
          vaultId: _vaultId,
          recordId: id,
          instanceId: _instanceId,
          serverSpaceId: _serverSpaceId,
          kind: 'concurrent_edit',
          branchEnvelope: local,
          remoteEnvelope: remote,
        );
        expect(
          await database.openConflicts(
            _vaultId,
            instanceId: _instanceId,
            serverSpaceId: _serverSpaceId,
          ),
          hasLength(1),
        );

        await app.refreshSyncStatus();
        expect(app.openConflicts, isEmpty);
        expect(app.conflictCount, 0);
        expect(app.unresolvedConflictCount, 0);
        expect(app.feedConflictItems, isEmpty);
        // The branch that lost is dropped by itself: the resolution is
        // queued for the next sync, and nothing is said.
        Future<List<String>> states() async => [
          for (final conflict in await database.openConflicts(
            _vaultId,
            instanceId: _instanceId,
            serverSpaceId: _serverSpaceId,
          ))
            conflict.state,
        ];
        for (var i = 0; i < 100; i++) {
          if ((await states()).single != 'open') break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(await states(), ['resolution_pending']);
        await app.refreshSyncStatus();
        expect(app.openConflicts, isEmpty);
        expect(app.unresolvedConflictCount, 0);
        expect(app.errorMessage, isNull);
        expect(app.noticeMessage, isNull);
      } finally {
        app.dispose();
        await database.close();
      }
    });

    test('is not written to a read-only Vault, before the records are '
        'loaded, or by a client that is not the browser client', () async {
      final (readOnly, readOnlyDatabase) = await _vaultApp(
        sodium,
        canWrite: false,
      );
      final (app, database) = await _vaultApp(sodium);
      try {
        expect(
          await readOnly.saveOpenWorkspaceSnapshot(_snapshot(_layout())),
          isFalse,
        );
        expect(readOnly.errorMessage, isNull);

        app.vaultRecordsLoadedFor = null;
        expect(
          await app.saveOpenWorkspaceSnapshot(_snapshot(_layout())),
          isFalse,
        );
        app.vaultRecordsLoadedFor = _vaultId;
        debugServerHostedOverride = false;
        expect(
          await app.saveOpenWorkspaceSnapshot(_snapshot(_layout())),
          isFalse,
        );
        for (final db in [database, readOnlyDatabase]) {
          expect(
            await db.cachedEnvelopes(
              _vaultId,
              instanceId: _instanceId,
              serverSpaceId: _serverSpaceId,
            ),
            isEmpty,
          );
        }
        expect(app.errorMessage, isNull);
      } finally {
        readOnly.dispose();
        app.dispose();
        await readOnlyDatabase.close();
        await database.close();
      }
    });
  });

  group('keeper', () {
    late _App app;
    late ClientDatabase database;
    late MemoryOpenWorkspaceStore store;
    String? scope;
    WindowCombination? layout;
    late List<WindowCombination> restored;

    setUp(() {
      database = ClientDatabase.forTesting(NativeDatabase.memory());
      app =
          _App(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..activeVault = const VaultDescriptor(
              id: _vaultId,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..vaultRecordsLoadedFor = _vaultId;
      store = MemoryOpenWorkspaceStore();
      scope = _scope;
      layout = null;
      restored = [];
    });
    tearDown(() async {
      app.dispose();
      await database.close();
    });

    // These tests are about what is stored and when it is captured; the
    // wait before the synced copy is written has its own test below.
    OpenWorkspaceKeeper keeper({Duration vaultDelay = Duration.zero}) =>
        OpenWorkspaceKeeper(
          app: app,
          scope: () => scope,
          capture: () => layout,
          restore: (value) async => restored.add(value),
          store: store,
          now: () => DateTime.fromMillisecondsSinceEpoch(5000),
          vaultDelay: vaultDelay,
        );

    /// A keeper whose stored tabs were dealt with already.
    OpenWorkspaceKeeper storing() {
      app.openWorkspaceRestoreHandled.add(_scope);
      return keeper()..attach([app]);
    }

    WindowCombination? storedLayout() =>
        OpenWorkspaceSnapshot.decode(store.values[_scope]!).layout;

    test('stores a change once the tabs stayed the same for a moment, in '
        'this browser and in the Vault', () {
      FakeAsync().run((async) {
        final k = storing();
        layout = _layout();
        k.changed();
        async.elapse(const Duration(milliseconds: 800));
        layout = _layout(ratio: .5);
        k.changed();
        async.elapse(const Duration(milliseconds: 800));
        layout = _layout(ratio: .6);
        k.changed();
        async.elapse(const Duration(milliseconds: 1100));
        expect(store.writes, 0);
        expect(app.saved, isEmpty);

        async.elapse(const Duration(milliseconds: 200));
        expect(store.writes, 1);
        expect(storedLayout()!.tree['ratio'], .6);
        expect(app.saved.single.layout!.tree['ratio'], .6);
        expect(app.saved.single.savedAtMs, 5000);
        k.dispose();
      });
    });

    test('the synced copy waits until the tabs have been quiet; this '
        'browser\'s copy does not', () {
      FakeAsync().run((async) {
        app.openWorkspaceRestoreHandled.add(_scope);
        final k = keeper(vaultDelay: const Duration(seconds: 15))
          ..attach([app]);
        // A tab opens: this browser has it at once, the Vault not yet (its
        // upload would be in the way of the tab's own connection).
        layout = _layout();
        k.changed();
        async.elapse(const Duration(milliseconds: 1300));
        expect(store.writes, 1);
        expect(app.saved, isEmpty);

        // Another change inside the wait replaces what will be written;
        // one revision goes to the Vault, not two.
        async.elapse(const Duration(seconds: 10));
        layout = _layout(ratio: .6);
        k.changed();
        async.elapse(const Duration(milliseconds: 1300));
        expect(store.writes, 2);
        async.elapse(const Duration(seconds: 14));
        expect(app.saved, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(app.saved.single.layout!.tree['ratio'], .6);

        // Leaving the workspace drops a copy that is still waiting.
        layout = _layout(ratio: .7);
        k.changed();
        async.elapse(const Duration(milliseconds: 1300));
        k.dispose();
        async.elapse(const Duration(seconds: 30));
        expect(app.saved, hasLength(1));
      });
    });

    test('stores nothing while nothing about the tabs changed', () {
      FakeAsync().run((async) {
        final k = storing();
        layout = _layout();
        k.changed();
        async.elapse(const Duration(seconds: 2));
        expect(store.writes, 1);
        expect(app.saved, hasLength(1));

        // Notifications that change nothing about the tabs.
        for (var i = 0; i < 5; i++) {
          app.notifyListeners();
          async.elapse(const Duration(seconds: 2));
        }
        expect(store.writes, 1);
        expect(app.saved, hasLength(1));

        // Another tab becomes the active one.
        layout = _layout(active: 0);
        app.notifyListeners();
        async.elapse(const Duration(seconds: 2));
        expect(store.writes, 2);
        expect(app.saved, hasLength(2));
        expect(storedLayout()!.activePane, 0);

        // Back to what is stored already, within the delay: nothing.
        layout = _layout(active: 1);
        k.changed();
        layout = _layout(active: 0);
        k.changed();
        async.elapse(const Duration(seconds: 2));
        expect(store.writes, 2);
        expect(app.saved, hasLength(2));
        k.dispose();
      });
    });

    test('a Vault that could not be written is tried again with the next '
        'change; this browser keeps its copy meanwhile', () {
      FakeAsync().run((async) {
        final k = storing();
        app.accept = false;
        layout = _layout();
        k.changed();
        async.elapse(const Duration(seconds: 2));
        expect(store.writes, 1);
        expect(app.saved, hasLength(1));
        expect(app.errorMessage, isNull);

        app.accept = true;
        layout = _layout(active: 0);
        k.changed();
        async.elapse(const Duration(seconds: 2));
        expect(store.writes, 2);
        expect(app.saved, hasLength(2));
        expect(app.synced!.layout!.activePane, 0);
        k.dispose();
      });
    });

    test('a lock, a sign-out, a dropped workspace, another Vault or leaving '
        'the page never empties the snapshot', () {
      FakeAsync().run((async) {
        var k = storing();
        layout = _layout();
        k.changed();
        async.elapse(const Duration(seconds: 2));
        final stored = store.values[_scope];
        expect(stored, isNotNull);

        // The tabs are dropped without the user closing them (reconnect of
        // the whole workspace): still the same scope.
        layout = null;
        k.changed();
        async.elapse(const Duration(seconds: 2));

        // Locked or signed out: no scope, no tabs.
        scope = null;
        k.changed();
        async.elapse(const Duration(seconds: 2));

        // Another Vault, without tabs.
        scope = 'server|$_accountId|other-vault';
        app.openWorkspaceRestoreHandled.add(scope!);
        k.changed();
        async.elapse(const Duration(seconds: 2));

        // The page is left (or the workspace replaced by the lock screen)
        // right after a change.
        scope = _scope;
        layout = _layout(active: 0);
        k.changed();
        layout = null;
        k.dispose();
        async.elapse(const Duration(seconds: 5));

        // Unlocked again in the same page: no tabs, nothing to store.
        k = keeper()..attach([app]);
        async.elapse(const Duration(seconds: 5));
        k.dispose();

        expect(store.values, {_scope: stored});
        expect(store.writes, 1);
        expect(app.saved, hasLength(1));
      });
    });

    test('closing the last tab empties it', () {
      FakeAsync().run((async) {
        final k = storing();
        layout = _layout();
        k.changed();
        async.elapse(const Duration(seconds: 2));

        app.terminalTabClosures++;
        layout = null;
        k.changed();
        async.elapse(const Duration(seconds: 2));
        expect(storedLayout(), isNull);
        expect(app.saved, hasLength(2));
        expect(app.saved.last.layout, isNull);
        k.dispose();
      });
    });

    test('tabs that cannot be described leave the snapshot as it is', () {
      FakeAsync().run((async) {
        var fail = false;
        app.openWorkspaceRestoreHandled.add(_scope);
        final k = OpenWorkspaceKeeper(
          app: app,
          scope: () => scope,
          capture: () => fail ? throw StateError('console tab') : layout,
          restore: (_) async {},
          store: store,
          vaultDelay: Duration.zero,
        )..attach([app]);
        layout = _layout();
        k.changed();
        async.elapse(const Duration(seconds: 2));
        fail = true;
        k.changed();
        async.elapse(const Duration(seconds: 2));
        expect(store.writes, 1);
        expect(storedLayout(), isNotNull);
        k.dispose();
      });
    });

    test('opens the stored tabs once per page load, after waiting for the '
        'first sync', () {
      FakeAsync().run((async) {
        store.values[_scope] = _snapshot(_layout(), at: 10).encode();
        var k = keeper()..attach([app]);
        async.elapse(const Duration(milliseconds: 2900));
        expect(restored, isEmpty);
        async.elapse(const Duration(milliseconds: 200));
        expect(restored.single.activePane, 1);
        expect(app.openWorkspaceRestoreHandled, {_scope});

        // Later notifications, and the workspace coming back after a lock.
        app.notifyListeners();
        async.elapse(const Duration(seconds: 30));
        k.dispose();
        k = keeper()..attach([app]);
        async.elapse(const Duration(seconds: 30));
        k.dispose();
        expect(restored, hasLength(1));
        // Opening them stored nothing new.
        expect(store.writes, 0);
        expect(app.saved, isEmpty);
      });
    });

    test('does not wait longer than the first sync, and opens the later of '
        'the two copies', () {
      FakeAsync().run((async) {
        store.values[_scope] = _snapshot(_layout(), at: 10).encode();
        final k = keeper()..attach([app]);
        app.syncing = true;
        app.notifyListeners();
        async.elapse(const Duration(milliseconds: 300));
        expect(restored, isEmpty);
        // The sync brought what another browser stored later.
        app.synced = _snapshot(_layout(active: 0, third: true), at: 20);
        app.syncing = false;
        app.notifyListeners();
        async.flushMicrotasks();
        expect(restored.single.panes, hasLength(3));
        expect(restored.single.activePane, 0);
        k.dispose();
      });
    });

    test('waits for the records, and opens a snapshot that arrives a little '
        'later, but not one that arrives much later', () {
      FakeAsync().run((async) {
        app.vaultRecordsLoadedFor = null;
        final k = keeper()..attach([app]);
        async.elapse(const Duration(seconds: 60));
        expect(app.openWorkspaceRestoreHandled, isEmpty);

        app.vaultRecordsLoadedFor = _vaultId;
        app.notifyListeners();
        async.elapse(const Duration(seconds: 10));
        expect(restored, isEmpty);
        app.synced = _snapshot(_layout(), at: 20);
        app.notifyListeners();
        async.flushMicrotasks();
        expect(restored, hasLength(1));
        k.dispose();

        // Another page load in which nothing arrives in time.
        app.openWorkspaceRestoreHandled.clear();
        app.synced = null;
        restored.clear();
        final late = keeper()..attach([app]);
        async.elapse(const Duration(seconds: 21));
        expect(app.openWorkspaceRestoreHandled, {_scope});
        app.synced = _snapshot(_layout(), at: 30);
        app.notifyListeners();
        async.elapse(const Duration(seconds: 30));
        expect(restored, isEmpty);
        late.dispose();
      });
    });

    test('a snapshot that says the last tab was closed opens nothing; while '
        'the stored tabs are not dealt with, nothing is stored', () {
      FakeAsync().run((async) {
        store.values[_scope] = _snapshot(_layout(), at: 10).encode();
        app.synced = _snapshot(null, at: 20);
        layout = _layout(active: 0);
        final k = keeper()..attach([app]);
        async.elapse(const Duration(milliseconds: 2500));
        // Still waiting for the first sync: nothing stored over the snapshot.
        expect(store.writes, 0);
        expect(app.saved, isEmpty);
        async.elapse(const Duration(seconds: 1));
        expect(restored, isEmpty);
        expect(app.openWorkspaceRestoreHandled, {_scope});
        k.dispose();
      });
    });
  });
}

/// Stands in for the Vault side of the controller.
class _App extends AppController {
  _App({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  final saved = <OpenWorkspaceSnapshot>[];
  OpenWorkspaceSnapshot? synced;
  bool accept = true;

  @override
  OpenWorkspaceSnapshot? get syncedOpenWorkspaceSnapshot => synced;

  @override
  Future<bool> saveOpenWorkspaceSnapshot(OpenWorkspaceSnapshot snapshot) async {
    saved.add(snapshot);
    if (accept) synced = snapshot;
    return accept;
  }
}

class _Api extends ApiClient {
  _Api(this.identity) : super(baseUrl: 'https://open-workspace.test');

  final DeviceIdentity identity;

  Map<String, dynamic> get _device => {
    'device_id': identity.deviceId,
    'user_id': _accountId,
    'signing_public_key': identity.signingPublicKey,
    'status': 'active',
  };

  @override
  Future<List<Map<String, dynamic>>> devices() async => [_device];

  @override
  Future<List<Map<String, dynamic>>> vaultDevices(String vaultId) async => [
    _device,
  ];
}

/// A signed-in controller over a real encrypted repository.
Future<(AppController, ClientDatabase)> _vaultApp(
  SodiumSumo sodium, {
  bool canWrite = true,
}) async {
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final identity = DeviceIdentity.create(sodium);
  final Uint8List key = sodium.randombytes.buf(32);
  final repository = SyncRepository(
    api: _Api(identity),
    database: database,
    crypto: VaultCrypto(sodium),
    identity: identity,
    serverSpaceId: _serverSpaceId,
    instanceId: _instanceId,
    vaultId: _vaultId,
    keyEpoch: '1',
    membershipVersion: '1',
    serverGeneration: '1',
    vaultKey: key,
    canWrite: canWrite,
  );
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
          repositoryForTesting: repository,
        )
        ..session = AuthSession(
          accountId: _accountId,
          accessToken: 'test',
          expiresIn: 3600,
          refreshToken: 'test',
          deviceId: identity.deviceId,
          vaults: const [],
        )
        ..activeVault = VaultDescriptor(
          id: _vaultId,
          role: canWrite ? 'owner' : 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: canWrite,
        );
  await app.reloadRecords();
  return (app, database);
}
