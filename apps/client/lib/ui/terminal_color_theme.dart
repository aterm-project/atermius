import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../domain/vault_preference.dart';

/// Default SSH terminal text color: a soft grass green. Owned by the terminal
/// palette and intentionally independent of the app's emphasis colors.
///
/// The built-in dark palette is tuned as one family rather than colour by
/// colour. In OKLCH the text sits at lightness 0.80 and chroma 0.135; the
/// earlier 0xFF9BEF60 (0.87 / 0.195) read as fluorescent over long sessions.
/// The ANSI colours keep their hue meanings with chroma between 0.09 and
/// 0.145 and even lightness steps (normal around 0.72 to 0.84, bright about
/// 0.07 above), so no single colour glares next to the others. All of them
/// keep at least 4.5:1 contrast against the background, the text over 7:1.
const atermDarkTerminalForeground = Color(0xFF91D27B);
// xterm paints the selection over glyphs, so it must be translucent.
const _atermDarkTerminalSelection = Color(0x804A6FD0);

/// Builds a terminal palette only from the synchronized, strictly decoded
/// theme choice. Keep all terminal surfaces routed through this constructor.
/// Built-in palettes keep the ANSI hue meanings. Device presets remain
/// untouched.
TerminalTheme buildTerminalColorTheme(VaultTerminalThemeChoice choice) =>
    switch (choice) {
      VaultTerminalThemeChoice.atermDark => const TerminalTheme(
        cursor: atermDarkTerminalForeground,
        selection: _atermDarkTerminalSelection,
        foreground: atermDarkTerminalForeground,
        background: Color(0xFF0F1425),
        black: Color(0xFF3A4255),
        red: Color(0xFFF17B82),
        green: Color(0xFF5CD299),
        yellow: Color(0xFFEAC66E),
        blue: Color(0xFF77A6EC),
        magenta: Color(0xFFC395DF),
        cyan: Color(0xFF69CBDC),
        white: Color(0xFFD9DEE6),
        brightBlack: Color(0xFF8F98AB),
        brightRed: Color(0xFFFC9C9F),
        brightGreen: Color(0xFF7EE7B2),
        brightYellow: Color(0xFFF3D991),
        brightBlue: Color(0xFF97BDF4),
        brightMagenta: Color(0xFFD5B0EB),
        brightCyan: Color(0xFF91E0EE),
        brightWhite: Color(0xFFF3F5F9),
        searchHitBackground: Color(0xFF665324),
        searchHitBackgroundCurrent: Color(0xFF8A6620),
        searchHitForeground: Color(0xFFFFFFFF),
      ),
      VaultTerminalThemeChoice.light => const TerminalTheme(
        cursor: Color(0xFF325E98),
        selection: Color(0x8071A9E8),
        foreground: Color(0xFF17202D),
        background: Color(0xFFF8FAFC),
        black: Color(0xFF263238),
        red: Color(0xFFB42318),
        green: Color(0xFF18794E),
        yellow: Color(0xFF8A6100),
        blue: Color(0xFF175CD3),
        magenta: Color(0xFF9333A6),
        cyan: Color(0xFF087E8B),
        white: Color(0xFF374151),
        brightBlack: Color(0xFF667085),
        brightRed: Color(0xFFC22228),
        brightGreen: Color(0xFF087F47),
        brightYellow: Color(0xFF8C6200),
        brightBlue: Color(0xFF1769D2),
        brightMagenta: Color(0xFFA328B3),
        brightCyan: Color(0xFF007C91),
        brightWhite: Color(0xFF111827),
        searchHitBackground: Color(0xFFFFE08A),
        searchHitBackgroundCurrent: Color(0xFFFFC247),
        searchHitForeground: Color(0xFF17202D),
      ),
    };
