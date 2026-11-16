import 'dart:async' show unawaited;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'ios_native/ios_mode.dart' show isIosPhone;

/// Returns `true` when [platform] is an Apple operating system (`iOS` / `macOS`).
bool isApplePlatform(TargetPlatform platform) =>
    platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;

/// Returns `true` when the ambient [Theme] targets an Apple platform.
bool isAppleContext(BuildContext context) =>
    isApplePlatform(Theme.of(context).platform);

/// Returns `true` when Apple translucent frosted glass ("Liquid Glass" /
/// macOS Vibrancy) should be rendered, gracefully falling back to opaque
/// surfaces when high-contrast accessibility is enabled.
bool shouldUseAppleGlass(BuildContext context) {
  if (!isAppleContext(context)) return false;
  if (MediaQuery.maybeHighContrastOf(context) ?? false) return false;
  return true;
}

/// Builds a continuous-curvature squircle border ([RoundedSuperellipseBorder])
/// on Apple platforms (or when [platform] is omitted), falling back to a
/// standard [RoundedRectangleBorder] on non-Apple platforms.
OutlinedBorder appleSquircleBorder(
  BorderRadiusGeometry borderRadius, {
  TargetPlatform? platform,
  BorderSide side = BorderSide.none,
}) {
  if (platform == null || isApplePlatform(platform)) {
    return RoundedSuperellipseBorder(borderRadius: borderRadius, side: side);
  }
  return RoundedRectangleBorder(borderRadius: borderRadius, side: side);
}

/// Returns a crisp physical hairline stroke width (`0.5pt` on 2x/3x Retina
/// displays, `1.0pt` on standard-DPI displays).
double appleHairlineWidth(BuildContext context) {
  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
  return 1.0 / dpr.clamp(1.0, 2.0);
}

/// Subtle specular rim color used along Apple Liquid Glass edges.
Color appleGlassRimColor(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark
      ? Colors.white.withValues(alpha: 0.16)
      : Colors.black.withValues(alpha: 0.09);
}

/// Ambient subtle emerald/cyan aurora backdrop behind Home workspaces on Apple
/// platforms so translucent Liquid Glass bars, sidebars, and host cards refract
/// rich depth even when no custom photo wallpaper is configured.
class AppleAmbientBackdrop extends StatelessWidget {
  const AppleAmbientBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!shouldUseAppleGlass(context)) return child;
    // iPhone 纯血 iOS 模式：OLED 纯黑 / #F2F2F7 底色，不叠彩色极光。
    if (isIosPhone(context)) return child;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.78, -0.82),
                radius: 1.25,
                colors: [
                  const Color(0xFF0F7B6C).withValues(alpha: dark ? 0.22 : 0.10),
                  const Color(0xFF4FD8C4).withValues(alpha: dark ? 0.07 : 0.04),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.85, 0.78),
                  radius: 1.15,
                  colors: [
                    const Color(0xFF1A6B8A).withValues(alpha: dark ? 0.18 : 0.08),
                    Colors.transparent,
                  ],
                ),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Frosted translucent surface with continuous-curvature squircle clipping,
/// real-time Gaussian blur ([BackdropFilter]), and a subtle specular rim border.
///
/// On non-Apple platforms or high-contrast mode, renders a clean opaque surface
/// without blur overhead.
class AppleGlassSurface extends StatelessWidget {
  const AppleGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
    this.tintColor,
    this.opacity,
    this.sigma = 24.0,
    this.borderSide,
    this.boxShadow,
    this.padding,
  });

  final Widget child;
  final BorderRadiusGeometry borderRadius;
  final Color? tintColor;
  final double? opacity;
  final double sigma;
  final BorderSide? borderSide;
  final List<BoxShadow>? boxShadow;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final glass = shouldUseAppleGlass(context);
    final baseColor = tintColor ?? theme.colorScheme.surface;
    final effectiveOpacity = opacity ?? (dark ? 0.74 : 0.80);
    final side =
        borderSide ??
        BorderSide(
          color: appleGlassRimColor(context),
          width: appleHairlineWidth(context),
        );
    final shape = appleSquircleBorder(
      borderRadius,
      platform: theme.platform,
      side: side,
    );

    Widget body = padding != null
        ? Padding(padding: padding!, child: child)
        : child;

    if (!glass) {
      return DecoratedBox(
        decoration: ShapeDecoration(
          color: baseColor,
          shape: shape,
          shadows: boxShadow,
        ),
        child: body,
      );
    }

    body = ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: shape,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(
                  Colors.white.withValues(alpha: dark ? 0.09 : 0.45),
                  baseColor.withValues(alpha: effectiveOpacity),
                ),
                baseColor.withValues(alpha: effectiveOpacity),
              ],
            ),
          ),
          child: body,
        ),
      ),
    );

    if (boxShadow != null && boxShadow!.isNotEmpty) {
      return DecoratedBox(
        decoration: ShapeDecoration(shape: shape, shadows: boxShadow),
        child: body,
      );
    }
    return body;
  }
}

/// Rectangular frosted translucent bar for Apple Unified Titlebar / Tab Bar,
/// Sidebar (Vibrancy Source List), and iOS Keyboard Accessory Bar.
class AppleGlassBar extends StatelessWidget {
  const AppleGlassBar({
    super.key,
    required this.child,
    required this.fallbackColor,
    this.opacity,
    this.sigma = 22.0,
    this.border,
  });

  final Widget child;
  final Color fallbackColor;
  final double? opacity;
  final double sigma;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    final glass = shouldUseAppleGlass(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final effectiveOpacity = opacity ?? (dark ? 0.76 : 0.82);

    if (!glass) {
      return DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(border: border),
        child: Material(color: fallbackColor, child: child),
      );
    }

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(border: border),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(
                    Colors.white.withValues(alpha: dark ? 0.07 : 0.35),
                    fallbackColor.withValues(alpha: effectiveOpacity * 0.86),
                  ),
                  fallbackColor.withValues(alpha: effectiveOpacity * 0.92),
                ],
              ),
            ),
            child: Material(color: Colors.transparent, child: child),
          ),
        ),
      ),
    );
  }
}

/// Tactile feedback helpers aligned with Apple Human Interface Guidelines.
///
/// Haptics are strictly scoped to native `TargetPlatform.iOS` (never Web or
/// macOS) and swallow platform-channel errors so widget tests stay silent.
abstract final class AppleHaptics {
  /// Subtle selection tick for navigation switches, tabs, and segmented items.
  static void selection(BuildContext context) {
    if (kIsWeb || !context.mounted) return;
    if (Theme.of(context).platform != TargetPlatform.iOS) return;
    try {
      unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
    } on Object {
      // Ignore unavailable platform channels in headless/test environments.
    }
  }

  /// Light physical tap for primary actions such as quick-connect or import.
  static void light(BuildContext context) {
    if (kIsWeb || !context.mounted) return;
    if (Theme.of(context).platform != TargetPlatform.iOS) return;
    try {
      unawaited(HapticFeedback.lightImpact().catchError((Object _) {}));
    } on Object {
      // Ignore unavailable platform channels in headless/test environments.
    }
  }
}

/// Scroll behavior delivering native Apple elastic bounce without Android
/// edge-glow or stretch overscroll indicators, while preserving default desktop
/// pointer/trackpad drag semantics.
class AppleScrollBehavior extends MaterialScrollBehavior {
  const AppleScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    if (isApplePlatform(getPlatform(context))) {
      return const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      );
    }
    return super.getScrollPhysics(context);
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (isApplePlatform(getPlatform(context))) {
      return child;
    }
    return super.buildOverscrollIndicator(context, child, details);
  }
}
