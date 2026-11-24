import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

const _alphaHost = HostRecord(
  id: '33333333-3333-4333-8333-333333333333',
  name: 'Alpha',
  address: 'alpha.example.test',
  username: 'tester',
  credentialId: 'credential-alpha',
);
const _betaHost = HostRecord(
  id: '55555555-5555-4555-8555-555555555555',
  name: 'Beta',
  address: 'beta.example.test',
  username: 'tester',
  credentialId: 'credential-beta',
);
const _layoutId = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppController> signedIn(ClientDatabase database) async {
    final sodium = await SodiumSumoInit.init();
    final identity = DeviceIdentity.create(sodium);
    return AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
        sshConnectorForTesting:
            ({
              required host,
              required credential,
              required verifyHostKey,
            }) async => _Connection(),
      )
      ..session = AuthSession(
        accountId: 'account-test',
        accessToken: 'access-test',
        expiresIn: 3600,
        refreshToken: 'refresh-test',
        deviceId: identity.deviceId,
        vaults: const [],
      )
      ..identity = identity
      ..stage = ClientStage.workspace
      ..activeVault = const VaultDescriptor(
        id: '11111111-1111-4111-8111-111111111111',
        role: 'owner',
        activeKeyEpoch: '1',
        membershipVersion: '1',
      )
      ..credentials.addAll(const [
        CredentialRecord(
          id: 'credential-alpha',
          name: 'Alpha credential',
          username: 'tester',
          secret: 'ephemeral-test-secret',
        ),
        CredentialRecord(
          id: 'credential-beta',
          name: 'Beta credential',
          username: 'tester',
          secret: 'ephemeral-test-secret',
        ),
      ])
      ..hosts.addAll(const [_alphaHost, _betaHost]);
  }

  Future<void> pumpShell(WidgetTester tester, AppController app) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: AnimatedBuilder(
          animation: app,
          builder: (context, _) => AppShell(controller: app),
        ),
      ),
    );
    await tester.pump();
  }

  // The native clients used to show every session beside a "Connections"
  // host list, inside a padded frame; only the browser gave it the area.
  testWidgets('a session takes the whole area, with no host list beside it '
      'and no frame around it; closing the last tab shows Home', (
    tester,
  ) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = await signedIn(database);
    var shellMounted = false;
    try {
      await app.openTerminalTab(_alphaHost);
      final alpha = app.activeTerminalTab!;
      await pumpShell(tester, app);
      shellMounted = true;

      expect(app.page, WorkspacePage.terminal);
      expect(find.byType(TerminalView), findsOneWidget);
      final shell = tester.getRect(find.byType(AppShell));
      final area = tester.getRect(find.byType(SessionWorkspaceView));
      expect(area.left, shell.left);
      expect(area.right, shell.right);
      // The other saved host is reached from Home, not from a list here.
      expect(find.text('Beta'), findsNothing);

      // Closing waits on timers of the test clock: pump instead of awaiting.
      unawaited(app.closeTerminalTab(alpha.id));
      await tester.pumpAndSettle();
      // Nothing is left to show: Home, not an empty session page.
      expect(app.page, WorkspacePage.hosts);
      expect(find.byType(TerminalView), findsNothing);
      expect(find.text('Secure terminal workspace'), findsNothing);
      expect(find.text('Beta'), findsWidgets);
    } finally {
      if (shellMounted) await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('a staged layout previews in the area, then keeps its tabs and '
      'its way out in one row above the session', (tester) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = await signedIn(database);
    app.savedWorkspaces.add(
      WorkspaceRecord.fromHostIds(
        id: _layoutId,
        name: 'Pair layout',
        hostIds: [_alphaHost.id, _betaHost.id],
        activeIndex: 0,
      ),
    );
    var shellMounted = false;
    try {
      await pumpShell(tester, app);
      shellMounted = true;
      app.stageWorkspace(_layoutId);
      await tester.pumpAndSettle();

      final layout = app.savedWorkspaces.single;
      Finder connect(int pane) => find.byKey(
        ValueKey('workspace-connect-$_layoutId-${layout.panes[pane].paneId}'),
      );
      // Nothing connected: the preview is the content, staged, not a column.
      expect(app.page, WorkspacePage.terminal);
      expect(find.text('Pair layout'), findsOneWidget);
      expect(find.byKey(const ValueKey('workspace-staged-bar')), findsNothing);
      expect(connect(0), findsOneWidget);
      expect(connect(1), findsOneWidget);
      expect(app.terminalTabs, isEmpty);

      await tester.tap(connect(0));
      await tester.pumpAndSettle();
      expect(app.terminalTabs.single.host?.id, _alphaHost.id);
      expect(find.byType(TerminalView), findsOneWidget);
      // The session has the whole width; the layout is one row above it.
      final shell = tester.getRect(find.byType(AppShell));
      final area = tester.getRect(find.byType(SessionWorkspaceView));
      final bar = tester.getRect(
        find.byKey(const ValueKey('workspace-staged-bar')),
      );
      expect(area.left, shell.left);
      expect(area.right, shell.right);
      expect(bar.bottom, area.top);
      expect(find.text('Pair layout'), findsOneWidget);

      // The second tab of the layout is still one tap away.
      await tester.tap(connect(1));
      await tester.pumpAndSettle();
      expect(app.terminalTabs.map((tab) => tab.host?.id), [
        _alphaHost.id,
        _betaHost.id,
      ]);

      await tester.tap(find.byKey(const ValueKey('workspace-clear-staged')));
      await tester.pumpAndSettle();
      expect(app.activeSavedWorkspaceId, isNull);
      expect(find.byKey(const ValueKey('workspace-staged-bar')), findsNothing);
      // The sessions stay open as ordinary tabs.
      expect(app.terminalTabs, hasLength(2));
      expect(find.byType(TerminalView), findsOneWidget);
    } finally {
      if (shellMounted) await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });

  testWidgets('closing a staged preview with nothing open shows Home', (
    tester,
  ) async {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app = await signedIn(database);
    app.savedWorkspaces.add(
      WorkspaceRecord.fromHostIds(
        id: _layoutId,
        name: 'Pair layout',
        hostIds: [_alphaHost.id, _betaHost.id],
        activeIndex: 0,
      ),
    );
    var shellMounted = false;
    try {
      await pumpShell(tester, app);
      shellMounted = true;
      app.stageWorkspace(_layoutId);
      await tester.pumpAndSettle();
      expect(app.page, WorkspacePage.terminal);

      await tester.tap(find.byKey(const ValueKey('workspace-clear-staged')));
      await tester.pumpAndSettle();
      expect(app.page, WorkspacePage.hosts);
      expect(find.text('Secure terminal workspace'), findsNothing);
    } finally {
      if (shellMounted) await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await database.close();
    }
  });
}

class _Connection implements SshConnection {
  final StreamController<String> _output = StreamController<String>.broadcast(
    sync: true,
  );

  @override
  late final portForwards = SshPortForwardManager(
    _FakeSshClient(),
    platform: const _UnsupportedPortForwardPlatform(),
  );

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    await portForwards.closeAll();
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshClient extends Fake implements SSHClient {}

class _UnsupportedPortForwardPlatform implements SshPortForwardPlatform {
  const _UnsupportedPortForwardPlatform();

  @override
  bool get isSupported => false;

  @override
  String? get unsupportedReason => 'No local listeners in this test.';

  @override
  Future<SshPortForwardHandle> start(
    SSHClient client,
    SshPortForwardProfile profile,
  ) => throw UnsupportedError('No local listeners in this test.');
}
