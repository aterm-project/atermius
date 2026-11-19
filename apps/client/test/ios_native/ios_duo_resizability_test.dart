// iPhone Duo（折叠屏 iPhone）运行时动态折叠 ↔ 展开无损自适应与非对称 SafeArea 回归测试。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/platform/native_coordination.dart';
import 'package:aterm_client/ssh/local_profile_ssh_controller.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/sync/known_host_decision_lock.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/home_sidebar.dart';
import 'package:aterm_client/ui/ios_native/ios_native.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/workspace_status_bar.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/native.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

import '../support/l10n_fixture.dart';

const _password = 'correct horse battery staple';
const _fingerprint = 'SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  useAppLocaleFixture('zh');
  TestWidgetsFlutterBinding.ensureInitialized();

  late VaultCrypto crypto;
  late Directory directory;
  late LocalProfileCatalog catalog;
  late LocalProfileRecord profileRecord;
  late UnlockedLocalProfile unlockedFixture;
  late List<LocalVaultDatabase> openedDatabases;
  late _FakeSshHarness sshHarness;
  late String hostId;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('aterm-ios-duo-');
    coordinationDirectory = () async =>
        Directory('${directory.path}/coordination');
    catalog = LocalProfileCatalog.forTesting(
      NativeDatabase(File('${directory.path}/catalog.sqlite')),
    );
    final realService = LocalProfileService(catalog: catalog, crypto: crypto);
    final seeded = await realService.create(password: _password);
    profileRecord = seeded.record;

    final seedDb = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
      profileId: profileRecord.profileId,
      localDataDomainId: profileRecord.localDataDomainId,
      localVaultId: profileRecord.localVaultId,
    );
    final seedRepo = LocalHostRepository(
      database: seedDb,
      profile: seeded,
      crypto: crypto,
    );
    final credId = const Uuid().v4();
    await seedRepo.createCredential(
      CredentialRecord(
        id: credId,
        name: 'Duo Test Key',
        username: 'root',
        kind: AuthKind.password,
        secret: 's3cr3t',
      ),
    );
    final saved = await seedRepo.createHost(
      HostRecord(
        id: const Uuid().v4(),
        name: '东京边缘节点-Duo',
        address: '198.51.100.14',
        port: 22,
        username: 'root',
        credentialId: credId,
      ),
    );
    hostId = saved.id;
    await seedDb.close();
    unlockedFixture = seeded;
    openedDatabases = [];
    sshHarness = _FakeSshHarness();
  });

  tearDown(() async {
    for (final db in openedDatabases.reversed) {
      try {
        await db.close();
      } on Object {
        // 已关闭则忽略。
      }
    }
    await unlockedFixture.lock();
    await catalog.close();
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<void> pumpUntilIdle(WidgetTester tester) async {
    var idleFrames = 0;
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      final busy =
          find.byType(CupertinoActivityIndicator).evaluate().isNotEmpty ||
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
          find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
      idleFrames = busy ? 0 : idleFrames + 1;
      if (idleFrames >= 4) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }
  }

  Future<void> pumpUntilVisible(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
    }
    final texts = tester
        .widgetList<Text>(find.byType(Text, skipOffstage: false))
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    fail('Expected $finder to become visible. Texts on screen: $texts');
  }

  Future<void> drainClose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 6));
  }

  Widget buildFlowApp() => MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizationSetup.delegates,
    supportedLocales: AppLocalizationSetup.locales,
    theme: buildAppTheme(platform: TargetPlatform.iOS, brightness: Brightness.light),
    darkTheme: buildAppTheme(platform: TargetPlatform.iOS, brightness: Brightness.dark),
    themeMode: ThemeMode.dark,
    home: LocalProfileFlow(
      catalog: catalog,
      service: _SinglePreUnlockedService(
        record: profileRecord,
        unlocked: unlockedFixture,
      ),
      crypto: crypto,
      persistentMode: true,
      onExit: () {},
      quarantineRegistry: DatabaseQuarantineRegistry(),
      databaseFactory: (profile, {required mode}) async {
        final r = profile.record;
        final db = await LocalVaultDatabase.openForTesting(
          executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
          profileId: r.profileId,
          localDataDomainId: r.localDataDomainId,
          localVaultId: r.localVaultId,
          mode: mode,
        );
        openedDatabases.add(db);
        return db;
      },
      sshControllerFactory: (repository) => LocalProfileSshController(
        repository: repository,
        serviceForTesting: sshHarness.createService(
          knownHostDecisionLock: repository.knownHostDecisionLock,
        ),
      ),
    ),
  );

  testWidgets(
    'iPhone Duo 折叠 (390×844) → 展开 (780×840) → 合盖 (390×844) 无损形态切换且活跃终端 State 零销毁重建',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetPadding();
        });

        await tester.pumpWidget(buildFlowApp());
        await pumpUntilIdle(tester);

        await tester.enterText(
          find.byKey(const ValueKey('local_profile_unlock_password')),
          _password,
        );
        await tester.tap(
          find.byKey(const ValueKey('local_profile_unlock_button')),
        );
        await pumpUntilIdle(tester);

        // 1. 合盖外屏 (390×844)：纯血 5-Tab 壳，无桌面顶栏/侧栏
        expect(find.byKey(const ValueKey('ios_glass_tab_bar')), findsOneWidget);
        expect(find.byType(WorkspaceTabBar), findsNothing);
        expect(find.byType(HomeSidebar), findsNothing);

        // 发起 SSH 连接进入全屏终端
        await tester.tap(find.byKey(ValueKey('local_host_$hostId')));
        await pumpUntilVisible(
          tester,
          find.byKey(const ValueKey('local_ssh_host_key_approve')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(
          find.byKey(const ValueKey('local_ssh_host_key_approve')),
        );
        await pumpUntilVisible(
          tester,
          find.byKey(const ValueKey('local_ssh_terminal_view')),
        );
        await tester.pump(const Duration(milliseconds: 450));

        expect(find.byKey(const ValueKey('ios_session_bar')), findsOneWidget);
        final State terminalWorkspaceFolded = tester.state(
          find.byType(SessionWorkspaceView, skipOffstage: false),
        );
        expect(sshHarness.sessions.last.closed, isFalse);

        // 2. 展开内屏 (780×840)：shortestSide >= 600，切换为桌面宽屏布局，但会话零重建不断连！
        tester.view.physicalSize = const Size(780, 840);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
        await tester.pumpAndSettle();

        expect(find.byType(WorkspaceTabBar), findsOneWidget);
        expect(find.byType(WorkspaceStatusBar), findsOneWidget);
        expect(find.byKey(const ValueKey('ios_session_bar')), findsNothing);

        final State terminalWorkspaceUnfolded = tester.state(
          find.byType(SessionWorkspaceView, skipOffstage: false),
        );
        expect(
          identical(terminalWorkspaceFolded, terminalWorkspaceUnfolded),
          isTrue,
        );
        expect(sshHarness.sessions.last.closed, isFalse);
        expect(tester.takeException(), isNull);

        // 3. 再次合盖回到外屏 (390×844)：恢复纯血 iPhone 壳，且终端会话 State 仍为同一实例
        tester.view.physicalSize = const Size(390, 844);
        tester.view.padding = const FakeViewPadding(top: 59, bottom: 34);
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('ios_session_bar')), findsOneWidget);
        expect(find.byType(WorkspaceTabBar), findsNothing);
        final State terminalWorkspaceRefolded = tester.state(
          find.byType(SessionWorkspaceView, skipOffstage: false),
        );
        expect(
          identical(terminalWorkspaceFolded, terminalWorkspaceRefolded),
          isTrue,
        );
        expect(sshHarness.sessions.last.closed, isFalse);
        expect(tester.takeException(), isNull);

        // 4. 在主板测试切到 Hosts 后再来回展开/合盖：HomeSidebar ↔ IosGlassTabBar 切换正常
        await tester.tap(find.byKey(const ValueKey('ios_session_bar_back')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('ios_glass_tab_bar')), findsOneWidget);
        expect(
          find.byKey(const ValueKey('ios_live_session_pill')),
          findsOneWidget,
        );

        tester.view.physicalSize = const Size(780, 840);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
        await tester.pumpAndSettle();
        expect(find.byType(HomeSidebar), findsOneWidget);
        expect(find.byType(WorkspaceTabBar), findsOneWidget);
        expect(tester.takeException(), isNull);

        await drainClose(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    '非对称水平 SafeArea (left: 68 / right: 0 及反向) 严格避让且不双侧多扣宽',
    (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(844, 390);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetPadding();
        tester.view.resetViewPadding();
      });

      Widget wrapWithPadding({
        required FakeViewPadding padding,
        required Widget child,
      }) {
        tester.view.padding = padding;
        tester.view.viewPadding = padding;
        return MaterialApp(
          theme: buildAppTheme(
            platform: TargetPlatform.iOS,
            brightness: Brightness.dark,
          ),
          home: child,
        );
      }

      const pillTabs = [
        WorkspaceTab(
          id: 'tab-1',
          title: 'Tokyo Prod',
          isConnected: true,
        ),
      ];

      // 场景 A：左侧刘海/垂直栏 68pt，右侧 0pt
      await tester.pumpWidget(
        wrapWithPadding(
          padding: const FakeViewPadding(top: 0, bottom: 21, left: 68, right: 0),
          child: Scaffold(
            backgroundColor: IosColors.dark.groupedBackground,
            body: IosTabScaffold(
              currentIndex: 0,
              onTabSelected: (_) {},
              accessory: IosLiveSessionPill(
                sessions: pillTabs,
                currentId: 'tab-1',
                onResume: (_) {},
                onShowSwitcher: () {},
              ),
              items: const [
                IosTabItem(id: 'hosts', icon: IosIcons.hosts, label: '主机'),
                IosTabItem(id: 'settings', icon: IosIcons.settings, label: '设置'),
              ],
              tabBuilder: (tabContext, _) => IosLargeTitlePage(
                title: '主机',
                largeTitle: false,
                searchField: buildIosSearchTextField(
                  tabContext,
                  placeholder: '搜索',
                ),
                slivers: [
                  SliverToBoxAdapter(
                    child: IosListSection(
                      key: const ValueKey('duo_safe_section'),
                      children: [
                        IosListRow(
                          key: const ValueKey('duo_safe_row'),
                          title: const Text('Node-01'),
                          onTap: () {},
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final tabBarRectLeft = tester.getRect(
        find.byKey(const ValueKey('ios_glass_tab_bar')),
      );
      final pillRectLeft = tester.getRect(
        find.byKey(const ValueKey('ios_live_session_pill')),
      );
      final sectionRectLeft = tester.getRect(
        find.byKey(const ValueKey('duo_safe_section')),
      );
      final rowRectLeft = tester.getRect(
        find.byKey(const ValueKey('duo_safe_row')),
      );
      expect(tabBarRectLeft.left, closeTo(68 + IosMetrics.tabBarMargin, 0.5));
      expect(tabBarRectLeft.right, closeTo(844 - IosMetrics.tabBarMargin, 0.5));
      expect(pillRectLeft.left, closeTo(68 + IosMetrics.tabBarMargin, 0.5));
      expect(pillRectLeft.right, closeTo(844 - IosMetrics.tabBarMargin, 0.5));
      expect(sectionRectLeft.left, closeTo(68, 0.5));
      expect(sectionRectLeft.right, closeTo(844, 0.5));
      expect(rowRectLeft.left, closeTo(68 + IosMetrics.sectionMargin, 0.5));
      expect(rowRectLeft.right, closeTo(844 - IosMetrics.sectionMargin, 0.5));

      // 场景 B：左侧 0pt，右侧垂直栏 68pt，并验证 IosSessionBar + IosToast
      await tester.pumpWidget(
        wrapWithPadding(
          padding: const FakeViewPadding(top: 0, bottom: 21, left: 0, right: 68),
          child: Scaffold(
            backgroundColor: IosColors.dark.groupedBackground,
            body: Builder(
              builder: (ctx) => Stack(
                children: [
                  Column(
                    children: [
                      IosSessionBar(
                        sessions: pillTabs,
                        selectedId: 'tab-1',
                        backLabel: '主机',
                        onBack: () {},
                        onSelect: (_) {},
                        onClose: (_) {},
                        onDisconnect: (_) {},
                        onSftp: (_) {},
                      ),
                    ],
                  ),
                  const SizedBox.shrink(),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final backRect = tester.getRect(
        find.byKey(const ValueKey('ios_session_bar_back')),
      );
      final moreRect = tester.getRect(
        find.byKey(const ValueKey('ios_session_bar_more')),
      );
      expect(backRect.left, greaterThanOrEqualTo(6));
      expect(backRect.left, lessThan(20));
      expect(moreRect.right, lessThanOrEqualTo(844 - 68 - 10 + 0.5));

      // 验证 IosToast 在左侧 68pt 偏移时不侵占左侧安全区
      await tester.pumpWidget(
        wrapWithPadding(
          padding: const FakeViewPadding(top: 20, bottom: 0, left: 68, right: 0),
          child: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  key: const ValueKey('show_toast_btn'),
                  onPressed: () => IosToast.show(context, '已保存主机配置'),
                  child: const Text('Show'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('show_toast_btn')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      final toastRect = tester.getRect(
        find.byKey(const ValueKey('ios_toast_message')),
      );
      expect(toastRect.left, greaterThanOrEqualTo(68 + 16));

      // 清理 toast 定时器
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

class _SinglePreUnlockedService implements LocalProfileService {
  _SinglePreUnlockedService({required this.record, required this.unlocked});

  final LocalProfileRecord record;
  final UnlockedLocalProfile unlocked;

  @override
  Future<bool> isDeviceManaged(String profileId) async => false;

  @override
  Future<UnlockedLocalProfile?> tryResume() async => null;

  @override
  Future<void> remember(UnlockedLocalProfile profile) async {}

  @override
  Future<void> forgetResume() async {}

  @override
  Future<UnlockedLocalProfile> unlock({
    required String profileId,
    required String password,
  }) async => unlocked;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshHarness {
  final sessions = <_FakeSession>[];

  SshService createService({
    required KnownHostDecisionLock knownHostDecisionLock,
  }) => SshService(
    api: null,
    deviceId: 'ios-duo-test-device',
    useRelay: false,
    knownHostDecisionLock: knownHostDecisionLock,
    directSocketConnector: (_, _) async => _FakeSocket(),
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
          final session = _FakeSession();
          sessions.add(session);
          return _FakeClient(
            session: session,
            authenticate: () async {
              final approved = await onVerifyHostKey(
                'ssh-ed25519',
                Uint8List.fromList(utf8.encode(_fingerprint)),
              );
              if (!approved) throw SSHAuthFailError('untrusted key');
            },
          );
        },
  );
}

class _FakeClient implements SSHClient {
  _FakeClient({
    required this.session,
    required Future<void> Function() authenticate,
  }) : _authenticated = authenticate();

  final SSHSession session;
  final Future<void> _authenticated;
  final Completer<void> _done = Completer<void>();

  @override
  Future<void> get authenticated => _authenticated;

  @override
  Future<void> get done => _done.future;

  @override
  Future<SSHSession> shell({
    SSHPtyConfig? pty = const SSHPtyConfig(),
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async => session;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSession implements SSHSession {
  bool get closed => _stdout.isClosed;
  final _stdout = StreamController<Uint8List>(sync: true);
  final _stderr = StreamController<Uint8List>(sync: true);

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => _stderr.stream;

  @override
  void close() {
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }

  @override
  void write(Uint8List data) {}

  @override
  void resizeTerminal(
    int width,
    int height, [
    int pixelWidth = 0,
    int pixelHeight = 0,
  ]) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSocket implements SSHSocket {
  _FakeSocket() {
    _outgoing.stream.listen((_) {});
  }

  final _closed = Completer<void>();
  final _outgoing = StreamController<List<int>>();

  @override
  Stream<Uint8List> get stream => const Stream<Uint8List>.empty();

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => _closed.future;

  @override
  Future<void> close() async {
    if (!_outgoing.isClosed) await _outgoing.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  void destroy() {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Future<void> flush() async {}
}
