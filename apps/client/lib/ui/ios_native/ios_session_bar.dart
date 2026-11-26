import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../l10n/l10n.dart';
import '../../ssh/ssh_connection_health.dart';
import '../workspace_controls.dart' show WorkspaceAction;
import '../workspace_tab_bar.dart'
    show WorkspaceTab, workspaceTabAttentionColor;
import 'ios_glass.dart';
import 'ios_icons.dart';
import 'ios_large_title_page.dart';
import 'ios_pull_down_menu.dart';
import 'ios_session_switcher.dart';
import 'ios_sheet.dart';
import 'ios_tokens.dart';

/// 全屏 SSH / SFTP 终端顶栏（视觉附录 §9.3 / 蓝图 §1.6）：
///
/// - 高 `44 + safeTop`，**不遮盖终端行**（作为 detail Column 首项）。
/// - 左：`‹ 主机`（仅收起返回列表，不断连）。
/// - 中：主机备注 + 6pt 在线绿点，多会话时带 `⌄`；点按展开 `IosSessionSwitcherSheet`，
///   左右横滑快速切换上/下一个会话。
/// - 右：SFTP（传输中显示 2pt 进度环）+ `…` 玻璃胶囊按钮 → `IosPullDownMenu`；
///   断开 / 关闭会话走 `CupertinoActionSheet` 二次确认。
class IosSessionBar extends StatelessWidget {
  const IosSessionBar({
    super.key,
    required this.sessions,
    required this.selectedId,
    required this.onBack,
    required this.onSelect,
    required this.onClose,
    required this.onDisconnect,
    required this.onSftp,
    this.onToggleTools,
    this.actions = const [],
    this.transferProgress,
    this.transferActive = false,
    this.backgroundColor,
    this.backLabel,
    this.onNewConnection,
    this.sessionSubtitles = const {},
    this.activeHealth,
    this.onProbeHealth,
  });

  final List<WorkspaceTab> sessions;
  final String selectedId;

  /// 收起回主机列表（不断连）。
  final VoidCallback onBack;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final ValueChanged<String> onDisconnect;
  final ValueChanged<String> onSftp;
  final VoidCallback? onToggleTools;

  /// 终端扩展操作（如搜索终端、SCP、端口转发、连接属性）。
  final List<WorkspaceAction> actions;

  /// 传输进度 `0.0..1.0`；仅已知有活跃传输但无百分比时可设 [transferActive] 为 true。
  final double? transferProgress;
  final bool transferActive;

  /// 终端主题背景色（默认按亮度取 `#000000` / `#F9F9F9`）。
  final Color? backgroundColor;

  final String? backLabel;
  final VoidCallback? onNewConnection;
  final Map<String, String> sessionSubtitles;

  /// 当前活跃 SSH 会话的链路健康状态（用于实时显示绿/琥珀/红状态点与延迟微标）。
  final SshConnectionHealth? activeHealth;

  /// 手动立即探活当前连接（展示于 `…` 下拉菜单中）。
  final VoidCallback? onProbeHealth;

  static bool _isDisconnectAction(WorkspaceAction action) =>
      action.id.endsWith('_disconnect') || action.id == 'disconnect';

  Future<void> _openMoreMenu(
    BuildContext context,
    Rect anchor,
    WorkspaceTab? current,
    List<WorkspaceTab> live,
  ) async {
    final l10n = context.l10n;
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final toolActions = <WorkspaceAction>[
      if (onToggleTools != null)
        WorkspaceAction(
          'ios_session_tools',
          l10n.terminalSidebar,
          Icons.tune_rounded,
          onToggleTools!,
        ),
      if (onProbeHealth != null && current != null && current.isConnected)
        WorkspaceAction(
          'ios_session_probe_health',
          switch (Localizations.localeOf(context).languageCode) {
            'zh' => '立即探活链路',
            'ja' => '接続を即時確認',
            'ru' => 'Проверить канал сейчас',
            _ => 'Probe Link Health',
          },
          Icons.network_check_rounded,
          onProbeHealth!,
        ),
      for (final action in actions)
        if (!_isDisconnectAction(action)) action,
    ];

    final switchActions = <WorkspaceAction>[
      if (live.length >= 2)
        WorkspaceAction(
          'ios_session_switch',
          isZh ? '切换会话 (${live.length})' : 'Switch Session (${live.length})',
          Icons.layers_rounded,
          () => showIosSessionSwitcher(
            context,
            sessions: live,
            selectedId: selectedId,
            onSelect: onSelect,
            onClose: onClose,
            onNewConnection: onNewConnection,
            subtitles: sessionSubtitles,
          ),
        ),
    ];

    final destructiveActions = <WorkspaceAction>[
      if (current != null && current.canDisconnect)
        WorkspaceAction(
          'ios_session_disconnect',
          l10n.disconnect,
          Icons.link_off_rounded,
          () async {
            if (!context.mounted) return;
            final ok = await showIosDestructiveConfirm(
              context,
              title: current.title,
              action: l10n.disconnect,
              actionKey: const ValueKey('ios_session_disconnect_confirm'),
            );
            if (ok) onDisconnect(current.id);
          },
          destructive: true,
        ),
      if (current != null)
        WorkspaceAction(
          'ios_session_close',
          l10n.closeTab,
          IosIcons.close,
          () async {
            if (!context.mounted) return;
            if (current.isConnected && current.canDisconnect) {
              final ok = await showIosDestructiveConfirm(
                context,
                title: current.title,
                action: l10n.closeTab,
                actionKey: const ValueKey('ios_session_close_confirm'),
              );
              if (!ok) return;
            }
            onClose(current.id);
          },
          destructive: true,
        ),
    ];

    await showIosPullDownMenu(
      context,
      anchor: anchor,
      sections: [toolActions, switchActions, destructiveActions],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final pad = MediaQuery.paddingOf(context);
    final live = sessions.where((tab) => !tab.isHome).toList();
    final current =
        live.where((tab) => tab.id == selectedId).firstOrNull ??
        live.firstOrNull;
    final barFill = (backgroundColor ?? c.groupedBackground).withValues(
      alpha: 0.88,
    );
    final showSftp = current != null && current.canOpenFiles && !current.isFile;
    final hasTransfer = transferActive || transferProgress != null;

    final Widget trailing;
    if (showSftp) {
      trailing = IosBarButtonGroup(
        items: [
          IosBarButtonItem(
            key: const ValueKey('ios_session_bar_sftp'),
            icon: IosIcons.folder,
            semanticLabel: l10n.sftpFileManager,
            badge: hasTransfer
                ? _TransferProgressRing(
                    progress: transferProgress,
                    color: c.tint,
                  )
                : null,
            onPressed: (_) => onSftp(current.id),
          ),
          IosBarButtonItem(
            key: const ValueKey('ios_session_bar_more'),
            icon: IosIcons.more,
            onPressed: (anchor) => unawaited(
              _openMoreMenu(context, anchor, current, live),
            ),
          ),
        ],
      );
    } else {
      trailing = Builder(
        builder: (btnContext) => IosBarButton(
          key: const ValueKey('ios_session_bar_more'),
          icon: IosIcons.more,
          onPressed: () => unawaited(
            _openMoreMenu(context, iosWidgetRect(btnContext), current, live),
          ),
        ),
      );
    }

    return IosGlassBar(
      key: const ValueKey('ios_session_bar'),
      sigma: 20,
      // No separator line under the bar: the frosted fill sets it apart.
      fill: barFill,
      child: Padding(
        padding: EdgeInsets.only(
          top: pad.top,
          left: pad.left + 6,
          right: pad.right + 10,
        ),
        child: SizedBox(
          height: 44,
          child: NavigationToolbar(
            middleSpacing: 6,
            leading: IosBackButton(
              key: const ValueKey('ios_session_bar_back'),
              label: backLabel ?? l10n.hosts,
              onPressed: onBack,
            ),
            middle: _SessionTitleSwitcher(
              sessions: live,
              current: current,
              health: activeHealth,
              onSelect: onSelect,
              onOpenSwitcher: live.isEmpty
                  ? null
                  : () => showIosSessionSwitcher(
                      context,
                      sessions: live,
                      selectedId: selectedId,
                      onSelect: onSelect,
                      onClose: onClose,
                      onNewConnection: onNewConnection,
                      subtitles: sessionSubtitles,
                    ),
            ),
            trailing: trailing,
          ),
        ),
      ),
    );
  }
}

class _SessionTitleSwitcher extends StatefulWidget {
  const _SessionTitleSwitcher({
    required this.sessions,
    required this.current,
    required this.onSelect,
    required this.onOpenSwitcher,
    this.health,
  });

  final List<WorkspaceTab> sessions;
  final WorkspaceTab? current;
  final ValueChanged<String> onSelect;
  final VoidCallback? onOpenSwitcher;
  final SshConnectionHealth? health;

  @override
  State<_SessionTitleSwitcher> createState() => _SessionTitleSwitcherState();
}

class _SessionTitleSwitcherState extends State<_SessionTitleSwitcher> {
  double _rawDragX = 0;

  void _switchRelative(int step) {
    if (widget.sessions.length < 2 || widget.current == null) return;
    final idx = widget.sessions.indexWhere((t) => t.id == widget.current!.id);
    if (idx < 0) return;
    final next = (idx + step) % widget.sessions.length;
    final target =
        widget.sessions[next < 0 ? next + widget.sessions.length : next];
    HapticFeedback.selectionClick().catchError((Object _) {});
    widget.onSelect(target.id);
  }

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final current = widget.current;
    if (current == null) return const SizedBox.shrink();
    final canSwipe = widget.sessions.length >= 2;
    final visualDx = (_rawDragX * 0.45).clamp(-28.0, 28.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final threshold = math.min(64.0, math.max(32.0, constraints.maxWidth * 0.30));
        return GestureDetector(
          key: const ValueKey('ios_session_bar_title'),
          behavior: HitTestBehavior.opaque,
          onTap: widget.onOpenSwitcher,
          onHorizontalDragUpdate: canSwipe
              ? (details) => setState(() => _rawDragX += details.delta.dx)
              : null,
          onHorizontalDragEnd: canSwipe
              ? (details) {
                  final dx = _rawDragX;
                  final velocity = details.primaryVelocity ?? 0;
                  setState(() => _rawDragX = 0);
                  if (dx < -threshold || velocity < -400) {
                    _switchRelative(1);
                  } else if (dx > threshold || velocity > 400) {
                    _switchRelative(-1);
                  }
                }
              : null,
          onHorizontalDragCancel: canSwipe
              ? () => setState(() => _rawDragX = 0)
              : null,
          child: AnimatedContainer(
            duration: _rawDragX == 0
                ? const Duration(milliseconds: 180)
                : Duration.zero,
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(visualDx, 0, 0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: widget.health == null
                  ? _buildTitleRow(
                      c: c,
                      current: current,
                      canSwipe: canSwipe,
                      health: null,
                      maxWidth: constraints.maxWidth,
                    )
                  : ListenableBuilder(
                      listenable: widget.health!,
                      builder: (_, _) => _buildTitleRow(
                        c: c,
                        current: current,
                        canSwipe: canSwipe,
                        health: widget.health,
                        maxWidth: constraints.maxWidth,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
  Widget _buildTitleRow({
    required IosColors c,
    required WorkspaceTab current,
    required bool canSwipe,
    required SshConnectionHealth? health,
    required double maxWidth,
  }) {
    // A connection that waits on the user (a host key review in its pane)
    // shows yellow where a connected session shows green.
    final dotColor = current.needsAttention
        ? workspaceTabAttentionColor
        : !current.isConnected
        ? c.tertiaryLabel
        : switch (health?.state) {
            SshHealthState.degraded => c.warning,
            SshHealthState.stale => c.destructive,
            _ => c.online,
          };
    final probing = current.isConnected && health?.probing == true;
    final rtt = current.isConnected ? health?.lastRtt : null;
    final badgeText = probing
        ? '…'
        : (rtt == null ? null : SshConnectionHealth.formatRtt(rtt));
    final showBadge = badgeText != null && maxWidth >= 150;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IosStatusDot(size: 6, color: dotColor),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            current.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: IosType.headline.copyWith(color: c.label),
          ),
        ),
        if (showBadge) ...[
          const SizedBox(width: 5),
          Text(
            badgeText,
            key: const ValueKey('ios_session_bar_rtt'),
            maxLines: 1,
            softWrap: false,
            style: IosType.caption2.copyWith(
              color: dotColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
        if (canSwipe) ...[
          const SizedBox(width: 4),
          IosChevron(
            direction: IosChevronDirection.down,
            size: 10,
            color: c.secondaryLabel,
          ),
        ],
      ],
    );
  }
}

class _TransferProgressRing extends StatefulWidget {
  const _TransferProgressRing({required this.progress, required this.color});

  final double? progress;
  final Color color;

  @override
  State<_TransferProgressRing> createState() => _TransferProgressRingState();
}

class _TransferProgressRingState extends State<_TransferProgressRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  bool get _determinate =>
      widget.progress != null &&
      widget.progress! >= 0.0 &&
      widget.progress! <= 1.0;

  @override
  void initState() {
    super.initState();
    if (!_determinate) _spin.repeat();
  }

  @override
  void didUpdateWidget(_TransferProgressRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_determinate && !_spin.isAnimating) {
      _spin.repeat();
    } else if (_determinate && _spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SizedBox.square(
      dimension: 34,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, _) => CustomPaint(
          painter: _RingPainter(
            color: widget.color,
            progress: _determinate ? widget.progress! : null,
            phase: _spin.value,
          ),
        ),
      ),
    ),
  );
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.color,
    required this.progress,
    required this.phase,
  });

  final Color color;
  final double? progress;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.0;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final trackPaint = Paint()
      ..color = color.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawOval(rect, trackPaint);

    final arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    if (progress != null) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        2 * math.pi * progress!.clamp(0.05, 1.0),
        false,
        arcPaint,
      );
    } else {
      canvas.drawArc(
        rect,
        phase * 2 * math.pi - math.pi / 2,
        math.pi * 0.65,
        false,
        arcPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.color != color || old.progress != progress || old.phase != phase;
}
