import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/platform/native_coordination.dart';
import 'package:aterm_client/ssh/local_profile_ssh_controller.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

import 'support/l10n_fixture.dart';

// Local profile: a Group or a saved window set opens as one split tab right
// away. Its members connect at the same time, each in its own pane, and the
// home page neither waits for them nor shows a stop control.

const _password = 'correct horse battery staple';
const _fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _connectFailure =
    "Couldn't connect to the local SSH Host. Check the network and "
    'credentials, then try again.';

const _homeTab = ValueKey('workspace-tab-hosts');
const _homeSearch = ValueKey('local_home_search');
const _homeError = ValueKey('local_profile_error');
const _approve = ValueKey('local_ssh_host_key_approve');
const _stopKey = ValueKey('connect_progress_stop');
const _retryKey = ValueKey('connect_progress_retry');
const _errorKey = ValueKey('connect_progress_error');

final _pane = find.byKey(
  const ValueKey('connect_progress_pane'),
  skipOffstage: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');

  late Directory directory;
  late LocalProfileCatalog catalog;
  late LocalProfileService profileService;
  late VaultCrypto crypto;
  late LocalProfileRecord profileRecord;
  late String alphaId, betaId, deltaId, groupId;
  late WindowCombination pair, twins;
  late List<LocalVaultDatabase> openedDatabases;
  late _Ssh ssh;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'atermius-open-together-',
    );
    coordinationDirectory = () async =>
        Directory('${directory.path}/coordination');
    catalog = LocalProfileCatalog.forTesting(
      NativeDatabase(File('${directory.path}/catalog.sqlite')),
    );
    profileService = LocalProfileService(catalog: catalog, crypto: crypto);
    final seedProfile = await profileService.create(password: _password);
    profileRecord = seedProfile.record;
    final seedDatabase = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
      profileId: profileRecord.profileId,
      localDataDomainId: profileRecord.localDataDomainId,
      localVaultId: profileRecord.localVaultId,
    );
    final seedRepository = LocalHostRepository(
      database: seedDatabase,
      profile: seedProfile,
      crypto: crypto,
    );
    final credentialId = const Uuid().v4();
    await seedRepository.createCredential(
      CredentialRecord(
        id: credentialId,
        name: 'open together credential',
        username: 'local-user',
        kind: AuthKind.password,
        secret: 'test-only-local-password',
      ),
    );
    groupId = const Uuid().v4();
    await seedRepository.createGroup(GroupRecord(id: groupId, name: 'Fleet'));
    Future<String> host(String name, String address, {String? group}) async =>
        (await seedRepository.createHost(
          HostRecord(
            id: const Uuid().v4(),
            name: name,
            address: address,
            port: 2222,
            username: 'local-user',
            credentialId: credentialId,
            groupId: group,
          ),
        )).id;
    alphaId = await host('Alpha host', 'alpha.example.test', group: groupId);
    betaId = await host('Beta host', 'beta.example.test', group: groupId);
    await host('Gamma host', 'gamma.example.test', group: groupId);
    deltaId = await host('Delta host', 'delta.example.test');
    // Alpha above Beta, Alpha taking 30% of the height; Beta is the active
    // pane.
    pair = WindowCombination(
      id: 'pair',
      name: 'Pair',
      panes: [
        CombinationPane(kind: 'ssh', hostId: alphaId),
        CombinationPane(kind: 'ssh', hostId: betaId),
      ],
      tree: const {
        'axis': 'vertical',
        'ratio': .3,
        'first': {'pane': 0},
        'second': {'pane': 1},
      },
      activePane: 1,
    );
    // The same Host in two panes.
    twins = WindowCombination(
      id: 'twins',
      name: 'Twins',
      panes: [
        CombinationPane(kind: 'ssh', hostId: deltaId),
        CombinationPane(kind: 'ssh', hostId: deltaId),
      ],
      tree: const {
        'axis': 'horizontal',
        'ratio': .5,
        'first': {'pane': 0},
        'second': {'pane': 1},
      },
      activePane: 0,
    );
    await seedRepository.createPreference(
      scope: 'workspace',
      key: VaultPreferenceRecord.windowCombinationsKey,
      value: WindowCombination.encode([pair, twins]),
      platformFamily: 'all',
    );
    await seedDatabase.close();
    await seedProfile.lock();
    openedDatabases = [];
    ssh = _Ssh();
  });

  tearDown(() async {
    for (final database in openedDatabases.reversed) {
      try {
        await database.close();
      } on Object {
        // LocalProfileFlow may already have closed it while disposing.
      }
    }
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> pumpFor(WidgetTester tester, bool Function() done) async {
    for (var attempt = 0; attempt < 120 && !done(); attempt++) {
      await tester.pump(const Duration(milliseconds: 60));
      if (done()) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    expect(done(), isTrue);
    await tester.pump();
  }

  Future<void> pumpUntilIdle(WidgetTester tester) async {
    var idleFrames = 0;
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      final waiting =
          find.byType(LinearProgressIndicator).evaluate().isNotEmpty ||
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      idleFrames = waiting ? 0 : idleFrames + 1;
      if (idleFrames >= 4) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    fail('LocalProfileFlow did not finish its pending operation.');
  }

  Future<void> openProfile(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme().copyWith(platform: TargetPlatform.windows),
        home: LocalProfileFlow(
          catalog: catalog,
          service: profileService,
          crypto: crypto,
          onExit: () {},
          quarantineRegistry: DatabaseQuarantineRegistry(),
          databaseFactory: (profile, {required mode}) async {
            final record = profile.record;
            final database = await LocalVaultDatabase.openForTesting(
              executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
              profileId: record.profileId,
              localDataDomainId: record.localDataDomainId,
              localVaultId: record.localVaultId,
              mode: mode,
            );
            openedDatabases.add(database);
            return database;
          },
          sshControllerFactory: (repository) => LocalProfileSshController(
            repository: repository,
            serviceForTesting: ssh.service(repository),
          ),
        ),
      ),
    );
    await pumpUntilIdle(tester);
    await tester.tap(
      find.byKey(ValueKey('local_profile_${profileRecord.profileId}')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('local_profile_unlock_password')),
      _password,
    );
    await tester.tap(find.byKey(const ValueKey('local_profile_unlock_button')));
    await pumpUntilIdle(tester);
  }

  Future<void> closeFlow(WidgetTester tester) async {
    ssh.hold = false;
    await tester.pumpWidget(const SizedBox.shrink());
    // Closing the profile finishes its session-log writes on real I/O.
    for (var i = 0; i < 20; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();
  }

  WorkspaceTabBar tabBar(WidgetTester tester) =>
      tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
  List<WorkspaceTab> tabsOf(WidgetTester tester, String title) =>
      tabBar(tester).tabs.where((tab) => tab.title == title).toList();
  WorkspaceTab tabOf(WidgetTester tester, String title) =>
      tabsOf(tester, title).single;
  List<String> sessionTabs(WidgetTester tester) => [
    for (final tab in tabBar(tester).tabs)
      if (!tab.isHome) tab.title,
  ];
  SessionWorkspaceController layout(WidgetTester tester) => tester
      .widget<SessionWorkspaceView>(
        find.byType(SessionWorkspaceView, skipOffstage: false),
      )
      .controller;

  /// The connect progress surface inside the pane of [tab].
  Finder inPane(WorkspaceTab tab, Finder matching) => find.descendant(
    of: find.byKey(ValueKey('connect_progress_${tab.id}')),
    matching: matching,
  );
  String? paneError(WidgetTester tester, WorkspaceTab tab) =>
      tester.widget<Text>(inPane(tab, find.byKey(_errorKey))).data;

  Future<void> showHome(WidgetTester tester) async {
    await tester.tap(find.byKey(_homeTab));
    await tester.pump();
    expect(tabBar(tester).selectedId, 'hosts');
  }

  /// The home page is in front and shows no waiting indicator, stop control,
  /// connection error or message.
  void expectHomeIdle(WidgetTester tester) {
    expect(tabBar(tester).selectedId, 'hosts');
    expect(find.byKey(_homeSearch).hitTestable(), findsOneWidget);
    final body = tester.widget<IndexedStack>(
      find
          .ancestor(
            of: find.byKey(_homeSearch),
            matching: find.byType(IndexedStack),
          )
          .first,
    );
    expect(body.index, 0);
    final home = find.byWidget(body.children.first, skipOffstage: false);
    expect(home, findsOneWidget);
    for (final indicator in [
      LinearProgressIndicator,
      CircularProgressIndicator,
    ]) {
      expect(
        find.descendant(
          of: home,
          matching: find.byType(indicator, skipOffstage: false),
          skipOffstage: false,
        ),
        findsNothing,
      );
    }
    expect(
      find.descendant(
        of: home,
        matching: find.byIcon(
          Icons.stop_circle_outlined,
          skipOffstage: false,
        ),
        skipOffstage: false,
      ),
      findsNothing,
    );
    expect(find.byKey(_homeError, skipOffstage: false), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    // Groups and window sets can be opened again.
    expect(
      tester
          .widget<ActionChip>(find.byKey(ValueKey('local_host_group_$groupId')))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<InputChip>(
            find.byKey(const ValueKey('window-combination-pair')),
          )
          .onPressed,
      isNotNull,
    );
  }

  /// Approves the host-key review for [address] once it is the only dialog.
  Future<void> approveHostKey(WidgetTester tester, String address) async {
    await pumpFor(tester, () {
      final reviews = tester.widgetList<SelectableText>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(SelectableText),
        ),
      );
      return reviews.length == 1 &&
          reviews.single.data!.contains(address) &&
          find.byKey(_approve).hitTestable().evaluate().length == 1;
    });
    await tester.tap(find.byKey(_approve));
    await tester.pump();
  }

  Future<void> openGroup(WidgetTester tester) async {
    await tester.tap(find.byKey(ValueKey('local_host_group_$groupId')));
    await tester.pump();
  }

  testWidgets('a Group opens as one split tab at once: every member connects '
      'at the same time in its own pane and the home page stays usable', (
    tester,
  ) async {
    await openProfile(tester);
    ssh.hold = true;

    await openGroup(tester);
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
    expect(find.byKey(_homeSearch).hitTestable(), findsNothing);
    expect(_pane.hitTestable(), findsNWidgets(3));
    for (final tab in members) {
      expect(
        inPane(tab, find.text('Connecting to ${tab.title}')).hitTestable(),
        findsOneWidget,
      );
      expect(inPane(tab, find.byKey(_stopKey)).hitTestable(), findsOneWidget);
    }

    // No member waits for another: all three transports are requested while
    // none of them has answered.
    await pumpFor(tester, () => ssh.requests.length == 3);
    expect(ssh.requests.toSet(), {
      'alpha.example.test',
      'beta.example.test',
      'gamma.example.test',
    });
    expect(ssh.clients, isEmpty);
    for (final tab in members) {
      expect(tabOf(tester, tab.title).status, 'connecting');
      expect(
        inPane(tab, find.text('Opening the connection')),
        findsOneWidget,
      );
    }

    // The home page does not wait, has no stop control and opens another
    // Host while the Group is still connecting.
    await showHome(tester);
    expectHomeIdle(tester);
    await tester.tap(find.byKey(ValueKey('local_host_$deltaId')));
    await tester.pump();
    expect(sessionTabs(tester), [
      'Alpha host',
      'Beta host',
      'Gamma host',
      'Delta host',
    ]);
    expect(tabBar(tester).selectedId, tabOf(tester, 'Delta host').id);
    await pumpFor(tester, () => ssh.requests.length == 4);
    expect(tabBar(tester).groups, [ids]);

    // Opening the Group again while it connects shows the same panes; no
    // member is connected a second time.
    await showHome(tester);
    await openGroup(tester);
    expect(sessionTabs(tester), hasLength(4));
    expect(layout(tester).sessionIds, ids);
    expect(ids, contains(tabBar(tester).selectedId));
    await tester.pump(const Duration(milliseconds: 200));
    expect(ssh.requests, hasLength(4));

    await closeFlow(tester);
  });

  testWidgets('a member that fails or is stopped shows it with retry in its '
      'own pane; the other members keep connecting and connect', (
    tester,
  ) async {
    await openProfile(tester);
    ssh.hold = true;
    await openGroup(tester);
    await pumpFor(tester, () => ssh.requests.length == 3);
    final alpha = tabOf(tester, 'Alpha host');
    final beta = tabOf(tester, 'Beta host');
    final gamma = tabOf(tester, 'Gamma host');
    Completer<SSHSocket> socketOf(String address) =>
        ssh.pending[ssh.requests.indexOf(address)];

    socketOf('beta.example.test').completeError(
      const SocketException('refused'),
    );
    await pumpFor(
      tester,
      () => inPane(
        beta,
        find.text("Couldn't connect to Beta host"),
      ).evaluate().isNotEmpty,
    );
    expect(paneError(tester, beta), _connectFailure);
    expect(
      tester
          .widget<ButtonStyleButton>(inPane(beta, find.byKey(_retryKey)))
          .onPressed,
      isNotNull,
    );
    // The other panes are untouched and still loading; the split is intact.
    for (final tab in [alpha, gamma]) {
      expect(
        inPane(tab, find.text('Connecting to ${tab.title}')).hitTestable(),
        findsOneWidget,
      );
      expect(tabOf(tester, tab.title).status, 'connecting');
    }
    expect(layout(tester).sessionIds, [alpha.id, beta.id, gamma.id]);
    expect(find.byKey(_homeError, skipOffstage: false), findsNothing);
    expect(find.byType(SnackBar), findsNothing);

    // Stopping one member does not stop the others either.
    await tester.tap(inPane(gamma, find.byKey(_stopKey)));
    await tester.pump();
    expect(inPane(gamma, find.text('Loading stopped')), findsOneWidget);
    expect(tabOf(tester, 'Alpha host').status, 'connecting');
    expect(socketOf('alpha.example.test').isCompleted, isFalse);

    // Alpha connects in its pane while Beta shows its failure.
    ssh.hold = false;
    socketOf('alpha.example.test').complete(_Socket());
    await approveHostKey(tester, 'alpha.example.test');
    await pumpFor(tester, () => tabOf(tester, 'Alpha host').isConnected);
    expect(inPane(alpha, _pane), findsNothing);
    expect(paneError(tester, beta), _connectFailure);
    expect(inPane(gamma, find.text('Loading stopped')), findsOneWidget);

    // Retry in the failed pane and in the stopped pane: each reconnects on
    // its own.
    await tester.tap(inPane(beta, find.byKey(_retryKey)));
    await approveHostKey(tester, 'beta.example.test');
    await pumpFor(tester, () => tabOf(tester, 'Beta host').isConnected);
    await tester.tap(inPane(gamma, find.byKey(_retryKey)));
    await approveHostKey(tester, 'gamma.example.test');
    await pumpFor(tester, () => tabOf(tester, 'Gamma host').isConnected);
    expect(_pane, findsNothing);
    expect(ssh.authenticated, 3);
    expect(layout(tester).sessionIds, [alpha.id, beta.id, gamma.id]);
    expect(sessionTabs(tester), ['Alpha host', 'Beta host', 'Gamma host']);

    await closeFlow(tester);
  });

  testWidgets('opening the Group again tries a failed member again in its '
      'pane and leaves the other members alone', (tester) async {
    await openProfile(tester);
    ssh.hold = true;
    await openGroup(tester);
    await pumpFor(tester, () => ssh.requests.length == 3);
    final ids = layout(tester).sessionIds;
    final beta = tabOf(tester, 'Beta host');
    ssh.pending[ssh.requests.indexOf('beta.example.test')].completeError(
      const SocketException('refused'),
    );
    await pumpFor(
      tester,
      () => inPane(
        beta,
        find.text("Couldn't connect to Beta host"),
      ).evaluate().isNotEmpty,
    );

    await showHome(tester);
    await openGroup(tester);
    // The same split, with the failed pane loading again.
    expect(sessionTabs(tester), ['Alpha host', 'Beta host', 'Gamma host']);
    expect(layout(tester).sessionIds, ids);
    expect(tabBar(tester).groups, [ids]);
    expect(ids, contains(tabBar(tester).selectedId));
    expect(
      inPane(beta, find.text('Connecting to Beta host')).hitTestable(),
      findsOneWidget,
    );
    await pumpFor(tester, () => ssh.requests.length == 4);
    expect(ssh.requests.last, 'beta.example.test');
    await tester.pump(const Duration(milliseconds: 200));
    expect(ssh.requests, hasLength(4));

    await closeFlow(tester);
  });

  testWidgets('closing the split tab while its members connect cancels the '
      'remaining attempts: late sockets are closed and nothing comes back', (
    tester,
  ) async {
    await openProfile(tester);
    ssh.hold = true;
    await openGroup(tester);
    await pumpFor(tester, () => ssh.requests.length == 3);

    await tester.tap(find.byTooltip('Close this split group'));
    await pumpFor(tester, () => sessionTabs(tester).isEmpty);
    expect(_pane, findsNothing);
    expectHomeIdle(tester);

    // The sockets the cancelled attempts were waiting for arrive afterwards.
    final late = [for (final _ in ssh.pending) _Socket()];
    for (final (index, socket) in ssh.pending.indexed) {
      socket.complete(late[index]);
    }
    await pumpFor(tester, () => late.every((socket) => socket.closed));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 6));
    expect(ssh.clients, isEmpty, reason: 'no handshake on a closed pane');
    expect(ssh.requests, hasLength(3));
    expect(find.byType(AlertDialog), findsNothing);
    expect(sessionTabs(tester), isEmpty);
    expectHomeIdle(tester);

    await closeFlow(tester);
  });

  testWidgets('a saved window set opens in its saved arrangement at once and '
      'connects its panes together', (tester) async {
    await openProfile(tester);
    ssh.hold = true;

    await tester.tap(find.byKey(const ValueKey('window-combination-pair')));
    // The set is read from the encrypted profile first; nothing else is
    // awaited before the split is shown.
    await pumpFor(tester, () => sessionTabs(tester).isNotEmpty);
    expect(sessionTabs(tester), ['Alpha host', 'Beta host']);
    final alpha = tabOf(tester, 'Alpha host');
    final beta = tabOf(tester, 'Beta host');
    void expectSavedArrangement() {
      final root = layout(tester).root as SessionWorkspaceSplit;
      expect(root.axis, Axis.vertical);
      expect(root.ratio, .3);
      expect((root.first as SessionWorkspacePane).sessionId, alpha.id);
      expect((root.second as SessionWorkspacePane).sessionId, beta.id);
    }

    expectSavedArrangement();
    expect(tabBar(tester).selectedId, beta.id);
    expect(_pane.hitTestable(), findsNWidgets(2));
    await pumpFor(tester, () => ssh.requests.length == 2);
    expect(ssh.clients, isEmpty);
    expect(tabOf(tester, 'Alpha host').status, 'connecting');
    expect(tabOf(tester, 'Beta host').status, 'connecting');

    await showHome(tester);
    expectHomeIdle(tester);

    // Both panes finish in place.
    ssh.hold = false;
    for (final socket in ssh.pending) {
      socket.complete(_Socket());
    }
    await approveHostKey(tester, 'alpha.example.test');
    await approveHostKey(tester, 'beta.example.test');
    await pumpFor(
      tester,
      () =>
          tabOf(tester, 'Alpha host').isConnected &&
          tabOf(tester, 'Beta host').isConnected,
    );
    await tester.pumpAndSettle();
    expectSavedArrangement();
    expect(_pane, findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(ssh.authenticated, 2);

    await closeFlow(tester);
  });

  testWidgets('unknown host keys of members are reviewed one at a time, each '
      'over its own pane; a Host shown in two panes is reviewed once', (
    tester,
  ) async {
    await openProfile(tester);
    await openGroup(tester);
    for (final name in ['Alpha', 'Beta', 'Gamma']) {
      final address = '${name.toLowerCase()}.example.test';
      await pumpFor(
        tester,
        () => find.byKey(_approve).hitTestable().evaluate().isNotEmpty,
      );
      // Let every member reach its own review before answering this one.
      await pumpFor(tester, () => ssh.clients.length >= 3);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tabBar(tester).selectedId, tabOf(tester, '$name host').id);
      await approveHostKey(tester, address);
    }
    await pumpFor(
      tester,
      () => ['Alpha host', 'Beta host', 'Gamma host'].every(
        (name) => tabOf(tester, name).isConnected,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(ssh.authenticated, 3);

    // The same new Host twice: the answer given for the first pane also
    // serves the second one.
    await showHome(tester);
    await tester.tap(find.byKey(const ValueKey('window-combination-twins')));
    await pumpFor(tester, () => tabsOf(tester, 'Delta host').length == 2);
    await approveHostKey(tester, 'delta.example.test');
    await pumpFor(
      tester,
      () => tabsOf(tester, 'Delta host').every((tab) => tab.isConnected),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(ssh.authenticated, 5);
    expect(_pane, findsNothing);

    await closeFlow(tester);
  });
}

/// SSH transport double. Sockets either arrive at once or, while [hold] is
/// set, when the test completes the matching entry of [pending]. A socket
/// that arrived is followed by a handshake that presents [_fingerprint] and
/// authenticates.
class _Ssh {
  bool hold = false;

  /// Addresses of every socket request, in order.
  final requests = <String>[];
  final pending = <Completer<SSHSocket>>[];
  final clients = <_Client>[];
  final sessions = <_Session>[];
  int authenticated = 0;

  SshService service(LocalHostRepository repository) => SshService(
    api: null,
    deviceId: 'ssh-connect-in-tab-test-device',
    useRelay: false,
    knownHostDecisionLock: repository.knownHostDecisionLock,
    directSocketConnector: (address, _) {
      requests.add(address);
      if (!hold) return Future<SSHSocket>.value(_Socket());
      final socket = Completer<SSHSocket>();
      pending.add(socket);
      return socket.future;
    },
    sshClientFactory:
        ({
          required socket,
          required username,
          required identities,
          required onPasswordRequest,
          required onUserInfoRequest,
          required onVerifyHostKey,
          required handshakeTimeout,
          required authTimeout,
        }) {
          final session = _Session();
          final client = _Client(session, () async {
            final approved = await onVerifyHostKey(
              'ssh-ed25519',
              Uint8List.fromList(utf8.encode(_fingerprint)),
            );
            if (!approved) throw SSHAuthFailError('untrusted key');
            authenticated++;
            sessions.add(session);
          });
          clients.add(client);
          return client;
        },
  );
}

class _Client implements SSHClient {
  _Client(this.session, Future<void> Function() authenticate)
    : _authenticated = authenticate();

  final _Session session;
  final Future<void> _authenticated;
  bool closed = false;

  @override
  Future<void> get authenticated => _authenticated;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async => session;

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements SSHSession {
  final _stdout = StreamController<Uint8List>(sync: true);
  final _stderr = StreamController<Uint8List>(sync: true);
  final written = <int>[];

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  void emit(String text) => _stdout.add(Uint8List.fromList(utf8.encode(text)));

  @override
  void close() {
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }

  @override
  void write(Uint8List data) => written.addAll(data);

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Socket implements SSHSocket {
  _Socket() {
    _outgoing.stream.listen((_) {});
  }
  final _done = Completer<void>();
  final _outgoing = StreamController<List<int>>();
  bool closed = false;

  @override
  Stream<Uint8List> get stream => const Stream<Uint8List>.empty();

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    closed = true;
    if (!_outgoing.isClosed) await _outgoing.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> flush() async {}
}
