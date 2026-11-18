import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/admin_panel.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/settings_navigation.dart';

const _adminSectionIds = [
  'instance',
  'users',
  'access',
  'instance-vaults',
  'backup',
  'audit',
];
const _adminId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _memberId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _navEntry = ValueKey('home_nav_admin');
const _panel = ValueKey('admin_panel');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('instance admin sees the entry, the panel and every section', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      await _pump(tester, harness.app);
      expect(find.byKey(_navEntry), findsOneWidget);
      expect(find.byKey(_panel), findsNothing);

      await tester.tap(find.byKey(_navEntry));
      await tester.pumpAndSettle();
      expect(harness.app.page, WorkspacePage.admin);
      expect(find.byKey(_panel), findsOneWidget);
      expect(
        tester
            .widget<SettingsScaffold>(find.byKey(_panel))
            .sections
            .map((section) => section.id),
        _adminSectionIds,
      );
      for (final id in _adminSectionIds) {
        expect(find.byKey(ValueKey('settings_category_$id')), findsOneWidget);
      }
      // The panel has its own heading and opens on the instance overview.
      expect(find.text(currentL10n.adminPanelTitle), findsOneWidget);
      expect(find.text('Instance admin overview'), findsOneWidget);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('users section lists accounts with status and edit actions', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      harness.app.page = WorkspacePage.admin;
      await _pump(tester, harness.app);
      await openSettingsCategory(tester, 'users');
      await tester.pumpAndSettle();

      // Opening the section loads the list without a further click.
      expect(harness.api.accountListCalls, 1);
      expect(find.text('admin@example.test'), findsOneWidget);
      expect(find.text('alice@example.test'), findsOneWidget);
      expect(find.text('dana@example.test'), findsOneWidget);
      expect(find.byKey(const ValueKey('admin_account_self_chip')), findsOne);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('admin_account_status_$_memberId')),
          matching: find.text('Active'),
        ),
        findsOneWidget,
      );
      expect(find.text('Disabled'), findsOneWidget);
      expect(find.text('Disable account'), findsOneWidget);
      expect(find.text('Re-enable account'), findsOneWidget);
      expect(find.text('Revoke all sessions'), findsNWidgets(2));
      expect(find.text('Account invitations'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('admin_accounts_filter')),
        'ALICE',
      );
      await tester.pumpAndSettle();
      expect(find.text('alice@example.test'), findsOneWidget);
      expect(find.text('dana@example.test'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('admin_accounts_filter')),
        'nobody',
      );
      await tester.pumpAndSettle();
      expect(find.text(currentL10n.adminPanelUserFilterNoMatch), findsOne);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('every admin section lays out on desktop and narrow windows', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      harness.app.page = WorkspacePage.admin;
      await _pump(tester, harness.app);
      for (final width in [1280.0, 800.0, 390.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpAndSettle();
        for (final id in _adminSectionIds) {
          await openSettingsCategory(tester, id);
          await tester.pumpAndSettle();
          expect(find.byKey(ValueKey('settings_page_$id')), findsOneWidget);
          expect(
            find.byKey(ValueKey('admin_panel_section_$id')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull, reason: '$id at $width');
        }
      }
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('a requested admin section is selected when the panel opens', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      await _pump(tester, harness.app);
      AdminPanel.requestSection('audit');
      harness.app.showWorkspacePage(WorkspacePage.admin);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('settings_category_audit')),
            )
            .selected,
        isTrue,
      );
      expect(AdminPanel.requestedSection.value, isNull);
    } finally {
      AdminPanel.requestedSection.value = null;
      await _dispose(tester, harness);
    }
  });

  testWidgets('non-admin sees no entry and cannot reach the panel', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: false);
    try {
      await _pump(tester, harness.app);
      expect(find.byKey(_navEntry), findsNothing);
      expect(find.text(currentL10n.adminPanelNav), findsNothing);
      // Settings and Devices stay available, so the list itself rendered.
      expect(find.byKey(const ValueKey('home_nav_settings')), findsOneWidget);

      // Navigation requests are refused by the controller.
      expect(harness.app.canShowWorkspacePage(WorkspacePage.admin), isFalse);
      harness.app.showWorkspacePage(WorkspacePage.admin);
      await tester.pumpAndSettle();
      expect(harness.app.page, WorkspacePage.hosts);
      expect(find.byKey(_panel), findsNothing);

      // A stale or restored page selection is not rendered either.
      AdminPanel.requestSection('users');
      harness.app
        ..page = WorkspacePage.admin
        ..setStage(ClientStage.workspace);
      await tester.pumpAndSettle();
      expect(find.byKey(_panel), findsNothing);
      expect(find.byType(AdminPanel), findsNothing);
      expect(find.text('Instance admin overview'), findsNothing);
      expect(find.text('Instance accounts and sessions'), findsNothing);
      expect(harness.api.adminCalls, 0);
      expect(tester.takeException(), isNull);
    } finally {
      AdminPanel.requestedSection.value = null;
      await _dispose(tester, harness);
    }
  });

  testWidgets('the panel disappears when the account stops being an admin', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      harness.app.page = WorkspacePage.admin;
      await _pump(tester, harness.app);
      expect(find.byKey(_panel), findsOneWidget);

      harness.app
        ..account = _profile(isAdmin: false)
        ..setStage(ClientStage.workspace);
      await tester.pumpAndSettle();
      expect(find.byKey(_panel), findsNothing);
      expect(find.byKey(_navEntry), findsNothing);
      expect(find.text('Instance admin overview'), findsNothing);
    } finally {
      await _dispose(tester, harness);
    }
  });

  for (final isAdmin in [true, false]) {
    testWidgets(
      'Settings lists no instance admin section (admin: $isAdmin)',
      (tester) async {
        final harness = await _Harness.create(isAdmin: isAdmin);
        try {
          harness.app.page = WorkspacePage.settings;
          await _pump(tester, harness.app);
          final settings = find.byKey(const ValueKey('cloud_settings'));
          expect(settings, findsOneWidget);
          final ids = tester
              .widget<SettingsScaffold>(settings)
              .sections
              .map((section) => section.id)
              .toSet();
          expect(ids.intersection(_adminSectionIds.toSet()), isEmpty);
          expect(ids, containsAll(['workspace', 'security', 'vaults', 'about']));
          for (final id in _adminSectionIds) {
            expect(find.byKey(ValueKey('settings_category_$id')), findsNothing);
          }
          final l10n = currentL10n;
          for (final title in [
            l10n.instanceOverview,
            l10n.adminPanelUsersTitle,
            l10n.adminPanelAccessTitle,
            l10n.backupRestoreAndMaintenance,
            l10n.auditLog,
          ]) {
            expect(find.text(title), findsNothing);
          }
          expect(harness.api.adminCalls, 0);
        } finally {
          await _dispose(tester, harness);
        }
      },
    );
  }
}

Future<void> _pump(WidgetTester tester, AppController app) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: AppShell(controller: app),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _dispose(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  harness.app.dispose();
  harness.api.close();
  await harness.database.close();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

AccountProfile _profile({required bool isAdmin}) => AccountProfile(
  accountId: _adminId,
  deviceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
  accountKeyEnvelopeVersion: 1,
  accountKeyEnvelope: const {},
  policy: {'instance_admin': isAdmin},
);

class _Harness {
  _Harness(this.database, this.api, this.app);

  final ClientDatabase database;
  final _AdminApi api;
  final AppController app;

  static Future<_Harness> create({required bool isAdmin}) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _AdminApi();
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..api = api
          ..stage = ClientStage.workspace
          ..account = _profile(isAdmin: isAdmin);
    return _Harness(database, api, app);
  }
}

class _AdminApi extends ApiClient {
  _AdminApi()
    : super(
        baseUrl: 'https://admin-panel.example.test',
        client: MockClient((request) async {
          throw StateError('Unexpected request ${request.url.path}');
        }),
      );

  int adminCalls = 0;
  int accountListCalls = 0;

  @override
  Future<InstanceAdminOverview> instanceAdminOverview() async {
    adminCalls++;
    return InstanceAdminOverview.fromJson(_overviewJson);
  }

  @override
  Future<AdminAccountPage> adminAccounts({
    int limit = 50,
    int offset = 0,
  }) async {
    adminCalls++;
    accountListCalls++;
    return AdminAccountPage.fromJson({
      'accounts': [
        _account(_adminId, 'admin@example.test'),
        _account(_memberId, 'alice@example.test'),
        _account(
          'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          'dana@example.test',
          status: 'disabled',
        ),
      ],
      'total': 3,
      'limit': limit,
      'offset': offset,
    });
  }
}

Map<String, dynamic> _account(
  String id,
  String username, {
  String status = 'active',
}) => {
  'user_id': id,
  'username': username,
  'status': status,
  'created_at': '2026-09-29T12:30:00Z',
  'active_device_count': 2,
  'active_session_count': 1,
};

final _overviewJson = <String, dynamic>{
  'instance': {
    'instance_id': 'instance-123',
    'server_space_id': 'space-456',
    'generation': '7',
    'protocol_version': 2,
  },
  'counts': {
    'accounts_total': 3,
    'accounts_active': 2,
    'accounts_disabled': 1,
    'accounts_deleting': 0,
    'devices_active': 4,
    'vaults_active': 1,
    'vaults_deleting': 0,
    'stored_bytes': 2048,
    'reserved_upload_bytes': 0,
    'vault_quota_bytes': 1048576,
  },
  'relay': {
    'enabled': true,
    'allow_cidrs': ['10.0.0.0/8'],
    'allow_ports': [22],
    'max_connections_per_user': 3,
  },
  'generated_at': '2026-09-29T12:30:00Z',
};
