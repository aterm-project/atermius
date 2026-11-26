import 'dart:async';

import 'package:aterm_client/app_update/app_update_backend.dart';
import 'package:aterm_client/app_update/app_update_channel.dart';
import 'package:aterm_client/app_update/app_update_controller.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/app_update_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _current = 'local-20261124.2-178e1a78f57b';
const _next = 'local-20261124.3-0123456789ab';

AppUpdateRelease _release(String tag) => AppUpdateRelease(
  tag: tag,
  title: 'Atermius $tag',
  page: Uri.parse('https://example.invalid/$tag'),
  assetName: 'atermius-$tag.zip',
  assetUrl: Uri.parse('https://example.invalid/$tag.zip'),
  size: 100,
  sha256: 'a' * 64,
);

class _Channel implements AppUpdateChannel {
  AppUpdateRelease? release;
  @override
  Future<AppUpdateRelease?> latest({
    required String currentTag,
    required AppUpdateTarget target,
  }) async => release;
}

class _Backend implements AppUpdateBackend {
  bool installable = true;
  AppUpdateStaged? stagedNow;
  AppUpdateResult? result;
  AppUpdateApplyProblem? applyProblem;
  int applied = 0;
  bool others = false;
  final closedOthers = <bool>[];

  @override
  Future<bool> canInstall() async => installable;
  @override
  Future<AppUpdateStaged?> staged(String currentTag) async => stagedNow;
  @override
  Future<Set<String>> blockedTags() async => {};
  @override
  Future<AppUpdateResult?> takeResult() async => result;
  @override
  Future<bool> metered() async => false;
  @override
  Stream<AppUpdateApplyProblem> get problems => const Stream.empty();
  @override
  Future<AppUpdateStaged?> stage(
    AppUpdateRelease release, {
    required void Function(double fraction) onProgress,
  }) async => stagedNow = AppUpdateStaged(release: release, path: '/x');
  @override
  Future<AppUpdateApplyProblem?> apply(
    AppUpdateStaged staged, {
    bool closeOthers = false,
  }) async {
    applied++;
    closedOthers.add(closeOthers);
    return applyProblem;
  }

  @override
  Future<bool> othersRunning() async => others;

  @override
  Stream<void> get closeRequests => const Stream.empty();

  @override
  Future<bool> applyOnExit() async => false;

  @override
  Future<void> cleanup(String currentTag) async {}
}

void main() {
  late _Channel channel;
  late _Backend backend;
  var sessions = 0;

  Future<AppUpdateController> pump(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    bool automatic = true,
    bool settings = false,
  }) async {
    final controller = AppUpdateController(
      currentTag: _current,
      target: AppUpdateTarget.windowsX64,
      channel: channel,
      backend: backend,
      settings: MemoryAppUpdateSettingStore(automatic),
      startDelay: const Duration(days: 1),
      stagedPollInterval: const Duration(days: 1),
      applyWatchdog: const Duration(milliseconds: 10),
    );
    addTearDown(controller.dispose);
    await tester.runAsync(controller.start);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(locale: locale),
        home: Scaffold(
          body: SingleChildScrollView(
            child: settings
                ? AppUpdateSettingsCard(
                    controller: controller,
                    openSessions: () => sessions,
                  )
                : AppUpdateBanner(
                    controller: controller,
                    openSessions: () => sessions,
                  ),
          ),
        ),
      ),
    );
    return controller;
  }

  setUp(() {
    channel = _Channel();
    backend = _Backend();
    sessions = 0;
  });

  testWidgets('nothing is shown while the app is current', (tester) async {
    final controller = await pump(tester);
    await tester.runAsync(controller.checkNow);
    await tester.pump();
    expect(find.byKey(const ValueKey('app_update_banner')), findsNothing);
  });

  testWidgets('a version installed in the background offers the restart',
      (tester) async {
    channel.release = _release(_next);
    final controller = await pump(tester, locale: const Locale('zh'));
    expect(find.byKey(const ValueKey('app_update_banner')), findsNothing);
    await tester.runAsync(controller.checkNow);
    await tester.pump();
    expect(find.text('新版本已就绪'), findsOneWidget);
    expect(find.textContaining('20261124.3'), findsOneWidget);
    expect(find.textContaining('重启后即可使用'), findsOneWidget);
    expect(find.text('立即重启'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app_update_restart')));
    await tester.pumpAndSettle();
    // Closing the app is always confirmed on desktop, sessions or not.
    expect(find.text('关闭当前工作区并更新？'), findsOneWidget);
    expect(
      find.textContaining('Atermius 将关闭并安装 20261124.3'),
      findsOneWidget,
    );
    expect(find.textContaining('其他 Atermius 窗口'), findsNothing);
    expect(backend.applied, 0);
    await tester.tap(find.byKey(const ValueKey('app_update_restart_confirm')));
    await tester.pump();
    expect(backend.applied, 1);
    expect(backend.closedOthers, [true]);
    await tester.pump(const Duration(milliseconds: 20));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('cancelling the desktop confirmation changes nothing',
      (tester) async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('app_update_restart')));
    await tester.pumpAndSettle();
    expect(find.text('Close the current workspace and update?'), findsOneWidget);
    expect(find.text('Close and update'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app_update_restart_cancel')));
    await tester.pumpAndSettle();
    expect(backend.applied, 0);
    expect(find.byKey(const ValueKey('app_update_banner_problem')), findsNothing);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('Android says that installing closes the app', (tester) async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    await pump(tester, locale: const Locale('zh'));
    expect(find.text('新版本已就绪'), findsOneWidget);
    expect(find.textContaining('安装时应用会关闭'), findsOneWidget);
    expect(find.text('安装并重启'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('open sessions are confirmed before the restart', (tester) async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    sessions = 2;
    await pump(tester);
    expect(find.text('New version ready'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app_update_restart')));
    await tester.pumpAndSettle();
    expect(find.text('2 open sessions will be disconnected.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app_update_restart_cancel')));
    await tester.pumpAndSettle();
    expect(backend.applied, 0);
    await tester.tap(find.byKey(const ValueKey('app_update_restart')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app_update_restart_confirm')));
    await tester.pumpAndSettle();
    expect(backend.applied, 1);
  });

  testWidgets('other windows and sessions are named in the confirmation',
      (tester) async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    backend.others = true;
    sessions = 3;
    await pump(tester, locale: const Locale('zh'));
    await tester.tap(find.byKey(const ValueKey('app_update_restart')));
    await tester.pumpAndSettle();
    expect(find.text('关闭当前工作区并更新？'), findsOneWidget);
    expect(find.text('有 3 个会话正在连接，重启会断开它们。'), findsOneWidget);
    expect(
      find.text('其他 Atermius 窗口也会一起关闭，包括在通知区域后台运行的。'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('app_update_restart_confirm')));
    await tester.pumpAndSettle();
    // Asked to close them, not told to do it by hand.
    expect(backend.closedOthers, [true]);
    expect(find.byKey(const ValueKey('app_update_banner_problem')), findsNothing);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('windows that did not close are reported after the attempt',
      (tester) async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    backend.others = true;
    backend.applyProblem = AppUpdateApplyProblem.otherWindowsOpen;
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('app_update_restart')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app_update_restart_confirm')));
    await tester.pumpAndSettle();
    expect(
      find.text('Some Atermius windows did not close. Close them, then try again.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('app_update_restart')), findsOneWidget);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('a copy that cannot update itself points to the download',
      (tester) async {
    backend.installable = false;
    channel.release = _release(_next);
    final controller = await pump(tester);
    await tester.runAsync(controller.checkNow);
    await tester.pump();
    expect(find.text('Atermius 20261124.3 is available'), findsOneWidget);
    expect(find.text('Open download page'), findsOneWidget);
    expect(find.byKey(const ValueKey('app_update_download')), findsNothing);
    expect(find.byKey(const ValueKey('app_update_restart')), findsNothing);
  });

  testWidgets('with automatic updates off the banner offers the download',
      (tester) async {
    channel.release = _release(_next);
    final controller = await pump(tester, automatic: false);
    await tester.runAsync(controller.checkNow);
    await tester.pump();
    expect(find.text('Automatic updates are off.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app_update_download')));
    await tester.pump();
    await tester.pump();
    expect(find.text('New version ready'), findsOneWidget);
  });

  testWidgets('the first start after an update says so, once', (tester) async {
    backend.result = const AppUpdateResult(tag: _current, succeeded: true);
    await pump(tester);
    expect(find.text('Updated to Atermius 20261124.2.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app_update_dismiss')));
    await tester.pump();
    expect(find.byKey(const ValueKey('app_update_banner')), findsNothing);
  });

  testWidgets('settings show the version, the state and the switch',
      (tester) async {
    channel.release = _release(_next);
    final controller = await pump(tester, settings: true);
    expect(find.text('Current version: 20261124.2'), findsOneWidget);
    await tester.runAsync(controller.checkNow);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('app_update_settings_restart')),
      findsOneWidget,
    );
    expect(controller.automatic, isTrue);
    await tester.tap(find.byKey(const ValueKey('app_update_automatic')));
    await tester.pump();
    expect(controller.automatic, isFalse);
  });

  testWidgets('settings report a current app after a check', (tester) async {
    final controller = await pump(tester, settings: true);
    expect(find.byKey(const ValueKey('app_update_status')), findsNothing);
    await tester.runAsync(controller.checkNow);
    await tester.pump();
    expect(find.text('Atermius is up to date.'), findsOneWidget);
  });
}
