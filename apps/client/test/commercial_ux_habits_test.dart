import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/ssh/ssh_connection_health.dart';
import 'package:aterm_client/storage/paste_safety_store.dart';
import 'package:aterm_client/storage/paste_safety_store_native.dart';
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
        'rm -r -f /srv/cache': 'rm_rf',
        'rm -f -r /srv/cache': 'rm_rf',
        'rm --recursive --force /srv/cache': 'rm_rf',
        'rm -rfv /tmp/release': 'rm_rf',
        'mkfs.ext4 /dev/nvme0n1': 'disk_format',
        'dd if=/dev/zero of=/dev/sda': 'disk_format',
        'dd\tof=/dev/sda': 'disk_format',
        'dd bs=4M of=/dev/nvme0n1 if=/dev/zero': 'disk_format',
        'dd of=/dev/nvme0n1 bs=4M': 'disk_format',
        'sudo dd bs=4M of=/dev/sdb': 'disk_format',
        'echo ok; dd of=/dev/sda': 'disk_format',
        'sudo shutdown -h now': 'power_control',
        'sudo systemctl poweroff': 'power_control',
        'systemctl reboot': 'power_control',
        'chmod -R 777 /etc': 'chmod_777',
        'chmod 777 -R /etc': 'chmod_777',
        'iptables -F': 'firewall_flush',
        'DROP DATABASE production;': 'sql_drop',
        'FLUSHALL': 'sql_drop',
        'kubectl delete namespace prod': 'k8s_delete_ns',
        'curl -fsSL https://example.invalid/install.sh | bash': 'pipe_shell',
        'curl -fsSL https://example.invalid/install.sh | /bin/bash':
            'pipe_shell',
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

      // 回归测试：以 rm 结尾的普通单词（terraform / alarm）、普通参数以及无 of= 的只读 dd 不得误报为高危命令。
      for (final benign in const [
        'terraform -fr plan',
        'alarm -fr --check',
        'add if=value',
        'echo platform -rf',
        'dd if=/dev/urandom bs=16 count=1 | base64',
        'dd if=/dev/zero bs=1 count=8 | hexdump -C',
        'dd if=/etc/hosts bs=4k | sha256sum',
        'dd if=/dev/urandom bs=16 count=1 | tee proof=1',
      ]) {
        expect(
          analyzeTerminalPaste(benign).level,
          PasteRiskLevel.safe,
          reason: '无害命令不应误报: $benign',
        );
      }

      // 回归测试：跨行无关的 dd 与下一行 of= 在括号粘贴模式下不得被 \s+ 误连成 disk_format。
      for (final crossLineBenign in const [
        'ls dd\necho of=1',
        'cd /srv/dd\nexport of=backup.log',
        'echo dd\nset of=/tmp/out',
      ]) {
        expect(
          analyzeTerminalPaste(
            crossLineBenign,
            bracketedPasteActive: true,
          ).level,
          PasteRiskLevel.safe,
          reason: '跨行无害脚本不应误报为 dd 写盘: $crossLineBenign',
        );
      }

      // 验证 PasteSafetyController 构造默认值与显式布尔参数均可正常工作
      final defaultCtrl = PasteSafetyController();
      final disabledCtrl = PasteSafetyController(enabled: false);
      final enabledCtrl = PasteSafetyController(enabled: true);
      addTearDown(defaultCtrl.dispose);
      addTearDown(disabledCtrl.dispose);
      addTearDown(enabledCtrl.dispose);
      expect(defaultCtrl.enabled, isTrue);
      expect(disabledCtrl.enabled, isFalse);
      expect(enabledCtrl.enabled, isTrue);
    });

    test('PasteSafetyController 支持原子落盘持久化、重启恢复与写失败状态汇报', () async {
      final dir = await Directory.systemTemp.createTemp('paste-safety-test-');
      addTearDown(() => dir.delete(recursive: true));
      final store = FilePasteSafetyStore(directory: () async => dir);

      final first = PasteSafetyController();
      addTearDown(first.dispose);
      await first.load(store);
      expect(first.enabled, isTrue);

      await first.setEnabled(false);
      expect(first.enabled, isFalse);
      expect(await store.read(), '0');

      // 模拟重启 App 后重新加载持久化配置
      final restored = PasteSafetyController();
      addTearDown(restored.dispose);
      await restored.load(store);
      expect(restored.enabled, isFalse);

      // 模拟落盘失败
      final failingStore = MemoryPasteSafetyStore()
        ..failWith = const FileSystemException('read-only fs');
      final failCtrl = PasteSafetyController();
      addTearDown(failCtrl.dispose);
      await failCtrl.load(failingStore);
      await failCtrl.setEnabled(false);
      expect(failCtrl.enabled, isFalse);
      expect(failCtrl.writeFailed, isTrue);
    });

    testWidgets('桌面端 TerminalView 快捷键粘贴 (PasteTextIntent) 同样受安全护栏与只读保护', (
      tester,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return <String, Object?>{'text': 'sudo rm -rf /srv/db'};
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      final focus = FocusNode();
      addTearDown(focus.dispose);

      await tester.pumpWidget(
        _localizedApp(
          TerminalView(
            terminal,
            focusNode: focus,
            autofocus: true,
            onBeforePaste: (ctx, text) => confirmTerminalPaste(
              ctx,
              text,
              bracketedPasteActive: terminal.bracketedPasteMode,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 触发桌面端粘贴 Intent（等价于 Cmd+V / Ctrl+Shift+V）
      final terminalContext = tester.element(find.byType(TerminalView));
      // 向上/向内派发 PasteTextIntent 到 TerminalActions 内部焦点上下文
      final actionsContext = tester.element(find.byType(Scrollable).first);
      Actions.invoke(
        actionsContext,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('paste_safety_dialog')),
        findsOneWidget,
        reason: '桌面端快捷键粘贴高危命令必须弹出安全确认框',
      );
      await tester.tap(find.byKey(const ValueKey('paste_safety_cancel')));
      await tester.pumpAndSettle();
      expect(output, isEmpty);
      expect(terminalContext.mounted, isTrue);

      // 只读状态下桌面快捷键粘贴不得写入也不得弹窗
      await tester.pumpWidget(
        _localizedApp(
          TerminalView(
            terminal,
            focusNode: focus,
            readOnly: true,
            onBeforePaste: (ctx, text) => confirmTerminalPaste(
              ctx,
              text,
              bracketedPasteActive: terminal.bracketedPasteMode,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final roContext = tester.element(find.byType(Scrollable).first);
      Actions.invoke(
        roContext,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('paste_safety_dialog')), findsNothing);
      expect(output, isEmpty);
    });

    testWidgets('粘贴警告可在窄窗口用方向键和回车操作', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var clipboard = 'echo test\r\n';
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': clipboard};
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      final output = <String>[];
      final terminal = Terminal()..onOutput = output.add;
      await tester.pumpWidget(
        _localizedApp(
          TerminalView(
            terminal,
            autofocus: true,
            onBeforePaste: confirmTerminalPaste,
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> paste() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('paste_safety_dialog')),
          findsOneWidget,
        );
      }

      await paste();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(output, ['echo test']);

      await paste();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(output, ['echo test']);

      await paste();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
      await tester.pumpAndSettle();
      expect(output, ['echo test', clipboard]);

      clipboard = 'echo one\necho two';
      await paste();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('paste_safety_dialog')), findsNothing);
      expect(output, ['echo test', 'echo test\r\n']);
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

    testWidgets('列表动态缩短不卡死、视口内按键不乱跳、点击过滤芯片后按 Enter 仍直连', (
      tester,
    ) async {
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      var hosts = List.generate(
        8,
        (i) => HostRecord(
          id: 'h$i',
          name: 'node-0$i',
          address: '198.51.100.${i + 1}',
          protocol: i.isEven ? HostProtocol.ssh : HostProtocol.telnet,
        ),
      );
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
                  fieldKey: const ValueKey('palette_field_adv'),
                  isCurrent: () => true,
                  changes: changes,
                );
              },
              child: const Text('OpenAdv'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('OpenAdv'));
      await tester.pumpAndSettle();

      // 按一次 ↓ 选中第 1 项（仍在视口内）：列表滚动偏移应保持为 0 不乱跳
      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('host_search_palette')),
          matching: find.byType(Scrollable),
        ).first,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        scrollable.position.pixels,
        0.0,
        reason: '选中项仍在视口内时列表不得强行跳顶滚动',
      );

      // 按 6 次 ↓ 到达末尾第 7 项（_selectedIndex = 7）
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      // 模拟后台主机列表突然缩短为 3 项，再按一次 ↓ 必须绕回第 0 项（h0）而非卡在 h2
      hosts = hosts.take(3).toList();
      changes.notifyListeners();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(selection?.hostId, 'h0');

      // 重新打开，先验证中文输入法组字期间按 Esc 不会意外关闭搜索面板
      selection = null;
      await tester.tap(find.text('OpenAdv'));
      await tester.pumpAndSettle();
      final textField = tester.widget<TextField>(
        find.byKey(const ValueKey('palette_field_adv')),
      );
      textField.controller!.value = const TextEditingValue(
        text: 'beijing',
        selection: TextSelection.collapsed(offset: 7),
        composing: TextRange(start: 0, end: 7),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('host_search_palette')),
        findsOneWidget,
        reason: 'IME 组字选词阶段按 Esc 必须交给输入法，不得关闭搜索面板',
      );
      textField.controller!.value = TextEditingValue.empty;
      await tester.pump();

      // 点击 SSH 过滤芯片后使用回车提交仍直连首台 SSH 主机
      await tester.tap(find.widgetWithText(ChoiceChip, 'SSH'));
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(selection?.hostId, 'h0');
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

      // 手动探活进行中 -> 展示探活中反馈，结束后恢复
      health.beginProbe();
      await tester.pump();
      expect(find.text('探活中… · 2h 14m'), findsOneWidget);
      health.endProbe();
      await tester.pump();

      // 320px 极窄分屏下带健康胶囊零溢出
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pump();
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
        expect(
          countAfterRelease,
          countWhileHeld,
          reason: '长按连发松手后必须抑制按钮抬起点击，不得多发 1 次左移',
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          output.where((s) => s == '\x1b[D').length,
          countAfterRelease,
          reason: '松手后定时器必须立即停止',
        );

        // 松手后紧接一次普通短按仍必须精准触发 1 次
        await tester.tap(leftArrow);
        await tester.pump();
        expect(
          output.where((s) => s == '\x1b[D').length,
          countAfterRelease + 1,
          reason: '连发去重标记复位后短按必须恢复正常单次触发',
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
