import 'package:flutter/widgets.dart';

/// Glyphs of the app's own icon font, assets/fonts/atermius_icons.ttf, which
/// tool/atermius_icon_font.dart generates from vector outlines.
///
/// A font rather than a CustomPainter because the marks are then ordinary
/// [IconData]: workspace actions, menus, tabs and settings sections all take
/// IconData, and [Icon] already follows IconTheme size, colour and opacity
/// (light and dark themes, disabled tiles) and carries semantics labels. The
/// glyphs are const so release builds tree-shake the font like Material
/// Icons; an IconData built at run time would fail release builds unless
/// icon tree shaking is turned off for the whole app.
abstract final class AtermiusIcons {
  static const _family = 'AtermiusIcons';

  /// RDP: a monitor on a stand with a pointer on the screen, the picture of
  /// the Windows remote-desktop window icon; also the remote-desktop settings
  /// section. VNC keeps Material's plain monitor, so the two protocols stay
  /// distinguishable in lists.
  static const IconData remoteDesktop = IconData(0xe000, fontFamily: _family);
}
