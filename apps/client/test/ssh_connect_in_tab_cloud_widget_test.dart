import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/terminal/connect_progress.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

import 'support/l10n_fixture.dart';

// Signed-in workspace: an SSH attempt lives in its own tab. The home page
// shows no loading state for it and its search / quick connect do not wait.

const _vault = '11111111-1111-4111-8111-111111111111';
const _alpha = HostRecord(
  id: 'host-alpha',
  name: 'Alpha host',
  address: 'alpha.example.test',
  username: 'tester',
  credentialId: 'credential-in-tab',
);
const _beta = HostRecord(
  id: 'host-beta',
  name: 'Beta host',
  address: 'beta.example.test',
  username: 'tester',
  credentialId: 'credential-in-tab',
);

const _homeTab = ValueKey('workspace-tab-hosts');
const _homeSearch = ValueKey('cloud_home_search');
final _pane = find.byKey(const ValueKey('connect_progress_pane'));
final _retry = find.byKey(const ValueKey('connect_progress_retry'));
final _close = find.byKey(const ValueKey('connect_progress_close'));

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

  Future<void> showHome(WidgetTester tester) async {
    await tester.tap(find.byKey(_homeTab));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// The home page is in front and shows no waiting indicator or message.
  void expectHomeIdle(WidgetTester tester) {
    expect(tabBar(tester).selectedId, 'hosts');
    expect(find.byKey(_homeSearch).hitTestable(), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  }

  Future<void> submitHomeSearch(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(_homeSearch), text);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
  }

  testWidgets('a host card opens a selected tab that shows the loading; the '
      'home page shows none and opens a second host meanwhile', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final fixture = await _Fixture.create();
    try {
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('host_connect_host-alpha')));
      await tester.pump();
      expect(sessionTabs(tester), ['Alpha host']);
      expect(tabBar(tester).selectedId, tabOf(tester, 'Alpha host').id);
      expect(_pane.hitTestable(), findsOneWidget);
      expect(find.text('Connecting to Alpha host'), findsOneWidget);
      expect(tabOf(tester, 'Alpha host').status, 'connecting');
      await fixture.pumpUntilAttempts(tester, 1);

      await showHome(tester);
      expectHomeIdle(tester);

      await tester.tap(find.byKey(const ValueKey('host_connect_host-beta')));
      await tester.pump();
      expect(sessionTabs(tester), ['Alpha host', 'Beta host']);
      expect(tabBar(tester).selectedId, tabOf(tester, 'Beta host').id);
      expect(find.text('Connecting to Beta host'), findsOneWidget);
      await fixture.pumpUntilAttempts(tester, 2);
      expect(tabOf(tester, 'Alpha host').status, 'connecting');
      expect(tabOf(tester, 'Beta host').status, 'connecting');
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('quick connect and Enter in the home search open their tab and '
      'do not wait for the connection', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final fixture = await _Fixture.create();
    try {
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pump();
      await submitHomeSearch(tester, 'ssh tester@alpha.example.test');
      expect(sessionTabs(tester), ['Alpha host']);
      expect(_pane.hitTestable(), findsOneWidget);
      await fixture.pumpUntilAttempts(tester, 1);

      // While that tab is still connecting, quick connect takes the next one.
      await showHome(tester);
      expectHomeIdle(tester);
      await submitHomeSearch(tester, 'ssh tester@beta.example.test');
      expect(sessionTabs(tester), ['Alpha host', 'Beta host']);
      expect(tabBar(tester).selectedId, tabOf(tester, 'Beta host').id);
      await fixture.pumpUntilAttempts(tester, 2);

      // Enter on a search result connects it as well.
      await showHome(tester);
      await submitHomeSearch(tester, 'Beta');
      expect(sessionTabs(tester), ['Alpha host', 'Beta host', 'Beta host']);
      await fixture.pumpUntilAttempts(tester, 3);
      expect(fixture.attempts.map((attempt) => attempt.host), [
        'alpha.example.test',
        'beta.example.test',
        'beta.example.test',
      ]);
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('failure, retry, success and a later reconnect all stay in the '
      'tab', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final fixture = await _Fixture.create();
    try {
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('host_connect_host-alpha')));
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, 1);
      final tab = fixture.app.activeTerminalTab!;

      fixture.attempts[0].result.completeError(
        StateError('The SSH server refused the connection.'),
      );
      await tester.pump();
      await tester.pump();
      expect(tabBar(tester).selectedId, tab.id);
      expect(find.text("Couldn't connect to Alpha host"), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('connect_progress_error')))
            .data,
        'The SSH server refused the connection.',
      );
      expect(tester.widget<ButtonStyleButton>(_retry).onPressed, isNotNull);
      expect(tester.widget<ButtonStyleButton>(_close).onPressed, isNotNull);

      await tester.tap(_retry);
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, 2);
      final first = _Connection();
      fixture.attempts[1].result.complete(first);
      await tester.pump();
      await tester.pump();
      expect(tab.state, 'connected');
      expect(tab.connectProgress.phase, ConnectPhase.idle);
      expect(_pane, findsNothing);
      expect(find.byType(TerminalView), findsOneWidget);
      expect(fixture.app.terminalTabs, [tab]);

      // The server ends the session: the automatic reconnect reuses the same
      // tab, and the home page does not wait for it either.
      await tester.pumpAndSettle();
      final measuredSize = (tab.terminal.viewWidth, tab.terminal.viewHeight);
      expect(first.sizes.last, measuredSize);
      expect(measuredSize, isNot((100, 30)));
      await first.end();
      await tester.pump();
      expect(tab.state, 'disconnected');
      await tester.pump(const Duration(seconds: 5));
      await fixture.pumpUntilAttempts(tester, 3);
      expect(tab.state, 'connecting');
      await showHome(tester);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final retainedSize = (tab.terminal.viewWidth, tab.terminal.viewHeight);
      final reconnected = _Connection();
      fixture.attempts[2].result.complete(reconnected);
      await tester.pump();
      await tester.pump();
      expect(tab.state, 'connected');
      expect(fixture.app.terminalTabs, [tab]);
      expect(fixture.attempts, hasLength(3));
      expect(
        reconnected.sizes.first,
        retainedSize,
        reason: 'a retained view needs no layout to replay its PTY size',
      );
      await tester.tap(find.byKey(ValueKey('workspace-tab-${tab.id}')));
      await tester.pumpAndSettle();
      expect(
        (tab.terminal.viewWidth, tab.terminal.viewHeight),
        measuredSize,
        reason: 'the same window has the same grid as the fresh connection',
      );
      expect(reconnected.sizes.last, measuredSize);
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

  static Future<_Fixture> create() async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final attempts = <_Attempt>[];
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
                }) {
                  final attempt = _Attempt(host.address, cancellation);
                  attempts.add(attempt);
                  return attempt.result.future;
                },
          )
          ..api = ApiClient(baseUrl: 'https://server.test')
          ..session = AuthSession(
            accountId: 'account-in-tab',
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
              id: 'credential-in-tab',
              name: 'Credential',
              username: 'tester',
              secret: 'ephemeral-test-secret',
            ),
          )
          ..hosts.addAll([_alpha, _beta]);
    return _Fixture(app, database, attempts);
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
  final sizes = <(int, int)>[];

  @override
  Stream<String> get output => _output.stream;

  /// The remote side closes the session.
  Future<void> end() => _output.close();

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) => sizes.add((columns, rows));

  @override
  Future<void> close() async {
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
