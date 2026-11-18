import 'dart:math' as math;

import 'package:aterm_client/domain/vault_preference.dart';
import 'package:flutter/painting.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/terminal_color_theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('validated choices construct distinct terminal palettes', () {
    final dark = buildTerminalColorTheme(VaultTerminalThemeChoice.atermDark);
    final light = buildTerminalColorTheme(VaultTerminalThemeChoice.light);

    expect(dark.background.toARGB32(), 0xFF0F1425);
    expect(dark.foreground.toARGB32(), 0xFF21B568);
    expect(dark.cursor, dark.foreground);
    expect(dark.foreground, isNot(AppColors.accent));
    expect(dark.foreground, isNot(AppColors.accentText));
    // ANSI semantics are preserved (programs keep their colors).
    expect(dark.red.toARGB32(), 0xFFF17B82);
    expect(dark.green.toARGB32(), 0xFF5CD299);
    expect(dark.blue.toARGB32(), 0xFF77A6EC);
    expect(dark.white.toARGB32(), 0xFFD9DEE6);
    expect(light.background.toARGB32(), 0xFFF8FAFC);
    expect(light.foreground.toARGB32(), 0xFF17202D);
    expect(light.background, isNot(dark.background));
    expect(light.cursor, isNot(dark.cursor));
  });

  test('dark terminal text is legible and ANSI colors stay distinct', () {
    final dark = buildTerminalColorTheme(VaultTerminalThemeChoice.atermDark);
    double contrast(Color a, Color b) =>
        (math.max(a.computeLuminance(), b.computeLuminance()) + .05) /
        (math.min(a.computeLuminance(), b.computeLuminance()) + .05);
    final normal = [
      dark.red,
      dark.green,
      dark.yellow,
      dark.blue,
      dark.magenta,
      dark.cyan,
    ];
    final bright = [
      dark.brightRed,
      dark.brightGreen,
      dark.brightYellow,
      dark.brightBlue,
      dark.brightMagenta,
      dark.brightCyan,
    ];

    // The Termius foreground has 6.86:1 contrast on our dark background.
    expect(contrast(dark.foreground, dark.background), greaterThan(6.8));
    for (final color in [...normal, ...bright, dark.white, dark.brightBlack]) {
      expect(contrast(color, dark.background), greaterThan(4.5));
    }

    // One family: no colour is much more saturated or much lighter than the
    // others, and each bright colour is a lighter version of its normal one.
    for (final color in [...normal, ...bright]) {
      expect(_oklch(color).chroma, inInclusiveRange(.07, .15));
    }
    final lightness = normal.map((color) => _oklch(color).lightness);
    expect(
      lightness.reduce(math.max) - lightness.reduce(math.min),
      lessThan(.14),
    );
    for (var i = 0; i < normal.length; i++) {
      final base = _oklch(normal[i]), lighter = _oklch(bright[i]);
      expect(lighter.lightness, greaterThan(base.lightness + .03));
      final hueGap = (lighter.hue - base.hue).abs();
      expect(math.min(hueGap, 360 - hueGap), lessThan(12));
    }

    // ANSI green is lighter than plain text even though their hues are close.
    expect(
      _oklch(dark.green).lightness - _oklch(dark.foreground).lightness,
      greaterThan(.05),
    );
  });

  test('app theme uses the emerald-teal emphasis with legible on-colors', () {
    final scheme = buildAppTheme().colorScheme;
    expect(scheme.primary.toARGB32(), 0xFF0F7B6C);
    expect(scheme.secondary.toARGB32(), 0xFF4FD8C4);
    expect(AppColors.accentText.toARGB32(), 0xFF4FD8C4);
    double contrast(Color a, Color b) {
      final la = a.computeLuminance(), lb = b.computeLuminance();
      return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
    }

    expect(contrast(scheme.onPrimary, scheme.primary), greaterThan(4.5));
    expect(
      contrast(scheme.onPrimaryContainer, scheme.primaryContainer),
      greaterThan(4.5),
    );
    expect(contrast(scheme.onSecondary, scheme.secondary), greaterThan(4.5));
    expect(contrast(AppColors.accentText, AppColors.surface), greaterThan(4.5));
    expect(
      contrast(AppColors.accentText, AppColors.background),
      greaterThan(4.5),
    );
  });
}

/// OKLCH coordinates of [color]: perceptual lightness (0..1), chroma and hue
/// in degrees.
({double lightness, double chroma, double hue}) _oklch(Color color) {
  double linear(double c) =>
      c <= .04045 ? c / 12.92 : math.pow((c + .055) / 1.055, 2.4).toDouble();
  final r = linear(color.r), g = linear(color.g), b = linear(color.b);
  double cbrt(double v) => math.pow(v, 1 / 3).toDouble();
  final l = cbrt(.4122214708 * r + .5363325363 * g + .0514459929 * b);
  final m = cbrt(.2119034982 * r + .6806995451 * g + .1073969566 * b);
  final s = cbrt(.0883024619 * r + .2817188376 * g + .6299787005 * b);
  final lightness = .2104542553 * l + .7936177850 * m - .0040720468 * s;
  final a = 1.9779984951 * l - 2.4285922050 * m + .4505937099 * s;
  final bb = .0259040371 * l + .7827717662 * m - .8086757660 * s;
  final hue = (math.atan2(bb, a) * 180 / math.pi + 360) % 360;
  return (lightness: lightness, chroma: math.sqrt(a * a + bb * bb), hue: hue);
}
