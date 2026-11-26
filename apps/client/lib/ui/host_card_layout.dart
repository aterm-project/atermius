import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_density.dart';
import 'app_theme.dart';
import 'apple_hig.dart';
import 'surfaces.dart';

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

  /// Corner radius of a host card: a block on the window canvas.
  static double cardRadius(BuildContext context) =>
      AppDensity.of(context).radiusLg;

  /// Host card shape: an outline-free block (continuous squircle on Apple
  /// platforms). Hover and press change the fill through [overlayColor],
  /// never a stroke.
  static OutlinedBorder cardShape(BuildContext context) =>
      appBlockShape(context, cardRadius(context));

  /// Fill of a host card on the surface it sits on (the canvas on Home).
  static Color cardFill(BuildContext context) =>
      _paletteOf(context).blockFill(SurfaceScope.depthOf(context) + 1);

  /// Distance from the card's top-left corner to the icon tile: the leading
  /// padding ([leading], [padding] by default), or the top padding plus the
  /// tile's centering slack in the header row, whichever is closer.
  double iconTileInset({double? leading}) => math.min(
    leading ?? padding.left,
    padding.top + (headerHeight - iconBox) / 2,
  );

  /// Concentric radius of the icon tile in a card: the card radius minus
  /// [iconTileInset], never below the small-shape radius.
  double iconTileRadius(BuildContext context, {double? leading}) =>
      concentricRadius(
        cardRadius(context),
        iconTileInset(leading: leading),
        floor: AppDensity.of(context).radiusSm,
      );

  /// Tinted protocol/system icon tile: a fill with the card's concentric
  /// radius, no outline.
  static Decoration iconBadgeDecoration(
    BuildContext context,
    Color tint, {
    double? radius,
  }) {
    final palette = _paletteOf(context);
    return ShapeDecoration(
      color: tint.withValues(alpha: palette.isDark ? 0.16 : 0.12),
      shape: appleSquircleBorder(
        BorderRadius.circular(
          radius ?? HostCardMetrics.of(context).iconTileRadius(context),
        ),
        platform: Theme.of(context).platform,
      ),
    );
  }

  /// Hover/press/focus feedback of a host card: the fill lifts a step (focus
  /// tints it toward the accent) instead of an outline appearing.
  static WidgetStateProperty<Color?> overlayColor(BuildContext context) {
    final palette = _paletteOf(context);
    return WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) return palette.fillPressed;
      if (states.contains(WidgetState.hovered)) return palette.fill;
      if (states.contains(WidgetState.focused)) {
        return palette.accent.withValues(alpha: palette.isDark ? 0.16 : 0.12);
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
              // Rounding slack.
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

/// Interactive host card surface: an outline-free block whose fill lifts on
/// hover and press (Apple platforms drop the ripple and add the iOS
/// quick-connect haptic).
class HostCardSurface extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final apple = isAppleContext(context);
    final shape = HostCardMetrics.cardShape(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: margin,
      elevation: 0,
      color: HostCardMetrics.cardFill(context),
      surfaceTintColor: Colors.transparent,
      shape: shape,
      child: InkWell(
        key: inkWellKey,
        customBorder: shape,
        splashFactory: apple ? NoSplash.splashFactory : null,
        overlayColor: HostCardMetrics.overlayColor(context),
        onTap: HostCardMetrics.wrapConnectAction(context, onConnect),
        onSecondaryTapDown: onSecondaryTapDown,
        child: child,
      ),
    );
  }
}
