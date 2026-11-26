import 'package:aterm_client/api/workspace_agents.dart';
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/credential_visibility/credential_visibility_api.dart'
    show credentialVisibilityCapability;
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/platform/server_hosted.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/admin_panel.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/credential_visibility/credential_visibility_admin_ui.dart'
    show CredentialVisibilityAdminCard;
import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:aterm_client/ui/workspace_status_bar.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/settings_navigation.dart';

/// Sections of a server without credential visibility: the access section,
/// which holds nothing else, is not offered.
const _adminSectionIds = [
  'instance',
  'users',
  'instance-vaults',
  'backup',
  'audit',
];
const _adminId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _memberId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _disabledId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _navEntry = ValueKey('home_nav_admin_console');
const _exit = ValueKey('admin_site_exit');
const _panel = ValueKey('admin_panel');

void main() {
  testWidgets(
    'native Agent section follows capability, revision and migration state',
    (tester) async {
      final harness = await _Harness.create(isAdmin: true);
      try {
        harness.app.instance = const InstanceInfo(
          instanceId: 'test-instance',
          serverSpaceId: 'test-space',
          generation: '1',
          protocolVersion: 1,
          setupRequired: false,
          capabilities: ['workspace_agent_admin_v1'],
        );
        harness.app.page = WorkspacePage.admin;
        await _pump(tester, harness.app);
        await openSettingsCategory(tester, 'workspace-agents');
        await tester.pumpAndSettle();
        expect(
          find.byKey(const PageStorageKey('workspace_node_alpha')),
          findsOneWidget,
        );
        final cluster = find.byKey(
          const PageStorageKey('workspace_cluster_lab'),
        );
        await tester.ensureVisible(cluster);
        await tester.tap(
          find.descendant(of: cluster, matching: find.text('lab')),
        );
        await tester.pumpAndSettle();
        final migrate = find.byKey(const ValueKey('workspace_migrate_lab'));
        await tester.ensureVisible(migrate);
        await tester.tap(migrate);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('workspace_confirm')));
        await tester.pumpAndSettle();
        expect(harness.api.agentChanges.single, {
          'action': 'migrate',
          'cluster': 'lab',
          'destination': 'beta',
          'expected_generation': 1,
        });
        final abort = find.byKey(const ValueKey('workspace_abort_lab'));
        await tester.ensureVisible(abort);
        await tester.tap(abort);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('workspace_confirm')));
        await tester.pumpAndSettle();
        expect(harness.api.agentChanges.last, {
          'action': 'abort',
          'cluster': 'lab',
          'expected_generation': 2,
        });
      } finally {
        await _dispose(tester, harness);
      }
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('losing admin access dismisses a pending node confirmation', (
    tester,
  ) async {
    final h = await _Harness.create(isAdmin: true);
    try {
      h.app.instance = const InstanceInfo(
        instanceId: 'id',
        serverSpaceId: 'space',
        generation: '1',
        protocolVersion: 1,
        setupRequired: false,
        capabilities: ['workspace_agent_admin_v1'],
      );
      h.app.page = WorkspacePage.admin;
      await _pump(tester, h.app);
      await openSettingsCategory(tester, 'workspace-agents');
      await tester.pumpAndSettle();
      await tester.tap(find.text('alpha').first);
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('workspace_toggle_alpha'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workspace_confirm')), findsOneWidget);
      h.app
        ..account = _profile(isAdmin: false)
        ..setStage(ClientStage.workspace);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workspace_confirm')), findsNothing);
      expect(h.api.agentChanges, isEmpty);
    } finally {
      await _dispose(tester, h);
    }
  });

  testWidgets('the admin console is a site of its own, not a workspace page', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      await _pump(tester, harness.app);
      // The workspace lists no Admin page; the sidebar row below Settings
      // opens the console instead.
      expect(find.byKey(const ValueKey('home_nav_admin')), findsNothing);
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
      // The console has its own heading, names its server and the signed-in
      // account, and opens on the instance overview.
      expect(find.text(currentL10n.adminSiteTitle), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('admin_site_server'))).data,
        'admin-panel.example.test',
      );
      expect(find.text('Instance admin overview'), findsOneWidget);
      // Nothing of the workspace is beside it: no navigation, no account
      // card, no status bar.
      for (final key in [
        'home_nav_devices',
        'home_nav_settings',
        'home_nav_user_card',
        'home_nav_import_export',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(find.byType(WorkspaceStatusBar), findsNothing);
      // An installed app keeps its tab row: it is the window's title bar.
      expect(find.byType(WorkspaceTabBar), findsOneWidget);

      // The console's own way back opens the workspace again.
      await tester.tap(find.byKey(_exit));
      await tester.pumpAndSettle();
      expect(harness.app.page, WorkspacePage.hosts);
      expect(find.byKey(_panel), findsNothing);
      expect(find.byKey(const ValueKey('home_nav_settings')), findsOneWidget);
      expect(find.byKey(const ValueKey('home_nav_user_card')), findsOneWidget);
      expect(find.byType(WorkspaceStatusBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('in the browser the console owns the whole page', (tester) async {
    debugServerHostedOverride = true;
    final harness = await _Harness.create(isAdmin: true);
    try {
      await _pump(tester, harness.app);
      expect(find.byType(WorkspaceTabBar), findsOneWidget);
      harness.app.showWorkspacePage(WorkspacePage.admin);
      await tester.pumpAndSettle();
      expect(find.byKey(_panel), findsOneWidget);
      expect(find.byType(WorkspaceTabBar), findsNothing);
      expect(find.byKey(const ValueKey('home_nav_settings')), findsNothing);

      await tester.tap(find.byKey(_exit));
      await tester.pumpAndSettle();
      expect(harness.app.page, WorkspacePage.hosts);
      expect(find.byType(WorkspaceTabBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, harness);
      debugServerHostedOverride = null;
    }
  });

  testWidgets('a narrow console keeps its heading and its way back', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      harness.app.page = WorkspacePage.admin;
      await _pump(tester, harness.app);
      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_site_brand')), findsNothing);
      expect(find.text(currentL10n.adminSiteTitle), findsOneWidget);
      await tester.tap(find.byKey(_exit));
      await tester.pumpAndSettle();
      expect(harness.app.page, WorkspacePage.hosts);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('users are a table; a row opens the account beside it', (
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
      final table = find.byKey(const ValueKey('admin_accounts_table'));
      expect(table, findsOneWidget);
      final l10n = currentL10n;
      for (final column in [
        l10n.adminUsersColumnUser,
        l10n.adminUsersColumnStatus,
        l10n.adminUsersColumnDevices,
        l10n.adminUsersColumnSessions,
        l10n.adminUsersColumnCreated,
      ]) {
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('admin_accounts_table_header')),
            matching: find.text(column),
          ),
          findsOneWidget,
          reason: column,
        );
      }
      // One row per account, each a single line of the table.
      final rows = [
        for (final id in [_adminId, _memberId, _disabledId])
          tester.getRect(find.byKey(ValueKey('admin_account_$id'))),
      ];
      expect(rows[0].height, lessThan(60));
      expect(rows[1].top, greaterThanOrEqualTo(rows[0].bottom));
      expect(rows[2].top, greaterThanOrEqualTo(rows[1].bottom));
      expect({for (final row in rows) row.left}, hasLength(1));
      expect({for (final row in rows) row.width}, hasLength(1));
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
      // The table only lists. Details and actions are not on the page until
      // an account is opened.
      expect(find.text('Disable account'), findsNothing);
      expect(find.text('Re-enable account'), findsNothing);
      expect(find.text('Revoke all sessions'), findsNothing);
      expect(find.text(_memberId), findsNothing);
      expect(find.text('Account invitations'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('admin_account_$_memberId')));
      await tester.pumpAndSettle();
      final drawer = find.byKey(
        const ValueKey('admin_account_drawer_$_memberId'),
      );
      expect(drawer, findsOneWidget);
      // It floats over the right edge of the admin site (dialogs are
      // window-level: below the tab row, which an installed app keeps as its
      // title bar), full height; the table is still there behind it.
      final app = tester.getRect(find.byType(MaterialApp));
      final tabRow = find.byType(WorkspaceTabBar);
      final window = tabRow.evaluate().isEmpty
          ? app
          : Rect.fromLTRB(
              app.left,
              tester.getRect(tabRow).bottom,
              app.right,
              app.bottom,
            );
      final panel = tester.getRect(
        find.ancestor(of: drawer, matching: find.byType(Dialog)),
      );
      final surface = tester.getRect(
        find
            .descendant(
              of: find.ancestor(of: drawer, matching: find.byType(Dialog)),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(panel, window);
      expect(surface.right, window.right);
      expect(surface.top, window.top);
      expect(surface.bottom, window.bottom);
      expect(surface.width, lessThan(window.width / 2));
      expect(table, findsOneWidget);
      expect(
        find.descendant(of: drawer, matching: find.text('alice@example.test')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: drawer, matching: find.text(_memberId)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: drawer, matching: find.text('Disable account')),
        findsOneWidget,
      );
      expect(find.text('Revoke all sessions'), findsOneWidget);
      expect(find.text('View sessions'), findsOneWidget);
      expect(find.text('Re-enable account'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('admin_account_drawer_close')));
      await tester.pumpAndSettle();
      expect(drawer, findsNothing);
      expect(find.text('Disable account'), findsNothing);

      // A disabled account offers to enable it again.
      await tester.tap(
        find.byKey(const ValueKey('admin_account_$_disabledId')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Re-enable account'), findsOneWidget);
      expect(find.text('Disable account'), findsNothing);
      // Clicking outside the panel closes it too.
      await tester.tapAt(const Offset(40, 500));
      await tester.pumpAndSettle();
      expect(find.text('Re-enable account'), findsNothing);

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
      expect(table, findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('the account panel follows the list and closes with the console', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      harness.app.page = WorkspacePage.admin;
      await _pump(tester, harness.app);
      await openSettingsCategory(tester, 'users');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin_account_$_memberId')));
      await tester.pumpAndSettle();
      final drawer = find.byKey(
        const ValueKey('admin_account_drawer_$_memberId'),
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('admin_account_detail_status_$_memberId'),
          ),
          matching: find.text('Active'),
        ),
        findsOneWidget,
      );

      // A reload that changes the account shows in the open panel.
      harness.api.accounts = [
        _account(_adminId, 'admin@example.test'),
        _account(_memberId, 'alice@example.test', status: 'disabled'),
      ];
      await harness.app.loadAdminAccounts();
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('admin_account_detail_status_$_memberId'),
          ),
          matching: find.text('Disabled'),
        ),
        findsOneWidget,
      );
      expect(find.text('Re-enable account'), findsOneWidget);

      // An account that left the list is said to be gone, with no actions.
      harness.api.accounts = [_account(_adminId, 'admin@example.test')];
      await harness.app.loadAdminAccounts();
      await tester.pumpAndSettle();
      expect(drawer, findsOneWidget);
      expect(find.text(currentL10n.adminUserNoLongerListed), findsOneWidget);
      expect(find.text('Re-enable account'), findsNothing);

      // Losing administrator access takes the panel away with the console.
      harness.app
        ..account = _profile(isAdmin: false)
        ..setStage(ClientStage.workspace);
      await tester.pumpAndSettle();
      expect(drawer, findsNothing);
      expect(find.byKey(_panel), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('a narrow window lists accounts in two-line rows', (tester) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      harness.app.page = WorkspacePage.admin;
      await _pump(tester, harness.app);
      tester.view.physicalSize = const Size(390, 900);
      await tester.pumpAndSettle();
      await openSettingsCategory(tester, 'users');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('admin_accounts_table')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('admin_accounts_table_header')),
        findsNothing,
      );
      final row = find.byKey(const ValueKey('admin_account_$_memberId'));
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('Disable account'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('an active filter stays clearable on a one-account page', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      harness.app.page = WorkspacePage.admin;
      await _pump(tester, harness.app);
      await openSettingsCategory(tester, 'users');
      await tester.pumpAndSettle();
      final filter = find.byKey(const ValueKey('admin_accounts_filter'));
      await tester.enterText(filter, 'ali');
      await tester.pumpAndSettle();

      // The next page (or a refresh) holds a single account that the filter
      // hides: the field must still be there to clear.
      harness.api.accounts = [
        _account('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'bob@example.test'),
      ];
      await harness.app.loadAdminAccounts(offset: 50);
      await tester.pumpAndSettle();
      expect(find.text('bob@example.test'), findsNothing);
      expect(find.text(currentL10n.adminPanelUserFilterNoMatch), findsOne);
      expect(filter, findsOneWidget);

      await tester.enterText(filter, '');
      await tester.pumpAndSettle();
      expect(find.text('bob@example.test'), findsOneWidget);
      expect(find.text(currentL10n.adminPanelUserFilterNoMatch), findsNothing);
      // With nothing typed a one-account page needs no filter.
      expect(filter, findsNothing);
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

  testWidgets('the access section holds only credential visibility', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      harness.app.instance = const InstanceInfo(
        instanceId: 'test-instance',
        serverSpaceId: 'test-space',
        generation: '1',
        protocolVersion: 1,
        setupRequired: false,
        capabilities: [credentialVisibilityCapability],
      );
      harness.app.page = WorkspacePage.admin;
      await _pump(tester, harness.app);
      expect(
        tester
            .widget<SettingsScaffold>(find.byKey(_panel))
            .sections
            .map((section) => section.id),
        [
          'instance',
          'users',
          'access',
          'instance-vaults',
          'backup',
          'audit',
        ],
      );
      await openSettingsCategory(tester, 'access');
      await tester.pumpAndSettle();
      final section = find.byKey(
        const ValueKey('admin_panel_section_access'),
      );
      expect(section, findsOneWidget);
      expect(find.text(currentL10n.adminPanelAccessTitle), findsWidgets);
      expect(
        find.descendant(
          of: section,
          matching: find.byType(CredentialVisibilityAdminCard),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: section, matching: find.byType(Card)),
        findsOneWidget,
      );
      // No relay policy, relay groups or allowlist editor: the server opens
      // relay connections itself.
      for (final key in [
        'admin-relay-policy-load',
        'admin-relay-policy-cidrs',
        'admin_relay_groups_refresh',
        'admin_relay_group_create_name',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(
        find.textContaining(RegExp('relay', caseSensitive: false)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('an account opened from the users table has no relay policy', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      harness.app.page = WorkspacePage.admin;
      await _pump(tester, harness.app);
      await openSettingsCategory(tester, 'users');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('admin_account_$_memberId')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('admin_account_drawer_$_memberId')),
        findsOneWidget,
      );
      expect(find.text('View sessions'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('admin_account_relay_policy_$_memberId')),
        findsNothing,
      );
      expect(
        find.textContaining(RegExp('relay', caseSensitive: false)),
        findsNothing,
      );
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
      // The controller agrees with what is rendered, and nothing loaded as
      // an administrator is kept for a later return of the flag.
      expect(harness.app.page, WorkspacePage.hosts);
      expect(harness.app.instanceAdminOverview, isNull);
      expect(harness.app.adminAccountsPage, isNull);

      harness.app
        ..account = _profile(isAdmin: true)
        ..setStage(ClientStage.workspace);
      await tester.pumpAndSettle();
      expect(harness.app.page, WorkspacePage.hosts);
      expect(find.byKey(_panel), findsNothing);
      expect(find.byKey(_navEntry), findsOneWidget);
    } finally {
      await _dispose(tester, harness);
    }
  });

  for (final isAdmin in [true, false]) {
    testWidgets('Settings lists no instance admin section (admin: $isAdmin)', (
      tester,
    ) async {
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
    });
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

  final agentChanges = <Map<String, Object?>>[];
  @override
  Future<WorkspaceAgentOverview> workspaceAgents() async =>
      WorkspaceAgentOverview.fromJson({
        'configured': true,
        'ssh_host': '172.30.83.2',
        'nodes': [
          for (final name in ['alpha', 'beta'])
            <String, dynamic>{
              'name': name,
              'enabled': true,
              'revision': 1,
              'online': true,
              'last_seen_seconds_ago': 1,
              'network': 'none',
              'host_ssh': true,
              'image': 'sha256:${'a' * 64}',
              'fingerprint': 'b' * 64,
            },
        ],
        'clusters': [
          <String, dynamic>{
            'cluster': 'lab',
            'node': 'alpha',
            'target': agentChanges.isEmpty ? null : 'beta',
            'phase': agentChanges.isEmpty ? 'Running' : 'Snapshot',
            'generation': agentChanges.isEmpty ? 1 : 2,
            'port': 24001,
            'pending_cleanup': 0,
            'type': 'workspace',
          },
        ],
      });
  @override
  Future<void> manageWorkspaceAgent(Map<String, Object?> command) async {
    agentChanges.add(command);
  }

  int adminCalls = 0;
  int accountListCalls = 0;
  List<Map<String, dynamic>>? accounts;

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
      'accounts':
          accounts ??
          [
            _account(_adminId, 'admin@example.test'),
            _account(_memberId, 'alice@example.test'),
            _account(
              'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
              'dana@example.test',
              status: 'disabled',
            ),
          ],
      'total': accounts == null ? 3 : offset + accounts!.length,
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
  'relay': {'enabled': true, 'max_connections_per_user': 3},
  'generated_at': '2026-09-29T12:30:00Z',
};
