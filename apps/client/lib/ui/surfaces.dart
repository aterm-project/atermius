import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'app_density.dart';
import 'app_theme.dart';
import 'apple_hig.dart';

// Atermius surface system (2026-11-26).
//
// 1. No outlines. Areas are told apart by fill, never by a stroke: the window
//    canvas, then blocks on it, then nested blocks and controls in a block.
//    Each level is one step lighter (dark) or one step apart (light) from the
//    level it sits on; translucent control fills read on every level.
// 2. Concentric corners. A shape nested in a rounded parent takes the parent's
//    radius minus the inset between their edges, r = max(R - d, floor), so the
//    two curves share a center. The density radii are one such chain:
//    radiusDialog - blockInset = radiusLg, radiusLg - blockInset = radiusMd,
//    radiusMd - controlInset = radiusSm. A block publishes the radius its
//    content edge has through [SurfaceScope]; nested blocks and controls read
//    it instead of picking a number.
// 3. Glass for the navigation layer only: bars, sidebars, menus, dialogs and
//    floating panels. Content (lists, forms, terminals) stays on solid blocks.

/// Radius of a shape nested [inset] logical pixels inside a parent with corner
/// radius [outer]: the concentric radius, never below [floor].
double concentricRadius(double outer, double inset, {double floor = 4}) =>
    math.max(outer - inset, floor);

/// [outer] shrunk per corner by the [inset] at that corner (the smaller of the
/// two edges meeting there), never below [floor].
BorderRadius concentricBorderRadius(
  BorderRadius outer,
  EdgeInsets inset, {
  double floor = 4,
}) {
  Radius corner(Radius r, double a, double b) =>
      Radius.circular(concentricRadius(r.x, math.min(a, b), floor: floor));
  return BorderRadius.only(
    topLeft: corner(outer.topLeft, inset.left, inset.top),
    topRight: corner(outer.topRight, inset.right, inset.top),
    bottomLeft: corner(outer.bottomLeft, inset.left, inset.bottom),
    bottomRight: corner(outer.bottomRight, inset.right, inset.bottom),
  );
}

/// The block a widget sits in: how deep (0 = the window canvas) and the corner
/// radius of the block's content edge (its radius minus its padding).
class SurfaceScope extends InheritedWidget {
  const SurfaceScope({
    super.key,
    required this.depth,
    required this.innerRadius,
    required super.child,
  });

  /// 0 on the canvas, 1 inside a block (or a dialog), 2 in a nested block…
  final int depth;

  /// Radius a shape flush with the content edge takes; a shape further in
  /// subtracts its extra inset through [concentric].
  final double innerRadius;

  static SurfaceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SurfaceScope>();

  /// Nesting depth at [context]; 0 when no block encloses it.
  static int depthOf(BuildContext context) => maybeOf(context)?.depth ?? 0;

  /// Concentric radius for a shape [inset] further in than the enclosing
  /// block's content edge, or [fallback] when there is no enclosing block.
  static double concentric(
    BuildContext context, {
    double inset = 0,
    required double fallback,
    double floor = 4,
  }) {
    final scope = maybeOf(context);
    if (scope == null) return fallback;
    return concentricRadius(scope.innerRadius, inset, floor: floor);
  }

  @override
  bool updateShouldNotify(SurfaceScope oldWidget) =>
      depth != oldWidget.depth || innerRadius != oldWidget.innerRadius;
}

/// Whether translucent blurred glass is drawn. Off when the platform asks for
/// high contrast; every other case (all platforms) gets glass.
bool shouldUseGlass(BuildContext context) =>
    !(MediaQuery.maybeHighContrastOf(context) ?? false);

/// A filled, outline-free block that groups one functional area.
///
/// Its fill follows its depth (a block in a block is one level up) unless
/// [color] or [tone] say otherwise. Its radius defaults to the concentric
/// radius of the enclosing block, or [AppDensity.radiusLg] on the canvas, and
/// children see `radius - padding` through [SurfaceScope].
class AppBlock extends StatelessWidget {
  const AppBlock({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.radius,
    this.color,
    this.tone,
    this.clip = false,
    this.width,
    this.height,
    this.constraints,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// Outer corner radius; null takes the concentric one.
  final double? radius;

  /// Fill override (opaque or translucent).
  final Color? color;

  /// Tints the fill toward a status color (info, warning, error, accent).
  final Color? tone;

  /// Clips children to the rounded shape (lists whose rows paint to the edge).
  final bool clip;
  final double? width;
  final double? height;
  final BoxConstraints? constraints;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final density = AppDensity.of(context);
    final depth = SurfaceScope.depthOf(context) + 1;
    final r =
        radius ??
        SurfaceScope.concentric(
          context,
          fallback: density.radiusLg,
          floor: density.radiusMd,
        );
    final base = color ?? palette.blockFill(depth);
    final fill = tone == null ? base : palette.tinted(tone!, base: base);
    final resolvedPadding = padding?.resolve(Directionality.of(context));
    final innerInset = resolvedPadding == null
        ? 0.0
        : math.min(
            math.min(resolvedPadding.left, resolvedPadding.right),
            math.min(resolvedPadding.top, resolvedPadding.bottom),
          );
    final borderRadius = BorderRadius.circular(r);
    Widget body = SurfaceScope(
      depth: depth,
      innerRadius: concentricRadius(r, innerInset, floor: density.radiusSm),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );
    if (clip) {
      body = ClipRRect(borderRadius: borderRadius, child: body);
    }
    return Container(
      width: width,
      height: height,
      constraints: constraints,
      margin: margin,
      decoration: BoxDecoration(color: fill, borderRadius: borderRadius),
      child: body,
    );
  }
}

/// Liquid-glass recipe: blur plus a saturation lift, so whatever passes under
/// the glass keeps its color instead of turning grey.
ImageFilter appGlassFilter({double sigma = 26}) => ImageFilter.compose(
  outer: ImageFilter.blur(
    sigmaX: sigma,
    sigmaY: sigma,
    tileMode: TileMode.mirror,
  ),
  inner: const ColorFilter.matrix(<double>[
    1.36, -0.32, -0.04, 0, 0, //
    -0.09, 1.13, -0.04, 0, 0, //
    -0.09, -0.32, 1.41, 0, 0, //
    0, 0, 0, 1, 0, //
  ]),
);

/// Translucent blurred surface for the navigation layer (bars, sidebars,
/// floating panels). No outline: the edge is a light sheen across the top of
/// the fill and, when [elevated], a soft shadow. With glass off (high
/// contrast) it is a plain opaque block of [tint].
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.tint,
    this.opacity,
    this.sigma = 26,
    this.elevated = false,
    this.padding,
    this.material = true,
  });

  final Widget child;
  final BorderRadius borderRadius;

  /// Base color of the glass; the palette's rail color by default.
  final Color? tint;

  /// Opacity of [tint] over the blurred backdrop (multiplies [tint]'s own
  /// alpha, so a wallpaper-translucent tint stays more translucent).
  final double? opacity;
  final double sigma;

  /// Floating panels cast a soft shadow; bars flush with the window do not.
  final bool elevated;
  final EdgeInsetsGeometry? padding;

  /// Wraps [child] in a transparent [Material] so ink and text styles work.
  final bool material;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final dark = palette.isDark;
    final base = tint ?? palette.rail;
    final glass = shouldUseGlass(context);
    final alpha = opacity ?? (dark ? .72 : .76);
    Widget body = padding == null
        ? child
        : Padding(padding: padding!, child: child);
    if (material) {
      body = Material(type: MaterialType.transparency, child: body);
    }
    final rounded = borderRadius != BorderRadius.zero;
    final decoration = BoxDecoration(
      borderRadius: rounded ? borderRadius : null,
      color: glass ? null : base,
      gradient: glass
          ? LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color.alphaBlend(
                  Colors.white.withValues(alpha: dark ? .075 : .32),
                  base.withValues(alpha: base.a * alpha),
                ),
                base.withValues(alpha: base.a * alpha),
                base.withValues(alpha: base.a * math.min(1, alpha + .04)),
              ],
              stops: const [0, .42, 1],
            )
          : null,
    );
    body = DecoratedBox(decoration: decoration, child: body);
    if (glass) {
      body = BackdropFilter.grouped(
        filter: appGlassFilter(sigma: sigma),
        child: body,
      );
      body = rounded
          ? ClipRRect(borderRadius: borderRadius, child: body)
          : ClipRect(child: body);
    }
    if (elevated) {
      body = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: rounded ? borderRadius : null,
          boxShadow: appFloatingShadow(palette),
        ),
        child: body,
      );
    }
    return body;
  }
}

/// Soft two-layer shadow of floating surfaces (menus, popovers, sidebars).
List<BoxShadow> appFloatingShadow(AppPalette palette) => [
  BoxShadow(
    color: Colors.black.withValues(alpha: palette.isDark ? .34 : .08),
    blurRadius: 24,
    offset: const Offset(0, 8),
  ),
  BoxShadow(
    color: Colors.black.withValues(alpha: palette.isDark ? .22 : .05),
    blurRadius: 4,
    offset: const Offset(0, 1),
  ),
];

/// Faint accent glows painted on the window canvas so glass above it has
/// color to refract even without a wallpaper.
class AmbientCanvas extends StatelessWidget {
  const AmbientCanvas({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!shouldUseGlass(context)) return child;
    final palette = context.palette;
    final dark = palette.isDark;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.85, -0.9),
                radius: 1.2,
                colors: [
                  palette.accent.withValues(alpha: dark ? .16 : .08),
                  palette.accentText.withValues(alpha: dark ? .05 : .03),
                  Colors.transparent,
                ],
                stops: const [0, .45, 1],
              ),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.9, 0.85),
                  radius: 1.1,
                  colors: [
                    palette.info.withValues(alpha: dark ? .09 : .05),
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

/// Rounded block shape: a continuous squircle on Apple platforms, circular
/// corners elsewhere.
OutlinedBorder appBlockShape(BuildContext context, double radius) =>
    appleSquircleBorder(
      BorderRadius.circular(radius),
      platform: Theme.of(context).platform,
    );
