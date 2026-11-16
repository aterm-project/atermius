import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'ios_tokens.dart';

/// 1.8 饱和度矩阵：Liquid Glass 折射时让背景色更通透鲜活。
const List<double> _kSaturation180 = <double>[
  1.6386, -0.5724, -0.0662, 0, 0, //
  -0.1614, 1.2276, -0.0662, 0, 0, //
  -0.1614, -0.5724, 1.7338, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// Liquid Glass 统一配方：模糊 + 饱和度提升。
ImageFilter iosGlassFilter({double sigma = 24}) => ImageFilter.compose(
  outer: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.mirror),
  inner: const ColorFilter.matrix(_kSaturation180),
);

/// 是否渲染真实玻璃；高对比度 / 无障碍粗体等情况下退化为不透明。
bool iosGlassEnabled(BuildContext context) =>
    !(MediaQuery.maybeHighContrastOf(context) ?? false);

/// 通用 Liquid Glass 表面：任意 [shape] 裁剪 + 背景模糊 + 镜面渐变描边 + 柔和投影。
///
/// 自动接入最近的 [BackdropGroup]（导航栏与 TabBar 共享一次背景采样）。
class IosGlassSurface extends StatelessWidget {
  const IosGlassSurface({
    super.key,
    required this.child,
    this.shape = const StadiumBorder(),
    this.sigma = 24,
    this.fill,
    this.gradient,
    this.highContrastFill,
    this.shadow = true,
    this.shadows,
    this.rim = true,
    this.rimStrong,
    this.rimWeak,
    this.rimWidth,
    this.padding,
  });

  final Widget child;
  final OutlinedBorder shape;
  final double sigma;
  final Color? fill;

  /// 自定义玻璃层渐变填充（如 Tinted Liquid Glass 染色液态玻璃）；未指定时使用 [fill] 叠加镜面微光。
  final Gradient? gradient;

  /// 高对比无障碍模式下的实色回退填充。
  final Color? highContrastFill;

  final bool shadow;

  /// 自定义外投影列表；未指定且 [shadow] 为 true 时使用默认单层玻璃阴影。
  final List<BoxShadow>? shadows;

  final bool rim;
  final Color? rimStrong;
  final Color? rimWeak;
  final double? rimWidth;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final glass = iosGlassEnabled(context);
    final effectiveFill = fill ?? c.glassFill;
    Widget body = padding == null ? child : Padding(padding: padding!, child: child);
    final decorated = DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        gradient: glass
            ? (gradient ??
                  LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color.alphaBlend(
                        Colors.white.withValues(alpha: c.isDark ? 0.08 : 0.20),
                        effectiveFill,
                      ),
                      Color.alphaBlend(
                        Colors.white.withValues(alpha: c.isDark ? 0.04 : 0.0),
                        effectiveFill,
                      ),
                    ],
                  ))
            : null,
        color: glass
            ? null
            : (highContrastFill ??
                  (c.isDark
                      ? const Color(0xFF1C1C1E)
                      : const Color(0xFFF9F9F9))),
      ),
      child: body,
    );
    body = ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: glass
          ? BackdropFilter.grouped(
              filter: iosGlassFilter(sigma: sigma),
              child: decorated,
            )
          : decorated,
    );
    if (rim) {
      body = CustomPaint(
        foregroundPainter: _GlassRimPainter(
          shape: shape,
          strong: glass
              ? (rimStrong ?? c.glassRimStrong)
              : (rimStrong?.withValues(alpha: 1) ?? c.separator),
          weak: glass
              ? (rimWeak ?? c.glassRimWeak)
              : (rimWeak?.withValues(alpha: 1) ?? c.separator),
          width: glass ? (rimWidth ?? 0.75) : (rimWidth ?? IosMetrics.hairline(context)),
        ),
        child: body,
      );
    }
    if (shadow) {
      body = DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          shadows:
              shadows ??
              [
                BoxShadow(
                  color: c.glassShadow,
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
        ),
        child: body,
      );
    }
    return body;
  }
}

class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter({
    required this.shape,
    required this.strong,
    required this.weak,
    required this.width,
  });

  final OutlinedBorder shape;
  final Color strong;
  final Color weak;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = shape.getOuterPath(rect.deflate(width / 2));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [strong, weak, weak],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassRimPainter old) =>
      old.shape != shape ||
      old.strong != strong ||
      old.weak != weak ||
      old.width != width;
}

/// 玻璃胶囊（TabBar / Live Session Pill / Toast / 按钮组）。
class IosGlassCapsule extends StatelessWidget {
  const IosGlassCapsule({
    super.key,
    required this.child,
    this.height,
    this.padding,
    this.sigma = 24,
    this.fill,
    this.gradient,
    this.highContrastFill,
    this.shadow = true,
    this.shadows,
    this.rimStrong,
    this.rimWeak,
    this.rimWidth,
  });

  final Widget child;
  final double? height;
  final EdgeInsetsGeometry? padding;
  final double sigma;
  final Color? fill;
  final Gradient? gradient;
  final Color? highContrastFill;
  final bool shadow;
  final List<BoxShadow>? shadows;
  final Color? rimStrong;
  final Color? rimWeak;
  final double? rimWidth;

  @override
  Widget build(BuildContext context) => IosGlassSurface(
    sigma: sigma,
    fill: fill,
    gradient: gradient,
    highContrastFill: highContrastFill,
    shadow: shadow,
    shadows: shadows,
    rimStrong: rimStrong,
    rimWeak: rimWeak,
    rimWidth: rimWidth,
    padding: padding,
    child: height == null ? child : SizedBox(height: height, child: child),
  );
}

/// 44pt 玻璃圆钮（iOS 26 导航栏按钮）。
class IosGlassCircle extends StatelessWidget {
  const IosGlassCircle({
    super.key,
    required this.child,
    this.size = IosMetrics.glassButton,
    this.onPressed,
    this.semanticLabel,
    this.shadow = false,
  });

  final Widget child;
  final double size;
  final VoidCallback? onPressed;
  final String? semanticLabel;
  final bool shadow;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: semanticLabel,
    child: IosGlassTapScale(
      onTap: onPressed,
      child: SizedBox.square(
        dimension: size,
        child: IosGlassSurface(
          shape: const CircleBorder(),
          shadow: shadow,
          child: Center(child: child),
        ),
      ),
    ),
  );
}

/// 矩形毛玻璃条（导航栏滚动后背景、会话栏、键盘附件栏）。
class IosGlassBar extends StatelessWidget {
  const IosGlassBar({
    super.key,
    required this.child,
    this.sigma = 20,
    this.fill,
    this.bottomSeparator = false,
    this.topSeparator = false,
    this.separatorColor,
  });

  final Widget child;
  final double sigma;
  final Color? fill;
  final bool bottomSeparator;
  final bool topSeparator;
  final Color? separatorColor;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final glass = iosGlassEnabled(context);
    final line = BorderSide(
      color: separatorColor ?? c.separator,
      width: IosMetrics.hairline(context),
    );
    final decorated = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border(
          top: topSeparator ? line : BorderSide.none,
          bottom: bottomSeparator ? line : BorderSide.none,
        ),
      ),
      child: ColoredBox(
        color: glass ? (fill ?? c.barFill) : (fill ?? c.barFill).withValues(alpha: 1),
        child: child,
      ),
    );
    if (!glass) return decorated;
    return ClipRect(
      child: BackdropFilter.grouped(
        filter: iosGlassFilter(sigma: sigma),
        child: decorated,
      ),
    );
  }
}

/// 下拉菜单 / 弹出面板（14pt 连续曲率玻璃）。
class IosGlassPanel extends StatelessWidget {
  const IosGlassPanel({
    super.key,
    required this.child,
    this.radius = IosMetrics.menuRadius,
  });

  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => IosGlassSurface(
    shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius)),
    fill: IosColors.of(context).menuFill,
    sigma: 30,
    child: child,
  );
}

/// 玻璃控件按压反馈：scale 0.94 + 不透明度 0.85（无水波纹）。
class IosGlassTapScale extends StatefulWidget {
  const IosGlassTapScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.94,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;

  @override
  State<IosGlassTapScale> createState() => _IosGlassTapScaleState();
}

class _IosGlassTapScaleState extends State<IosGlassTapScale> {
  bool _pressed = false;

  void _set(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        child: AnimatedOpacity(
          opacity: !enabled ? 0.4 : (_pressed ? 0.85 : 1),
          duration: const Duration(milliseconds: 140),
          child: widget.child,
        ),
      ),
    );
  }
}
