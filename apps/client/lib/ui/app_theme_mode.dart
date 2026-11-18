import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../storage/app_theme_store.dart';
import 'app_theme.dart';
import 'apple_hig.dart';
import 'ios_native/ios_native.dart';
import 'settings_scaffold.dart';

/// Device-local UI theme choice. [code] is the stable persisted value; never
/// rename it. The historic dark theme stays the default until the user picks
/// another option explicitly.
enum AppThemePreference {
  dark('dark', ThemeMode.dark),
  light('light', ThemeMode.light),
  system('system', ThemeMode.system);

  const AppThemePreference(this.code, this.mode);
  final String code;
  final ThemeMode mode;

  String label(AppLocalizations l10n) => switch (this) {
    dark => l10n.themeOptionDark,
    light => l10n.themeOptionLight,
    system => l10n.themeOptionSystem,
  };
}

const defaultAppThemePreference = AppThemePreference.dark;

AppThemePreference parseAppThemePreference(String? value) {
  final normalized = value?.split(_accentSeparator).first.trim().toLowerCase();
  for (final preference in AppThemePreference.values) {
    if (preference.code == normalized) return preference;
  }
  return defaultAppThemePreference;
}

/// Display name of a color scheme.
String appAccentLabel(AppLocalizations l10n, AppAccent accent) =>
    switch (accent) {
      AppAccent.emerald => l10n.themeAccentEmerald,
      AppAccent.ocean => l10n.themeAccentOcean,
      AppAccent.violet => l10n.themeAccentViolet,
      AppAccent.rose => l10n.themeAccentRose,
      AppAccent.amber => l10n.themeAccentAmber,
      AppAccent.graphite => l10n.themeAccentGraphite,
    };

/// The stored record is the theme code alone for the default color scheme (as
/// every earlier version wrote it), else `<theme>:<scheme>`.
const _accentSeparator = ':';

AppAccent parseStoredAppAccent(String? value) {
  final at = value?.indexOf(_accentSeparator) ?? -1;
  return at < 0 ? AppAccent.emerald : AppAccent.parse(value!.substring(at + 1));
}

String encodeAppTheme(AppThemePreference preference, AppAccent accent) =>
    accent == AppAccent.emerald
    ? preference.code
    : '${preference.code}$_accentSeparator${accent.code}';

/// Color Flutter publishes to the browser via its application title.
Color? browserThemeColor(BuildContext context, ThemeMode mode) {
  if (!kIsWeb) return null;
  final brightness = switch (mode) {
    ThemeMode.light => Brightness.light,
    ThemeMode.dark => Brightness.dark,
    ThemeMode.system => MediaQuery.platformBrightnessOf(context),
  };
  return AppPalette.resolve(
    AppThemeController.instance.accent,
    brightness,
  ).background;
}

/// Owns the persisted UI theme preference and color scheme. Changing either
/// only swaps the [ThemeData] handed to the app roots, so sessions, panes and
/// form drafts keep their State.
class AppThemeController extends ChangeNotifier {
  AppThemeController();

  static AppThemeController? _instance;

  /// Process-wide controller used by the app roots.
  static AppThemeController get instance => _instance ??= AppThemeController();

  @visibleForTesting
  static set debugInstance(AppThemeController? controller) =>
      _instance = controller;

  AppThemeStore? _store;
  AppThemePreference _preference = defaultAppThemePreference;
  AppAccent _accent = AppAccent.emerald;
  bool _writeFailed = false;
  int _writeRevision = 0;
  Future<void> _writeChain = Future<void>.value();
  bool _disposed = false;

  AppThemePreference get preference => _preference;
  ThemeMode get themeMode => _preference.mode;

  /// Color scheme of both the dark and the light theme.
  AppAccent get accent => _accent;

  /// Whether the last attempt to persist a choice failed. The choice still
  /// applies for this run.
  bool get writeFailed => _writeFailed;

  /// Reads the stored preference. Missing, invalid or failing reads keep the
  /// dark default and the emerald color scheme.
  Future<void> load(AppThemeStore store) async {
    _store = store;
    AppThemePreference next;
    AppAccent accent;
    try {
      final stored = await store.read().timeout(const Duration(seconds: 2));
      next = parseAppThemePreference(stored);
      accent = parseStoredAppAccent(stored);
    } on Object {
      next = defaultAppThemePreference;
      accent = AppAccent.emerald;
    }
    if (next != _preference || accent != _accent) {
      _preference = next;
      _accent = accent;
      notifyListeners();
    }
  }

  /// Applies [preference] immediately and persists it as a device preference.
  /// Writes are serialized and coalesced; only the latest choice may update
  /// [writeFailed].
  Future<void> setPreference(AppThemePreference preference) {
    if (preference != _preference) {
      _preference = preference;
      notifyListeners();
    }
    return _write();
  }

  /// Applies the color scheme immediately and persists it like the theme.
  Future<void> setAccent(AppAccent accent) {
    if (accent != _accent) {
      _accent = accent;
      notifyListeners();
    }
    return _write();
  }

  Future<void> _write() {
    final store = _store;
    if (store == null) return Future<void>.value();
    final revision = ++_writeRevision;
    final code = encodeAppTheme(_preference, _accent);
    final next = _writeChain.then((_) async {
      if (revision != _writeRevision || _disposed) return;
      var failed = false;
      try {
        await store.write(code);
      } on Object {
        failed = true;
      }
      if (revision != _writeRevision || _disposed) return;
      if (_writeFailed != failed) {
        _writeFailed = failed;
        notifyListeners();
      }
    });
    _writeChain = next;
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Unawaited-safe helper for persisting a theme choice from UI callbacks.
void selectAppTheme(
  AppThemePreference preference, {
  AppThemeController? using,
}) =>
    unawaited((using ?? AppThemeController.instance).setPreference(preference));

/// Rebuilds an app root (normally a `MaterialApp`) with the current
/// [ThemeMode]. The root widget is updated in place, never recreated.
class AppThemeModeBuilder extends StatelessWidget {
  const AppThemeModeBuilder({
    required this.builder,
    this.controller,
    super.key,
  });

  final Widget Function(BuildContext context, ThemeMode mode) builder;
  final AppThemeController? controller;

  @override
  Widget build(BuildContext context) {
    final themes = controller ?? AppThemeController.instance;
    return ListenableBuilder(
      listenable: themes,
      builder: (context, _) => builder(context, themes.themeMode),
    );
  }
}

/// Appearance setting: Dark / Light / Match system and the color scheme.
/// Applies immediately.
class AppThemeSettings extends StatelessWidget with IosFlushSettingsChild {
  const AppThemeSettings({this.controller, this.dense = false, super.key});

  final AppThemeController? controller;
  final bool dense;

  Widget _buildIos(BuildContext context, AppThemeController themes) {
    final l10n = context.l10n;
    final colors = IosColors.of(context);
    final current = themes.preference;
    final systemDark =
        MediaQuery.maybePlatformBrightnessOf(context) != Brightness.light;
    final resolved = systemDark ? l10n.themeOptionDark : l10n.themeOptionLight;
    return Padding(
      key: const ValueKey('app_theme_settings'),
      padding: const EdgeInsets.all(IosMetrics.rowPaddingH),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IosIconTile(
                icon: Icons.palette_rounded,
                color: colors.blue,
                size: 28,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.themeSettingTitle,
                  style: IosType.headline.copyWith(color: colors.label),
                ),
              ),
            ],
          ),
          if (!dense) ...[
            const SizedBox(height: 6),
            Text(
              l10n.themeSettingDescription,
              style: IosType.footnote.copyWith(color: colors.secondaryLabel),
            ),
          ],
          const SizedBox(height: 12),
          Semantics(
            container: true,
            label: l10n.themeSettingTitle,
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<AppThemePreference>(
                groupValue: current,
                backgroundColor: colors.fill,
                thumbColor: colors.isDark
                    ? const Color(0xFF636366)
                    : Colors.white,
                onValueChanged: (next) {
                  if (next == null || next == current) return;
                  AppleHaptics.selection(context);
                  selectAppTheme(next, using: themes);
                },
                children: {
                  for (final preference in AppThemePreference.values)
                    preference: KeyedSubtree(
                      key: ValueKey('app_theme_${preference.code}'),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 7,
                        ),
                        child: Text(
                          preference.label(l10n),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: IosType.footnote.copyWith(
                            color: colors.label,
                            fontWeight: preference == current
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                },
              ),
            ),
          ),
          if (current == AppThemePreference.system) ...[
            const SizedBox(height: 8),
            Text(
              l10n.themeSettingSystemResolved(resolved),
              style: IosType.footnote.copyWith(color: colors.secondaryLabel),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            themes.writeFailed
                ? l10n.themeSettingSaveFailed
                : l10n.languageSettingDevicePreference,
            key: const ValueKey('app_theme_storage_note'),
            style: IosType.footnote.copyWith(
              color: themes.writeFailed ? colors.warning : colors.secondaryLabel,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themes = controller ?? AppThemeController.instance;
    return ListenableBuilder(
      listenable: themes,
      builder: (context, _) {
        if (isIosPhone(context)) {
          return _buildIos(context, themes);
        }
        final l10n = context.l10n;
        final palette = context.palette;
        final current = themes.preference;
        final systemDark =
            MediaQuery.maybePlatformBrightnessOf(context) != Brightness.light;
        final resolved = systemDark
            ? l10n.themeOptionDark
            : l10n.themeOptionLight;
        return Column(
          key: const ValueKey('app_theme_settings'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.palette_outlined, size: 20, color: palette.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.themeSettingTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (!dense) ...[
              const SizedBox(height: 6),
              Text(
                l10n.themeSettingDescription,
                style: TextStyle(color: palette.muted, height: 1.4),
              ),
            ],
            const SizedBox(height: 8),
            Semantics(
              container: true,
              label: l10n.themeSettingTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final preference in AppThemePreference.values)
                    _ThemeOption(
                      preference: preference,
                      selected: preference == current,
                      label: preference.label(l10n),
                      subtitle: preference == AppThemePreference.system
                          ? l10n.themeSettingSystemResolved(resolved)
                          : null,
                      onSelected: () =>
                          selectAppTheme(preference, using: themes),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.themeAccentTitle,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Semantics(
              container: true,
              label: l10n.themeAccentTitle,
              child: Wrap(
                key: const ValueKey('app_accent_options'),
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final accent in AppAccent.values)
                    _AccentOption(
                      accent: accent,
                      selected: accent == themes.accent,
                      label: appAccentLabel(l10n, accent),
                      onSelected: () => unawaited(themes.setAccent(accent)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              themes.writeFailed
                  ? l10n.themeSettingSaveFailed
                  : l10n.languageSettingDevicePreference,
              key: const ValueKey('app_theme_storage_note'),
              style: TextStyle(
                color: themes.writeFailed ? palette.orange : palette.muted,
                fontSize: 12,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.preference,
    required this.selected,
    required this.label,
    required this.subtitle,
    required this.onSelected,
  });

  final AppThemePreference preference;
  final bool selected;
  final String label;
  final String? subtitle;
  final VoidCallback onSelected;

  IconData get _icon => switch (preference) {
    AppThemePreference.dark => Icons.dark_mode_outlined,
    AppThemePreference.light => Icons.light_mode_outlined,
    AppThemePreference.system => Icons.brightness_auto_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      child: ListTile(
        key: ValueKey('app_theme_${preference.code}'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        selected: selected,
        selectedColor: palette.accentText,
        selectedTileColor: palette.accent.withValues(alpha: 0.12),
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          color: selected ? palette.accentText : palette.muted,
          size: 20,
        ),
        title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Icon(_icon, size: 18, color: palette.muted),
        onTap: onSelected,
      ),
    );
  }
}

/// One color scheme: a swatch in that scheme's own accent (for the theme now
/// shown) and its name.
class _AccentOption extends StatelessWidget {
  const _AccentOption({
    required this.accent,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final AppAccent accent;
  final bool selected;
  final String label;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = AppPalette.resolve(accent, palette.brightness);
    final radius = BorderRadius.circular(10);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      child: Material(
        color: selected
            ? palette.accent.withValues(alpha: 0.12)
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected ? palette.accentText : palette.line,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          key: ValueKey('app_accent_${accent.code}'),
          borderRadius: radius,
          onTap: onSelected,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.accent,
                    border: Border.all(color: scheme.accentText, width: 1.5),
                  ),
                  child: selected
                      ? Icon(Icons.check, size: 14, color: scheme.onAccent)
                      : null,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? palette.accentText : palette.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
