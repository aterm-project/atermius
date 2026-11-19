import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/host_sort.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/host_sort_store.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/host_sort_menu.dart';
import 'package:aterm_client/ui/ios_native/ios_hosts_tab.dart';
import 'package:aterm_client/ui/ios_native/ios_group_detail_page.dart';
import 'package:aterm_client/ui/ios_native/ios_workspace_scope.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/host_sort_fixture.dart';

class _SortApp extends AppController {
  _SortApp({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });
  @override
  String get hostSortScope => 'cloud-fixture';
  @override
  Future<void> openTerminalTab(
    HostRecord host, {
    void Function(String)? onTabOpened,
    bool userStarted = true,
  }) async {
    noteHostRequested(host);
    throw StateError('fixture connection failed');
  }
}

class _RequestApp extends AppController {
  _RequestApp({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });
  @override
  String get hostSortScope => 'real-connect-fixture';
}

void main() {
  late HostSortController sort;
  setUp(() {
    sort = HostSortController();
    HostSortController.debugInstance = sort;
  });
  tearDown(() => HostSortController.debugInstance = null);

  test(
    'an actual failed SSH connect is recorded before credential validation',
    () async {
      final db = ClientDatabase.forTesting(NativeDatabase.memory());
      final app = _RequestApp(
        sodium: await SodiumSumoInit.init(),
        database: db,
        secureStore: ClientSecureStore(),
      )..stage = ClientStage.workspace;
      try {
        await expectLater(app.openTerminalTab(hosts[1]), throwsStateError);
        expect(sort.lastRequested(app.hostSortScope, 'b'), isNotNull);
        expect(sort.sorted(hosts, scope: app.hostSortScope).first.id, 'b');
        final requested = sort.lastRequested(app.hostSortScope, 'b');
        await expectLater(
          app.openTerminalTab(hosts[1], userStarted: false),
          throwsStateError,
        );
        expect(
          sort.lastRequested(app.hostSortScope, 'b'),
          requested,
          reason: "automation does not change the user's recent requests",
        );
      } finally {
        app.dispose();
        await db.close();
      }
    },
  );

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.android,
  ]) {
    testWidgets(
      '$platform menu changes all six sort modes and persists choice',
      (tester) async {
        final store = MemoryHostSortStore();
        await sort.load(store);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizationSetup.delegates,
            supportedLocales: AppLocalizationSetup.locales,
            theme: ThemeData(platform: platform),
            home: const Scaffold(body: HostSortMenu()),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('home_host_sort')));
        await tester.pumpAndSettle();
        expect(
          find.byType(CheckedPopupMenuItem<HostSortOrder>),
          findsNWidgets(6),
        );
        expect(HostSortController.instance, same(sort));
        await tester.tap(
          find.byWidgetPredicate(
            (widget) =>
                widget is CheckedPopupMenuItem<HostSortOrder> &&
                widget.value == HostSortOrder.nameDescending,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(CheckedPopupMenuItem<HostSortOrder>),
          findsNothing,
          reason: 'menu should close after selecting',
        );
        expect(HostSortController.instance, same(sort));
        expect(sort.order, HostSortOrder.nameDescending);
        final restored = HostSortController();
        await restored.load(store);
        expect(restored.order, HostSortOrder.nameDescending);
      },
    );
  }

  testWidgets('cloud Home immediately reorders a failed connection request', (
    tester,
  ) async {
    final db = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        _SortApp(
            sodium: await SodiumSumoInit.init(),
            database: db,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = const VaultDescriptor(
            id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
          );
    app.hosts.addAll(hosts);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    try {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: buildAppTheme(),
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      Offset point(String id) =>
          tester.getTopLeft(find.byKey(ValueKey('host_connect_$id')));
      expect(point('a').dx, lessThan(point('z').dx));
      await tester.tap(find.byKey(const ValueKey('host_connect_z')));
      await tester.pumpAndSettle();
      expect(sort.lastRequested(app.hostSortScope, 'z'), isNotNull);
      expect(point('z').dx, lessThan(point('a').dx));
      await sort.select(HostSortOrder.nameAscending);
      await tester.pumpAndSettle();
      expect(point('a').dx, lessThan(point('z').dx));
      await tester.enterText(
        find.byKey(const ValueKey('cloud_home_search')),
        'Zulu',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('host_connect_z')), findsOneWidget);
      expect(find.byKey(const ValueKey('host_connect_a')), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      app.dispose();
      await tester.runAsync(db.close);
    }
  });

  testWidgets(
    'iPhone native Home uses recent requests and the same six choices',
    (tester) async {
      final search = TextEditingController();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const scope = 'ios-fixture';
      sort.requested(scope, ['z']);
      try {
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizationSetup.delegates,
            supportedLocales: AppLocalizationSetup.locales,
            theme: ThemeData(platform: TargetPlatform.iOS),
            home: IosWorkspaceScope(
              data: IosWorkspaceData(
                hosts: hosts,
                groups: const [],
                search: search,
                hostSortScope: scope,
                connect: (h) => sort.requested(scope, [h.id]),
                edit: (_) {},
                delete: (_) {},
                hostActions: (_) => const [],
              ),
              child: const IosHostsTab(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        List<String> rows() => tester
            .widgetList<IosHostRow>(find.byType(IosHostRow))
            .map((row) => row.host.id)
            .toList();
        expect(rows(), ['z', 'a', 'b']);
        await tester.tap(find.byKey(const ValueKey('ios_hosts_sort_button')));
        await tester.pumpAndSettle();
        for (final order in HostSortOrder.values) {
          expect(
            find.text(
              hostSortLabel(appLocalizationsFor(const Locale('en')), order),
            ),
            findsWidgets,
          );
        }
        await tester.tap(find.text('Name (A–Z)').last);
        await tester.pumpAndSettle();
        expect(rows(), ['a', 'b', 'z']);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        search.dispose();
      }
    },
  );

  testWidgets('iPhone folders follow the home sort choice', (tester) async {
    final search = TextEditingController();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    sort.requested('folder-fixture', ['z']);
    try {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: IosWorkspaceScope(
            data: IosWorkspaceData(
              hosts: hosts
                  .map((host) => host.copyWith(groupId: 'folder'))
                  .toList(),
              groups: const [GroupRecord(id: 'folder', name: 'Folder')],
              search: search,
              hostSortScope: 'folder-fixture',
              connect: (_) {},
              edit: (_) {},
              delete: (_) {},
              hostActions: (_) => const [],
            ),
            child: const IosGroupDetailPage(groupId: 'folder'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      List<String> rows() => tester
          .widgetList<IosHostRow>(find.byType(IosHostRow))
          .map((row) => row.host.id)
          .toList();
      expect(rows(), ['z', 'a', 'b']);
      await sort.select(HostSortOrder.nameAscending);
      await tester.pumpAndSettle();
      expect(rows(), ['a', 'b', 'z']);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      search.dispose();
    }
  });

  testWidgets('compact menu fits a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizationSetup.delegates,
        supportedLocales: AppLocalizationSetup.locales,
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Row(
              children: [
                const Expanded(child: TextField()),
                const HostSortMenu(compact: true),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
