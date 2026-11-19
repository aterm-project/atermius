import 'dart:math' as math;

import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/terminal/mirrored_terminal.dart';
import 'package:aterm_client/terminal/session_reconnect_policy.dart';
import 'package:aterm_client/terminal/session_recovery.dart';
import 'package:aterm_client/terminal/terminal_search.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/ios_native/ios_session_bar.dart';
import 'package:aterm_client/ui/session_recovery_overlay.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/terminal_keybar.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('工作区分屏树与多视口折叠屏极限压测', () {
    test('32 会话 500 次随机分屏/取消分屏/切换/缩放/关闭不破坏树不变量', () {
      final controller = SessionWorkspaceController();
      addTearDown(controller.dispose);
      final rng = math.Random(20261119);
      final allIds = List.generate(32, (i) => 'sess-$i');
      final activePool = <String>[allIds.first];
      controller.activate(allIds.first);

      for (var step = 0; step < 500; step++) {
        final op = rng.nextInt(5);
        if (op == 0 && activePool.length < allIds.length) {
          final next = allIds.firstWhere((id) => !activePool.contains(id));
          activePool.add(next);
          final visible = controller.sessionIds;
          if (visible.isNotEmpty && visible.length < 8) {
            final target = visible[rng.nextInt(visible.length)];
            final edge =
                SessionSplitEdge.values[rng.nextInt(SessionSplitEdge.values.length)];
            controller.split(next, target, edge);
          } else {
            controller.activate(next);
          }
        } else if (op == 1 && activePool.isNotEmpty) {
          controller.activate(activePool[rng.nextInt(activePool.length)]);
        } else if (op == 2 && controller.sessionIds.length > 1) {
          final id =
              controller.sessionIds[rng.nextInt(controller.sessionIds.length)];
          controller.unsplit(id);
        } else if (op == 3 && controller.root is SessionWorkspaceSplit) {
          final split = controller.root! as SessionWorkspaceSplit;
          controller.resize(split, rng.nextDouble());
          expect(split.ratio, inInclusiveRange(0.15, 0.85));
        } else if (op == 4 && activePool.length > 2) {
          final victim = activePool.removeAt(rng.nextInt(activePool.length));
          controller.remove(victim);
        }

        // 每步验证无重复会话 ID 且选中态合法
        final ids = controller.sessionIds;
        expect(ids.toSet().length, ids.length, reason: '分屏树中不得存在重复会话 ID');
        if (ids.isNotEmpty) {
          expect(ids, contains(controller.selectedId));
        }
      }

      // 全部清理后回到干净空态
      for (final id in List<String>.of(activePool)) {
        controller.remove(id);
      }
      expect(controller.root, isNull);
      expect(controller.selectedId, isNull);
    });

    testWidgets('连续 40 次折叠屏/分屏极端尺寸抖动下终端视图、顶栏与快捷键栏零溢出且缓冲不丢', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(tester.view.reset);

      try {
        final terminal = MirroredTerminal(maxLines: 500);
        addTearDown(terminal.closeMirror);
        terminal.write('prod-db-01# uptime\r\n 13:20:00 up 94 days, 3 users\r\n');
        final focusNode = FocusNode();
        addTearDown(focusNode.dispose);
        final policy = SessionReconnectController();
        addTearDown(policy.dispose);
        final recovery = SessionRecovery(
          automatic: true,
          isCurrent: () => true,
          policy: policy,
          reconnect: () async {},
        );
        addTearDown(recovery.dispose);
        recovery.update(connected: true);

        const tabs = [
          WorkspaceTab(
            id: 't1',
            title: 'prod-tokyo-gw-01',
            isConnected: true,
            canDisconnect: true,
          ),
          WorkspaceTab(
            id: 't2',
            title: 'prod-shanghai-core-02',
            isConnected: true,
            canDisconnect: true,
          ),
        ];

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: buildAppTheme(brightness: Brightness.dark),
            home: Scaffold(
              body: Column(
                children: [
                  IosSessionBar(
                    sessions: tabs,
                    selectedId: 't1',
                    onBack: () {},
                    onSelect: (_) {},
                    onClose: (_) {},
                    onDisconnect: (_) {},
                    onSftp: (_) {},
                  ),
                  Expanded(
                    child: SessionRecoveryOverlay(
                      recovery: recovery,
                      onClose: () {},
                      child: TerminalView(terminal, focusNode: focusNode),
                    ),
                  ),
                  TerminalKeybar(terminal: terminal, focusNode: focusNode),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        const viewports = <Size>[
          Size(390, 844), // iPhone 竖屏
          Size(844, 390), // iPhone 横屏
          Size(674, 844), // iPhone Duo 展开态
          Size(320, 568), // 极限窄分屏
          Size(1024, 768), // iPad 横屏
          Size(430, 932), // iPhone Pro Max
        ];

        for (var i = 0; i < 40; i++) {
          final size = viewports[i % viewports.length];
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          if (i == 20) {
            // 中途触发一次断线恢复卡片覆盖测试极窄屏不溢出
            recovery.update(
              connected: false,
              disconnectReason: 'keepalive_timeout',
            );
          } else if (i == 30) {
            recovery.update(connected: true);
          }
          await tester.pump();
          expect(
            tester.takeException(),
            isNull,
            reason: '第 $i 次尺寸切换至 $size 出现布局或渲染异常',
          );
        }

        // 校验折叠抖动全程终端历史未丢失
        final hit = searchTerminalBuffer(terminal, 'up 94 days');
        expect(hit.matches.length, 1);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
