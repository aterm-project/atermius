import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

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
