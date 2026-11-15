import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/platform/native_coordination.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/storage/terminal_scrollback_store.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:aterm_client/terminal/terminal_scrollback.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';

import 'support/l10n_fixture.dart';
import 'support/settings_navigation.dart';

const _password = 'correct horse battery staple';

class _MemoryChannel implements TelnetByteChannel {
  final StreamController<Uint8List> incoming = StreamController<Uint8List>();
  bool closed = false;

  @override
  Stream<Uint8List> get stream => incoming.stream;

  @override
  void add(Uint8List bytes) {}

  @override
  Future<void> close() async {
    closed = true;
    if (!incoming.isClosed) unawaited(incoming.close());
  }
}

/// Local-profile mode: the Scrollback setting sits in Settings > Theme next to
/// the terminal color schemes, and a terminal opened after changing it is
/// created with the new limit while an already open one keeps its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');

  late Directory directory;
  late LocalProfileCatalog catalog;
  late LocalProfileService profileService;
  late VaultCrypto crypto;
  late LocalProfileRecord profileRecord;
  late List<String> hostIds;
  late List<LocalVaultDatabase> openedDatabases;
  late List<_MemoryChannel> channels;
  late MemoryTerminalScrollbackStore scrollbackStore;
  late TerminalScrollbackController scrollback;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    scrollbackStore = MemoryTerminalScrollbackStore();
    scrollback = TerminalScrollbackController();
    TerminalScrollbackController.debugInstance = scrollback;
    await scrollback.load(scrollbackStore);
    directory = await Directory.systemTemp.createTemp('atermius-scrollback-');
    coordinationDirectory = () async =>
        Directory('${directory.path}/coordination');
    catalog = LocalProfileCatalog.forTesting(
      NativeDatabase(File('${directory.path}/catalog.sqlite')),
    );
    profileService = LocalProfileService(catalog: catalog, crypto: crypto);
    final profile = await profileService.create(password: _password);
    profileRecord = profile.record;
    final seedDatabase = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
      profileId: profileRecord.profileId,
      localDataDomainId: profileRecord.localDataDomainId,
      localVaultId: profileRecord.localVaultId,
    );
    final repository = LocalHostRepository(
      database: seedDatabase,
      profile: profile,
      crypto: crypto,
    );
    hostIds = [];
    for (final (name, address) in const [
      ('Telnet lab switch A', '192.0.2.30'),
      ('Telnet lab switch B', '192.0.2.31'),
    ]) {
      final saved = await repository.createHost(
        HostRecord(
          id: const Uuid().v4(),
          name: name,
          address: address,
          port: 2323,
          protocol: HostProtocol.telnet,
        ),
      );
      hostIds.add(saved.id);
    }
    await seedDatabase.close();
    await profile.lock();
    openedDatabases = [];
    channels = [];
    telnetConnectorOverrideForTesting = (host, port) async {
      final channel = _MemoryChannel();
      channels.add(channel);
      return channel;
    };
  });

  tearDown(() async {
    TerminalScrollbackController.debugInstance = null;
    telnetConnectorOverrideForTesting = null;
    for (final database in openedDatabases.reversed) {
      try {
        await database.close();
      } on Object {
        // Already closed by the flow.
      }
    }
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (condition()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    fail('condition not met');
  }

  Future<void> tapWorkspaceAction(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(const ValueKey('workspace_host_menu')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(ValueKey(id)));
    await tester.tap(find.byKey(ValueKey(id)));
    await tester.pumpAndSettle();
  }

  List<Terminal> telnetTerminals(WidgetTester tester) => [
    for (final view in tester.widgetList<TerminalView>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TerminalView &&
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'local_telnet_view_',
            ),
        skipOffstage: false,
      ),
    ))
      view.terminal,
  ];

  testWidgets(
    'local settings show Scrollback; terminals opened afterwards use it',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
                executor: NativeDatabase(
                  File('${directory.path}/vault.sqlite'),
                ),
                profileId: record.profileId,
                localDataDomainId: record.localDataDomainId,
                localVaultId: record.localVaultId,
                mode: mode,
              );
              openedDatabases.add(database);
              return database;
            },
          ),
        ),
      );
      await pumpUntil(
        tester,
        () => find
            .byKey(ValueKey('local_profile_${profileRecord.profileId}'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(
        find.byKey(ValueKey('local_profile_${profileRecord.profileId}')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        _password,
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      Finder host(int index) =>
          find.byKey(ValueKey('local_host_${hostIds[index]}'));
      await pumpUntil(tester, () => host(0).evaluate().isNotEmpty);

      // A terminal opened before the change gets the default scrollback.
      await tester.tap(host(0));
      await pumpUntil(tester, () => telnetTerminals(tester).isNotEmpty);
      await pumpUntil(tester, () => channels.isNotEmpty);
      final before = telnetTerminals(tester).single;
      expect(before.maxLines, terminalScrollbackDefault);

      // Settings > Theme holds the setting next to the color schemes.
      WorkspaceTabBar tabBar() =>
          tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
      tabBar().onSelect(tabBar().tabs.firstWhere((tab) => tab.isHome).id);
      await tester.pumpAndSettle();
      await tapWorkspaceAction(tester, 'local_profile_preferences_toggle');
      expect(
        find.byKey(const ValueKey('local_profile_preferences')),
        findsOneWidget,
      );
      await openSettingsCategory(tester, 'appearance');
      await tester.pumpAndSettle();
      final setting = find.byKey(const ValueKey('terminal_scrollback_setting'));
      expect(setting, findsOneWidget);
      expect(
        find.byKey(const ValueKey('terminal_palette_gallery')),
        findsOneWidget,
        reason: 'same category as the terminal color schemes',
      );
      expect(
        find.descendant(
          of: setting,
          matching: find.textContaining('terminals opened afterwards'),
        ),
        findsOneWidget,
      );
      final dropdown = find.byKey(
        const ValueKey('terminal_scrollback_dropdown'),
      );
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('500,000 lines').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(scrollback.lines, 500000);
      expect(scrollbackStore.value, '500000');

      // The next terminal uses the new limit; the open one keeps its own.
      await tapWorkspaceAction(tester, 'local_profile_hosts_toggle');
      await pumpUntil(tester, () => host(1).evaluate().isNotEmpty);
      await tester.tap(host(1));
      await pumpUntil(tester, () => channels.length == 2);
      await pumpUntil(
        tester,
        () => telnetTerminals(tester).any((terminal) => terminal != before),
      );
      final after = telnetTerminals(tester)
          .firstWhere((terminal) => terminal != before);
      expect(after.maxLines, 500000);
      expect(before.maxLines, terminalScrollbackDefault);

      for (final tab in tabBar().tabs.where((tab) => !tab.isHome).toList()) {
        tabBar().onClose(tab.id);
        await tester.pump();
      }
      await pumpUntil(tester, () => channels.every((c) => c.closed));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
    },
  );
}
