import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../workspace_tab_bar.dart' show WorkspaceTab;
import 'ios_glass.dart';
import 'ios_icons.dart';
import 'ios_mode.dart';
import 'ios_tokens.dart';

/// 实时活跃会话胶囊条（视觉附录 §9.2 / 蓝图 §1.4），对标 iOS 26 `tabViewBottomAccessory`
/// 与灵动岛 Live Activity **Tinted Liquid Glass 染色液态玻璃** 规范。
///
/// - 高度 54pt（横屏紧凑 44pt），位于底部悬浮玻璃 TabBar 上方 8pt。
/// - 翡翠/琥珀染色毛玻璃底 + 1.1pt 高光染色镜面描边 + 彩色环境辉光投影，与下方中性灰 TabBar 形成鲜明层次。
/// - 点按主体：回到 [currentId] 对应的终端会话（不断连）。
/// - 点按右侧 `+N / ⌃`、长按或上滑：展开会话切换 Sheet（[onShowSwitcher]）。
class IosLiveSessionPill extends StatelessWidget {
  const IosLiveSessionPill({
    super.key,
    required this.sessions,
    this.currentId,
    required this.onResume,
    required this.onShowSwitcher,
    this.subtitles = const {},
    this.connectingIds = const {},
  });

  final List<WorkspaceTab> sessions;
  final String? currentId;
  final ValueChanged<String> onResume;
  final VoidCallback onShowSwitcher;

  /// 可选副标题映射（`tabId -> 'user@addr:port'`）。
  final Map<String, String> subtitles;

  /// 正在握手连接中的会话 ID（显示快呼吸琥珀光环）。
  final Set<String> connectingIds;

  @override
  Widget build(BuildContext context) {
    final live = sessions.where((tab) => !tab.isHome).toList();
    if (live.isEmpty) return const SizedBox.shrink();

    final c = IosColors.of(context);
    final compact = isIosCompactHeight(context);
    final active =
        live.where((tab) => tab.id == currentId).firstOrNull ?? live.first;
    final isConnecting =
        !active.isConnected &&
        (connectingIds.contains(active.id) || active.status == 'connecting');

    // 状态主题强调色：在线翡翠绿 / 握手琥珀橙 / 断开品牌色。
    final Color accent = active.isConnected
        ? Color.lerp(c.tint, c.online, c.isDark ? 0.42 : 0.35)!
        : isConnecting
        ? c.warning
        : c.tint;

    // 亮色浅底上的高对比可读强调色（琥珀橙在亮色玻璃上略压深以保证锐利对比度）。
    final Color readableAccent = !c.isDark && isConnecting
        ? Color.lerp(c.warning, const Color(0xFF8F4900), 0.38)!
        : accent;

    // 染色毛玻璃渐变底色（不再复用中性暗灰 c.glassFill）。
    final Gradient glassGradient = c.isDark
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                accent.withValues(alpha: 0.34),
                isConnecting
                    ? const Color(0xDB22190B)
                    : const Color(0xDB0B221E),
              ),
              Color.alphaBlend(
                accent.withValues(alpha: 0.18),
                isConnecting
                    ? const Color(0xDB1C1610)
                    : const Color(0xDB101C1B),
              ),
            ],
          )
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                accent.withValues(alpha: 0.20),
                isConnecting
                    ? const Color(0xF0FFFDF9)
                    : const Color(0xF0FFFFFF),
              ),
              Color.alphaBlend(
                accent.withValues(alpha: 0.10),
                isConnecting
                    ? const Color(0xF0FBF7EF)
                    : const Color(0xF0F4FBF9),
              ),
            ],
          );

    // 高对比无障碍模式同样采用清晰的染色实底。
    final Color highContrastFill = c.isDark
        ? Color.alphaBlend(
            accent.withValues(alpha: 0.36),
            isConnecting ? const Color(0xFF211709) : const Color(0xFF0A1F1B),
          )
        : Color.alphaBlend(
            accent.withValues(alpha: 0.22),
            isConnecting ? const Color(0xFFFFF8EC) : const Color(0xFFF0FAF7),
          );

    final extraCount = live.length - 1;
    final subtitle = subtitles[active.id] ?? active.status;
    final pillHeight = compact
        ? IosMetrics.accessoryHeightCompact
        : IosMetrics.accessoryHeight;

    void triggerSwitcher() {
      HapticFeedback.selectionClick().catchError((Object _) {});
      onShowSwitcher();
    }

    return Semantics(
      container: true,
      button: true,
      label: active.title,
      child: GestureDetector(
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) < -180) {
            triggerSwitcher();
          }
        },
        child: IosGlassTapScale(
          key: const ValueKey('ios_live_session_pill'),
          pressedScale: 0.97,
          onTap: () {
            HapticFeedback.lightImpact().catchError((Object _) {});
            onResume(active.id);
          },
          onLongPress: triggerSwitcher,
          child: IosGlassCapsule(
            height: pillHeight,
            sigma: 28,
            gradient: glassGradient,
            highContrastFill: highContrastFill,
            shadows: [
              BoxShadow(
                color: accent.withValues(alpha: c.isDark ? 0.32 : 0.20),
                blurRadius: 22,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: c.isDark ? 0.38 : 0.12),
                blurRadius: 28,
                offset: const Offset(0, 10),
              ),
            ],
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.15,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showSecondLine =
                      !compact && subtitle != null && subtitle.isNotEmpty;
                  final showMicroBadge =
                      constraints.maxWidth >= 220 &&
                      (active.isConnected || isConnecting);
                  final isZh =
                      Localizations.maybeLocaleOf(context)?.languageCode ==
                      'zh';
                  final microBadgeLabel = active.isConnected
                      ? 'LIVE'
                      : (isZh ? '连接中' : 'SYNC');

                  final badgeColor = active.isConnected
                      ? c.online
                      : isConnecting
                      ? c.warning
                      : c.tertiaryLabel;

                  return Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: compact ? 7 : 9,
                      end: compact ? 5 : 6,
                    ),
                    child: Row(
                      children: [
                        _LiveTerminalOrb(
                          size: compact ? 30 : 36,
                          accent: accent,
                          beaconColor: badgeColor,
                          isDark: c.isDark,
                          isFile: active.isFile,
                          isConnected: active.isConnected,
                          isConnecting: isConnecting,
                        ),
                        SizedBox(width: compact ? 9 : 11),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      active.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: IosType.subheadline.copyWith(
                                        fontSize: compact ? 14.5 : 15.5,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.32,
                                        height: 1.18,
                                        color: c.isDark
                                            ? Colors.white
                                            : const Color(0xFF071F1B),
                                      ),
                                    ),
                                  ),
                                  if (showMicroBadge) ...[
                                    const SizedBox(width: 6),
                                    _LiveStateMicroPill(
                                      label: microBadgeLabel,
                                      accent: accent,
                                      readableAccent: readableAccent,
                                      isDark: c.isDark,
                                    ),
                                  ],
                                ],
                              ),
                              if (showSecondLine) ...[
                                const SizedBox(height: 2),
                                Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: IosType.mono.copyWith(
                                    fontSize: 12,
                                    height: 1.15,
                                    color: c.isDark
                                        ? Colors.white.withValues(alpha: 0.78)
                                        : Color.alphaBlend(
                                            accent.withValues(alpha: 0.36),
                                            const Color(0xBF122420),
                                          ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        Semantics(
                          button: true,
                          child: GestureDetector(
                            key: const ValueKey(
                              'ios_live_session_pill_switcher',
                            ),
                            behavior: HitTestBehavior.opaque,
                            onTap: triggerSwitcher,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minWidth: 44,
                                minHeight: 40,
                              ),
                              child: Center(
                                child: DecoratedBox(
                                  decoration: ShapeDecoration(
                                    color: accent.withValues(
                                      alpha: c.isDark ? 0.24 : 0.16,
                                    ),
                                    shape: const StadiumBorder(),
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: extraCount > 0 ? 10 : 11,
                                      vertical: compact ? 5 : 7,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (extraCount > 0) ...[
                                          Text(
                                            '+$extraCount',
                                            style: IosType.footnote.copyWith(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              height: 1.0,
                                              color: c.isDark
                                                  ? Colors.white
                                                  : readableAccent,
                                            ),
                                          ),
                                          const SizedBox(width: 5),
                                        ],
                                        IosChevron(
                                          direction: IosChevronDirection.up,
                                          size: extraCount > 0 ? 11.5 : 12,
                                          strokeWidth: 2.2,
                                          color: readableAccent,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 左侧实色渐变圆形终端徽章 + 右下角双圈状态光环信标。
class _LiveTerminalOrb extends StatelessWidget {
  const _LiveTerminalOrb({
    required this.size,
    required this.accent,
    required this.beaconColor,
    required this.isDark,
    required this.isFile,
    required this.isConnected,
    required this.isConnecting,
  });

  final double size;
  final Color accent;
  final Color beaconColor;
  final bool isDark;
  final bool isFile;
  final bool isConnected;
  final bool isConnecting;

  @override
  Widget build(BuildContext context) {
    final topColor = Color.lerp(accent, Colors.white, isDark ? 0.18 : 0.12)!;
    final bottomColor = Color.lerp(accent, Colors.black, isDark ? 0.10 : 0.14)!;
    final onBadgeBrightness = ThemeData.estimateBrightnessForColor(accent);
    final glyphColor = onBadgeBrightness == Brightness.light
        ? (isConnecting ? const Color(0xFF2B1500) : const Color(0xFF04261F))
        : Colors.white;

    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [topColor, bottomColor],
                ),
                boxShadow: [
                  BoxShadow(
                    color: accent.withValues(alpha: isDark ? 0.42 : 0.28),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Center(
                child: Icon(
                  isFile ? IosIcons.folder : IosIcons.terminal,
                  size: size * 0.52,
                  color: glyphColor,
                ),
              ),
            ),
          ),
          PositionedDirectional(
            end: -2,
            bottom: -2,
            child: _LiveRadarBeacon(
              color: beaconColor,
              isDark: isDark,
              showHalo: isConnected || isConnecting,
              // 重要：仅在连接握手中（!isConnected && isConnecting）启用呼吸动画；
              // isConnected 使用静态双层发光同心圆光晕环，保证 pumpAndSettle() 瞬间完成不超时。
              pulsing: isConnecting && !isConnected,
            ),
          ),
        ],
      ),
    );
  }
}

/// 双圈同心光环状态指示器：
/// - `pulsing: false` 且 `showHalo: true`（已连接）：渲染静态双层发光同心圆光晕环，零无限动画开销。
/// - `pulsing: true`（连接握手中）：双圈呼吸光环快脉冲动画。
class _LiveRadarBeacon extends StatefulWidget {
  const _LiveRadarBeacon({
    required this.color,
    required this.isDark,
    required this.showHalo,
    required this.pulsing,
  });

  final Color color;
  final bool isDark;
  final bool showHalo;
  final bool pulsing;

  @override
  State<_LiveRadarBeacon> createState() => _LiveRadarBeaconState();
}

class _LiveRadarBeaconState extends State<_LiveRadarBeacon>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  void _syncAnimation() {
    if (widget.pulsing) {
      final ctrl = _controller ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 900),
      );
      if (!ctrl.isAnimating) ctrl.repeat(reverse: true);
    } else {
      _controller
        ?..stop()
        ..value = 0;
    }
  }

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(_LiveRadarBeacon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulsing != widget.pulsing) {
      _syncAnimation();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Widget _buildRings(double t) {
    final outerAlpha = widget.pulsing
        ? (0.14 + 0.22 * t)
        : (widget.isDark ? 0.26 : 0.22);
    final midAlpha = widget.pulsing
        ? (0.28 + 0.30 * t)
        : (widget.isDark ? 0.46 : 0.38);
    final outerScale = widget.pulsing ? (0.90 + 0.22 * t) : 1.0;
    final coreBackdrop = widget.isDark
        ? const Color(0xFF0A1E1A)
        : const Color(0xFFF4FBF9);

    return SizedBox.square(
      dimension: 15,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.showHalo) ...[
            Transform.scale(
              scale: outerScale,
              child: SizedBox.square(
                dimension: 15,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: outerAlpha),
                  ),
                ),
              ),
            ),
            SizedBox.square(
              dimension: 11,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: midAlpha),
                ),
              ),
            ),
          ],
          SizedBox.square(
            dimension: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color,
                // Knock-out gap between the core and its halo: part of the
                // status glyph, not a surface outline.
                border: Border.all(color: coreBackdrop, width: 1.2),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _controller;
    if (!widget.pulsing || ctrl == null) {
      return _buildRings(0);
    }
    return AnimatedBuilder(
      animation: ctrl,
      builder: (context, _) => _buildRings(ctrl.value),
    );
  }
}

/// 标题右侧精致状态微标胶囊（如 `LIVE` / `连接中`）。
class _LiveStateMicroPill extends StatelessWidget {
  const _LiveStateMicroPill({
    required this.label,
    required this.accent,
    required this.readableAccent,
    required this.isDark,
  });

  final String label;
  final Color accent;
  final Color readableAccent;
  final bool isDark;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(
      color: accent.withValues(alpha: isDark ? 0.22 : 0.15),
      shape: const StadiumBorder(),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      child: Text(
        label,
        maxLines: 1,
        style: IosType.caption2.copyWith(
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.55,
          height: 1.15,
          color: isDark
              ? Color.lerp(accent, Colors.white, 0.38)!
              : readableAccent,
        ),
      ),
    ),
  );
}
