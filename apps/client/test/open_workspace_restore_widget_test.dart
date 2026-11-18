import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/open_workspace_snapshot.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/platform/server_hosted.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/open_workspace_store.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/open_workspace_restore.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/l10n_fixture.dart';

// Browser client: the open tabs are remembered without being asked, and come
// back after a reload (a new page with the same browser storage).

const _vault = '11111111-1111-4111-8111-111111111111';
const _account = 'account-restore';
const _server = 'https://server.test';

HostRecord _host(String name) => HostRecord(
  id: 'host-${name.toLowerCase()}',
  name: '$name host',
  address: '${name.toLowerCase()}.example.test',
  username: 'tester',
  credentialId: 'credential-restore',
);

final _alpha = _host('Alpha');
final _beta = _host('Beta');
final _gamma = _host('Gamma');

const _homeTab = ValueKey('workspace-tab-hosts');
const _pairChip = ValueKey('window-combination-pair');

String get _scope => '${secureStorageNamespace(_server)}|$_account|$_vault';

void main() {
  useAppLocaleFixture('en');
  late MemoryOpenWorkspaceStore store;

  setUp(() {
    debugServerHostedOverride = true;
    debugOpenWorkspaceStore = store = MemoryOpenWorkspaceStore();
  });
  tearDown(() {
    debugServerHostedOverride = null;
    debugOpenWorkspaceStore = null;
  });

  WorkspaceTabBar tabBar(WidgetTester tester) =>
      tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
  WorkspaceTab tabOf(WidgetTester tester, String title) =>
      tabBar(tester).tabs.singleWhere((tab) => tab.title == title);
  List<String> sessionTabs(WidgetTester tester) => [
    for (final tab in tabBar(tester).tabs)
      if (!tab.isHome) tab.title,
  ];
  SessionWorkspaceController layout(WidgetTester tester) => tester
      .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
      .controller;
  WindowCombination? stored() =>
      OpenWorkspaceSnapshot.tryDecode(store.values[_scope])?.layout;

  Future<void> openHost(WidgetTester tester, HostRecord host) async {
    await tester.tap(find.byKey(_homeTab));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(ValueKey('host_connect_${host.id}')));
    await tester.pump();
  }

  /// A page load: a new controller and workspace over the same browser
  /// storage, unlocked.
  Future<_Fixture> load(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final fixture = await _Fixture.create();
    await tester.pumpWidget(_shell(fixture.app));
    await tester.pump();
    return fixture;
  }

  /// The pair (Alpha above Beta, 30 %) as one split tab, then Gamma as a tab
  /// of its own, which is the active one.
  Future<void> openPairAndGamma(WidgetTester tester) async {
    await tester.tap(find.byKey(_pairChip));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await openHost(tester, _gamma);
    expect(sessionTabs(tester), ['Alpha host', 'Beta host', 'Gamma host']);
  }

  testWidgets('the open tabs are stored a moment after they changed, and a '
      'reload brings them back: same order, split, active tab, on the '
      'terminal page, each connecting anew', (tester) async {
    final first = await load(tester);
    try {
      // Nothing was open before: nothing comes back, nothing is stored.
      await tester.pump(const Duration(seconds: 4));
      expect(sessionTabs(tester), isEmpty);
      expect(store.writes, 0);

      await openPairAndGamma(tester);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(store.writes, 0);
      await tester.pump(const Duration(milliseconds: 400));
      expect(store.writes, 1);
      final snapshot = stored()!;
      expect(snapshot.panes.map((pane) => '${pane.kind}:${pane.hostId}'), [
        'ssh:host-alpha',
        'ssh:host-beta',
        'ssh:host-gamma',
      ]);
      expect(snapshot.activePane, 2);
      expect(snapshot.tree, {'pane': 2});
      expect(snapshot.groups.single.tree, {
        'axis': 'vertical',
        'ratio': .3,
        'first': {'pane': 0},
        'second': {'pane': 1},
      });
      expect(snapshot.groups.single.activePane, 1);
      // Only references and layout.
      expect(store.values[_scope], isNot(contains('example.test')));
      expect(store.values[_scope], isNot(contains('ephemeral-test-secret')));
      expect(store.values[_scope], isNot(contains('tester')));

      // Nothing about the tabs changes: nothing more is stored.
      await tester.pump(const Duration(seconds: 5));
      expect(store.writes, 1);
    } finally {
      // The page goes away with its tabs.
      await first.cleanup(tester);
    }
    expect(store.writes, 1);
    expect(stored(), isNotNull);

    final second = await load(tester);
    try {
      await tester.pump(const Duration(milliseconds: 3100));
      await second.pumpUntilAttempts(tester, 3);
      expect(sessionTabs(tester), ['Alpha host', 'Beta host', 'Gamma host']);
      final alpha = tabOf(tester, 'Alpha host').id;
      final beta = tabOf(tester, 'Beta host').id;
      final gamma = tabOf(tester, 'Gamma host').id;
      expect(second.app.page, WorkspacePage.terminal);
      expect(tabBar(tester).selectedId, gamma);
      expect(second.app.activeTerminalTabId, gamma);
      expect(tabBar(tester).groups, [
        [alpha, beta],
      ]);
      expect(tabBar(tester).groupSelections, {alpha: beta});
      expect(layout(tester).sessionIds, [gamma]);
      expect(second.attempts.map((attempt) => attempt.host).toSet(), {
        'alpha.example.test',
        'beta.example.test',
        'gamma.example.test',
      });
      expect(find.byType(SnackBar), findsNothing);

      // The split is as it was.
      await tester.tap(find.byKey(ValueKey('workspace-tab-$alpha')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final root = layout(tester).root as SessionWorkspaceSplit;
      expect(root.axis, Axis.vertical);
      expect(root.ratio, .3);
      expect(layout(tester).sessionIds, [alpha, beta]);

      // Bringing them back stored nothing; looking at another tab does.
      await tester.pump(const Duration(seconds: 3));
      expect(store.writes, 2);
      expect(stored()!.activePane, isNot(2));
      expect(stored()!.panes, hasLength(3));
    } finally {
      await second.cleanup(tester);
    }
  });

  testWidgets('a lock or sign-out keeps the snapshot and unlocking in the '
      'same page opens nothing twice; closing the last tab empties it', (
    tester,
  ) async {
    store.values[_scope] = OpenWorkspaceSnapshot(
      savedAtMs: 1,
      layout: WindowCombination(
        id: OpenWorkspaceSnapshot.layoutId,
        name: OpenWorkspaceSnapshot.layoutId,
        panes: [CombinationPane(kind: 'ssh', hostId: _alpha.id)],
        tree: const {'pane': 0},
        activePane: 0,
      ),
    ).encode();
    final fixture = await load(tester);
    try {
      await tester.pump(const Duration(milliseconds: 3100));
      await fixture.pumpUntilAttempts(tester, 1);
      expect(sessionTabs(tester), ['Alpha host']);
      await tester.pump(const Duration(seconds: 2));
      expect(store.writes, 0);

      // Locked: the lock screen replaces the workspace and the tabs are
      // dropped.
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.cancelAttempts();
      await tester.runAsync(() => fixture.app.disconnectAllTerminalTabs());
      await tester.pump(const Duration(seconds: 5));
      expect(stored()!.panes.single.hostId, _alpha.id);
      expect(store.writes, 0);

      // Unlocked again in the same page.
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      expect(sessionTabs(tester), isEmpty);
      expect(fixture.attempts, hasLength(1));
      expect(stored()!.panes.single.hostId, _alpha.id);
      expect(store.writes, 0);

      // The user opens a tab and closes it again: now nothing is open.
      await openHost(tester, _beta);
      await tester.pump(const Duration(seconds: 2));
      expect(stored()!.panes.single.hostId, _beta.id);
      final id = tabOf(tester, 'Beta host').id;
      fixture.cancelAttempts();
      unawaited(fixture.app.closeTerminalTab(id));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(sessionTabs(tester), isEmpty);
      expect(store.values[_scope], isNotNull);
      expect(stored(), isNull);
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('a Host that no longer exists is left out without a word; '
      'the others come back', (tester) async {
    store.values[_scope] = OpenWorkspaceSnapshot(
      savedAtMs: 1,
      layout: WindowCombination(
        id: OpenWorkspaceSnapshot.layoutId,
        name: OpenWorkspaceSnapshot.layoutId,
        panes: [
          CombinationPane(kind: 'ssh', hostId: 'host-gone'),
          CombinationPane(kind: 'ssh', hostId: _beta.id),
          // Was SSH when the snapshot was taken, is not a desktop Host.
          CombinationPane(kind: 'rdp', hostId: _gamma.id),
          CombinationPane(kind: 'ssh', hostId: _alpha.id),
        ],
        tree: const {
          'axis': 'horizontal',
          'ratio': .5,
          'first': {'pane': 0},
          'second': {'pane': 1},
        },
        activePane: 0,
      ),
    ).encode();
    final fixture = await load(tester);
    try {
      await tester.pump(const Duration(milliseconds: 3100));
      await fixture.pumpUntilAttempts(tester, 2);
      expect(sessionTabs(tester), ['Beta host', 'Alpha host']);
      expect(fixture.app.page, WorkspacePage.terminal);
      expect(tabBar(tester).selectedId, tabOf(tester, 'Beta host').id);
      expect(tabBar(tester).groups, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      expect(fixture.app.errorMessage, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(SnackBar), findsNothing);
      // The snapshot now describes what is open.
      expect(stored()!.panes.map((pane) => pane.hostId), [_beta.id, _alpha.id]);
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('tabs the user opened before the stored ones came back stay '
      'alone', (tester) async {
    store.values[_scope] = OpenWorkspaceSnapshot(
      savedAtMs: 1,
      layout: WindowCombination(
        id: OpenWorkspaceSnapshot.layoutId,
        name: OpenWorkspaceSnapshot.layoutId,
        panes: [
          CombinationPane(kind: 'ssh', hostId: _alpha.id),
          CombinationPane(kind: 'ssh', hostId: _beta.id),
        ],
        tree: const {'pane': 0},
        activePane: 0,
      ),
    ).encode();
    final fixture = await load(tester);
    try {
      await tester.pump(const Duration(milliseconds: 500));
      await openHost(tester, _gamma);
      await tester.pump(const Duration(seconds: 30));
      expect(sessionTabs(tester), ['Gamma host']);
      expect(fixture.attempts, hasLength(1));
      expect(stored()!.panes.single.hostId, _gamma.id);
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('other clients than the browser client neither store nor open '
      'anything', (tester) async {
    debugServerHostedOverride = false;
    final snapshot = OpenWorkspaceSnapshot(
      savedAtMs: 1,
      layout: WindowCombination(
        id: OpenWorkspaceSnapshot.layoutId,
        name: OpenWorkspaceSnapshot.layoutId,
        panes: [CombinationPane(kind: 'ssh', hostId: _alpha.id)],
        tree: const {'pane': 0},
        activePane: 0,
      ),
    ).encode();
    store.values[_scope] = snapshot;
    final fixture = await load(tester);
    try {
      await tester.pump(const Duration(seconds: 30));
      expect(sessionTabs(tester), isEmpty);
      expect(fixture.attempts, isEmpty);
      expect(fixture.app.page, WorkspacePage.hosts);
      expect(fixture.app.openWorkspaceRestoreHandled, isEmpty);

      await openHost(tester, _beta);
      await tester.pump(const Duration(seconds: 5));
      expect(sessionTabs(tester), ['Beta host']);
      expect(store.writes, 0);
      expect(store.values[_scope], snapshot);
    } finally {
      await fixture.cleanup(tester);
    }
  });
}

Widget _shell(AppController app) => MaterialApp(
  theme: buildAppTheme(),
  home: AppShell(controller: app),
);

class _Attempt {
  _Attempt(this.host);
  final String host;
  final result = Completer<SshConnection>();
}

class _Fixture {
  _Fixture(this.app, this.database, this.attempts);
  final AppController app;
  final ClientDatabase database;
  final List<_Attempt> attempts;

  Future<void> pumpUntilAttempts(WidgetTester tester, int count) async {
    for (var i = 0; i < 100 && attempts.length < count; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (attempts.length < count) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
    }
    expect(attempts, hasLength(count));
    await tester.pump();
  }

  void cancelAttempts() {
    for (final attempt in attempts) {
      if (!attempt.result.isCompleted) {
        attempt.result.completeError(const SshConnectCancelledException());
      }
    }
  }

  static Future<_Fixture> create() async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final attempts = <_Attempt>[];
    final pair = WindowCombination(
      id: 'pair',
      name: 'Pair',
      panes: [
        CombinationPane(kind: 'ssh', hostId: _alpha.id),
        CombinationPane(kind: 'ssh', hostId: _beta.id),
      ],
      tree: const {
        'axis': 'vertical',
        'ratio': .3,
        'first': {'pane': 0},
        'second': {'pane': 1},
      },
      activePane: 1,
    );
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            sshConnectorWithCancellationForTesting:
                ({
                  required host,
                  required credential,
                  required verifyHostKey,
                  required jumpHops,
                  required cancellation,
                  required onUserInfoRequest,
                }) async {
                  final attempt = _Attempt(host.address);
                  attempts.add(attempt);
                  attempt.result.future.ignore();
                  return attempt.result.future;
                },
          )
          ..api = ApiClient(baseUrl: _server)
          ..session = AuthSession(
            accountId: _account,
            accessToken: 'test',
            expiresIn: 3600,
            refreshToken: 'test',
            deviceId: identity.deviceId,
            vaults: const [],
          )
          ..identity = identity
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: _vault,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          )
          ..vaults.add(
            const VaultDescriptor(
              id: _vault,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            ),
          )
          ..credentials.add(
            const CredentialRecord(
              id: 'credential-restore',
              name: 'Credential',
              username: 'tester',
              secret: 'ephemeral-test-secret',
            ),
          )
          ..hosts.addAll([_alpha, _beta, _gamma])
          ..preferences.add(
            VaultPreferenceRecord.windowCombinations(
              value: WindowCombination.encode([pair]),
            ),
          )
          // The records above are this Vault's.
          ..vaultRecordsLoadedFor = _vault;
    return _Fixture(app, database, attempts);
  }

  Future<void> cleanup(WidgetTester tester) async {
    cancelAttempts();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => app.disconnectAllTerminalTabs());
    app.dispose();
    await tester.runAsync(() => database.close());
    await tester.binding.setSurfaceSize(null);
  }
}
