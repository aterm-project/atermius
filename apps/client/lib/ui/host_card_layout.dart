import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_density.dart';
import 'app_theme.dart';
import 'apple_hig.dart';

/// Shared density rules for Home host cards (cloud and local profile).
///
/// Line boxes are pinned with forced struts, so a CJK/Cyrillic fallback font
/// cannot grow a line past the height the grid reserved for it. The grid
/// extent is then derived from those struts and the user's text scale rather
/// than a fixed pixel height, and nothing is clipped at large text sizes.
@immutable
class HostCardMetrics {
  const HostCardMetrics._({
    required this.textScale,
    required this.touch,
    required this.textNudge,
  });

  factory HostCardMetrics.of(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final platform = Theme.of(context).platform;
    return HostCardMetrics.resolve(
      textScale: scaler.scale(titleSize) / titleSize,
      textNudge: AppDensity.of(context).textSize(0),
      touch:
          platform == TargetPlatform.android || platform == TargetPlatform.iOS,
    );
  }

  factory HostCardMetrics.resolve({
    required double textScale,
    required bool touch,
    double textNudge = 0,
  }) => HostCardMetrics._(
    textScale: textScale.isFinite && textScale > 0 ? textScale : 1,
    touch: touch,
    textNudge: textNudge,
  );

  static const titleSize = 13.0;
  static const subtitleSize = 11.0;
  static const metaSize = 10.5;
  static const lineHeight = 1.3;
  static const iconSize = 20.0;
  static const iconPadding = 4.0;
  static const metaIconSize = 14.0;
  static const metaGap = 3.0;
  static const titleGap = 1.0;
  static const padding = EdgeInsets.symmetric(horizontal: 10, vertical: 6);

  /// Smallest comfortable tile width at text scale 1.
  static const minTileWidth = 220.0;
  static const maxTileWidth = 300.0;
  static const spacing = 8.0;

  /// Outer corner radius for host cards across desktop and touch surfaces.
  static const cardBorderRadius = BorderRadius.all(Radius.circular(12));

  /// Soft continuous-squircle radius for protocol/OS badges on Apple platforms.
  static const appleBadgeBorderRadius = BorderRadius.all(Radius.circular(8));

  /// Standard circular corner radius for protocol/OS badges on non-Apple platforms.
  static const standardBadgeBorderRadius = BorderRadius.all(Radius.circular(6));

  static const titleStrut = StrutStyle(
    fontSize: titleSize,
    height: lineHeight,
    forceStrutHeight: true,
  );
  static const subtitleStrut = StrutStyle(
    fontSize: subtitleSize,
    height: lineHeight,
    forceStrutHeight: true,
  );
  static const metaStrut = StrutStyle(
    fontSize: metaSize,
    height: lineHeight,
    forceStrutHeight: true,
  );

  static AppPalette _paletteOf(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<AppPalette>() ?? AppPalette.fallback(theme.brightness);
  }

  /// Resolves the host card outline border: a continuous-curvature squircle
  /// with a crisp Retina hairline stroke and subtle hover/press luminance on
  /// Apple platforms, or a standard rounded rectangle elsewhere.
  static OutlinedBorder cardShape(
    BuildContext context, {
    bool hovered = false,
    bool pressed = false,
  }) {
    final platform = Theme.of(context).platform;
    final palette = _paletteOf(context);
    if (isAppleContext(context)) {
      final hairline = appleHairlineWidth(context);
      final borderColor = pressed
          ? palette.lime.withValues(alpha: palette.isDark ? 0.42 : 0.36)
          : hovered
          ? palette.line.withValues(alpha: palette.isDark ? 0.96 : 0.92)
          : palette.line.withValues(alpha: palette.isDark ? 0.80 : 0.86);
      return appleSquircleBorder(
        BorderRadius.circular(12),
        platform: platform,
        side: BorderSide(
          color: borderColor,
          width: hovered || pressed ? math.max(hairline, 0.75) : hairline,
        ),
      );
    }
    return RoundedRectangleBorder(
      borderRadius: cardBorderRadius,
      side: BorderSide(
        color: hovered ? palette.lime.withValues(alpha: 0.35) : palette.line,
      ),
    );
  }

  /// Builds the tinted protocol/system icon badge decoration using an 8pt
  /// continuous-curvature squircle on Apple platforms and a 6px rounded box
  /// on other platforms.
  static Decoration iconBadgeDecoration(BuildContext context, Color tint) {
    if (isAppleContext(context)) {
      final palette = _paletteOf(context);
      return ShapeDecoration(
        color: tint.withValues(alpha: palette.isDark ? 0.15 : 0.12),
        shape: appleSquircleBorder(
          appleBadgeBorderRadius,
          platform: Theme.of(context).platform,
          side: BorderSide(
            color: tint.withValues(alpha: palette.isDark ? 0.24 : 0.18),
            width: appleHairlineWidth(context),
          ),
        ),
      );
    }
    return BoxDecoration(
      color: tint.withValues(alpha: 0.12),
      borderRadius: standardBadgeBorderRadius,
    );
  }

  /// Ripple-free subtle highlight/hover overlay property for Apple host cards.
  static WidgetStateProperty<Color?> overlayColor(BuildContext context) {
    final palette = _paletteOf(context);
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return palette.text.withValues(alpha: palette.isDark ? 0.08 : 0.06);
      }
      if (states.contains(WidgetState.hovered)) {
        return palette.text.withValues(alpha: palette.isDark ? 0.045 : 0.03);
      }
      if (states.contains(WidgetState.focused)) {
        return palette.lime.withValues(alpha: palette.isDark ? 0.10 : 0.08);
      }
      return Colors.transparent;
    });
  }

  /// Wraps a primary host quick-connect callback with light iOS haptic impact.
  static VoidCallback? wrapConnectAction(
    BuildContext context,
    VoidCallback? onConnect,
  ) {
    if (onConnect == null) return null;
    return () {
      AppleHaptics.light(context);
      onConnect();
    };
  }

  StrutStyle _strut(double size) => StrutStyle(
    fontSize: size,
    height: lineHeight,
    forceStrutHeight: true,
  );

  final double textScale;
  final double textNudge;
  double get titleTextSize => titleSize + textNudge;
  double get subtitleTextSize => subtitleSize + textNudge;
  double get metaTextSize => metaSize + textNudge;
  double get glyphSize => iconSize + textNudge;
  StrutStyle get titleTextStrut => _strut(titleTextSize);
  StrutStyle get subtitleTextStrut =>
      _strut(subtitleTextSize);
  StrutStyle get metaTextStrut => _strut(metaTextSize);

  /// Touch platforms (Android/iOS) use a real 48x48 trailing hit box; pointer
  /// platforms use 28. Visible glyphs stay 17-18 px either way.
  final bool touch;

  /// Actual laid-out size of the favorite/overflow buttons (= hit area).
  double get buttonExtent => touch ? 48 : 28 + textNudge * 2;

  /// The button box itself is the hit area, so Material must not add or cap
  /// padding around it.
  MaterialTapTargetSize get tapTargetSize => MaterialTapTargetSize.shrinkWrap;
  double get iconBox => glyphSize + iconPadding * 2;

  double _line(double size) => size * textScale * lineHeight;

  double get headerHeight => [
    iconBox,
    buttonExtent,
    _line(titleTextSize) + titleGap + _line(subtitleTextSize),
  ].reduce(math.max);

  double get metaHeight => math.max(metaIconSize, _line(metaTextSize));

  /// Card height; [withMeta] adds the group/tags/route row.
  double extent({required bool withMeta}) =>
      (padding.vertical +
              headerHeight +
              (withMeta ? metaGap + metaHeight : 0) +
              // Card outline and rounding slack.
              2)
          .ceilToDouble();

  /// Responsive column count: tiles widen with text scale so long German,
  /// Russian or Japanese labels keep their ellipsis budget.
  int columnsFor(double width) {
    final scale = textScale.clamp(1.0, 1.6);
    final minWidth = minTileWidth * scale;
    final count = ((width + spacing) / (minWidth + spacing)).floor();
    return math.max(1, count);
  }

  SliverGridDelegate gridDelegate(double width, {bool withMeta = true}) =>
      SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columnsFor(width),
        mainAxisExtent: extent(withMeta: withMeta),
        crossAxisSpacing: spacing,
        mainAxisSpacing: spacing,
      );
}

/// Soft squircle badge container for a host card's protocol or OS glyph.
class HostCardIconBadge extends StatelessWidget {
  const HostCardIconBadge({
    required this.tint,
    required this.child,
    this.padding = const EdgeInsets.all(HostCardMetrics.iconPadding),
    super.key,
  });

  final Color tint;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: HostCardMetrics.iconBadgeDecoration(context, tint),
    child: Padding(padding: padding, child: child),
  );
}

/// Interactive host card surface applying Apple continuous-curvature squircle
/// geometry, Retina hairline borders, subtle hover/press sheen, and iOS
/// quick-connect haptics.
class HostCardSurface extends StatefulWidget {
  const HostCardSurface({
    required this.child,
    this.onConnect,
    this.onSecondaryTapDown,
    this.inkWellKey,
    this.margin = EdgeInsets.zero,
    super.key,
  });

  final Widget child;
  final VoidCallback? onConnect;
  final GestureTapDownCallback? onSecondaryTapDown;
  final Key? inkWellKey;
  final EdgeInsetsGeometry margin;

  @override
  State<HostCardSurface> createState() => _HostCardSurfaceState();
}

class _HostCardSurfaceState extends State<HostCardSurface> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final apple = isAppleContext(context);
    final shape = HostCardMetrics.cardShape(
      context,
      hovered: _hovered,
      pressed: _pressed,
    );
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: widget.margin,
      elevation: apple ? 0 : null,
      surfaceTintColor: apple ? Colors.transparent : null,
      shape: apple ? shape : null,
      child: InkWell(
        key: widget.inkWellKey,
        customBorder: apple ? shape : null,
        splashFactory: apple ? NoSplash.splashFactory : null,
        overlayColor: apple ? HostCardMetrics.overlayColor(context) : null,
        onHover: apple
            ? (value) {
                if (_hovered != value) setState(() => _hovered = value);
              }
            : null,
        onHighlightChanged: apple
            ? (value) {
                if (_pressed != value) setState(() => _pressed = value);
              }
            : null,
        onTap: HostCardMetrics.wrapConnectAction(context, widget.onConnect),
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: widget.child,
      ),
    );
  }
}
