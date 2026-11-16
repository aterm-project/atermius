// iPhone Air (iOS 27.3, 1260×2736 @3x) 竖屏与横屏全链路原生体验验收测试。
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
import 'package:aterm_client/ui/ios_native/ios_unlock_view.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
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
  late String groupId;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('aterm-ios-phone-');
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
    groupId = const Uuid().v4();
    hostId = const Uuid().v4();

    await seedRepo.createCredential(
      CredentialRecord(
        id: credId,
        name: '阿里云主密钥',
        username: 'root',
        kind: AuthKind.password,
        secret: 's3cr3t-password',
      ),
    );
    await seedRepo.createGroup(
      GroupRecord(
        id: groupId,
        name: '生产集群',
        color: 1,
        defaultCredentialId: credId,
      ),
    );
    final saved = await seedRepo.createHost(
      HostRecord(
        id: hostId,
        name: '杭州核心节点-01',
        address: '10.0.1.10',
        port: 22,
        username: 'root',
        groupId: groupId,
        tags: const ['prod', 'k8s'],
      ),
    );
    hostId = saved.id;
    await seedRepo.createSnippet(
      SnippetRecord(
        id: const Uuid().v4(),
        title: '查看容器负载',
        body: 'docker stats --no-stream',
        shell: 'bash',
        executionMode: SnippetExecutionMode.script,
        program: '',
        parameters: const [],
        arguments: const [],
        tags: const ['ops'],
      ),
    );
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
        // Flow may already have closed the database.
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
    fail('Expected finder $finder to become visible. Texts on screen: $texts');
  }

  Future<void> drainClose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(seconds: 6));
  }

  Widget buildFlowApp({
    required TargetPlatform platform,
    Brightness brightness = Brightness.dark,
  }) => MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizationSetup.delegates,
    supportedLocales: AppLocalizationSetup.locales,
    theme: buildAppTheme(platform: platform, brightness: Brightness.light),
    darkTheme: buildAppTheme(platform: platform, brightness: Brightness.dark),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
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
    'iPhone Air (1260x2736 @3x) delivers pure iOS unlock, 5-tab shell, Settings push/pop without Dropdowns, Sheet host editor, Live Session Pill, and landscape stability',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        // iPhone Air portrait: 1260×2736 px @ 3x => 420×912 pt
        tester.view.physicalSize = const Size(1260, 2736);
        tester.view.devicePixelRatio = 3.0;
        tester.view.padding = const FakeViewPadding(top: 177, bottom: 102);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetPadding();
        });

      await tester.pumpWidget(buildFlowApp(platform: TargetPlatform.iOS));
      await pumpUntilIdle(tester);

      // 1. 解锁屏：纯正 IosUnlockView，彻底无桌面栏 / 侧栏 / 状态栏
      expect(find.byType(IosUnlockView), findsOneWidget);
      expect(find.byType(WorkspaceTabBar), findsNothing);
      expect(find.byType(HomeSidebar), findsNothing);
      expect(find.byType(WorkspaceStatusBar), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        _password,
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      await pumpUntilIdle(tester);

      // 2. 解锁进入主页：悬浮玻璃 5-TabBar，无桌面栏/侧栏/状态栏，无活跃会话时无 Pill
      expect(find.byKey(const ValueKey('ios_glass_tab_bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('ios_tab_hosts')), findsOneWidget);
      expect(find.byKey(const ValueKey('ios_tab_snippets')), findsOneWidget);
      expect(find.byKey(const ValueKey('ios_tab_forwarding')), findsOneWidget);
      expect(find.byKey(const ValueKey('ios_tab_keychain')), findsOneWidget);
      expect(find.byKey(const ValueKey('ios_tab_settings')), findsOneWidget);
      expect(find.byType(WorkspaceTabBar), findsNothing);
      expect(find.byType(HomeSidebar), findsNothing);
      expect(find.byType(WorkspaceStatusBar), findsNothing);
      expect(
        find.byKey(const ValueKey('ios_live_session_pill')),
        findsNothing,
      );

      // 主机与分组均已加载
      expect(find.text('杭州核心节点-01'), findsOneWidget);
      expect(
        find.byKey(ValueKey('local_host_group_$groupId')),
        findsOneWidget,
      );

      // 3. 分组文件夹 push -> 分组详情页 -> 自绘 IosBackButton 返回主机列表
      await tester.tap(find.byKey(ValueKey('local_host_group_$groupId')));
      await tester.pumpAndSettle();
      expect(find.text('生产集群'), findsWidgets);
      await tester.tap(find.byType(IosBackButton));
      await tester.pumpAndSettle();

      // 4. 点主机右侧 ⓘ 弹出 iOS 表单 Sheet（无 DropdownButtonFormField），修改备注并保存
      await tester.tap(find.byKey(ValueKey('ios_host_info_$hostId')));
      await tester.pumpAndSettle();
      expect(find.byType(DropdownButtonFormField), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('local_host_name')),
        '杭州核心节点-Pro',
      );
      await tester.tap(find.byKey(const ValueKey('local_host_save')));
      await pumpUntilIdle(tester);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('杭州核心节点-Pro'), findsOneWidget);

      // 保存后提示为顶部灵动胶囊 IosToast，绝非底部 Material SnackBar，并在 2.6s 后自动收起
      expect(find.byKey(const ValueKey('ios_toast_message')), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ios_toast_message')), findsNothing);

      // 5. 切换到「设置」Tab：纯正一级分类列表，0 个 DropdownButtonFormField！
      await tester.tap(find.byKey(const ValueKey('ios_tab_settings')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ios_settings_category_list')),
        findsOneWidget,
      );
      expect(find.byType(DropdownButtonFormField), findsNothing);

      // 点按「外观与终端」推入二级详情页，依然 0 个 DropdownButtonFormField
      await tester.tap(find.byKey(const ValueKey('settings_category_appearance')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('settings_page_appearance')),
        findsOneWidget,
      );
      expect(find.byType(DropdownButtonFormField), findsNothing);

      // 左上角 iOS 返回按钮回到设置一级列表
      await tester.tap(find.byKey(const ValueKey('ios_settings_back_button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ios_settings_category_list')),
        findsOneWidget,
      );

      // 6. 回到「主机」Tab，滚动到目标主机行并点按发起 SSH 连接
      await tester.tap(find.byKey(const ValueKey('ios_tab_hosts')));
      await tester.pumpAndSettle();
      final hostRow = find.byKey(ValueKey('local_host_$hostId'));
      await tester.scrollUntilVisible(
        hostRow,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(hostRow);

      // 首次未知指纹确认自动拦截为原生 CupertinoAlertDialog！
      await pumpUntilVisible(
        tester,
        find.byKey(const ValueKey('local_ssh_host_key_approve')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('local_ssh_host_key_approve')),
      );
      await pumpUntilVisible(
        tester,
        find.byKey(const ValueKey('local_ssh_terminal_view')),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // 已滑入全屏 SSH 终端：顶部为 IosSessionBar，底部 TabBar 已隐藏
      expect(find.byKey(const ValueKey('ios_session_bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('ios_glass_tab_bar')), findsNothing);
      expect(sshHarness.sessions.last.closed, isFalse);

      // 7. 点左上角「‹ 主机」收起回列表，会话保持不断连，Live Session Pill 浮现！
      await tester.tap(find.byKey(const ValueKey('ios_session_bar_back')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));

      expect(sshHarness.sessions.last.closed, isFalse);
      expect(find.byKey(const ValueKey('ios_glass_tab_bar')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ios_live_session_pill')),
        findsOneWidget,
      );

      // 8. 点按 Live Session Pill 一键回到刚才的实时终端，再用左缘右滑手势收起！
      await tester.tap(find.byKey(const ValueKey('ios_live_session_pill')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.byKey(const ValueKey('ios_session_bar')), findsOneWidget);

      await tester.dragFrom(
        const Offset(4, 420),
        const Offset(320, 0),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(sshHarness.sessions.last.closed, isFalse);
      expect(
        find.byKey(const ValueKey('ios_live_session_pill')),
        findsOneWidget,
      );

      // 9. 旋转为 iPhone Air 横屏（2736×1260 @3x => 912×420pt，shortestSide=420 < 600）：
      // 严禁翻回桌面 UI，保持纯血 iOS 壳与实时会话胶囊！
      tester.view.physicalSize = const Size(2736, 1260);
      tester.view.padding = const FakeViewPadding(bottom: 63);
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byKey(const ValueKey('ios_glass_tab_bar')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ios_live_session_pill')),
        findsOneWidget,
      );
      expect(find.byType(WorkspaceTabBar), findsNothing);
      expect(find.byType(HomeSidebar), findsNothing);
      expect(find.byType(WorkspaceStatusBar), findsNothing);
      expect(tester.takeException(), isNull);

      await drainClose(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'Android narrow viewport (390x844) preserves legacy WorkspaceTabBar and HomeSidebar with zero regression',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(buildFlowApp(platform: TargetPlatform.android));
      await pumpUntilIdle(tester);

      expect(find.byType(IosUnlockView), findsNothing);
      expect(find.byType(WorkspaceTabBar), findsOneWidget);

      await tester.tap(
        find.byKey(ValueKey('local_profile_${profileRecord.profileId}')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('local_profile_unlock_password')),
        _password,
      );
      await tester.tap(
        find.byKey(const ValueKey('local_profile_unlock_button')),
      );
      await pumpUntilIdle(tester);

      expect(find.byType(WorkspaceTabBar), findsOneWidget);
      expect(find.byType(HomeSidebar), findsOneWidget);
      expect(find.byKey(const ValueKey('ios_glass_tab_bar')), findsNothing);
      expect(tester.takeException(), isNull);

      await drainClose(tester);
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
  }) async {
    if (profileId != record.profileId || password != _password) {
      throw const FormatException('Invalid password');
    }
    return unlocked;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSshHarness {
  final sessions = <_FakeSession>[];

  SshService createService({
    required KnownHostDecisionLock knownHostDecisionLock,
  }) => SshService(
    api: null,
    deviceId: 'ios-phone-test-device',
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
  bool closed = false;

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
    closed = true;
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
