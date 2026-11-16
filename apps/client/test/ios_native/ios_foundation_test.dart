// ① ios-foundation 与 ② ios-shell 组件测试（iPhone Air 视口 420×912 @3x，iOS 平台）。
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/home_sidebar.dart';
import 'package:aterm_client/ui/ios_native/ios_native.dart';
import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      theme: buildAppTheme(
        platform: TargetPlatform.iOS,
        brightness: brightness,
      ),
      home: child,
    );

void _iphoneAir(WidgetTester tester, {bool landscape = false}) {
  tester.view.physicalSize = landscape
      ? const Size(2736, 1260)
      : const Size(1260, 2736);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = landscape
      ? FakeViewPadding.zero
      : const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('isIosPhone：iOS 手机视口为 true，横屏仍为 true，Android 为 false', (
    tester,
  ) async {
    _iphoneAir(tester);
    bool? portrait;
    await tester.pumpWidget(
      _app(Builder(builder: (c) => Text('${portrait = isIosPhone(c)}'))),
    );
    expect(portrait, isTrue);

    _iphoneAir(tester, landscape: true);
    bool? landscape;
    await tester.pumpWidget(
      _app(Builder(builder: (c) => Text('${landscape = isIosPhone(c)}'))),
    );
    expect(landscape, isTrue);

    bool? android;
    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey('android_app'),
        theme: buildAppTheme(platform: TargetPlatform.android),
        home: Builder(builder: (c) => Text('${android = isIosPhone(c)}')),
      ),
    );
    await tester.pumpAndSettle();
    expect(android, isFalse);
  });

  testWidgets('IosTabScaffold：玻璃 TabBar 切换、底部占位下发、Pill 占位', (tester) async {
    _iphoneAir(tester);
    var index = 0;
    late ({double tabBar, double accessory}) insets;
    late double bottomPadding;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => IosTabScaffold(
            currentIndex: index,
            onTabSelected: (i) => setState(() => index = i),
            accessory: const SizedBox.expand(key: ValueKey('pill')),
            items: const [
              IosTabItem(id: 'hosts', icon: IosIcons.hosts, label: '主机'),
              IosTabItem(id: 'snippets', icon: IosIcons.snippets, label: '片段'),
              IosTabItem(
                id: 'settings',
                icon: IosIcons.settings,
                label: '设置',
                badge: 3,
              ),
            ],
            tabBuilder: (context, i) {
              insets = IosChromeInsets.of(context);
              bottomPadding = MediaQuery.paddingOf(context).bottom;
              return IosLargeTitlePage(
                title: 'Tab $i',
                searchField: buildIosSearchTextField(context, placeholder: '搜索'),
                trailing: IosBarButtonGroup(
                  items: [
                    IosBarButtonItem(icon: IosIcons.add, onPressed: (_) {}),
                    IosBarButtonItem(icon: IosIcons.more, onPressed: (_) {}),
                  ],
                ),
                slivers: [
                  SliverToBoxAdapter(
                    child: IosListSection(
                      header: '全部主机',
                      separatorIndent: IosListSection.indentForIcon(),
                      children: [
                        for (var r = 0; r < 3; r++)
                          IosListRow(
                            leading: const IosIconTile(
                              icon: IosIcons.terminal,
                              color: Colors.blue,
                            ),
                            title: Text('主机 $r'),
                            subtitle: const Text('root@1.2.3.4:22'),
                            monoSubtitle: true,
                            accessory: IosRowAccessory.info,
                            onInfo: () {},
                            onTap: () {},
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ios_glass_tab_bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('pill')), findsOneWidget);
    expect(find.text('Tab 0'), findsWidgets);
    // 34pt 安全区 → 悬浮底距 22 + 62 = 84；实时会话胶囊 54 + 8 = 62。
    expect(insets.tabBar, 84);
    expect(bottomPadding, 84);
    expect(insets.accessory, 62);

    await tester.tap(find.byKey(const ValueKey('ios_tab_snippets')));
    await tester.pumpAndSettle();
    expect(index, 1);
    expect(find.text('Tab 1'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('浅色主题：Inset Grouped、表单行、滑动操作可渲染', (tester) async {
    _iphoneAir(tester);
    final controller = TextEditingController(text: 'example.com');
    addTearDown(controller.dispose);
    var deleted = false;
    await tester.pumpWidget(
      _app(
        brightness: Brightness.light,
        IosGroupedPageBackground(
          child: ListView(
            children: [
              IosListSection(
                header: '连接',
                footer: '说明文字',
                children: [
                  IosTextFieldRow(label: '地址', controller: controller),
                  IosSwitchRow(label: '保持连接', value: true, onChanged: (_) {}),
                  IosSegmentedRow<int>(
                    segments: const {0: '密码', 1: '私钥'},
                    value: 0,
                    onChanged: (_) {},
                  ),
                  IosPickerRow<int>(
                    label: '协议',
                    options: const [
                      IosPickerOption(value: 0, label: 'SSH'),
                      IosPickerOption(value: 1, label: 'Telnet'),
                    ],
                    value: 0,
                    onChanged: (_) {},
                  ),
                  IosSwipeActionCell(
                    trailing: [
                      IosSwipeAction(
                        label: '删除',
                        color: IosColors.light.destructive,
                        onTap: () => deleted = true,
                      ),
                    ],
                    child: IosListRow(title: const Text('可左滑'), onTap: () {}),
                  ),
                ],
              ),
              const SizedBox(
                height: 300,
                child: IosEmptyState(
                  icon: IosIcons.hosts,
                  title: '暂无主机',
                  message: '点按右上角 + 添加',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('example.com'), findsOneWidget);
    await tester.drag(find.text('可左滑'), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('下拉菜单与 Toast', (tester) async {
    _iphoneAir(tester);
    var ran = false;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IosPullDownButton(
                  sections: () => [
                    [
                      WorkspaceAction('a', '新建主机', IosIcons.add, () => ran = true),
                    ],
                    [
                      WorkspaceAction(
                        'd',
                        '删除',
                        IosIcons.delete,
                        () {},
                        destructive: true,
                      ),
                    ],
                  ],
                  child: const Text('打开菜单'),
                ),
                GestureDetector(
                  onTap: () => IosToast.show(
                    context,
                    '已复制',
                    kind: IosToastKind.success,
                  ),
                  child: const Text('提示'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();
    expect(find.text('新建主机'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ios_menu_a')));
    await tester.pumpAndSettle();
    expect(ran, isTrue);

    await tester.tap(find.text('提示'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('ios_toast_message')), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ios_toast_message')), findsNothing);
  });

  testWidgets('② ios-shell：PushStack 常驻、Pill 恢复、SessionBar 与切换器', (
    tester,
  ) async {
    _iphoneAir(tester);
    final detailKey = GlobalKey();
    var showDetail = false;
    var selectedDest = HomeDestination.hosts;
    var selectedSession = 's1';
    var disconnected = false;
    var shownCount = 0;
    final sessions = <WorkspaceTab>[
      const WorkspaceTab(id: 'hosts', title: 'Home', isHome: true),
      const WorkspaceTab(
        id: 's1',
        title: '阿里云-生产',
        isConnected: true,
        canDisconnect: true,
        canOpenFiles: true,
      ),
      const WorkspaceTab(
        id: 's2',
        title: 'Mac-mini',
        isConnected: true,
        canDisconnect: true,
        canOpenFiles: true,
      ),
    ];

    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) => IosPushStack(
            showDetail: showDetail,
            onPopGesture: () => setState(() => showDetail = false),
            onShown: () => shownCount++,
            home: IosHomeShell(
              selected: selectedDest,
              onSelect: (d) => setState(() => selectedDest = d),
              accessory: IosLiveSessionPill(
                sessions: sessions,
                currentId: selectedSession,
                subtitles: const {'s1': 'root@1.2.3.4:22'},
                onResume: (id) => setState(() {
                  selectedSession = id;
                  showDetail = true;
                }),
                onShowSwitcher: () => showIosSessionSwitcher(
                  context,
                  sessions: sessions,
                  selectedId: selectedSession,
                  onSelect: (id) => setState(() {
                    selectedSession = id;
                    showDetail = true;
                  }),
                  onClose: (id) => setState(
                    () => sessions.removeWhere((t) => t.id == id),
                  ),
                ),
              ),
              tabBuilder: (ctx, dest) => IosLargeTitlePage(
                title: dest.name,
                slivers: [
                  SliverToBoxAdapter(child: Text('Body:${dest.name}')),
                ],
              ),
            ),
            detail: Column(
              children: [
                IosSessionBar(
                  sessions: sessions,
                  selectedId: selectedSession,
                  transferProgress: 0.4,
                  onBack: () => setState(() => showDetail = false),
                  onSelect: (id) => setState(() => selectedSession = id),
                  onClose: (id) => setState(() {
                    sessions.removeWhere((t) => t.id == id);
                    showDetail = false;
                  }),
                  onDisconnect: (_) => setState(() => disconnected = true),
                  onSftp: (_) {},
                ),
                Expanded(
                  child: Container(
                    key: detailKey,
                    child: Text('Terminal:$selectedSession'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1. 即使在主页，detail 的 GlobalKey 也已常驻挂载，但处于 Offstage。
    expect(detailKey.currentContext, isNotNull);
    expect(find.byKey(const ValueKey('ios_session_bar')), findsNothing);
    expect(find.byKey(const ValueKey('ios_live_session_pill')), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);

    // 2. 点按 Pill 右侧切换区展开会话切换器，选 s2 进入全屏终端。
    await tester.tap(
      find.byKey(const ValueKey('ios_live_session_pill_switcher')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(IosSessionSwitcherSheet), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ios_switcher_item_s2')));
    await tester.pumpAndSettle();

    expect(showDetail, isTrue);
    expect(selectedSession, 's2');
    expect(shownCount, 1);
    expect(find.byKey(const ValueKey('ios_session_bar')), findsOneWidget);
    // 进入终端后主页转为 Offstage，Pill 被隐藏。
    expect(find.byKey(const ValueKey('ios_live_session_pill')), findsNothing);

    // 3. 在顶栏标题横滑切换到另一个会话。
    await tester.drag(
      find.byKey(const ValueKey('ios_session_bar_title')),
      const Offset(-180, 0),
    );
    await tester.pumpAndSettle();
    expect(selectedSession, 's1');

    // 4. 点按 `…` → 断开 → CupertinoActionSheet 二次确认。
    await tester.tap(find.byKey(const ValueKey('ios_session_bar_more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ios_menu_ios_session_disconnect')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('ios_session_disconnect_confirm')),
    );
    await tester.pumpAndSettle();
    expect(disconnected, isTrue);

    // 5. 左边缘右滑返回主页，终端 GlobalKey 依旧常驻不卸载。
    await tester.flingFrom(
      const Offset(4, 400),
      const Offset(320, 0),
      1500,
    );
    await tester.pumpAndSettle();
    expect(showDetail, isFalse);
    expect(detailKey.currentContext, isNotNull);
    expect(find.byKey(const ValueKey('ios_live_session_pill')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('IosLargeTitlePage：二级详情页（largeTitle:false）push 与横屏搜索不触发 SDK 断言', (
    tester,
  ) async {
    _iphoneAir(tester);
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => IosLargeTitlePage(
            title: '设置',
            slivers: [
              SliverToBoxAdapter(
                child: IosListSection(
                  children: [
                    IosListRow(
                      title: const Text('外观'),
                      accessory: IosRowAccessory.chevron,
                      onTap: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const IosLargeTitlePage(
                            title: '外观',
                            largeTitle: false,
                            backLabel: '设置',
                            slivers: [
                              SliverToBoxAdapter(child: Text('二级详情内容')),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    expect(find.text('二级详情内容'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 切换为横屏 compact 模式并包含 searchField。
    _iphoneAir(tester, landscape: true);
    await tester.pumpWidget(
      MaterialApp(
        key: const ValueKey('landscape_app'),
        theme: buildAppTheme(platform: TargetPlatform.iOS),
        home: Builder(
          builder: (context) => IosLargeTitlePage(
            title: '主机',
            searchField: buildIosSearchTextField(
              context,
              key: const ValueKey('landscape_search'),
              placeholder: '搜索主机',
            ),
            slivers: const [SliverToBoxAdapter(child: Text('横屏列表'))],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('landscape_search')), findsOneWidget);
    expect(find.text('横屏列表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'IosLiveSessionPill：染色液态玻璃 54pt/44pt、窄屏副标题展示、切换热区与 pumpAndSettle 兼容',
    (tester) async {
      _iphoneAir(tester);
      var connecting = true;
      var connected = false;
      var resumed = '';
      var switched = 0;

      Widget buildPill({
        Brightness brightness = Brightness.dark,
        bool highContrast = false,
        double width = 300,
      }) => _app(
        brightness: brightness,
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(highContrast: highContrast),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  child: IosLiveSessionPill(
                    sessions: [
                      WorkspaceTab(
                        id: 's1',
                        title: '杭州核心节点-Pro',
                        isConnected: connected,
                      ),
                    ],
                    currentId: 's1',
                    subtitles: const {'s1': 'root@10.0.1.10:22'},
                    connectingIds: connecting ? const {'s1'} : const {},
                    onResume: (id) => resumed = id,
                    onShowSwitcher: () => switched++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // 1. 握手中呼吸态渲染（不调 pumpAndSettle，单帧推进验证无异常）。
      await tester.pumpWidget(buildPill());
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.byIcon(Icons.terminal_rounded), findsOneWidget);
      // 宽度 300 (< 340) 下副标题依然清晰显示。
      expect(find.text('root@10.0.1.10:22'), findsOneWidget);

      // 2. 转为已连接态：静态双层发光光晕环，pumpAndSettle 必须秒过不超时！
      connecting = false;
      connected = true;
      await tester.pumpWidget(buildPill());
      await tester.pumpAndSettle();
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('root@10.0.1.10:22'), findsOneWidget);

      final pillSize = tester.getSize(
        find.byKey(const ValueKey('ios_live_session_pill')),
      );
      expect(pillSize.height, IosMetrics.accessoryHeight);

      final switcherSize = tester.getSize(
        find.byKey(const ValueKey('ios_live_session_pill_switcher')),
      );
      expect(switcherSize.width, greaterThanOrEqualTo(44));
      expect(switcherSize.height, greaterThanOrEqualTo(40));

      await tester.tap(find.byKey(const ValueKey('ios_live_session_pill')));
      await tester.pumpAndSettle();
      expect(resumed, 's1');

      await tester.tap(
        find.byKey(const ValueKey('ios_live_session_pill_switcher')),
      );
      await tester.pumpAndSettle();
      expect(switched, 1);

      // 3. 亮色模式与高对比无障碍模式同样稳定无异常且可 settle。
      await tester.pumpWidget(
        buildPill(brightness: Brightness.light, highContrast: true),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
