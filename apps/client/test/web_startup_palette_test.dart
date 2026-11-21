// The browser entry page paints before Flutter can supply ThemeData.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _css(Color color) =>
    '#${color.toARGB32().toRadixString(16).substring(2)}';

void main() {
  test('browser startup colors match every Windows app palette', () {
    final script = File('web/startup-theme.js').readAsStringSync();
    final table = RegExp(
      r'const palettes = (\{.*?\n  \});',
      dotAll: true,
    ).firstMatch(script)![1]!;
    final expected = {
      for (final brightness in Brightness.values)
        brightness.name: {
          for (final accent in AppAccent.values)
            accent.code: _colorsFor(brightness, accent),
        },
    };
    expect(jsonDecode(table), expected);

    // A record without a scheme, or none at all, starts on the default one.
    final code = defaultAppAccent.code;
    expect(script, contains("colon < 0 ? '$code'"));
    expect(script, contains(': scheme.$code;'));
    final defaults = expected['dark']![code]!;
    final manifest = jsonDecode(File('web/manifest.json').readAsStringSync());
    expect(manifest['background_color'], defaults.first);
    expect(manifest['theme_color'], defaults.first);
    final html = File('web/index.html').readAsStringSync();
    expect(html, contains('name="theme-color" content="${defaults.first}"'));
    for (final (i, role) in [
      'background',
      'text',
      'progress',
      'warning',
    ].indexed) {
      expect(html, contains('--app-$role: ${defaults[i]};'));
    }
  });
}

List<String> _colorsFor(Brightness brightness, AppAccent accent) {
  final theme = buildAppTheme(
    platform: TargetPlatform.windows,
    brightness: brightness,
    accent: accent,
  );
  final palette = theme.extension<AppPalette>()!;
  return [
    palette.background,
    palette.text,
    palette.accentText,
    palette.orange,
  ].map(_css).toList();
}
