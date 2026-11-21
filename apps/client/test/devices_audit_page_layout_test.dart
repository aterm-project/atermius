import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
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
const _accountId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

void _seedDevices(AppController app) {
  app
    ..devices = [
      {
        'device_id': app.identity!.deviceId,
        'name': 'This laptop',
        'status': 'active',
        'created_at': '2026-10-21T09:00:00Z',
        'signed_in': true,
        'signing_public_key': 'c2lnbmluZy1rZXktcHVibGlj',
        'activity': {
          'platform': 'macos',
          'device_name': 'MacBook Pro with a rather long device name',
        },
      },
      {
        'device_id': 'd-1111',
        'name': 'Windows workstation',
        'status': 'active',
        'created_at': '2026-11-01T09:00:00Z',
        'signed_in': true,
        'signing_public_key': 'c2lnbmluZy1rZXktcHVibGlk',
        'activity': {'platform': 'windows', 'device_name': 'Workstation'},
      },
      {
        'device_id': 'd-2222',
        'name': 'Pixel 9',
        'status': 'active',
        'created_at': '2026-11-10T09:00:00Z',
        'signed_in': false,
        'signing_public_key': 'c2lnbmluZy1rZXktcHVibGll',
        'activity': {'platform': 'android', 'device_name': 'Pixel 9'},
      },
      {
        'device_id': 'd-3333',
        'name': 'Browser',
        'status': 'active',
        'created_at': '2026-11-12T09:00:00Z',
        'signed_in': true,
        'signing_public_key': 'c2lnbmluZy1rZXktcHVibGlm',
        'activity': {
          'platform': 'web',
          'user_agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
          'last_ip': '2001:db8:1234:5678:9abc:def0:1234:5678',
          'ip_history': ['198.51.100.9', '2001:db8::1', '203.0.113.77'],
        },
      },
      {
        'device_id': 'd-4444',
        'name': 'Old iPad',
        'status': 'revoked',
        'created_at': '2026-03-02T09:00:00Z',
        'revoked_at': '2026-09-04T12:34:00Z',
        'signing_public_key': 'c2lnbmluZy1rZXktcHVibGln',
      },
      {
        'device_id': 'd-5555',
        'name': 'Staging runner',
        'status': 'pending',
        'signing_public_key': 'c2lnbmluZy1rZXktcHVibGlo',
      },
    ]
    ..vaultDeviceRowsVaultId = _vaultId
    ..vaultDeviceRows = [
      {
        'device_id': '77777777-7777-4777-8777-777777777777',
        'user_id': _accountId,
        'name': 'A Vault device whose name is long enough to wrap',
        'signing_public_key': 'c2lnbmluZy1rZXktcHVibGlj',
        'status': 'active',
        'membership_status': 'active',
        'redaction_capability_report': null,
      },
      {
        'device_id': '88888888-8888-4888-8888-888888888888',
        'user_id': _accountId,
        'name': 'Browser',
        'signing_public_key': 'c2lnbmluZy1rZXktcHVibGlj',
        'status': 'active',
        'membership_status': 'active',
      },
    ];
}

/// Event times count back from noon so the day groups (today, yesterday,
/// a date) do not depend on when the test runs.
DateTime _noonToday() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, 12);
}

AuditEvent _event(
  String id,
  String scope,
  String action, {
  String resourceType = 'account',
  String? resourceId,
  String result = 'success',
  String source = 'api',
  Duration age = const Duration(minutes: 5),
}) => AuditEvent(
  eventId: id,
  scope: scope,
  vaultId: scope == 'vault' ? _vaultId : null,
  actorUserId: '33333333-3333-4333-8333-333333333333',
  actorDeviceId: '44444444-4444-4444-8444-444444444444',
  action: action,
  resourceType: resourceType,
  resourceId: resourceId,
  result: result,
  occurredAt: _noonToday().subtract(age).toUtc(),
  source: source,
);

void _seedAudit(AppController app) {
  app.auditPageEvents = [
    _event(
      '41',
      'account',
      'auth.login_succeeded',
      resourceType: 'session',
      resourceId: '88888888-8888-4888-8888-888888888888',
    ),
    _event(
      '40',
      'account',
      'auth.refresh_reuse_detected',
      resourceType: 'session_family',
      resourceId: '77777777-7777-4777-8777-777777777777',
      result: 'failure',
      age: const Duration(minutes: 20),
    ),
    _event(
      '39',
      'account',
      'account.purged',
      source: 'maintenance',
      age: const Duration(days: 1),
    ),
    _event(
      '38',
      'account',
      'some.unknown_action_with_a_long_name',
      resourceType: 'a_resource_type_with_a_long_name',
      resourceId: 'abc',
      result: 'odd',
      age: const Duration(days: 9),
    ),
    _event(
      '20',
      'vault',
      'vault.member_role_changed',
      resourceType: 'membership',
      resourceId: '55555555-5555-4555-8555-555555555555',
      age: const Duration(hours: 2),
    ),
  ];
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required WorkspacePage page,
  required Size size,
  required Locale locale,
  double textScale = 1,
  void Function(AppController app)? configure,
  Future<void> Function(AppController app)? expectations,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  final previousL10n = currentL10n;
  debugCurrentL10n = lookupAppLocalizations(locale);
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final identity = DeviceIdentity.create(sodium);
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..stage = ClientStage.workspace
        ..page = page
        ..identity = identity
        ..activeVault = const VaultDescriptor(
          id: _vaultId,
          role: 'owner',
          activeKeyEpoch: '1',
          membershipVersion: '1',
        );
  _seedDevices(app);
  _seedAudit(app);
  configure?.call(app);
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
    await expectations?.call(app);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    identity.dispose();
    await database.close();
    debugCurrentL10n = previousL10n;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final lang in ['en', 'zh', 'ru']) {
    for (final width in [320.0, 390.0]) {
      testWidgets('trusted devices fit a ${width.toInt()} px phone in $lang', (
        tester,
      ) async {
        await _pumpPage(
          tester,
          page: WorkspacePage.devices,
          size: Size(width, 4000),
          locale: Locale(lang),
        );
      });

      testWidgets('audit records fit a ${width.toInt()} px phone in $lang', (
        tester,
      ) async {
        await _pumpPage(
          tester,
          page: WorkspacePage.audit,
          size: Size(width, 2600),
          locale: Locale(lang),
        );
      });
    }
  }

  testWidgets('trusted devices fit a phone at 1.5x text in Russian', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.devices,
      size: const Size(390, 6000),
      locale: const Locale('ru'),
      textScale: 1.5,
    );
  });

  testWidgets('audit records fit a phone at 1.5x text in Russian', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.audit,
      size: const Size(390, 3600),
      locale: const Locale('ru'),
      textScale: 1.5,
    );
  });

  testWidgets('audit error and pager fit 320 px at 1.5x text', (tester) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.audit,
      size: const Size(320, 2000),
      locale: const Locale('ru'),
      textScale: 1.5,
      configure: (app) => app
        ..auditError = 'The audit cursor expired.'
        ..auditPageIndex = 2,
      expectations: (_) async {
        final ru = lookupAppLocalizations(const Locale('ru'));
        expect(find.text(ru.couldntLoadAuditRecords), findsOneWidget);
        expect(find.byTooltip(ru.previousPage), findsOneWidget);
        expect(find.byTooltip(ru.nextPage), findsOneWidget);
      },
    );
  });

  testWidgets('device and readiness statuses are localized, never raw', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.devices,
      size: const Size(1440, 2400),
      locale: const Locale('zh'),
      expectations: (_) async {
        final zh = lookupAppLocalizations(const Locale('zh'));
        expect(find.text(zh.devicesStatusActive), findsNWidgets(4));
        expect(find.text(zh.devicesStatusRevoked), findsOneWidget);
        expect(find.text(zh.devicesStatusUnknown), findsOneWidget);
        expect(find.text(zh.devicesThisDevice), findsOneWidget);
        expect(find.text(zh.devicesActiveCount(4)), findsOneWidget);
        expect(find.text(zh.devicesRevokedCount(1)), findsOneWidget);
        expect(find.text(zh.devicesReadinessMissing), findsOneWidget);
        expect(find.text(zh.devicesReadinessUnverifiable), findsOneWidget);
        expect(find.text(zh.devicesReadinessSummary(0, 2, 2)), findsOneWidget);
        for (final raw in [
          'Active',
          'Revoked',
          'pending',
          'Status unavailable',
          'Report not received',
        ]) {
          expect(find.text(raw), findsNothing, reason: raw);
        }
        // Signed-in devices other than this one can be signed out; every
        // active device other than this one can be revoked.
        expect(find.byTooltip(zh.signOutDevice), findsNWidgets(2));
        expect(find.byTooltip(zh.revokeDevice), findsNWidgets(3));
        expect(find.byTooltip(zh.refreshDevices), findsOneWidget);
        expect(find.text(zh.approveEnrollment), findsOneWidget);
      },
    );
  });

  testWidgets('audit rows show result, day groups, scope chips and pager', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.audit,
      size: const Size(1440, 1400),
      locale: const Locale('en'),
      expectations: (app) async {
        expect(find.text('Today'), findsOneWidget);
        expect(find.text('Yesterday'), findsOneWidget);
        expect(find.text('Signed in'), findsOneWidget);
        expect(find.text('Succeeded'), findsNWidgets(2));
        expect(find.text('Failed'), findsOneWidget);
        expect(find.text('Unknown result'), findsOneWidget);
        expect(find.text('1 failed'), findsOneWidget);
        expect(find.text('Page 1'), findsOneWidget);
        expect(find.text('4 events'), findsOneWidget);
        expect(find.text('Previous page'), findsOneWidget);
        expect(find.text('Next page'), findsOneWidget);
        // Vault events stay out of the account scope.
        expect(find.text('Member permissions changed'), findsNothing);

        await tester.tap(find.text('Current Vault'));
        await tester.pump();
        expect(app.auditScope, AuditScope.activeVault);
      },
    );
  });

  testWidgets('an empty audit scope shows no pager', (tester) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.audit,
      size: const Size(1440, 900),
      locale: const Locale('en'),
      configure: (app) => app.auditPageEvents = [],
      expectations: (_) async {
        expect(
          find.text('No audit records in the current scope'),
          findsOneWidget,
        );
        expect(find.text('Page 1'), findsNothing);
      },
    );
  });
}
