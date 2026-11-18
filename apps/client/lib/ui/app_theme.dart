import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';

import 'app_density.dart';
import 'app_motion.dart';
import 'apple_hig.dart';

abstract final class AppColors {
  static const background = Color(0xFF0B0F10);
  static const surface = Color(0xFF12191C);
  static const surfaceRaised = Color(0xFF182226);
  static const surfaceSoft = Color(0xFF1F2C31);
  static const line = Color(0xFF28383E);
  static const text = Color(0xFFECF3F2);
  static const muted = Color(0xFF91A3A0);

  /// Obsidian-Emerald app emphasis. `accent` fills large controls (filled
  /// buttons, switches, selection borders) and always pairs with [onAccent];
  /// emerald-teal text and small glyphs on dark surfaces use [accentText] for
  /// legible WCAG AA+ contrast. Terminal text colors are owned by
  /// `terminal_color_theme.dart` and are deliberately not derived from these
  /// values.
  static const accent = Color(0xFF0F7B6C);
  static const onAccent = Color(0xFFFFFFFF);
  static const accentContainer = Color(0xFF133B36);
  static const onAccentContainer = Color(0xFFD2F7EE);
  static const accentText = Color(0xFF4FD8C4);
  static const onAccentText = Color(0xFF062924);
  static const accentSoft = Color(0xFF8BE8D9);
  // Compatibility names for existing surfaces share the emerald emphasis.
  static const lime = accentText;
  static const teal = accentSoft;
  static const orange = Color(0xFFFFB55E);
  static const red = Color(0xFFFF7379);
}

/// App color scheme: the accent and the tint of the neutral surfaces that go
/// with it. [code] is the stable persisted value; never rename it.
///
/// [emerald] is the historic Obsidian-Emerald palette, stored as constants.
/// Every other scheme is that palette moved in OKLCH: the accent family is
/// rotated by [hueShift] degrees and its chroma scaled by [accentChroma];
/// tinted neutrals take the accent's hue and [neutralChroma]. Lightness is
/// kept, so each scheme has the contrast of the emerald one (text roles stay
/// WCAG AA). Status colors (info, warning, error) are the same in all schemes.
enum AppAccent {
  emerald('emerald', 0, 1, 1),
  ocean('ocean', 72, 1.25, 1),
  violet('violet', 118, 1.3, 1),
  rose('rose', 178, 1.25, 1),
  amber('amber', -105, 1.15, 1),
  graphite('graphite', 72, .12, .5);

  const AppAccent(
    this.code,
    this.hueShift,
    this.accentChroma,
    this.neutralChroma,
  );

  final String code;
  final double hueShift;
  final double accentChroma;
  final double neutralChroma;

  static AppAccent parse(String? value) {
    final normalized = value?.trim().toLowerCase();
    for (final accent in values) {
      if (accent.code == normalized) return accent;
    }
    return emerald;
  }

  /// A neutral chrome color of the emerald palette in this scheme.
  Color neutral(Color color) =>
      this == emerald ? color : _retint(color, this, accent: false);
}

/// OKLCH hue of the emerald accent; tinted neutrals of the other schemes sit
/// on the rotated accent hue.
const _emeraldHue = 180.0;

double _srgbToLinear(double c) =>
    c <= .04045 ? c / 12.92 : math.pow((c + .055) / 1.055, 2.4).toDouble();

double _linearToSrgb(double c) =>
    c <= .0031308 ? 12.92 * c : 1.055 * math.pow(c, 1 / 2.4) - .055;

double _cbrt(double x) =>
    x < 0 ? -math.pow(-x, 1 / 3).toDouble() : math.pow(x, 1 / 3).toDouble();

/// Linear sRGB of an OKLCH color (may lie outside 0..1).
(double, double, double) _oklchToLinear(double l, double c, double hue) {
  final a = c * math.cos(hue * math.pi / 180);
  final b = c * math.sin(hue * math.pi / 180);
  final l_ = math.pow(l + .3963377774 * a + .2158037573 * b, 3).toDouble();
  final m_ = math.pow(l - .1055613458 * a - .0638541728 * b, 3).toDouble();
  final s_ = math.pow(l - .0894841775 * a - 1.2914855480 * b, 3).toDouble();
  return (
    4.0767416621 * l_ - 3.3077115913 * m_ + .2309699292 * s_,
    -1.2684380046 * l_ + 2.6097574011 * m_ - .3413193965 * s_,
    -.0041960863 * l_ - .7034186147 * m_ + 1.7076147010 * s_,
  );
}

bool _inGamut((double, double, double) rgb) {
  bool ok(double v) => v >= -1e-4 && v <= 1 + 1e-4;
  return ok(rgb.$1) && ok(rgb.$2) && ok(rgb.$3);
}

/// [color] in [scheme]: same lightness, rotated hue and scaled chroma. Colors
/// the display cannot show lose chroma only, never lightness.
Color _retint(Color color, AppAccent scheme, {required bool accent}) {
  final r = _srgbToLinear(color.r);
  final g = _srgbToLinear(color.g);
  final b = _srgbToLinear(color.b);
  final l_ = _cbrt(.4122214708 * r + .5363325363 * g + .0514459929 * b);
  final m_ = _cbrt(.2119034982 * r + .6806995451 * g + .1073969566 * b);
  final s_ = _cbrt(.0883024619 * r + .2817188376 * g + .6299787005 * b);
  final lightness = .2104542553 * l_ + .7936177850 * m_ - .0040720468 * s_;
  final ka = 1.9779984951 * l_ - 2.4285922050 * m_ + .4505937099 * s_;
  final kb = .0259040371 * l_ + .7827717662 * m_ - .8086757660 * s_;
  var chroma =
      math.sqrt(ka * ka + kb * kb) *
      (accent ? scheme.accentChroma : scheme.neutralChroma);
  final hue = accent
      ? math.atan2(kb, ka) * 180 / math.pi + scheme.hueShift
      : _emeraldHue + scheme.hueShift;
  var rgb = _oklchToLinear(lightness, chroma, hue);
  if (!_inGamut(rgb)) {
    var low = 0.0, high = chroma;
    for (var i = 0; i < 24; i++) {
      final middle = (low + high) / 2;
      if (_inGamut(_oklchToLinear(lightness, middle, hue))) {
        low = middle;
      } else {
        high = middle;
      }
    }
    chroma = low;
    rgb = _oklchToLinear(lightness, chroma, hue);
  }
  int channel(double v) =>
      (_linearToSrgb(v.clamp(0.0, 1.0)).clamp(0.0, 1.0) * 255).round();
  return Color.fromARGB(
    (color.a * 255).round(),
    channel(rgb.$1),
    channel(rgb.$2),
    channel(rgb.$3),
  );
}

/// Context-scoped UI chrome palette.
///
/// Installed by [buildAppTheme] as a [ThemeExtension]; read it with
/// `context.palette`. [AppPalette.dark] carries exactly the historic
/// [AppColors] values so the default dark theme is unchanged. Terminal text,
/// ANSI and custom terminal palettes, and remote-desktop framebuffers are
/// deliberately not derived from this palette.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceSoft,
    required this.rail,
    required this.line,
    required this.text,
    required this.muted,
    required this.hint,
    required this.accent,
    required this.onAccent,
    required this.accentContainer,
    required this.onAccentContainer,
    required this.accentText,
    required this.onAccentText,
    required this.accentSoft,
    required this.info,
    required this.hostBlue,
    required this.orange,
    required this.red,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.warningContainer,
    required this.codeBackground,
    required this.codeText,
    required this.tooltipBackground,
    required this.tooltipText,
  });

  final Brightness brightness;
  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceSoft;

  /// Navigation rail / secondary chrome behind the main canvas.
  final Color rail;
  final Color line;
  final Color text;
  final Color muted;
  final Color hint;
  final Color accent;
  final Color onAccent;
  final Color accentContainer;
  final Color onAccentContainer;
  final Color accentText;
  final Color onAccentText;
  final Color accentSoft;

  /// Informational blue for links/directories, readable on [surface].
  final Color info;

  /// Third host-avatar color.
  final Color hostBlue;
  final Color orange;
  final Color red;
  final Color errorContainer;
  final Color onErrorContainer;
  final Color warningContainer;

  /// Read-only command/script previews (not live terminal content).
  final Color codeBackground;
  final Color codeText;

  /// Tooltips are always dark with white text, in both themes.
  final Color tooltipBackground;
  final Color tooltipText;

  bool get isDark => brightness == Brightness.dark;

  // Compatibility names for existing surfaces share the blue emphasis.
  Color get lime => accentText;
  Color get teal => accentSoft;

  static const dark = AppPalette(
    brightness: Brightness.dark,
    background: AppColors.background,
    surface: AppColors.surface,
    surfaceRaised: AppColors.surfaceRaised,
    surfaceSoft: AppColors.surfaceSoft,
    rail: Color(0xFF0E1416),
    line: AppColors.line,
    text: AppColors.text,
    muted: AppColors.muted,
    hint: Color(0xFF677A77),
    accent: AppColors.accent,
    onAccent: AppColors.onAccent,
    accentContainer: AppColors.accentContainer,
    onAccentContainer: AppColors.onAccentContainer,
    accentText: AppColors.accentText,
    onAccentText: AppColors.onAccentText,
    accentSoft: AppColors.accentSoft,
    info: Color(0xFF67CBFF),
    hostBlue: Color(0xFF6AA9FF),
    orange: AppColors.orange,
    red: AppColors.red,
    errorContainer: Color(0xFF4F2224),
    onErrorContainer: Color(0xFFFFFFFF),
    warningContainer: Color(0xFF332919),
    codeBackground: Color(0xFF0A0E0F),
    codeText: Color(0xFFC9DCD9),
    tooltipBackground: Color(0xFF1C272B),
    tooltipText: Color(0xFFFFFFFF),
  );

  /// White canvas and cards, cool porcelain separators, dark readable text and
  /// the emerald-teal app accent. Text-role colors meet WCAG AA (>= 4.5:1).
  static const light = AppPalette(
    brightness: Brightness.light,
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF3F7F6),
    surfaceSoft: Color(0xFFE6EFED),
    rail: Color(0xFFF3F7F6),
    line: Color(0xFFD6E2DF),
    text: Color(0xFF14211F),
    muted: Color(0xFF516360),
    hint: Color(0xFF657875),
    accent: AppColors.accent,
    onAccent: AppColors.onAccent,
    accentContainer: Color(0xFFD4F5EC),
    onAccentContainer: Color(0xFF0A3D35),
    accentText: Color(0xFF0C6B5E),
    onAccentText: Color(0xFFFFFFFF),
    accentSoft: Color(0xFF137A6B),
    info: Color(0xFF0E6496),
    hostBlue: Color(0xFF2864B8),
    orange: Color(0xFF9E4B00),
    red: Color(0xFFBE2331),
    errorContainer: Color(0xFFFDE8EA),
    onErrorContainer: Color(0xFF75151E),
    warningContainer: Color(0xFFFFF4E0),
    codeBackground: Color(0xFFF3F7F6),
    codeText: Color(0xFF1E302D),
    tooltipBackground: Color(0xFF1A2524),
    tooltipText: Color(0xFFFFFFFF),
  );

  static final _schemes = <(AppAccent, Brightness), AppPalette>{};

  /// The palette of [accent] for [brightness]; the constants for emerald.
  static AppPalette resolve(AppAccent accent, Brightness brightness) {
    final base = brightness == Brightness.dark ? dark : light;
    if (accent == AppAccent.emerald) return base;
    return _schemes[(accent, brightness)] ??= base._in(accent);
  }

  AppPalette _in(AppAccent scheme) {
    Color neutral(Color color) => _retint(color, scheme, accent: false);
    Color emphasis(Color color) => _retint(color, scheme, accent: true);
    return AppPalette(
      brightness: brightness,
      background: neutral(background),
      surface: neutral(surface),
      surfaceRaised: neutral(surfaceRaised),
      surfaceSoft: neutral(surfaceSoft),
      rail: neutral(rail),
      line: neutral(line),
      text: neutral(text),
      muted: neutral(muted),
      hint: neutral(hint),
      accent: emphasis(accent),
      onAccent: onAccent,
      accentContainer: emphasis(accentContainer),
      onAccentContainer: emphasis(onAccentContainer),
      accentText: emphasis(accentText),
      onAccentText: emphasis(onAccentText),
      accentSoft: emphasis(accentSoft),
      info: info,
      hostBlue: hostBlue,
      orange: orange,
      red: red,
      errorContainer: errorContainer,
      onErrorContainer: onErrorContainer,
      warningContainer: warningContainer,
      codeBackground: neutral(codeBackground),
      codeText: neutral(codeText),
      tooltipBackground: neutral(tooltipBackground),
      tooltipText: tooltipText,
    );
  }

  static AppPalette of(BuildContext context) =>
      Theme.of(context).extension<AppPalette>() ?? dark;

  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(covariant AppPalette? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      brightness: t < .5 ? brightness : other.brightness,
      background: c(background, other.background),
      surface: c(surface, other.surface),
      surfaceRaised: c(surfaceRaised, other.surfaceRaised),
      surfaceSoft: c(surfaceSoft, other.surfaceSoft),
      rail: c(rail, other.rail),
      line: c(line, other.line),
      text: c(text, other.text),
      muted: c(muted, other.muted),
      hint: c(hint, other.hint),
      accent: c(accent, other.accent),
      onAccent: c(onAccent, other.onAccent),
      accentContainer: c(accentContainer, other.accentContainer),
      onAccentContainer: c(onAccentContainer, other.onAccentContainer),
      accentText: c(accentText, other.accentText),
      onAccentText: c(onAccentText, other.onAccentText),
      accentSoft: c(accentSoft, other.accentSoft),
      info: c(info, other.info),
      hostBlue: c(hostBlue, other.hostBlue),
      orange: c(orange, other.orange),
      red: c(red, other.red),
      errorContainer: c(errorContainer, other.errorContainer),
      onErrorContainer: c(onErrorContainer, other.onErrorContainer),
      warningContainer: c(warningContainer, other.warningContainer),
      codeBackground: c(codeBackground, other.codeBackground),
      codeText: c(codeText, other.codeText),
      tooltipBackground: c(tooltipBackground, other.tooltipBackground),
      tooltipText: c(tooltipText, other.tooltipText),
    );
  }
}

extension AppPaletteContext on BuildContext {
  /// UI chrome palette of the nearest [Theme] (dark when none is installed).
  ///
  /// Unmounted contexts (late async callbacks) get the dark palette instead of
  /// an ancestor-lookup assertion; callers should still check `mounted`.
  AppPalette get palette => mounted ? AppPalette.of(this) : AppPalette.dark;
}

/// UI font fallbacks per display language. They only apply to glyphs the
/// platform UI font lacks, so Han characters use the regional glyph forms of
/// the selected language (Japanese vs Simplified Chinese) and Cyrillic uses a
/// full-coverage face. Explicit monospace styles (terminal, fingerprints,
/// framebuffer overlays) keep their own families.
List<String> appFontFallback(Locale? locale) => switch (locale?.languageCode) {
  'ja' => const [
    'Hiragino Sans',
    'Yu Gothic UI',
    'Meiryo UI',
    'Noto Sans CJK JP',
    'Noto Sans JP',
    'Microsoft YaHei UI',
  ],
  'zh' => const [
    'PingFang SC',
    'Hiragino Sans GB',
    'Microsoft YaHei UI',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Yu Gothic UI',
  ],
  _ => const [
    '.AppleSystemUIFont',
    'SF Pro Text',
    'Segoe UI',
    'Roboto',
    'Noto Sans',
    'PingFang SC',
    'Microsoft YaHei UI',
  ],
};

/// Builds the app theme. The default (no [brightness]) is the historic dark
/// theme; [Brightness.light] builds the white/light UI chrome theme. Both
/// share the R7 density, motion and font fallbacks. [accent] picks the color
/// scheme (emerald by default).
ThemeData buildAppTheme({
  Locale? locale,
  TargetPlatform? platform,
  Brightness brightness = Brightness.dark,
  AppAccent accent = AppAccent.emerald,
}) {
  final dark = brightness == Brightness.dark;
  final p = AppPalette.resolve(accent, brightness);
  final effectivePlatform = platform ?? defaultTargetPlatform;
  final apple = isApplePlatform(effectivePlatform);
  // Browser controls share the Windows colors, including on Apple devices.
  final nativeAppleColors = apple && !kIsWeb;
  final base = dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);
  final fallback = appFontFallback(locale);
  // R7 density: shared compact (desktop) / touch proportions. Sizes only;
  // never a transform or a text-scale override.
  final density = AppDensity.forPlatform(effectivePlatform);
  final textTheme = density.applyTextSizes(base.textTheme);
  final radiusSm = BorderRadius.circular(density.radiusSm);
  final radiusMd = BorderRadius.circular(density.radiusMd);
  final radiusLg = BorderRadius.circular(density.radiusLg);
  final menuShadowColor = Colors.black.withValues(alpha: dark ? 0.45 : 0.14);
  return base.copyWith(
    platform: effectivePlatform,
    splashFactory: apple ? NoSplash.splashFactory : null,
    splashColor: nativeAppleColors ? Colors.transparent : null,
    highlightColor: nativeAppleColors ? p.text.withValues(alpha: dark ? 0.07 : 0.05) : null,
    hoverColor: nativeAppleColors ? p.text.withValues(alpha: dark ? 0.04 : 0.03) : null,
    extensions: <ThemeExtension<dynamic>>[density, p],
    pageTransitionsTheme: appPageTransitionsTheme,
    scaffoldBackgroundColor: p.background,
    canvasColor: dark ? base.canvasColor : p.surface,
    colorScheme: dark
        ? ColorScheme.dark(
            primary: p.accent,
            onPrimary: p.onAccent,
            primaryContainer: p.accentContainer,
            onPrimaryContainer: p.onAccentContainer,
            secondary: p.accentText,
            onSecondary: p.onAccentText,
            secondaryContainer: p.accentContainer,
            onSecondaryContainer: p.onAccentContainer,
            tertiary: p.accentSoft,
            onTertiary: p.onAccentText,
            inversePrimary: p.accentText,
            surfaceTint: Colors.transparent,
            surface: p.surface,
            error: p.red,
          )
        : ColorScheme.light(
            primary: p.accent,
            onPrimary: p.onAccent,
            primaryContainer: p.accentContainer,
            onPrimaryContainer: p.onAccentContainer,
            secondary: p.accentText,
            onSecondary: p.onAccentText,
            secondaryContainer: p.accentContainer,
            onSecondaryContainer: p.onAccentContainer,
            tertiary: p.accentSoft,
            onTertiary: p.onAccentText,
            inversePrimary: AppPalette.resolve(
              accent,
              Brightness.dark,
            ).accentText,
            surfaceTint: Colors.transparent,
            surface: p.surface,
            onSurface: p.text,
            onSurfaceVariant: p.muted,
            surfaceContainerLowest: p.surface,
            surfaceContainerLow: p.surface,
            surfaceContainer: p.surface,
            surfaceContainerHigh: p.surfaceRaised,
            surfaceContainerHighest: p.surfaceSoft,
            outline: accent.neutral(const Color(0xFF809490)),
            outlineVariant: p.line,
            inverseSurface: p.tooltipBackground,
            onInverseSurface: p.tooltipText,
            error: p.red,
            errorContainer: p.errorContainer,
            onErrorContainer: p.onErrorContainer,
          ),
    textTheme: textTheme.apply(
      bodyColor: p.text,
      displayColor: p.text,
      fontFamilyFallback: fallback,
    ),
    primaryTextTheme: density
        .applyTextSizes(base.primaryTextTheme)
        .apply(fontFamilyFallback: fallback),
    iconTheme: base.iconTheme.copyWith(size: density.iconDefault),
    primaryIconTheme: base.primaryIconTheme.copyWith(size: density.iconDefault),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(iconSize: density.iconDefault),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: density.listTilePadding,
      horizontalTitleGap: density.space5,
      minLeadingWidth: density.iconLg,
    ),
    dividerColor: p.line,
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: p.surfaceRaised,
      selectedColor: p.accentContainer,
      labelStyle: TextStyle(color: p.text),
      secondaryLabelStyle: TextStyle(color: p.onAccentContainer),
      checkmarkColor: p.onAccentContainer,
      side: BorderSide(color: p.line),
      shape: appleSquircleBorder(radiusSm, platform: effectivePlatform),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accentText,
        padding: EdgeInsets.symmetric(horizontal: density.space5),
        shape: appleSquircleBorder(radiusMd, platform: effectivePlatform),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.accentText,
        side: BorderSide(color: p.line),
        padding: EdgeInsets.symmetric(horizontal: density.space6),
        shape: appleSquircleBorder(radiusMd, platform: effectivePlatform),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: EdgeInsets.symmetric(horizontal: density.space6),
        shape: appleSquircleBorder(radiusMd, platform: effectivePlatform),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: density.isCompact
            ? VisualDensity.compact
            : VisualDensity.standard,
        side: WidgetStatePropertyAll(BorderSide(color: p.line)),
        shape: WidgetStatePropertyAll(
          appleSquircleBorder(radiusMd, platform: effectivePlatform),
        ),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      radius: const Radius.circular(999),
      thickness: const _HoverScrollbarThickness(),
      thumbColor: _HoverScrollbarThumbColor(p.muted),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: p.accentText,
        shape: apple
            ? appleSquircleBorder(radiusMd, platform: effectivePlatform)
            : null,
      ),
    ),
    switchTheme: nativeAppleColors
        ? SwitchThemeData(
            trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
            trackOutlineWidth: const WidgetStatePropertyAll(0),
            trackColor: _AppleSwitchTrackColor(
              accent: p.accent,
              surfaceSoft: p.surfaceSoft,
            ),
            thumbColor: _AppleSwitchThumbColor(dark: dark),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            splashRadius: 0,
          )
        : null,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accentText,
      selectionColor: p.accent.withValues(alpha: .45),
      selectionHandleColor: p.accentText,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.accentText,
      indicatorColor: p.accentText,
      unselectedLabelColor: p.muted,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: apple ? 10 : 6,
      shadowColor: menuShadowColor,
      shape: appleSquircleBorder(
        radiusMd,
        platform: effectivePlatform,
        side: BorderSide(
          color: nativeAppleColors ? p.line.withValues(alpha: dark ? 0.85 : 0.75) : p.line,
        ),
      ),
      menuPadding: EdgeInsets.symmetric(vertical: density.space2),
      labelTextStyle: _PopupMenuLabelTextStyle(
        fontSize: density.textSize(density.isCompact ? 12 : 13),
        enabledColor: p.text,
        disabledColor: p.muted.withValues(alpha: .5),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: nativeAppleColors
            ? WidgetStatePropertyAll(p.surfaceRaised)
            : null,
        surfaceTintColor: nativeAppleColors
            ? const WidgetStatePropertyAll(Colors.transparent)
            : null,
        elevation: apple ? const WidgetStatePropertyAll(10) : null,
        shadowColor: nativeAppleColors ? WidgetStatePropertyAll(menuShadowColor) : null,
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: 4),
        ),
        shape: WidgetStatePropertyAll(
          appleSquircleBorder(
            radiusMd,
            platform: effectivePlatform,
            side: BorderSide(
              color: nativeAppleColors
                  ? p.line.withValues(alpha: dark ? 0.85 : 0.75)
                  : p.line,
            ),
          ),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        minimumSize: WidgetStatePropertyAll(Size(0, density.menuItemHeight)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        ),
        textStyle: WidgetStatePropertyAll(
          TextStyle(
            fontSize: density.textSize(density.isCompact ? 12 : 13),
            height: 1.3,
          ),
        ),
        iconSize: WidgetStatePropertyAll(density.menuIconSize),
        visualDensity: VisualDensity.standard,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceRaised,
      contentPadding: density.inputPadding,
      // Compact desktop drops the 48px minimum field height (pointer input);
      // touch keeps it so fields stay >= 48dp hit targets.
      isDense: density.isCompact,
      // Helper/error copy wraps instead of ellipsizing at large text scales
      // or in narrower compact panels.
      helperMaxLines: 3,
      errorMaxLines: 3,
      prefixIconConstraints: density.isCompact
          ? const BoxConstraints(minWidth: 40, minHeight: 36)
          : null,
      suffixIconConstraints: density.isCompact
          ? const BoxConstraints(minWidth: 40, minHeight: 36)
          : null,
      border: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(
          color: nativeAppleColors ? p.line.withValues(alpha: dark ? 0.72 : 0.85) : p.line,
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(
          color: nativeAppleColors ? p.line.withValues(alpha: dark ? 0.72 : 0.85) : p.line,
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radiusMd,
        borderSide: BorderSide(
          color: nativeAppleColors ? p.lime.withValues(alpha: dark ? 0.65 : 0.55) : p.lime,
          width: apple ? 1.0 : 1.4,
        ),
      ),
      labelStyle: TextStyle(color: p.muted),
      hintStyle: TextStyle(color: p.hint),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.surfaceSoft,
      contentTextStyle: TextStyle(color: p.text),
      behavior: SnackBarBehavior.floating,
      shape: apple
          ? appleSquircleBorder(
              radiusMd,
              platform: effectivePlatform,
              side: BorderSide(color: p.line),
            )
          : null,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: nativeAppleColors
          ? p.surface.withValues(alpha: dark ? 0.76 : 0.84)
          : p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: apple ? 18 : 12,
      shape: appleSquircleBorder(
        BorderRadius.circular(density.radiusDialog),
        platform: effectivePlatform,
        side: BorderSide(
          color: nativeAppleColors
              ? (dark
                    ? Colors.white.withValues(alpha: 0.16)
                    : Colors.black.withValues(alpha: 0.09))
              : p.line,
        ),
      ),
      insetPadding: EdgeInsets.symmetric(
        horizontal: density.dialogInset,
        vertical: 24,
      ),
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: p.text,
        fontWeight: FontWeight.w600,
        fontFamilyFallback: fallback,
      ),
      actionsPadding: EdgeInsets.fromLTRB(
        density.dialogPadding.left,
        0,
        density.dialogPadding.right,
        density.dialogPadding.bottom,
      ),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: appleSquircleBorder(
        radiusLg,
        platform: effectivePlatform,
        side: BorderSide(color: p.line),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: p.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.text,
      elevation: 0,
    ),
    // Tooltips stay dark in both themes, so their text is explicitly white
    // (Material's dark-theme default text would be black on this surface).
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.tooltipBackground,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
      ),
      textStyle: TextStyle(
        color: p.tooltipText,
        fontSize: density.isCompact ? 12 : 13,
        height: 1.3,
        fontFamilyFallback: fallback,
      ),
    ),
  );
}

@immutable
class _HoverScrollbarThickness implements WidgetStateProperty<double?> {
  const _HoverScrollbarThickness();

  @override
  double resolve(Set<WidgetState> states) =>
      states.contains(WidgetState.hovered) ? 7.0 : 5.0;

  @override
  bool operator ==(Object other) => other is _HoverScrollbarThickness;

  @override
  int get hashCode => (runtimeType).hashCode;
}

@immutable
class _HoverScrollbarThumbColor implements WidgetStateProperty<Color?> {
  const _HoverScrollbarThumbColor(this.muted);

  final Color muted;

  @override
  Color resolve(Set<WidgetState> states) =>
      muted.withValues(alpha: states.contains(WidgetState.hovered) ? .55 : .30);

  @override
  bool operator ==(Object other) =>
      other is _HoverScrollbarThumbColor && other.muted == muted;

  @override
  int get hashCode => Object.hash(runtimeType, muted);
}

@immutable
class _AppleSwitchTrackColor implements WidgetStateProperty<Color?> {
  const _AppleSwitchTrackColor({
    required this.accent,
    required this.surfaceSoft,
  });

  final Color accent;
  final Color surfaceSoft;

  @override
  Color resolve(Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) {
      return surfaceSoft.withValues(alpha: 0.5);
    }
    return states.contains(WidgetState.selected) ? accent : surfaceSoft;
  }

  @override
  bool operator ==(Object other) =>
      other is _AppleSwitchTrackColor &&
      other.accent == accent &&
      other.surfaceSoft == surfaceSoft;

  @override
  int get hashCode => Object.hash(runtimeType, accent, surfaceSoft);
}

@immutable
class _AppleSwitchThumbColor implements WidgetStateProperty<Color?> {
  const _AppleSwitchThumbColor({required this.dark});

  final bool dark;

  @override
  Color resolve(Set<WidgetState> states) {
    final thumb = states.contains(WidgetState.selected)
        ? Colors.white
        : (dark ? const Color(0xFFD5E2E0) : Colors.white);
    return states.contains(WidgetState.disabled)
        ? thumb.withValues(alpha: 0.6)
        : thumb;
  }

  @override
  bool operator ==(Object other) =>
      other is _AppleSwitchThumbColor && other.dark == dark;

  @override
  int get hashCode => Object.hash(runtimeType, dark);
}

@immutable
class _PopupMenuLabelTextStyle implements WidgetStateProperty<TextStyle?> {
  const _PopupMenuLabelTextStyle({
    required this.fontSize,
    required this.enabledColor,
    required this.disabledColor,
  });

  final double fontSize;
  final Color enabledColor;
  final Color disabledColor;

  @override
  TextStyle resolve(Set<WidgetState> states) => TextStyle(
    fontSize: fontSize,
    height: 1.3,
    color: states.contains(WidgetState.disabled) ? disabledColor : enabledColor,
  );

  @override
  bool operator ==(Object other) =>
      other is _PopupMenuLabelTextStyle &&
      other.fontSize == fontSize &&
      other.enabledColor == enabledColor &&
      other.disabledColor == disabledColor;

  @override
  int get hashCode =>
      Object.hash(runtimeType, fontSize, enabledColor, disabledColor);
}
