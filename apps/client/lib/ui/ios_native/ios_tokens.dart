import 'package:flutter/material.dart';

import '../app_theme.dart';

/// iOS 系统语义色（仅 iOS Phone 模式使用），按当前 Theme 亮度解析。
///
/// 数值对齐 UIKit 动态系统色；`tint` 复用品牌翡翠 `palette.accentText`。
@immutable
class IosColors {
  const IosColors._({
    required this.brightness,
    required this.groupedBackground,
    required this.cell,
    required this.cellPressed,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.separator,
    required this.fill,
    required this.tint,
    required this.onTint,
    required this.destructive,
    required this.online,
    required this.warning,
    required this.blue,
    required this.green,
    required this.indigo,
    required this.orange,
    required this.pink,
    required this.purple,
    required this.red,
    required this.teal,
    required this.cyan,
    required this.mint,
    required this.yellow,
    required this.gray,
    required this.glassFill,
    required this.glassRimStrong,
    required this.glassRimWeak,
    required this.glassShadow,
    required this.barFill,
    required this.menuFill,
    required this.menuSectionGap,
  });

  final Brightness brightness;

  /// 分组列表背景：暗 `#000000`（OLED 纯黑）/ 亮 `#F2F2F7`。
  final Color groupedBackground;

  /// 分组容器（secondarySystemGroupedBackground）：暗 `#1C1C1E` / 亮 `#FFFFFF`。
  final Color cell;
  final Color cellPressed;
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;

  /// 不透明分割线：暗 `#38383A` / 亮 `#C6C6C8`。
  final Color separator;

  /// tertiarySystemFill：搜索槽、计数胶囊、键帽底色。
  final Color fill;
  final Color tint;
  final Color onTint;
  final Color destructive;
  final Color online;
  final Color warning;

  // 系统彩色（设置图标块等）。
  final Color blue;
  final Color green;
  final Color indigo;
  final Color orange;
  final Color pink;
  final Color purple;
  final Color red;
  final Color teal;
  final Color cyan;
  final Color mint;
  final Color yellow;
  final Color gray;

  // Liquid Glass。
  final Color glassFill;
  final Color glassRimStrong;
  final Color glassRimWeak;
  final Color glassShadow;

  /// 滚动后导航栏毛玻璃填充。
  final Color barFill;

  /// 下拉菜单面板填充。
  final Color menuFill;

  /// 下拉菜单分组间粗分隔。
  final Color menuSectionGap;

  bool get isDark => brightness == Brightness.dark;

  static const dark = IosColors._(
    brightness: Brightness.dark,
    groupedBackground: Color(0xFF000000),
    cell: Color(0xFF1C1C1E),
    cellPressed: Color(0xFF2C2C2E),
    label: Color(0xFFFFFFFF),
    secondaryLabel: Color(0x99EBEBF5),
    tertiaryLabel: Color(0x4DEBEBF5),
    separator: Color(0xFF38383A),
    fill: Color(0x3D767680),
    tint: Color(0xFF4FD8C4),
    onTint: Color(0xFF062924),
    destructive: Color(0xFFFF453A),
    online: Color(0xFF30D158),
    warning: Color(0xFFFF9F0A),
    blue: Color(0xFF0A84FF),
    green: Color(0xFF30D158),
    indigo: Color(0xFF5E5CE6),
    orange: Color(0xFFFF9F0A),
    pink: Color(0xFFFF375F),
    purple: Color(0xFFBF5AF2),
    red: Color(0xFFFF453A),
    teal: Color(0xFF40C8E0),
    cyan: Color(0xFF64D2FF),
    mint: Color(0xFF63E6E2),
    yellow: Color(0xFFFFD60A),
    gray: Color(0xFF8E8E93),
    glassFill: Color(0x8C1C1C1E),
    glassRimStrong: Color(0x59FFFFFF),
    glassRimWeak: Color(0x14FFFFFF),
    glassShadow: Color(0x2E000000),
    barFill: Color(0x99000000),
    menuFill: Color(0xC72C2C2E),
    menuSectionGap: Color(0x40000000),
  );

  static const light = IosColors._(
    brightness: Brightness.light,
    groupedBackground: Color(0xFFF2F2F7),
    cell: Color(0xFFFFFFFF),
    cellPressed: Color(0xFFD1D1D6),
    label: Color(0xFF000000),
    secondaryLabel: Color(0x993C3C43),
    tertiaryLabel: Color(0x4D3C3C43),
    separator: Color(0xFFC6C6C8),
    fill: Color(0x1F767680),
    tint: Color(0xFF0C7A6C),
    onTint: Color(0xFFFFFFFF),
    destructive: Color(0xFFFF3B30),
    online: Color(0xFF34C759),
    warning: Color(0xFFFF9500),
    blue: Color(0xFF007AFF),
    green: Color(0xFF34C759),
    indigo: Color(0xFF5856D6),
    orange: Color(0xFFFF9500),
    pink: Color(0xFFFF2D55),
    purple: Color(0xFFAF52DE),
    red: Color(0xFFFF3B30),
    teal: Color(0xFF30B0C7),
    cyan: Color(0xFF32ADE6),
    mint: Color(0xFF00C7BE),
    yellow: Color(0xFFFFCC00),
    gray: Color(0xFF8E8E93),
    glassFill: Color(0xB8FFFFFF),
    glassRimStrong: Color(0xE6FFFFFF),
    glassRimWeak: Color(0x14FFFFFF),
    glassShadow: Color(0x1A000000),
    barFill: Color(0xB3F9F9F9),
    menuFill: Color(0xD1F2F2F7),
    menuSectionGap: Color(0x14000000),
  );

  /// 按当前 Theme 解析；tint 跟随品牌 `palette.accentText`。
  static IosColors of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = dark ? IosColors.dark : IosColors.light;
    final palette = Theme.of(context).extension<AppPalette>();
    if (palette == null) return base;
    return base._withTint(palette.accentText);
  }

  IosColors _withTint(Color value) => value == tint
      ? this
      : IosColors._(
          brightness: brightness,
          groupedBackground: groupedBackground,
          cell: cell,
          cellPressed: cellPressed,
          label: label,
          secondaryLabel: secondaryLabel,
          tertiaryLabel: tertiaryLabel,
          separator: separator,
          fill: fill,
          tint: value,
          onTint: onTint,
          destructive: destructive,
          online: online,
          warning: warning,
          blue: blue,
          green: green,
          indigo: indigo,
          orange: orange,
          pink: pink,
          purple: purple,
          red: red,
          teal: teal,
          cyan: cyan,
          mint: mint,
          yellow: yellow,
          gray: gray,
          glassFill: glassFill,
          glassRimStrong: glassRimStrong,
          glassRimWeak: glassRimWeak,
          glassShadow: glassShadow,
          barFill: barFill,
          menuFill: menuFill,
          menuSectionGap: menuSectionGap,
        );
}

/// iOS 几何 Token（单位 pt）。
abstract final class IosMetrics {
  /// Inset Grouped 容器圆角（iOS 26/27 放大圆角，连续曲率）。
  static const double groupRadius = 26;
  static const double sectionMargin = 20;
  static const double sectionSpacing = 35;
  static const double sectionHeaderInset = 36;
  static const double rowMinHeight = 44;
  static const double hostRowHeight = 60;
  static const double rowPaddingH = 16;
  static const double rowPaddingV = 11;
  static const double iconTile = 29;
  static const double iconTileRadius = 7;
  static const double hostIconTile = 36;
  static const double hostIconTileRadius = 9;
  static const double iconTextGap = 12;

  static const double tabBarHeight = 62;
  static const double tabBarHeightCompact = 50;
  static const double tabBarMargin = 20;
  static const double accessoryHeight = 54;
  static const double accessoryHeightCompact = 44;
  static const double accessoryGap = 8;

  static const double glassButton = 44;
  static const double searchHeight = 36;
  static const double menuRadius = 14;
  static const double menuWidth = 250;
  static const double menuRowHeight = 44;
  static const double swipeActionWidth = 74;
  static const double formLabelWidth = 96;

  /// 文字起点相对行左缘的缩进（有图标块时）。
  static double textInsetFor(double iconSize) =>
      rowPaddingH + iconSize + iconTextGap;

  /// 真 1 物理像素发丝线（不再 clamp 到 0.5pt）。
  static double hairline(BuildContext context) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return 1.0 / (dpr <= 0 ? 1.0 : dpr);
  }

  /// TabBar 浮动底边距：悬于 Home 指示条之上。
  static double tabBarBottom(double safeBottom) =>
      (safeBottom - 12).clamp(8.0, double.infinity);
}

/// SF Pro 文字样式（不含颜色；用 `copyWith(color:)` 着色）。字距对齐 Apple 规范。
abstract final class IosType {
  static const largeTitle = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.37,
    height: 1.2,
  );
  static const title1 = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.36,
    height: 1.2,
  );
  static const title2 = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.26,
    height: 1.25,
  );
  static const title3 = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.45,
    height: 1.25,
  );
  static const headline = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.43,
    height: 1.3,
  );
  static const body = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.43,
    height: 1.3,
  );
  static const callout = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.31,
    height: 1.3,
  );
  static const subheadline = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.23,
    height: 1.3,
  );
  static const footnote = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.08,
    height: 1.3,
  );
  static const caption1 = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.3,
  );
  static const caption2 = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
    height: 1.2,
  );

  /// 等宽副标题（`user@host:port`、命令预览）。
  static const mono = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w400,
    fontFamily: 'Menlo',
    fontFamilyFallback: ['Courier'],
    letterSpacing: 0,
    height: 1.3,
  );
}
