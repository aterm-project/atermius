import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/app_theme_store.dart';
import 'package:aterm_client/ui/app_density.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/app_theme_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + .05) / (lo + .05);
}

void main() {
  group('buildAppTheme', () {
    test('default callers get the dark ocean theme', () {
      expect(defaultAppAccent, AppAccent.ocean);
      final theme = buildAppTheme();
      final ocean = AppPalette.resolve(AppAccent.ocean, Brightness.dark);
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0C0E11));
      expect(theme.scaffoldBackgroundColor, ocean.background);
      expect(theme.colorScheme.primary, ocean.accent);
      expect(theme.colorScheme.surface, ocean.surface);
      expect(theme.extension<AppPalette>(), same(ocean));
      expect(AppPalette.fallback(), same(ocean));
      // R7 density stays installed.
      expect(theme.extension<AppDensity>(), isNotNull);
    });

    test('the emerald scheme keeps the historic dark theme', () {
      final theme = buildAppTheme(accent: AppAccent.emerald);
      expect(theme.scaffoldBackgroundColor, AppColors.background);
      expect(theme.colorScheme.primary, AppColors.accent);
      expect(theme.colorScheme.surface, AppColors.surface);
      expect(theme.extension<AppPalette>(), same(AppPalette.dark));
    });

    test('light theme: white canvas, same accent, readable text roles', () {
      final theme = buildAppTheme(brightness: Brightness.light);
      final p = theme.extension<AppPalette>()!;
      expect(theme.brightness, Brightness.light);
      expect(p, same(AppPalette.resolve(defaultAppAccent, Brightness.light)));
      expect(theme.scaffoldBackgroundColor, const Color(0xFFFFFFFF));
      expect(theme.cardTheme.color, const Color(0xFFFFFFFF));
      expect(
        theme.colorScheme.primary,
        AppPalette.resolve(defaultAppAccent, Brightness.dark).accent,
      );
      for (final role in [p.text, p.muted, p.accentText, p.orange, p.red]) {
        expect(_contrast(role, p.surface), greaterThanOrEqualTo(4.5));
        expect(_contrast(role, p.surfaceRaised), greaterThanOrEqualTo(4.5));
      }
      expect(_contrast(p.onAccent, p.accent), greaterThanOrEqualTo(4.5));
      expect(_contrast(p.onErrorContainer, p.errorContainer), greaterThan(7));
    });

    for (final brightness in Brightness.values) {
      test('$brightness tooltips are dark with explicit white text', () {
        final tooltip = buildAppTheme(brightness: brightness).tooltipTheme;
        final background = (tooltip.decoration! as BoxDecoration).color!;
        final text = tooltip.textStyle!.color!;
        expect(text, const Color(0xFFFFFFFF));
        expect(background.computeLuminance(), lessThan(.05));
        expect(_contrast(text, background), greaterThanOrEqualTo(7));
      });
    }
  });

  group('color schemes', () {
    test('emerald is the historic palette, unchanged', () {
      expect(
        AppPalette.resolve(AppAccent.emerald, Brightness.dark),
        same(AppPalette.dark),
      );
      expect(
        AppPalette.resolve(AppAccent.emerald, Brightness.light),
        same(AppPalette.light),
      );
      expect(AppAccent.emerald.neutral(AppColors.line), AppColors.line);
    });

    for (final accent in AppAccent.values) {
      for (final brightness in Brightness.values) {
        test('${accent.code} ${brightness.name} keeps readable text roles', () {
          final theme = buildAppTheme(brightness: brightness, accent: accent);
          final p = theme.extension<AppPalette>()!;
          expect(p, same(AppPalette.resolve(accent, brightness)));
          expect(theme.colorScheme.primary, p.accent);
          expect(theme.colorScheme.secondary, p.accentText);
          expect(theme.scaffoldBackgroundColor, p.background);
          for (final surface in [p.background, p.surface, p.surfaceRaised]) {
            for (final role in [p.text, p.muted, p.accentText, p.accentSoft]) {
              expect(_contrast(role, surface), greaterThanOrEqualTo(4.5));
            }
          }
          expect(_contrast(p.onAccent, p.accent), greaterThanOrEqualTo(4.5));
          expect(
            _contrast(p.onAccentContainer, p.accentContainer),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            _contrast(p.onAccentText, p.accentText),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            _contrast(p.codeText, p.codeBackground),
            greaterThanOrEqualTo(7),
          );
          // Status colors are the same in every scheme.
          final base = brightness == Brightness.dark
              ? AppPalette.dark
              : AppPalette.light;
          expect([p.red, p.orange, p.info], [base.red, base.orange, base.info]);
          expect(p.brightness, brightness);
        });
      }
    }

    test('schemes differ visibly from each other', () {
      final accents = {
        for (final accent in AppAccent.values)
          AppPalette.resolve(accent, Brightness.dark).accent,
      };
      expect(accents, hasLength(AppAccent.values.length));
      // Hue moves, lightness stays: every fill is about as bright as emerald.
      final reference = AppColors.accent.computeLuminance();
      for (final color in accents) {
        expect(color.computeLuminance(), closeTo(reference, .06));
      }
    });
  });

  group('AppThemeController', () {
    test('missing, invalid and failing reads keep the dark default', () async {
      for (final stored in [null, '', 'neon', 'x' * 40]) {
        final controller = AppThemeController();
        await controller.load(MemoryAppThemeStore(stored));
        expect(controller.preference, AppThemePreference.dark);
        expect(controller.themeMode, ThemeMode.dark);
        expect(controller.accent, AppAccent.ocean);
      }
    });

    test('restores and persists explicit choices', () async {
      final store = MemoryAppThemeStore('light');
      final controller = AppThemeController();
      await controller.load(store);
      expect(controller.themeMode, ThemeMode.light);
      await controller.setPreference(AppThemePreference.system);
      expect(controller.themeMode, ThemeMode.system);
      expect(store.value, 'system:ocean');
      expect(controller.writeFailed, isFalse);
    });

    test(
      'the color scheme is stored after the theme, ocean by default',
      () async {
        // A bare theme code (what versions with the emerald default wrote)
        // now means the default scheme.
        final store = MemoryAppThemeStore('light');
        final controller = AppThemeController();
        await controller.load(store);
        expect(controller.accent, AppAccent.ocean);
        await controller.setAccent(AppAccent.violet);
        expect(controller.accent, AppAccent.violet);
        expect(controller.themeMode, ThemeMode.light);
        expect(store.value, 'light:violet');
        await controller.setPreference(AppThemePreference.system);
        expect(store.value, 'system:violet');
        for (final accent in AppAccent.values) {
          expect(
            encodeAppTheme(AppThemePreference.system, accent).length,
            lessThanOrEqualTo(appThemeStoreMaxLength),
          );
        }

        final restored = AppThemeController();
        await restored.load(store);
        expect(restored.accent, AppAccent.violet);
        expect(restored.preference, AppThemePreference.system);

        // An explicit emerald choice is written out, so it is kept (and older
        // versions read it as emerald too).
        await restored.setAccent(AppAccent.emerald);
        expect(store.value, 'system:emerald');
        final again = AppThemeController();
        await again.load(store);
        expect(again.accent, AppAccent.emerald);
      },
    );

    test('an unknown color scheme keeps the stored theme', () async {
      for (final stored in ['light:neon', 'light:', 'light:ocean:x']) {
        final controller = AppThemeController();
        await controller.load(MemoryAppThemeStore(stored));
        expect(controller.preference, AppThemePreference.light, reason: stored);
        expect(controller.accent, AppAccent.ocean, reason: stored);
      }
      final controller = AppThemeController();
      await controller.load(MemoryAppThemeStore('neon:violet'));
      expect(controller.preference, AppThemePreference.dark);
      expect(controller.accent, AppAccent.violet);
    });

    test('a failed write still applies and is reported', () async {
      final store = MemoryAppThemeStore()..failWith = StateError('disk');
      final controller = AppThemeController();
      await controller.load(store);
      await controller.setPreference(AppThemePreference.light);
      expect(controller.themeMode, ThemeMode.light);
      expect(controller.writeFailed, isTrue);
    });
  });

  testWidgets('switching theme applies in place and keeps State and drafts', (
    tester,
  ) async {
    final controller = AppThemeController();
    await controller.load(MemoryAppThemeStore());
    final draft = TextEditingController(text: 'unsaved draft');
    addTearDown(draft.dispose);
    var created = 0;
    await tester.pumpWidget(
      AppThemeModeBuilder(
        controller: controller,
        builder: (context, mode) => MaterialApp(
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: buildAppTheme(
            brightness: Brightness.light,
            accent: controller.accent,
          ),
          darkTheme: buildAppTheme(accent: controller.accent),
          themeMode: mode,
          home: Scaffold(
            body: ListView(
              children: [
                _Counter(onCreate: () => created++),
                TextField(key: const ValueKey('draft'), controller: draft),
                AppThemeSettings(controller: controller),
                const Tooltip(message: 'Hint', child: Text('target')),
              ],
            ),
          ),
        ),
      ),
    );
    BuildContext ctx() => tester.element(find.text('target'));
    expect(Theme.of(ctx()).brightness, Brightness.dark);

    await tester.tap(find.byKey(const ValueKey('app_theme_light')));
    await tester.pumpAndSettle();
    expect(controller.preference, AppThemePreference.light);
    expect(Theme.of(ctx()).brightness, Brightness.light);
    expect(ctx().palette.isDark, isFalse);
    expect(created, 1, reason: 'subtree must not be recreated');
    expect(draft.text, 'unsaved draft');
    expect(find.text('unsaved draft'), findsOneWidget);

    // Color scheme: applies to the shown theme in place, like the theme.
    for (final accent in AppAccent.values) {
      expect(find.byKey(ValueKey('app_accent_${accent.code}')), findsOneWidget);
    }
    await tester.ensureVisible(find.byKey(const ValueKey('app_accent_violet')));
    await tester.tap(find.byKey(const ValueKey('app_accent_violet')));
    await tester.pumpAndSettle();
    expect(controller.accent, AppAccent.violet);
    expect(
      ctx().palette,
      same(AppPalette.resolve(AppAccent.violet, Brightness.light)),
    );
    expect(
      Theme.of(ctx()).colorScheme.primary,
      AppPalette.resolve(AppAccent.violet, Brightness.light).accent,
    );
    expect(created, 1, reason: 'subtree must not be recreated');
    expect(draft.text, 'unsaved draft');
    expect(tester.takeException(), isNull);

    // The rendered tooltip label is white on the light theme too.
    tester.state<TooltipState>(find.byType(Tooltip)).ensureTooltipVisible();
    await tester.pumpAndSettle();
    final label = tester.widget<RichText>(
      find.byWidgetPredicate(
        (widget) => widget is RichText && widget.text.toPlainText() == 'Hint',
      ),
    );
    expect(label.text.style?.color, const Color(0xFFFFFFFF));
  });
}

class _Counter extends StatefulWidget {
  const _Counter({required this.onCreate});
  final VoidCallback onCreate;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 1);
}
