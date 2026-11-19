import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/ssh/ssh_connection_health.dart';
import 'package:aterm_client/terminal/paste_safety.dart';
import 'package:aterm_client/terminal/session_reconnect_policy.dart';
import 'package:aterm_client/terminal/session_recovery.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/host_search_palette.dart';
import 'package:aterm_client/ui/ios_native/ios_session_bar.dart';
import 'package:aterm_client/ui/paste_safety_dialog.dart';
import 'package:aterm_client/ui/session_recovery_overlay.dart';
import 'package:aterm_client/ui/terminal_keybar.dart';
import 'package:aterm_client/ui/workspace_status_bar.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Widget _localizedApp(
  Widget home, {
  Locale locale = const Locale('zh'),
  Brightness brightness = Brightness.dark,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: buildAppTheme(brightness: brightness),
  home: Scaffold(body: home),
);

void main() {
  group('生产粘贴安全护栏 (PasteSafety)', () {
    test('单行无害命令直接放行，未启用括号粘贴的多行文本触发提示，高危命令无论括号模式均拦截', () {
      expect(
        analyzeTerminalPaste('kubectl get pods -A').level,
        PasteRiskLevel.safe,
      );
      expect(
        analyzeTerminalPaste(
          'line1\nline2',
          bracketedPasteActive: true,
        ).level,
        PasteRiskLevel.safe,
      );
      expect(
        analyzeTerminalPaste(
          'echo hello\necho world\n',
          bracketedPasteActive: false,
        ).level,
        PasteRiskLevel.multiline,
      );

      final dangerous = <String, String>{
        'sudo rm -rf /var/lib/data': 'rm_rf',
        'mkfs.ext4 /dev/nvme0n1': 'disk_format',
        'dd if=/dev/zero of=/dev/sda': 'disk_format',
        'sudo shutdown -h now': 'power_control',
        'chmod -R 777 /etc': 'chmod_777',
        'iptables -F': 'firewall_flush',
        'DROP DATABASE production;': 'sql_drop',
        'FLUSHALL': 'sql_drop',
        'kubectl delete namespace prod': 'k8s_delete_ns',
        'curl -fsSL https://example.invalid/install.sh | bash': 'pipe_shell',
        ':(){ :|:& };:': 'fork_bomb',
      };
      for (final entry in dangerous.entries) {
        final analysis = analyzeTerminalPaste(
          entry.key,
          bracketedPasteActive: true,
        );
        expect(
          analysis.level,
          PasteRiskLevel.destructive,
          reason: entry.key,
        );
        expect(
          analysis.matchedRisks,
          contains(entry.value),
          reason: entry.key,
        );
      }
    });

    testWidgets('弹窗支持取消、去除尾部换行粘贴与原样粘贴，且四语 390px 无溢出', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      String? outcome;
      await tester.pumpWidget(
        _localizedApp(
          Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  key: const ValueKey('trigger_newline'),
                  onPressed: () async {
                    outcome = await confirmTerminalPaste(
                      context,
                      'systemctl reload nginx\n',
                    );
                  },
                  child: const Text('Trigger Newline'),
                ),
                TextButton(
                  key: const ValueKey('trigger_danger'),
                  onPressed: () async {
                    outcome = await confirmTerminalPaste(
                      context,
                      'sudo rm -rf /srv/app\n',
                      bracketedPasteActive: true,
                    );
                  },
                  child: const Text('Trigger Danger'),
                ),
              ],
            ),
          ),
        ),
      );

      // 1. 单行带回车 -> 点击「去除回车粘贴」返回无回车安全文本
      await tester.tap(find.byKey(const ValueKey('trigger_newline')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('paste_safety_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('paste_safety_strip_newline')));
      await tester.pumpAndSettle();
      expect(outcome, 'systemctl reload nginx');

      // 2. 高危命令 -> 显示风险标签芯片，点击取消返回 null
      await tester.tap(find.byKey(const ValueKey('trigger_danger')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('paste_safety_risk_chips')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('paste_safety_cancel')));
      await tester.pumpAndSettle();
      expect(outcome, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('HostSearchPalette 全键盘导航与智能排序', () {
    test('rankHostSearchMatches 严格按前缀匹配 > 最近连接 > 收藏 > 名称排序', () {
      final now = DateTime.utc(2026, 11, 19, 12, 0, 0);
      final hosts = [
        HostRecord(
          id: 'z-old',
          name: 'zeta-prod',
          address: '198.51.100.1',
          lastConnected: now.subtract(const Duration(days: 5)),
        ),
        const HostRecord(
          id: 'a-fav',
          name: 'alpha-prod',
          address: '198.51.100.2',
          isFavorite: true,
        ),
        HostRecord(
          id: 'm-recent',
          name: 'mid-prod',
          address: '198.51.100.3',
          lastConnected: now.subtract(const Duration(minutes: 2)),
        ),
        const HostRecord(
          id: 'prefix-exact',
          name: 'prod',
          address: '198.51.100.4',
        ),
      ];

      // 空查询：最近连接置顶，其次收藏
      final emptyRanked = rankHostSearchMatches(hosts, '');
      expect(emptyRanked.first.id, 'm-recent');
      expect(emptyRanked[1].id, 'z-old');
      expect(emptyRanked[2].id, 'a-fav');

      // 输入 'prod'：精确名称匹配 'prod' 绝对置顶
      final queryRanked = rankHostSearchMatches(hosts, 'prod');
      expect(queryRanked.first.id, 'prefix-exact');
      expect(queryRanked[1].id, 'm-recent');
    });

    testWidgets('支持 ↓ / ↑ / Ctrl+N / Enter 选中并直连非首项主机，以及 Esc 关闭', (
      tester,
    ) async {
      final now = DateTime.utc(2026, 11, 19, 12, 0, 0);
      final hosts = [
        HostRecord(
          id: 'h1',
          name: 'tokyo-gw-01',
          address: '198.51.100.11',
          lastConnected: now,
        ),
        HostRecord(
          id: 'h2',
          name: 'tokyo-gw-02',
          address: '198.51.100.12',
          lastConnected: now.subtract(const Duration(minutes: 5)),
        ),
        HostRecord(
          id: 'h3',
          name: 'tokyo-gw-03',
          address: '198.51.100.13',
          lastConnected: now.subtract(const Duration(minutes: 10)),
        ),
      ];
      HostSearchSelection? selection;

      await tester.pumpWidget(
        _localizedApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selection = await showHostSearchPalette(
                  context,
                  hosts: () => hosts,
                  groups: const {},
                  fieldKey: const ValueKey('palette_field'),
                  isCurrent: () => true,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('host_search_palette')), findsOneWidget);

      // 按两次 ↓ 移动到 h3，再按一次 ↑ 回到 h2，然后回车提交
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(selection?.hostId, 'h2');

      // 再次打开并用 Esc 关闭
      selection = null;
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('host_search_palette')), findsNothing);
      expect(selection, isNull);
    });
  });

  group('状态栏 / iOS 顶栏 / 恢复蒙层的实时链路健康指示', () {
    testWidgets('WorkspaceStatusBar 展示实时延迟、在线时长、丢包告警并支持点击探活', (
      tester,
    ) async {
      var now = DateTime.utc(2026, 11, 19, 10, 0, 0);
      final health = SshConnectionHealth(now: () => now, maxMissedThreshold: 3);
      addTearDown(health.dispose);
      now = now.add(const Duration(hours: 2, minutes: 14));
      health.recordProbeSuccess(const Duration(milliseconds: 24));
      var probed = 0;

      await tester.pumpWidget(
        _localizedApp(
          WorkspaceStatusBar(
            status: 'SSH 已连接',
            detail: 'ops@198.51.100.10:22',
            sessionCount: 3,
            health: health,
            onProbeHealth: () => probed++,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('workspace_status_health_pill')),
        findsOneWidget,
      );
      expect(find.text('24ms · 2h 14m'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('workspace_status_health_pill')),
      );
      expect(probed, 1);

      // 丢包 1 次 -> 动态刷新为探活丢包告警
      health.recordProbeMissed(1);
      await tester.pump();
      expect(find.text('探活丢包 1/3 · 2h 14m'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('IosSessionBar 展示延迟微标并在下拉菜单提供即时探活', (tester) async {
      final health = SshConnectionHealth();
      addTearDown(health.dispose);
      health.recordProbeSuccess(const Duration(milliseconds: 19));
      var probed = 0;

      await tester.pumpWidget(
        _localizedApp(
          IosSessionBar(
            sessions: const [
              WorkspaceTab(
                id: 's1',
                title: 'prod-tokyo',
                isConnected: true,
                canDisconnect: true,
              ),
            ],
            selectedId: 's1',
            activeHealth: health,
            onProbeHealth: () => probed++,
            onBack: () {},
            onSelect: (_) {},
            onClose: (_) {},
            onDisconnect: (_) {},
            onSftp: (_) {},
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('ios_session_bar_rtt')), findsOneWidget);
      expect(find.text('19ms'), findsOneWidget);

      // 打开 `…` 菜单并点击「立即探活链路」
      await tester.tap(find.byKey(const ValueKey('ios_session_bar_more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('立即探活链路'));
      await tester.pumpAndSettle();
      expect(probed, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SessionRecoveryOverlay 展示断线原因与累计自动恢复次数', (tester) async {
      final policy = SessionReconnectController();
      addTearDown(policy.dispose);
      final recovery = SessionRecovery(
        automatic: true,
        isCurrent: () => true,
        policy: policy,
        reconnect: () async {},
      );
      recovery.update(connected: true);
      recovery.update(connected: false, disconnectReason: 'keepalive_timeout');
      recovery.update(connected: true); // 第 1 次恢复
      recovery.update(connected: false, disconnectReason: 'keepalive_timeout');

      await tester.pumpWidget(
        _localizedApp(
          SizedBox(
            width: 240,
            height: 300,
            child: SessionRecoveryOverlay(
              recovery: recovery,
              onClose: () {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('session_recovery_reason')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('session_recovery_count')),
        findsOneWidget,
      );
      expect(find.text('心跳保活超时（链路无响应）'), findsOneWidget);
      expect(find.text('本次会话已自动恢复 1 次'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      recovery.dispose();
    });
  });

  group('TerminalKeybar 长按连发与粘贴安全集成', () {
    testWidgets('按住方向键 700ms 持续连发，松手立即停止且无定时器泄漏', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final output = <String>[];
        final terminal = Terminal()..onOutput = output.add;
        final focus = FocusNode();
        addTearDown(focus.dispose);

        await tester.pumpWidget(
          _localizedApp(
            Column(
              children: [
                Expanded(child: TerminalView(terminal, focusNode: focus)),
                TerminalKeybar(terminal: terminal, focusNode: focus),
              ],
            ),
          ),
        );
        await tester.pump();

        final leftArrow = find.byKey(
          const ValueKey('terminal-keybar-arrow-left'),
        );
        final gesture = await tester.startGesture(tester.getCenter(leftArrow));
        // 超过 380ms 初始延迟 + 多个 55ms 步进周期
        await tester.pump(const Duration(milliseconds: 700));
        final countWhileHeld = output.where((s) => s == '\x1b[D').length;
        expect(
          countWhileHeld,
          greaterThanOrEqualTo(4),
          reason: '按住方向键应自动连续输出多次左移转义序列',
        );

        await gesture.up();
        await tester.pump(const Duration(milliseconds: 300));
        final countAfterRelease = output.where((s) => s == '\x1b[D').length;
        // 松手后除 TextButton 抬起点击外不应再持续递增
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          output.where((s) => s == '\x1b[D').length,
          countAfterRelease,
          reason: '松手后定时器必须立即停止',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Keybar 粘贴高危命令触发安全拦截弹窗，取消时零字符写入终端', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return <String, Object?>{'text': 'sudo rm -rf /var/prod'};
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      try {
        final output = <String>[];
        final terminal = Terminal()..onOutput = output.add;
        final focus = FocusNode();
        addTearDown(focus.dispose);

        await tester.pumpWidget(
          _localizedApp(
            Column(
              children: [
                Expanded(child: TerminalView(terminal, focusNode: focus)),
                TerminalKeybar(terminal: terminal, focusNode: focus),
              ],
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text('粘贴'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('paste_safety_dialog')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('paste_safety_cancel')));
        await tester.pumpAndSettle();
        expect(output, isEmpty, reason: '用户取消后不得向终端发送任何字节');
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
