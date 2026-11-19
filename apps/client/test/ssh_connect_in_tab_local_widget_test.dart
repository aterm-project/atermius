import 'package:aterm_client/domain/host_sort.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
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
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import 'support/l10n_fixture.dart';

// An SSH attempt in a local profile lives in its own tab: the home page shows
// no loading state or connection error for it and stays usable meanwhile.

const _password = 'correct horse battery staple';
const _fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _connectFailure =
    "Couldn't connect to the local SSH Host. Check the network and "
    'credentials, then try again.';

const _homeTab = ValueKey('workspace-tab-hosts');
const _homeSearch = ValueKey('local_home_search');
const _homeError = ValueKey('local_profile_error');
const _terminalView = ValueKey('local_ssh_terminal_view');
const _approve = ValueKey('local_ssh_host_key_approve');
const _restore = ValueKey('session_restore_connection');

final _pane = find.byKey(
  const ValueKey('connect_progress_pane'),
  skipOffstage: false,
);
final _stop = find.byKey(const ValueKey('connect_progress_stop'));
final _retry = find.byKey(const ValueKey('connect_progress_retry'));
final _close = find.byKey(const ValueKey('connect_progress_close'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');

  late Directory directory;
  late LocalProfileCatalog catalog;
  late LocalProfileService profileService;
  late VaultCrypto crypto;
  late LocalProfileRecord profileRecord;
  late String alphaId, betaId;
  late List<LocalVaultDatabase> openedDatabases;
  late _Ssh ssh;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'atermius-ssh-connect-in-tab-',
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
        name: 'in-tab credential',
        username: 'local-user',
        kind: AuthKind.password,
        secret: 'test-only-local-password',
      ),
    );
    Future<String> host(String name, String address) async =>
        (await seedRepository.createHost(
          HostRecord(
            id: const Uuid().v4(),
            name: name,
            address: address,
            port: 2222,
            username: 'local-user',
            credentialId: credentialId,
          ),
        )).id;
    alphaId = await host('Alpha host', 'alpha.example.test');
    betaId = await host('Beta host', 'beta.example.test');
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
  WorkspaceTab tabOf(WidgetTester tester, String title) =>
      tabBar(tester).tabs.singleWhere((tab) => tab.title == title);
  List<String> sessionTabs(WidgetTester tester) => [
    for (final tab in tabBar(tester).tabs)
      if (!tab.isHome) tab.title,
  ];
  bool selected(WidgetTester tester, String title) =>
      tabBar(tester).selectedId == tabOf(tester, title).id;

  Future<void> showHome(WidgetTester tester) async {
    await tester.tap(find.byKey(_homeTab));
    await tester.pump();
    expect(tabBar(tester).selectedId, 'hosts');
  }

  /// The home page is in front and shows no waiting indicator, connection
  /// error or message. Session tabs keep theirs in their own (hidden) pane.
  void expectHomeIdle(WidgetTester tester) {
    expect(tabBar(tester).selectedId, 'hosts');
    expect(find.byKey(_homeSearch).hitTestable(), findsOneWidget);
    // The workspace body is a stack of the home page and the session panes.
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
    expect(find.byKey(_homeError, skipOffstage: false), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
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

  String terminalText(WidgetTester tester) {
    final terminal = tester
        .widget<TerminalView>(find.byKey(_terminalView))
        .terminal;
    final lines = terminal.buffer.lines;
    return [for (var i = 0; i < lines.length; i++) lines[i].toString()].join();
  }

  testWidgets('a host card opens a selected tab that shows the loading; the '
      'home page shows none and opens a second host meanwhile', (tester) async {
    await openProfile(tester);
    ssh.hold = true;

    await tester.tap(find.byKey(ValueKey('local_host_$alphaId')));
    expect(HostSortController.instance.lastRequested(
      localHostSortScope(profileRecord.profileId), alphaId), isNotNull,
      reason: 'request is recorded before SSH authentication finishes');
    await tester.pump();
    // Open and selected in the frame after the click.
    expect(sessionTabs(tester), ['Alpha host']);
    expect(selected(tester, 'Alpha host'), isTrue);
    expect(_pane.hitTestable(), findsOneWidget);
    expect(find.text('Connecting to Alpha host'), findsOneWidget);
    expect(find.byKey(_homeSearch).hitTestable(), findsNothing);
    await pumpFor(tester, () => ssh.requests.length == 1);
    expect(find.text('Opening the connection'), findsOneWidget);
    expect(tabOf(tester, 'Alpha host').status, 'connecting');
    expect(tabOf(tester, 'Alpha host').isConnected, isFalse);
    expect(tabOf(tester, 'Alpha host').canDisconnect, isTrue);
    expect(find.textContaining('2222 · Connecting'), findsOneWidget);

    // Back on the home page nothing waits for that attempt.
    await showHome(tester);
    expectHomeIdle(tester);

    // The home page is not locked either: a second Host opens its own tab
    // while the first one is still connecting.
    await tester.tap(find.byKey(ValueKey('local_host_$betaId')));
    await tester.pump();
    expect(sessionTabs(tester), ['Alpha host', 'Beta host']);
    expect(selected(tester, 'Beta host'), isTrue);
    expect(find.text('Connecting to Beta host').hitTestable(), findsOneWidget);
    await pumpFor(tester, () => ssh.requests.length == 2);
    expect(ssh.requests, ['alpha.example.test', 'beta.example.test']);
    expect(tabOf(tester, 'Alpha host').status, 'connecting');
    expect(tabOf(tester, 'Beta host').status, 'connecting');
    expect(ssh.clients, isEmpty);

    await closeFlow(tester);
  });

  testWidgets('a failure is shown in the tab with retry and close, not on '
      'the home page; a retry that succeeds turns the tab into a terminal', (
    tester,
  ) async {
    await openProfile(tester);
    ssh.hold = true;
    await tester.tap(find.byKey(ValueKey('local_host_$alphaId')));
    await pumpFor(tester, () => ssh.requests.length == 1);

    ssh.pending[0].completeError(const SocketException('refused'));
    await pumpFor(
      tester,
      () => find.text("Couldn't connect to Alpha host").evaluate().isNotEmpty,
    );
    expect(selected(tester, 'Alpha host'), isTrue);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('connect_progress_error')))
          .data,
      _connectFailure,
    );
    expect(tester.widget<ButtonStyleButton>(_retry).onPressed, isNotNull);
    expect(tester.widget<ButtonStyleButton>(_close).onPressed, isNotNull);
    expect(tester.widget<ButtonStyleButton>(_stop).onPressed, isNull);
    expect(tabOf(tester, 'Alpha host').status, isNull);
    expect(find.byKey(_homeError, skipOffstage: false), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    await showHome(tester);
    expectHomeIdle(tester);
    expect(find.text(_connectFailure).hitTestable(), findsNothing);

    // Retry from the tab: the same tab loads again and this time connects.
    await tester.tap(
      find.byKey(ValueKey('workspace-tab-${tabOf(tester, 'Alpha host').id}')),
    );
    await tester.pump();
    await tester.tap(_retry);
    await pumpFor(tester, () => ssh.requests.length == 2);
    expect(find.text('Connecting to Alpha host'), findsOneWidget);
    ssh.hold = false;
    ssh.pending[1].complete(_Socket());
    // The unknown host key is reviewed over the tab that asked for it.
    await approveHostKey(tester, 'alpha.example.test');
    await pumpFor(
      tester,
      () => find.byKey(_terminalView).evaluate().isNotEmpty,
    );
    expect(sessionTabs(tester), ['Alpha host']);
    expect(selected(tester, 'Alpha host'), isTrue);
    expect(_pane, findsNothing);
    expect(tabOf(tester, 'Alpha host').isConnected, isTrue);
    expect(tabOf(tester, 'Alpha host').status, isNull);
    expect(ssh.authenticated, 1);
    // A normal terminal: remote output is shown and typing reaches the host.
    ssh.sessions.last.emit('welcome to alpha\r\n');
    await tester.pump();
    expect(terminalText(tester), contains('welcome to alpha'));
    tester.widget<TerminalView>(find.byKey(_terminalView)).terminal.onOutput!(
      'ls\r',
    );
    expect(utf8.decode(ssh.sessions.last.written), 'ls\r');

    await closeFlow(tester);
  });

  testWidgets('closing the tab while it connects cancels the attempt: the '
      'late socket is closed and nothing comes back', (tester) async {
    await openProfile(tester);
    ssh.hold = true;
    await tester.tap(find.byKey(ValueKey('local_host_$alphaId')));
    await pumpFor(tester, () => ssh.requests.length == 1);

    await tester.tap(_close);
    await pumpFor(tester, () => _pane.evaluate().isEmpty);
    expect(sessionTabs(tester), isEmpty);
    expectHomeIdle(tester);

    // The socket the cancelled attempt was waiting for arrives afterwards.
    final late = _Socket();
    ssh.pending[0].complete(late);
    await pumpFor(tester, () => late.closed);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 6));
    expect(ssh.clients, isEmpty, reason: 'no handshake on a cancelled attempt');
    expect(ssh.requests, hasLength(1));
    expect(find.byKey(_approve), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(sessionTabs(tester), isEmpty);
    expect(find.byKey(_terminalView, skipOffstage: false), findsNothing);
    expectHomeIdle(tester);

    // Stop loading keeps the tab, and a late socket is discarded as well.
    await tester.tap(find.byKey(ValueKey('local_host_$alphaId')));
    await pumpFor(tester, () => ssh.requests.length == 2);
    await tester.tap(_stop);
    await tester.pump();
    expect(find.text('Loading stopped'), findsOneWidget);
    final stopped = _Socket();
    ssh.pending[1].complete(stopped);
    await pumpFor(tester, () => stopped.closed);
    expect(find.text('Loading stopped'), findsOneWidget);
    expect(ssh.clients, isEmpty);
    expect(sessionTabs(tester), ['Alpha host']);

    await closeFlow(tester);
  });

  testWidgets('tabs that connect at the same time review their host keys one '
      'at a time, each over its own tab', (tester) async {
    await openProfile(tester);
    ssh.hold = true;
    await tester.tap(find.byKey(ValueKey('local_host_$alphaId')));
    await pumpFor(tester, () => ssh.requests.length == 1);
    await showHome(tester);
    await tester.tap(find.byKey(ValueKey('local_host_$betaId')));
    await pumpFor(tester, () => ssh.requests.length == 2);
    expect(selected(tester, 'Beta host'), isTrue);

    // Both servers present an unknown key while the Beta tab is in front.
    ssh.hold = false;
    ssh.pending[0].complete(_Socket());
    await pumpFor(tester, () => find.byKey(_approve).evaluate().isNotEmpty);
    ssh.pending[1].complete(_Socket());
    await pumpFor(tester, () => ssh.clients.length == 2);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(selected(tester, 'Alpha host'), isTrue);
    await approveHostKey(tester, 'alpha.example.test');

    await approveHostKey(tester, 'beta.example.test');
    await pumpFor(
      tester,
      () =>
          tabOf(tester, 'Alpha host').isConnected &&
          tabOf(tester, 'Beta host').isConnected,
    );
    await tester.pumpAndSettle();
    expect(ssh.authenticated, 2);
    expect(find.byType(AlertDialog), findsNothing);
    expect(selected(tester, 'Beta host'), isTrue);
    expect(_pane, findsNothing);

    await closeFlow(tester);
  });

  testWidgets('reconnecting an existing tab still works, keeps the home page '
      'idle and reports its failure in the tab', (tester) async {
    await openProfile(tester);
    await tester.tap(find.byKey(ValueKey('local_host_$alphaId')));
    await approveHostKey(tester, 'alpha.example.test');
    await pumpFor(
      tester,
      () => find.byKey(_terminalView).evaluate().isNotEmpty,
    );
    expect(ssh.authenticated, 1);

    // The server ends the session: the tab offers to restore it.
    final terminal = tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
    final measuredSize = (terminal.viewWidth, terminal.viewHeight);
    expect(ssh.sessions.last.sizes.last, measuredSize);
    expect(measuredSize, isNot((100, 30)));
    ssh.hold = true;
    final requests = ssh.requests.length;
    ssh.sessions.last.close();
    await pumpFor(tester, () => find.byKey(_restore).evaluate().isNotEmpty);
    expect(tabOf(tester, 'Alpha host').isConnected, isFalse);
    await tester.tap(find.byKey(_restore));
    await pumpFor(tester, () => ssh.requests.length == requests + 1);

    // The reconnect belongs to the tab; the home page neither waits nor locks.
    await showHome(tester);
    expectHomeIdle(tester);
    await tester.tap(find.byKey(ValueKey('local_host_$betaId')));
    await tester.pump();
    expect(sessionTabs(tester), ['Alpha host', 'Beta host']);
    await pumpFor(tester, () => ssh.requests.length == requests + 2);
    await tester.tap(_close);
    await pumpFor(tester, () => _pane.evaluate().isEmpty);
    expect(sessionTabs(tester), ['Alpha host']);

    // This reconnect fails: the reason is written into the tab's terminal.
    ssh.pending[0].completeError(const SocketException('refused'));
    await pumpFor(tester, () => terminalText(tester).contains("Couldn't"));
    expect(
      terminalText(tester).replaceAll(RegExp(r'\s+'), ' '),
      contains(_connectFailure.replaceAll(RegExp(r'\s+'), ' ')),
    );
    expect(find.byKey(_restore), findsOneWidget);
    expect(find.byKey(_homeError, skipOffstage: false), findsNothing);
    expect(find.byType(SnackBar), findsNothing);

    // Restore again: the same tab is a live terminal once more.
    ssh.hold = false;
    await tester.tap(find.byKey(_restore));
    await pumpFor(tester, () => ssh.authenticated == 2);
    await pumpFor(tester, () => find.byKey(_restore).evaluate().isEmpty);
    expect(sessionTabs(tester), ['Alpha host']);
    expect(tabOf(tester, 'Alpha host').isConnected, isTrue);
    expect(find.byType(AlertDialog), findsNothing);
    expect(ssh.sessions.last.sizes.first, measuredSize,
        reason: 'manual restore must replay the retained terminal size');
    ssh.sessions.last.emit('back again\r\n');
    await tester.pump();
    expect(terminalText(tester), contains('back again'));
    await showHome(tester);
    expectHomeIdle(tester);

    await closeFlow(tester);
  });

  testWidgets('a session dropped inside a full-screen program does not leave '
      'the wheel typing mouse reports into the reconnected shell', (
    tester,
  ) async {
    Terminal shown() =>
        tester.widget<TerminalView>(find.byKey(_terminalView)).terminal;
    Future<void> wheel(double dy) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final at = tester.getCenter(find.byKey(_terminalView));
      await tester.sendEventToBinding(pointer.hover(at));
      for (var i = 0; i < 4; i++) {
        await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pump(const Duration(milliseconds: 300));
    }

    // A two-finger touchpad scroll, as Windows precision touchpads send it.
    Future<void> touchpad(double dy) async {
      final at = tester.getCenter(find.byKey(_terminalView));
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomStart(at);
      for (var i = 1; i <= 5; i++) {
        await gesture.panZoomUpdate(at, pan: Offset(0, dy * i / 5));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.panZoomEnd();
      await tester.pump(const Duration(seconds: 2));
    }

    await openProfile(tester);
    await tester.tap(find.byKey(ValueKey('local_host_$alphaId')));
    await approveHostKey(tester, 'alpha.example.test');
    await pumpFor(
      tester,
      () => find.byKey(_terminalView).evaluate().isNotEmpty,
    );
    final first = ssh.sessions.last;
    for (var i = 0; i < 60; i++) {
      first.emit('history $i\r\n');
    }
    // tmux/vim with the mouse on: alternate screen, mouse reports (SGR),
    // bracketed paste, application cursor keys.
    first.emit(
      '\x1b[?1049h\x1b[?1h\x1b=\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?2004h'
      'full screen program',
    );
    await tester.pump();
    final terminal = shown();
    expect(terminal.isUsingAltBuffer, isTrue);

    // While the program runs the wheel is its to handle.
    first.written.clear();
    await wheel(120);
    expect(utf8.decode(first.written), contains('\x1b[<65;'));
    first.written.clear();
    await touchpad(-160);
    expect(utf8.decode(first.written), contains('\x1b[<6'));

    // The connection drops; nothing switches those modes back off.
    ssh.hold = true;
    first.close();
    await pumpFor(tester, () => find.byKey(_restore).evaluate().isNotEmpty);
    expect(shown(), same(terminal));
    expect(terminal.isUsingAltBuffer, isFalse);
    expect(terminal.mouseMode, MouseMode.none);
    expect(terminalText(tester), contains('history 59'));
    expect(terminalText(tester), isNot(contains('full screen program')));

    ssh.hold = false;
    if (ssh.authenticated < 2) {
      final restore = find.byKey(_restore);
      if (restore.evaluate().isNotEmpty &&
          tester.widget<ButtonStyleButton>(restore).onPressed != null) {
        await tester.tap(restore);
      }
    }
    await pumpFor(tester, () => ssh.authenticated == 2);
    await pumpFor(tester, () => find.byKey(_restore).evaluate().isEmpty);
    final second = ssh.sessions.last;
    expect(second, isNot(same(first)));
    second.emit('Last login: today\r\nuser@alpha:~\$ ');
    await tester.pump();
    expect(shown(), same(terminal));
    expect(terminalText(tester), contains('user@alpha:~\$'));

    // The wheel scrolls the history; nothing is typed into the new shell.
    second.written.clear();
    await wheel(-120);
    await wheel(120);
    await touchpad(160);
    await touchpad(-160);
    expect(second.written, isEmpty);
    expect(terminal.isUsingAltBuffer, isFalse);
    expect(terminal.bracketedPasteMode, isFalse);
    expect(terminal.cursorKeysMode, isFalse);
    expect(terminal.appKeypadMode, isFalse);

    await closeFlow(tester);
  });

  testWidgets('quick connect and Enter in the home search open their tab and '
      'do not wait for the connection', (tester) async {
    await openProfile(tester);
    ssh.hold = true;

    await tester.enterText(
      find.byKey(_homeSearch),
      'ssh local-user@alpha.example.test -p 2222',
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(sessionTabs(tester), ['Alpha host']);
    expect(selected(tester, 'Alpha host'), isTrue);
    expect(_pane.hitTestable(), findsOneWidget);
    await pumpFor(tester, () => ssh.requests.length == 1);

    // While that tab is still connecting, quick connect takes the next one.
    await showHome(tester);
    expectHomeIdle(tester);
    await tester.enterText(
      find.byKey(_homeSearch),
      'ssh local-user@beta.example.test -p 2222',
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(sessionTabs(tester), ['Alpha host', 'Beta host']);
    expect(selected(tester, 'Beta host'), isTrue);
    await pumpFor(tester, () => ssh.requests.length == 2);

    // Enter on a search result connects it in a third tab.
    await showHome(tester);
    await tester.enterText(find.byKey(_homeSearch), 'Alpha');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(sessionTabs(tester), ['Alpha host', 'Beta host', 'Alpha host']);
    expect(_pane.hitTestable(), findsOneWidget);
    await pumpFor(tester, () => ssh.requests.length == 3);
    expect(ssh.clients, isEmpty);

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
  final sizes = <(int, int)>[];

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
  ]) { sizes.add((width, height)); }

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
