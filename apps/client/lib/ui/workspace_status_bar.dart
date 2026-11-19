import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../platform/fullscreen.dart';
import '../ssh/ssh_connection_health.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'apple_hig.dart';

class WorkspaceStatusBar extends StatelessWidget {
  const WorkspaceStatusBar({
    required this.status,
    required this.detail,
    required this.sessionCount,
    this.onProperties,
    this.transfer,
    this.badge,
    this.health,
    this.onProbeHealth,
    super.key,
  });
  final String status;
  final String detail;
  final int sessionCount;
  final VoidCallback? onProperties;
  final Widget? transfer;

  /// Optional compact account badge before the session count (for example
  /// the credential-visibility "admin-visible" chip). Null keeps the layout.
  final Widget? badge;

  /// 当前活跃 SSH 会话的实时链路健康遥测（RTT / 在线时长 / 抖动状态）。
  final SshConnectionHealth? health;

  /// 点按状态栏链路健康胶囊时触发即时探活。
  final VoidCallback? onProbeHealth;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: FullscreenController.instance,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    if ((Theme.of(context).platform == TargetPlatform.android ||
            Theme.of(context).platform == TargetPlatform.iOS) &&
        FullscreenController.instance.enabled) {
      return const SizedBox.shrink();
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return const SizedBox.shrink();
    }
    // The bar grows with the user's text scale instead of clipping glyphs;
    // 28px stays the height at 100%.
    final lineHeight = MediaQuery.textScalerOf(context).scale(11) * 1.4;
    final height = lineHeight + 12 > 28 ? lineHeight + 12 : 28.0;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: SafeArea(
        top: false,
        child: SizedBox(
          key: const ValueKey('workspace_status_bar'),
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Narrow phones / large text: tighter gaps; every text segment
              // can shrink (ellipsis) so the Row never overflows.
              final narrow = constraints.maxWidth < 420;
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: narrow ? 8 : 12),
                child: Row(
                  children: [
                    const Icon(Icons.lock_outline, size: 13),
                    const SizedBox(width: 6),
                    // connecting → connected / disconnected cross-fades.
                    Flexible(
                      flex: 2,
                      child: MotionSwitcher(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text(
                          status,
                          key: ValueKey(status),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                    SizedBox(width: narrow ? 8 : 14),
                    Expanded(
                      flex: 3,
                      child: GestureDetector(
                        onSecondaryTap: onProperties,
                        onTap: onProperties,
                        child: Text(
                          detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ),
                    if (health != null) ...[
                      SizedBox(width: narrow ? 6 : 10),
                      Flexible(
                        child: _StatusBarHealthPill(
                          health: health!,
                          compact: narrow,
                          onTap: onProbeHealth,
                        ),
                      ),
                    ],
                    if (transfer != null) Flexible(child: transfer!),
                    if (badge != null) ...[
                      SizedBox(width: narrow ? 6 : 10),
                      Flexible(child: badge!),
                    ],
                    SizedBox(width: narrow ? 6 : 10),
                    Text(
                      '$sessionCount SSH',
                      maxLines: 1,
                      softWrap: false,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 桌面与平板底部状态栏的实时链路健康胶囊（等宽数字防跳动、每 30 秒低功耗刷新在线时长）。
class _StatusBarHealthPill extends StatefulWidget {
  const _StatusBarHealthPill({
    required this.health,
    required this.compact,
    this.onTap,
  });

  final SshConnectionHealth health;
  final bool compact;
  final VoidCallback? onTap;

  @override
  State<_StatusBarHealthPill> createState() => _StatusBarHealthPillState();
}

class _StatusBarHealthPillState extends State<_StatusBarHealthPill> {
  Timer? _uptimeTicker;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _StatusBarHealthPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.health, widget.health)) {
      _syncTicker();
    }
  }

  void _syncTicker() {
    _uptimeTicker?.cancel();
    _uptimeTicker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && widget.health.state != SshHealthState.closed) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _uptimeTicker?.cancel();
    super.dispose();
  }

  static String _t(
    BuildContext context, {
    required String zh,
    required String en,
    required String ja,
    required String ru,
  }) => switch (Localizations.maybeLocaleOf(context)?.languageCode) {
    'zh' => zh,
    'ja' => ja,
    'ru' => ru,
    _ => en,
  };

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ListenableBuilder(
      listenable: widget.health,
      builder: (context, _) {
        final h = widget.health;
        if (h.state == SshHealthState.closed) return const SizedBox.shrink();
        final dotColor = switch (h.state) {
          SshHealthState.healthy => palette.accentText,
          SshHealthState.degraded => palette.orange,
          SshHealthState.stale => palette.red,
          SshHealthState.closed => palette.muted,
        };
        final parts = <String>[];
        if (h.probing) {
          parts.add(
            _t(
              context,
              zh: '探活中…',
              en: 'Probing…',
              ja: '確認中…',
              ru: 'Проверка…',
            ),
          );
        } else if (h.missedProbes > 0) {
          parts.add(
            _t(
              context,
              zh: '探活丢包 ${h.missedProbes}/${h.maxMissedThreshold}',
              en: 'Missed ${h.missedProbes}/${h.maxMissedThreshold}',
              ja: '応答欠損 ${h.missedProbes}/${h.maxMissedThreshold}',
              ru: 'Потери ${h.missedProbes}/${h.maxMissedThreshold}',
            ),
          );
        } else if (h.lastRtt != null) {
          parts.add(SshConnectionHealth.formatRtt(h.lastRtt!));
        }
        if (!widget.compact) {
          parts.add(SshConnectionHealth.formatUptime(h.uptime));
        }
        final label = parts.isEmpty
            ? SshConnectionHealth.formatUptime(h.uptime)
            : parts.join(' · ');

        final content = Container(
          key: const ValueKey('workspace_status_health_pill'),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: dotColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: dotColor.withValues(alpha: 0.28)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    color: dotColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        );

        final onTap = widget.onTap;
        if (onTap == null) return content;
        return Tooltip(
          message: _t(
            context,
            zh: '点击立即探活链路延迟',
            en: 'Click to probe SSH link now',
            ja: 'クリックして SSH 接続を即時確認',
            ru: 'Нажмите для проверки канала SSH',
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () {
                AppleHaptics.selection(context);
                onTap();
              },
              child: content,
            ),
          ),
        );
      },
    );
  }
}
