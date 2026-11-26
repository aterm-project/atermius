import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
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

Future<void> _pumpSyncPage(
  WidgetTester tester, {
  required Size size,
  required Locale locale,
  required String status,
  int pending = 0,
  double textScale = 1,
  void Function(AppController app)? expectations,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  final previousL10n = currentL10n;
  debugCurrentL10n = lookupAppLocalizations(locale);
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..stage = ClientStage.workspace
        ..page = WorkspacePage.sync
        ..activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        )
        ..instance = const InstanceInfo(
          instanceId: '3c1d2e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f',
          serverSpaceId: 'space-1',
          generation: 'generation-current-987654321',
          protocolVersion: 1,
          setupRequired: false,
          capabilities: [],
        )
        ..syncStatus = status
        ..pendingCount = pending
        ..receivedCount = 12;
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
    expectations?.call(app);
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

  // An earlier page laid counters out in a fixed-ratio grid whose text
  // overflowed the tiles on phone widths.
  for (final lang in ['en', 'zh', 'ru']) {
    for (final width in [320.0, 390.0]) {
      testWidgets('sync health fits a ${width.toInt()} px phone in $lang', (
        tester,
      ) async {
        await _pumpSyncPage(
          tester,
          size: Size(width, 2400),
          locale: Locale(lang),
          status: 'resnapshot_required',
          pending: 2,
        );
      });
    }
  }

  testWidgets('sync health fits a phone at 1.5x text in Russian', (
    tester,
  ) async {
    await _pumpSyncPage(
      tester,
      size: const Size(390, 3200),
      locale: const Locale('ru'),
      status: 'auth_required',
      pending: 3,
      textScale: 1.5,
    );
  });

  testWidgets('a healthy Vault reads as up to date, nothing more', (
    tester,
  ) async {
    await _pumpSyncPage(
      tester,
      size: const Size(1440, 1400),
      locale: const Locale('en'),
      status: 'idle',
      expectations: (_) {
        expect(find.text('Up to date'), findsOneWidget);
        expect(
          find.text('This device is in sync with the server.'),
          findsOneWidget,
        );
        expect(find.text('Issue category'), findsNothing);
        expect(find.text('Sync now'), findsOneWidget);
        // The page is the status card only: no counters, recovery details,
        // diagnostics or empty conflict sections.
        for (final gone in [
          '12',
          'Recovery details',
          'Conflict branches',
          'Cross-device conflict inbox',
          'Open conflicts',
          'Export diagnostics',
          'Sync status',
        ]) {
          expect(find.text(gone), findsNothing, reason: gone);
        }
      },
    );
  });

  testWidgets('queued changes are counted in the summary', (tester) async {
    await _pumpSyncPage(
      tester,
      size: const Size(1440, 1400),
      locale: const Locale('en'),
      status: 'idle',
      pending: 3,
      expectations: (_) {
        expect(find.text('Idle'), findsOneWidget);
        expect(
          find.text('3 local changes are waiting to upload.'),
          findsOneWidget,
        );
      },
    );
  });

  testWidgets('an issue shows its category and what to do, localized', (
    tester,
  ) async {
    await _pumpSyncPage(
      tester,
      size: const Size(1440, 1400),
      locale: const Locale('zh'),
      status: 'offline',
      expectations: (_) {
        final zh = lookupAppLocalizations(const Locale('zh'));
        expect(find.text(zh.offline), findsOneWidget);
        expect(find.text(zh.syncHintOffline), findsOneWidget);
        expect(find.text(zh.issueCategory), findsOneWidget);
        expect(find.text(zh.networkUnavailable), findsOneWidget);
        expect(find.text('None'), findsNothing);
      },
    );
  });
}
