import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/domain/workspace_layout.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';
const _hostA = 'a1111111-1111-4111-8111-111111111111';
const _hostB = 'a2222222-2222-4222-8222-222222222222';
const _hostC = 'a3333333-3333-4333-8333-333333333333';
const _missingHost = 'a4444444-4444-4444-8444-444444444444';
const _tabsWorkspace = 'b1111111-1111-4111-8111-111111111111';
const _splitWorkspace = 'b2222222-2222-4222-8222-222222222222';
const _nestedWorkspace = 'b3333333-3333-4333-8333-333333333333';
const _paneA = 'c1111111-1111-4111-8111-111111111111';
const _paneMissing = 'c2222222-2222-4222-8222-222222222222';
const _paneC = 'c3333333-3333-4333-8333-333333333333';

void _seed(AppController app) {
  app.hosts.addAll(const [
    HostRecord(
      id: _hostA,
      name: 'db-primary-with-a-rather-long-name',
      address: '10.0.1.21',
      username: 'postgres',
    ),
    HostRecord(
      id: _hostB,
      name: 'api-gateway-01',
      address: 'api01.production.eu-central.example.test',
      username: 'deploy',
    ),
    HostRecord(
      id: _hostC,
      name: 'grafana',
      address: 'grafana.staging.example.test',
      username: 'ops',
    ),
  ]);
  app.snippets.addAll(const [
    SnippetRecord(
      id: 'disk',
      title: 'Disk usage',
      body: 'df -h && du -sh /var/log/* | sort -h | tail',
      tags: ['ops'],
    ),
    SnippetRecord(
      id: 'rotate',
      title:
          'Rotate and compress old release archives on every web node of the '
          'production cluster',
      shell: 'zsh',
      body:
          'set -euo pipefail\n'
          'for f in /srv/releases/*.tar; do\n'
          '  gzip -9 "\$f"\n'
          'done\n'
          'find /srv/releases -name "*.gz" -mtime +30 -delete\n'
          'echo done\n'
          'exit 0',
      tags: ['ops', 'cleanup', 'weekly', 'a-very-long-tag-name-for-wrapping'],
    ),
    SnippetRecord(
      id: 'search',
      title: 'Search files',
      body: '',
      executionMode: SnippetExecutionMode.bashCommand,
      program: 'grep',
      parameters: [
        SnippetParameter.text(name: 'pattern'),
        SnippetParameter.credential(name: 'token', credentialId: 'cred'),
      ],
      arguments: [
        SnippetArgument.literal('-rn'),
        SnippetArgument.literal('two words'),
        SnippetArgument.reference('pattern'),
        SnippetArgument.reference('token'),
      ],
      tags: ['search'],
    ),
  ]);
  app.savedWorkspaces.addAll([
    WorkspaceRecord.fromHostIds(
      id: _tabsWorkspace,
      name: 'Production triage with a long workspace name',
      hostIds: const [_hostA, _hostB, _hostC],
    ),
    WorkspaceRecord.fromSplitHostIds(
      id: _splitWorkspace,
      name: 'API + DB',
      hostIds: const [_hostB, _hostA],
      axis: WorkspaceSplitAxis.horizontal,
      splitRatioBasisPoints: 6500,
      activeIndex: 1,
    ),
    WorkspaceRecord.fromSplitTree(
      id: _nestedWorkspace,
      name: 'Release war room',
      activePaneId: _paneA,
      layoutTree: WorkspaceSplitNode(
        axis: WorkspaceSplitAxis.vertical,
        splitRatioBasisPoints: 6000,
        first: WorkspaceSplitNode(
          axis: WorkspaceSplitAxis.horizontal,
          splitRatioBasisPoints: 5000,
          first: WorkspaceTerminalNode(paneId: _paneA, hostId: _hostB),
          second: WorkspaceTerminalNode(
            paneId: _paneMissing,
            hostId: _missingHost,
          ),
        ),
        second: WorkspaceTerminalNode(paneId: _paneC, hostId: _hostC),
      ),
    ),
  ]);
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required WorkspacePage page,
  required Size size,
  required Locale locale,
  double textScale = 1,
  bool seeded = true,
  bool canWrite = true,
  void Function(AppLocalizations l10n)? expectations,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  final previousL10n = currentL10n;
  final l10n = lookupAppLocalizations(locale);
  debugCurrentL10n = l10n;
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      AppController(
          sodium: await SodiumSumoInit.init(),
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..stage = ClientStage.workspace
        ..page = page
        ..activeVault = VaultDescriptor(
          id: _vaultId,
          role: canWrite ? 'owner' : 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: canWrite,
        );
  if (seeded) _seed(app);
  try {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizationSetup.delegates,
        supportedLocales: AppLocalizationSetup.locales,
        theme: buildAppTheme(locale: locale),
        home: AppShell(controller: app),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expectations?.call(l10n);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await database.close();
    debugCurrentL10n = previousL10n;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pages = {
    'snippets': WorkspacePage.snippets,
    'saved workspaces': WorkspacePage.savedWorkspaces,
    'files': WorkspacePage.sftp,
  };

  for (final MapEntry(key: name, value: page) in pages.entries) {
    for (final lang in ['en', 'zh', 'ru']) {
      for (final width in [320.0, 390.0]) {
        testWidgets('$name fits a ${width.toInt()} px phone in $lang', (
          tester,
        ) async {
          await _pumpPage(
            tester,
            page: page,
            size: Size(width, 3200),
            locale: Locale(lang),
          );
        });
      }
    }

    testWidgets('$name fits a phone at 1.5x text in Russian', (tester) async {
      await _pumpPage(
        tester,
        page: page,
        size: const Size(320, 4800),
        locale: const Locale('ru'),
        textScale: 1.5,
      );
    });

    testWidgets('$name empty state fits a phone at 1.5x text', (tester) async {
      await _pumpPage(
        tester,
        page: page,
        size: const Size(320, 1600),
        locale: const Locale('ru'),
        textScale: 1.5,
        seeded: false,
      );
    });
  }

  testWidgets('snippet cards share rows on a wide window', (tester) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.snippets,
      size: const Size(1440, 1400),
      locale: const Locale('en'),
      expectations: (l10n) {
        final disk = tester.getRect(find.text('Disk usage'));
        final rotate = tester.getRect(find.textContaining('Rotate and'));
        expect(rotate.top, disk.top, reason: 'two cards on one row');
        expect(rotate.left, greaterThan(disk.right));
        // The structured command reads like the command, parameters in braces.
        expect(
          find.text("grep -rn 'two words' {pattern} {token}"),
          findsOneWidget,
        );
        expect(find.text(l10n.snippetsParameterCount(2)), findsOneWidget);
        expect(find.text(l10n.snippetsMoreLines(3)), findsOneWidget);
        expect(find.text('#cleanup'), findsOneWidget);
        expect(find.text(l10n.reviewAndRun), findsNWidgets(3));
        // Copy only appears where there is a script to copy.
        expect(find.byTooltip(l10n.copy), findsNWidgets(2));
        expect(find.text(l10n.snippetsReadOnlyNotice), findsNothing);
      },
    );
  });

  testWidgets('a read-only Vault explains the disabled snippet actions', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.snippets,
      size: const Size(1440, 1400),
      locale: const Locale('en'),
      canWrite: false,
      expectations: (l10n) {
        expect(find.text(l10n.snippetsReadOnlyNotice), findsOneWidget);
        final newSnippet = tester.widget<FilledButton>(
          find.ancestor(
            of: find.text(l10n.newSnippet),
            matching: find.byWidgetPredicate(
              (widget) => widget is FilledButton,
            ),
          ),
        );
        expect(newSnippet.onPressed, isNull);
      },
    );
  });

  testWidgets('saved workspace actions sit on the title row', (tester) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.savedWorkspaces,
      size: const Size(1800, 1400),
      locale: const Locale('en'),
      expectations: (l10n) {
        final title = tester.getRect(find.text(l10n.savedWorkspaces));
        final save = tester.getRect(
          find.byKey(const ValueKey('workspace-save-current')),
        );
        final split = tester.getRect(
          find.byKey(const ValueKey('workspace-create-split')),
        );
        expect(save.top, lessThan(title.bottom));
        expect(split.top, save.top);
        // Two cards per row on a wide window.
        final tabs = tester.getRect(
          find.byKey(const ValueKey('saved-workspace-$_tabsWorkspace')),
        );
        final pair = tester.getRect(
          find.byKey(const ValueKey('saved-workspace-$_splitWorkspace')),
        );
        expect(pair.top, tabs.top);
        expect(pair.height, tabs.height);
        expect(
          find.text(
            'Pane 1 · api-gateway-01 · api01.production.eu-central.example.test:22',
          ),
          findsNWidgets(2),
        );
        expect(find.textContaining(l10n.missingHost), findsOneWidget);
        expect(find.text(l10n.replaceHost), findsOneWidget);
        expect(find.text(l10n.missingcountMissing(1)), findsOneWidget);
        expect(
          find.byKey(ValueKey('workspace-topology-$_nestedWorkspace-split-1')),
          findsOneWidget,
        );
        expect(find.text(l10n.onlyTheHostIdTabOrder), findsOneWidget);
      },
    );
  });
}
