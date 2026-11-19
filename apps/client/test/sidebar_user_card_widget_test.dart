import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
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
const _accountId = '1f1368ed-3333-4333-8333-333333333333';
const _deviceId = '44444444-4444-4444-8444-444444444444';
const _vault = VaultDescriptor(
  id: _vaultId,
  role: 'owner',
  activeKeyEpoch: '1',
  membershipVersion: '1',
);

const _card = ValueKey('home_nav_user_card');
const _identity = ValueKey('home_nav_user_identity');
const _role = ValueKey('home_nav_user_role');

class _Harness {
  _Harness(this.app, this.database);
  final AppController app;
  final ClientDatabase database;

  static Future<_Harness> create({
    String? username = 'admin@atermius.test',
    bool admin = false,
  }) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..activeVault = _vault
          ..authenticatedUsernameForTesting = username
          ..account = AccountProfile(
            accountId: _accountId,
            deviceId: _deviceId,
            accountKeyEnvelopeVersion: 1,
            accountKeyEnvelope: const {},
            policy: {'instance_admin': admin},
          )
          ..session = const AuthSession(
            accountId: _accountId,
            accessToken: 'test-access-token',
            expiresIn: 900,
            refreshToken: 'test-refresh-token',
            deviceId: _deviceId,
            vaults: [_vault],
          );
    return _Harness(app, database);
  }

  Future<void> pump(
    WidgetTester tester,
    Size size, {
    Locale locale = const Locale('en'),
  }) async {
    await tester.binding.setSurfaceSize(size);
    debugCurrentL10n = appLocalizationsFor(locale);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizationSetup.delegates,
        supportedLocales: AppLocalizationSetup.locales,
        theme: buildAppTheme().copyWith(platform: TargetPlatform.linux),
        home: AppShell(controller: app),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await database.close();
    await tester.binding.setSurfaceSize(null);
    debugCurrentL10n = appLocalizationsFor(const Locale('en'));
  }
}

Finder _nav(String page) => find.byKey(ValueKey('home_nav_$page'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('user card names the signed-in account and has no remark', (
    tester,
  ) async {
    final h = await _Harness.create();
    try {
      await h.pump(tester, const Size(1280, 800), locale: const Locale('zh'));

      final title = tester.widget<Text>(find.byKey(_identity));
      expect(title.data, 'admin@atermius.test');
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(
        find.ancestor(
          of: find.byKey(_identity),
          matching: find.byWidgetPredicate(
            (w) => w is Tooltip && w.message == 'admin@atermius.test',
          ),
        ),
        findsOneWidget,
      );
      // No id prefix, no session/encryption remark, no role for a member.
      expect(find.text('1f1368ed'), findsNothing);
      expect(find.text('加密会话已解锁'), findsNothing);
      expect(find.text('账户会话已解锁'), findsNothing);
      expect(find.byKey(_role), findsNothing);
      // Members get no admin destination either.
      expect(_nav('admin'), findsNothing);
      expect(_nav('settings'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(_card), matching: find.byType(Text)),
        findsOneWidget,
      );
      // The lock action stays on the card.
      expect(
        find.descendant(
          of: find.byKey(_card),
          matching: find.byTooltip('锁定工作区'),
        ),
        findsOneWidget,
      );
    } finally {
      await h.close(tester);
    }
  });

  testWidgets('instance admins get the admin console link as the only '
      'secondary line', (tester) async {
    final h = await _Harness.create(admin: true);
    try {
      await h.pump(tester, const Size(1280, 800), locale: const Locale('zh'));
      expect(tester.widget<Text>(find.byKey(_role)).data, '管理控制台');
      expect(
        find.descendant(of: find.byKey(_card), matching: find.byType(Text)),
        findsNWidgets(2),
      );
      // The line is the way into the console; the workspace has no Admin
      // page of its own.
      expect(_nav('admin'), findsNothing);
      final card = tester.getRect(find.byKey(_card));
      final link = tester.getRect(
        find.byKey(const ValueKey('home_nav_admin_console')),
      );
      expect(link.left, greaterThanOrEqualTo(card.left));
      expect(link.right, lessThanOrEqualTo(card.right));
      await tester.tap(find.byKey(const ValueKey('home_nav_admin_console')));
      await tester.pumpAndSettle();
      expect(h.app.page, WorkspacePage.admin);
      expect(find.byKey(_card), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await h.close(tester);
    }
  });

  testWidgets('a long account name stays on one ellipsized line', (
    tester,
  ) async {
    const long = 'a-very-long-operator-account-name@subdomain.example.test';
    final h = await _Harness.create(username: long, admin: true);
    try {
      await h.pump(tester, const Size(1280, 800));
      expect(tester.takeException(), isNull);
      final card = tester.getRect(find.byKey(_card));
      final title = tester.getRect(find.byKey(_identity));
      expect(title.height, lessThan(20));
      expect(title.right, lessThanOrEqualTo(card.right));
      expect(find.byTooltip(long), findsOneWidget);
    } finally {
      await h.close(tester);
    }
  });

  testWidgets('falls back to the account id prefix without a username', (
    tester,
  ) async {
    final h = await _Harness.create(username: null);
    try {
      await h.pump(tester, const Size(1280, 800));
      expect(tester.widget<Text>(find.byKey(_identity)).data, '1f1368ed');
    } finally {
      await h.close(tester);
    }
  });

  testWidgets('1280x800: every destination is visible above the pinned card', (
    tester,
  ) async {
    final h = await _Harness.create(admin: true);
    try {
      await h.pump(tester, const Size(1280, 800), locale: const Locale('zh'));
      expect(tester.takeException(), isNull);

      final card = tester.getRect(find.byKey(_card));
      final importExport = tester.getRect(
        find.byKey(const ValueKey('home_nav_import_export')),
      );
      expect(card.bottom, lessThanOrEqualTo(800));
      expect(importExport.bottom, lessThanOrEqualTo(card.top));
      // The last entries used to sit below the fold.
      for (final page in ['hosts', 'audit', 'devices', 'settings']) {
        final rect = tester.getRect(_nav(page));
        expect(rect.top, greaterThanOrEqualTo(0), reason: page);
        expect(rect.bottom, lessThanOrEqualTo(importExport.top), reason: page);
      }
      // The admin console is not one of the destinations.
      expect(_nav('admin'), findsNothing);
      // Rows are compacted, not clipped.
      expect(tester.getSize(_nav('hosts')).height, inInclusiveRange(30, 38));
      expect(find.text('管理'), findsNothing);
      expect(find.text('设备'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      // Nothing to scroll, so no permanent scrollbar thumb.
      final bar = tester.widget<Scrollbar>(
        find.byKey(const ValueKey('home_nav_scrollbar')),
      );
      expect(bar.thumbVisibility, isFalse);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('home_nav_scrollbar')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scrollable.position.maxScrollExtent, 0);

      await tester.tap(_nav('settings'));
      await tester.pumpAndSettle();
      expect(h.app.page, WorkspacePage.settings);
    } finally {
      await h.close(tester);
    }
  });

  testWidgets('tall windows keep the regular 38px rows', (tester) async {
    final h = await _Harness.create(admin: true);
    try {
      await h.pump(tester, const Size(1280, 1000));
      expect(tester.getSize(_nav('hosts')).height, 38);
      expect(
        tester.getRect(_nav('groups')).top -
            tester.getRect(_nav('hosts')).bottom,
        4,
      );
      expect(
        tester
            .widget<Scrollbar>(find.byKey(const ValueKey('home_nav_scrollbar')))
            .thumbVisibility,
        isFalse,
      );
    } finally {
      await h.close(tester);
    }
  });

  testWidgets('very short windows scroll with a visible scrollbar and keep '
      'the footer pinned', (tester) async {
    final h = await _Harness.create(admin: true);
    try {
      await h.pump(tester, const Size(1280, 520));
      expect(tester.takeException(), isNull);
      // Rows never shrink below the compact minimum.
      expect(tester.getSize(_nav('hosts')).height, 30);
      expect(
        tester
            .widget<Scrollbar>(find.byKey(const ValueKey('home_nav_scrollbar')))
            .thumbVisibility,
        isTrue,
      );
      final card = tester.getRect(find.byKey(_card));
      expect(card.bottom, lessThanOrEqualTo(520));
      expect(
        tester
            .getRect(find.byKey(const ValueKey('home_nav_import_export')))
            .bottom,
        lessThanOrEqualTo(card.top),
      );
      await tester.scrollUntilVisible(
        _nav('settings'),
        60,
        scrollable: find.descendant(
          of: find.byKey(const ValueKey('home_nav_scrollbar')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(_nav('settings'));
      await tester.pumpAndSettle();
      expect(h.app.page, WorkspacePage.settings);
    } finally {
      await h.close(tester);
    }
  });
}
