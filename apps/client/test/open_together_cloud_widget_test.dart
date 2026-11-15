import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/sync_repository.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

import 'support/l10n_fixture.dart';

// Signed-in workspace: a Group or a saved window set opens as one split tab
// right away. Its members connect at the same time, each in its own pane, and
// the home page does not wait for them.

const _vault = '11111111-1111-4111-8111-111111111111';
const _group = 'group-fleet';

HostRecord _host(String name, {bool grouped = true}) => HostRecord(
  id: 'host-${name.toLowerCase()}',
  name: '$name host',
  address: '${name.toLowerCase()}.example.test',
  username: 'tester',
  credentialId: 'credential-together',
  groupId: grouped ? _group : null,
);

final _alpha = _host('Alpha');
final _beta = _host('Beta');
final _gamma = _host('Gamma');
final _delta = _host('Delta', grouped: false);

const _homeTab = ValueKey('workspace-tab-hosts');
const _homeSearch = ValueKey('cloud_home_search');
const _groupButton = ValueKey('cloud_group_connect_$_group');
const _pairChip = ValueKey('window-combination-pair');
const _stopKey = ValueKey('connect_progress_stop');
const _retryKey = ValueKey('connect_progress_retry');
const _errorKey = ValueKey('connect_progress_error');
final _pane = find.byKey(const ValueKey('connect_progress_pane'));

void main() {
  useAppLocaleFixture('en');

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

  /// The connect progress surface inside the pane of [tab].
  Finder inPane(WorkspaceTab tab, Finder matching) => find.descendant(
    of: find.byKey(ValueKey('connect_progress_${tab.id}')),
    matching: matching,
  );

  Future<void> showHome(WidgetTester tester) async {
    await tester.tap(find.byKey(_homeTab));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The home page is in front, shows no waiting indicator or message, and
  /// its Groups and window sets can be opened.
  void expectHomeIdle(WidgetTester tester) {
    expect(tabBar(tester).selectedId, 'hosts');
    expect(find.byKey(_homeSearch).hitTestable(), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(
      tester.widget<ButtonStyleButton>(find.byKey(_groupButton)).onPressed,
      isNotNull,
    );
    expect(tester.widget<InputChip>(find.byKey(_pairChip)).onPressed, isNotNull);
  }

  Future<_Fixture> open(WidgetTester tester, {bool reviewHostKeys = false}) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final fixture = await _Fixture.create(reviewHostKeys: reviewHostKeys);
    await tester.pumpWidget(_shell(fixture.app));
    await tester.pump();
    return fixture;
  }

  testWidgets('a Group opens as one split tab at once: every member connects '
      'at the same time in its own pane and the home page stays usable', (
    tester,
  ) async {
    final fixture = await open(tester);
    try {
      await tester.tap(find.byKey(_groupButton));
      await tester.pump();
      // In the frame after the click: one split tab with a pane per member,
      // selected, every pane showing its own progress.
      expect(sessionTabs(tester), ['Alpha host', 'Beta host', 'Gamma host']);
      final members = [
        for (final name in ['Alpha host', 'Beta host', 'Gamma host'])
          tabOf(tester, name),
      ];
      final ids = members.map((tab) => tab.id).toList();
      expect(tabBar(tester).groups, [ids]);
      expect(layout(tester).sessionIds, ids);
      expect(ids, contains(tabBar(tester).selectedId));
      expect(_pane.hitTestable(), findsNWidgets(3));
      for (final tab in members) {
        expect(
          inPane(tab, find.text('Connecting to ${tab.title}')).hitTestable(),
          findsOneWidget,
        );
        expect(inPane(tab, find.byKey(_stopKey)).hitTestable(), findsOneWidget);
        expect(tab.status, 'connecting');
      }

      // No member waits for another: all three attempts are running while
      // none of them has an answer.
      await fixture.pumpUntilAttempts(tester, 3);
      expect(fixture.attempts.map((attempt) => attempt.host).toSet(), {
        'alpha.example.test',
        'beta.example.test',
        'gamma.example.test',
      });
      expect(fixture.attempts.every((a) => !a.result.isCompleted), isTrue);

      // The home page does not wait and opens another Host meanwhile.
      await showHome(tester);
      expectHomeIdle(tester);
      await tester.tap(find.byKey(const ValueKey('host_connect_host-delta')));
      await tester.pump();
      expect(sessionTabs(tester), hasLength(4));
      expect(tabBar(tester).selectedId, tabOf(tester, 'Delta host').id);
      await fixture.pumpUntilAttempts(tester, 4);
      expect(tabBar(tester).groups, [ids]);

      // Opening the Group again while it connects shows the same panes; no
      // member is connected a second time.
      await showHome(tester);
      await tester.tap(find.byKey(_groupButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(sessionTabs(tester), hasLength(4));
      expect(layout(tester).sessionIds, ids);
      expect(ids, contains(tabBar(tester).selectedId));
      expect(fixture.attempts, hasLength(4));
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('a member that fails or is stopped shows it with retry in its '
      'own pane; the other members keep connecting and connect', (
    tester,
  ) async {
    final fixture = await open(tester);
    try {
      await tester.tap(find.byKey(_groupButton));
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, 3);
      final alpha = tabOf(tester, 'Alpha host');
      final beta = tabOf(tester, 'Beta host');
      final gamma = tabOf(tester, 'Gamma host');

      fixture.attemptFor('beta').result.completeError(
        StateError('The SSH server refused the connection.'),
      );
      await tester.pump();
      await tester.pump();
      expect(
        inPane(beta, find.text("Couldn't connect to Beta host")),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(inPane(beta, find.byKey(_errorKey))).data,
        'The SSH server refused the connection.',
      );
      expect(
        tester
            .widget<ButtonStyleButton>(inPane(beta, find.byKey(_retryKey)))
            .onPressed,
        isNotNull,
      );
      // The other panes are untouched and still loading; the split is
      // intact.
      for (final tab in [alpha, gamma]) {
        expect(
          inPane(tab, find.text('Connecting to ${tab.title}')).hitTestable(),
          findsOneWidget,
        );
        expect(tabOf(tester, tab.title).status, 'connecting');
      }
      expect(layout(tester).sessionIds, [alpha.id, beta.id, gamma.id]);

      // Stopping one member does not stop the others either.
      await tester.tap(inPane(gamma, find.byKey(_stopKey)));
      await tester.pump();
      expect(inPane(gamma, find.text('Loading stopped')), findsOneWidget);
      expect(fixture.attemptFor('gamma').cancellation.isCancelled, isTrue);
      expect(fixture.attemptFor('alpha').cancellation.isCancelled, isFalse);
      expect(tabOf(tester, 'Alpha host').status, 'connecting');

      // Alpha connects in its pane while Beta shows its failure.
      fixture.attemptFor('alpha').result.complete(_Connection());
      await tester.pump();
      await tester.pump();
      expect(tabOf(tester, 'Alpha host').isConnected, isTrue);
      expect(inPane(alpha, _pane), findsNothing);
      expect(
        inPane(beta, find.text("Couldn't connect to Beta host")),
        findsOneWidget,
      );

      // Retry in the failed pane and in the stopped pane: each reconnects on
      // its own.
      await tester.tap(inPane(beta, find.byKey(_retryKey)));
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, 4);
      fixture.attempts[3].result.complete(_Connection());
      await tester.pump();
      await tester.pump();
      expect(tabOf(tester, 'Beta host').isConnected, isTrue);
      await tester.tap(inPane(gamma, find.byKey(_retryKey)));
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, 5);
      fixture.attempts[4].result.complete(_Connection());
      await tester.pump();
      await tester.pump();
      expect(tabOf(tester, 'Gamma host').isConnected, isTrue);
      expect(_pane, findsNothing);
      expect(find.byType(TerminalView), findsNWidgets(3));
      expect(layout(tester).sessionIds, [alpha.id, beta.id, gamma.id]);
      expect(fixture.attempts.map((a) => a.host), [
        'alpha.example.test',
        'beta.example.test',
        'gamma.example.test',
        'beta.example.test',
        'gamma.example.test',
      ]);
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('opening the Group again tries a failed member again in its '
      'pane and leaves the other members alone', (tester) async {
    final fixture = await open(tester);
    try {
      await tester.tap(find.byKey(_groupButton));
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, 3);
      final ids = layout(tester).sessionIds;
      final beta = tabOf(tester, 'Beta host');
      fixture.attemptFor('beta').result.completeError(
        StateError('The SSH server refused the connection.'),
      );
      await tester.pump();
      await tester.pump();
      expect(
        inPane(beta, find.text("Couldn't connect to Beta host")),
        findsOneWidget,
      );

      await showHome(tester);
      await tester.tap(find.byKey(_groupButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // The same split, with the failed pane loading again.
      expect(sessionTabs(tester), ['Alpha host', 'Beta host', 'Gamma host']);
      expect(layout(tester).sessionIds, ids);
      expect(tabBar(tester).groups, [ids]);
      expect(ids, contains(tabBar(tester).selectedId));
      expect(
        inPane(beta, find.text('Connecting to Beta host')).hitTestable(),
        findsOneWidget,
      );
      await fixture.pumpUntilAttempts(tester, 4);
      expect(fixture.attempts.last.host, 'beta.example.test');
      await tester.pump(const Duration(milliseconds: 200));
      expect(fixture.attempts, hasLength(4));
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('closing the split tab while its members connect cancels the '
      'remaining attempts and a late connection is closed', (tester) async {
    final fixture = await open(tester);
    try {
      await tester.tap(find.byKey(_groupButton));
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, 3);

      await tester.tap(find.byTooltip('Close this split group'));
      for (var i = 0; i < 20 && sessionTabs(tester).isNotEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(sessionTabs(tester), isEmpty);
      expect(fixture.app.terminalTabs, isEmpty);
      expect(
        fixture.attempts.every((a) => a.cancellation.isCancelled),
        isTrue,
      );
      await showHome(tester);
      expectHomeIdle(tester);

      // A connection that still arrives for a closed pane is closed, and
      // nothing comes back.
      final late = [for (final _ in fixture.attempts) _Connection()];
      for (final (index, attempt) in fixture.attempts.indexed) {
        attempt.result.complete(late[index]);
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(late.every((connection) => connection.closed), isTrue);
      expect(fixture.attempts, hasLength(3));
      expect(sessionTabs(tester), isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expectHomeIdle(tester);
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('a saved window set opens in its saved arrangement at once and '
      'connects its panes together', (tester) async {
    final fixture = await open(tester);
    try {
      await tester.tap(find.byKey(_pairChip));
      await tester.pump();
      expect(sessionTabs(tester), ['Alpha host', 'Beta host']);
      final alpha = tabOf(tester, 'Alpha host');
      final beta = tabOf(tester, 'Beta host');
      final workspace = layout(tester);
      void expectSavedArrangement() {
        final root = workspace.root as SessionWorkspaceSplit;
        expect(root.axis, Axis.vertical);
        expect(root.ratio, .3);
        expect((root.first as SessionWorkspacePane).sessionId, alpha.id);
        expect((root.second as SessionWorkspacePane).sessionId, beta.id);
      }

      expectSavedArrangement();
      expect(tabBar(tester).selectedId, beta.id);
      expect(_pane.hitTestable(), findsNWidgets(2));
      await fixture.pumpUntilAttempts(tester, 2);
      expect(fixture.attempts.every((a) => !a.result.isCompleted), isTrue);

      await showHome(tester);
      expectHomeIdle(tester);

      for (final attempt in fixture.attempts) {
        attempt.result.complete(_Connection());
      }
      await tester.pump();
      await tester.pump();
      expect(tabOf(tester, 'Alpha host').isConnected, isTrue);
      expect(tabOf(tester, 'Beta host').isConnected, isTrue);
      expectSavedArrangement();
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('members that do not fit under the tab limit are reported on '
      'the page; the ones that fit open in the split', (tester) async {
    final fixture = await open(tester);
    try {
      for (var i = 0; i < AppController.maxTerminalTabs - 2; i++) {
        unawaited(fixture.app.openTerminalTab(_delta).catchError((Object _) {}));
      }
      fixture.app.showWorkspacePage(WorkspacePage.hosts);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byKey(_groupButton));
      await tester.pump();
      await tester.pump();
      expect(fixture.app.terminalTabs, hasLength(AppController.maxTerminalTabs));
      final alpha = tabOf(tester, 'Alpha host');
      final beta = tabOf(tester, 'Beta host');
      expect(sessionTabs(tester), isNot(contains('Gamma host')));
      expect(layout(tester).sessionIds, [alpha.id, beta.id]);
      expect(tabBar(tester).groups, [
        [alpha.id, beta.id],
      ]);
      await fixture.pumpUntilAttempts(tester, AppController.maxTerminalTabs);

      // The signed-in workspace announces every connection in its message
      // bar; the reason a member could not open follows once the members
      // that did open have their result, so that it stays readable.
      final limit = find.descendant(
        of: find.byType(SnackBar),
        matching: find.text(
          'Up to 8 SSH terminal tabs can be open at once; close a tab first.',
        ),
      );
      expect(limit, findsNothing);
      fixture.attemptFor('alpha').result.complete(_Connection());
      await tester.pump();
      await tester.pump();
      expect(limit, findsNothing);
      fixture.attemptFor('beta').result.completeError(
        StateError('The SSH server refused the connection.'),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(limit, findsOneWidget);
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('unknown host keys of members are reviewed one at a time, each '
      'over its own pane', (tester) async {
    final fixture = await open(tester, reviewHostKeys: true);
    try {
      await tester.tap(find.byKey(_groupButton));
      await tester.pump();
      // Every member presents an unknown key at the same time.
      await fixture.pumpUntilAttempts(tester, 3);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      String reviewed() => ['alpha', 'beta', 'gamma'].singleWhere(
        (name) => find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.textContaining('$name.example.test'),
            )
            .evaluate()
            .isNotEmpty,
      );
      WorkspaceTab tabFor(String name) => tabOf(
        tester,
        '${name[0].toUpperCase()}${name.substring(1)} host',
      );

      final order = <String>[];
      for (var review = 0; review < 3; review++) {
        // One review, over the pane that asks.
        expect(find.byType(AlertDialog), findsOneWidget);
        final name = reviewed();
        order.add(name);
        expect(tabBar(tester).selectedId, tabFor(name).id);
        await tester.tap(find.widgetWithText(TextButton, 'Reject'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        // The rejected member says so in its pane, with retry.
        expect(
          inPane(tabFor(name), find.byKey(_retryKey)).evaluate(),
          isNotEmpty,
        );
      }
      expect(order.toSet(), {'alpha', 'beta', 'gamma'});
      expect(find.byType(AlertDialog), findsNothing);
      expect(fixture.attempts, hasLength(3));
      expect(layout(tester).sessionIds, hasLength(3));
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
  _Attempt(this.host, this.cancellation);
  final String host;
  final SshConnectCancellation cancellation;
  final result = Completer<SshConnection>();
}

class _Fixture {
  _Fixture(this.app, this.database, this.attempts, this.trusted);
  final AppController app;
  final ClientDatabase database;
  final List<_Attempt> attempts;

  /// Addresses whose key is trusted (with `reviewHostKeys`).
  final Set<String> trusted;

  _Attempt attemptFor(String name) =>
      attempts.firstWhere((attempt) => attempt.host == '$name.example.test');

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

  static Future<_Fixture> create({bool reviewHostKeys = false}) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final attempts = <_Attempt>[];
    final trusted = <String>{};
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
            knownHostTrustStatusForTesting: !reviewHostKeys
                ? null
                : ({
                    required host,
                    required port,
                    required algorithm,
                    required fingerprint,
                  }) async => trusted.contains(host)
                      ? KnownHostTrustStatus.trusted
                      : KnownHostTrustStatus.unknown,
            sshConnectorWithCancellationForTesting:
                ({
                  required host,
                  required credential,
                  required verifyHostKey,
                  required jumpHops,
                  required cancellation,
                  required onUserInfoRequest,
                }) async {
                  final attempt = _Attempt(host.address, cancellation);
                  attempts.add(attempt);
                  attempt.result.future.ignore();
                  if (reviewHostKeys &&
                      !await verifyHostKey(
                        'ssh-ed25519',
                        'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
                      )) {
                    throw StateError('The host key was not accepted.');
                  }
                  return attempt.result.future;
                },
          )
          ..api = ApiClient(baseUrl: 'https://server.test')
          ..session = AuthSession(
            accountId: 'account-together',
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
              id: 'credential-together',
              name: 'Credential',
              username: 'tester',
              secret: 'ephemeral-test-secret',
            ),
          )
          ..groups.add(const GroupRecord(id: _group, name: 'Fleet'))
          ..hosts.addAll([_alpha, _beta, _gamma, _delta])
          ..preferences.add(
            VaultPreferenceRecord.windowCombinations(
              value: WindowCombination.encode([pair]),
            ),
          );
    return _Fixture(app, database, attempts, trusted);
  }

  Future<void> cleanup(WidgetTester tester) async {
    for (final attempt in attempts) {
      if (!attempt.result.isCompleted) {
        attempt.result.completeError(const SshConnectCancelledException());
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => app.disconnectAllTerminalTabs());
    app.dispose();
    await tester.runAsync(() => database.close());
    await tester.binding.setSurfaceSize(null);
  }
}

class _Connection implements SshConnection {
  final _output = StreamController<String>.broadcast(sync: true);
  bool closed = false;

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    closed = true;
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
