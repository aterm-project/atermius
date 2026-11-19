import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// 编译期总开关：`--dart-define=ATERM_IOS_NATIVE=false` 可整体关闭 iPhone 纯血 iOS 模式。
const bool kIosNativeEnabled = bool.fromEnvironment(
  'ATERM_IOS_NATIVE',
  defaultValue: true,
);

/// 测试 / 调试用的显式开关：包在子树外即可强制开启或关闭 iOS Phone 模式。
class IosNativeScope extends InheritedWidget {
  const IosNativeScope({
    super.key,
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  /// 返回最近的强制开关；没有时返回 `null`（交给自动判定）。
  static bool? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<IosNativeScope>()
      ?.enabled;

  @override
  bool updateShouldNotify(IosNativeScope oldWidget) =>
      enabled != oldWidget.enabled;
}

/// iPhone 纯血 iOS 模式：Theme 平台为 iOS、非 Web，且可用视口最短边 < 600pt。
///
/// 适配契约（含 iPhone 横屏、iPhone Duo 折叠屏与 iPad Slide Over）：
/// - 普通 iPhone 竖屏/横屏及 iPhone Duo 合盖外屏（最短边 < 600pt）保持单栏 5-Tab 壳，
///   横屏不会误翻回桌面布局；
/// - iPhone Duo 展开内屏（例如 `760×820pt`，最短边 >= 600pt）或 iPad 分屏拖宽时，
///   自动切换为侧边栏 + 多栏工作区 + 顶部标签栏，并在运行时通过稳定 GlobalKey 无损迁移会话；
/// - macOS / Android / Windows / Web 一律返回 `false`，旧行为不变。
bool isIosPhone(BuildContext context) {
  final forced = IosNativeScope.maybeOf(context);
  if (forced != null) return forced;
  if (!kIosNativeEnabled || kIsWeb) return false;
  if (Theme.of(context).platform != TargetPlatform.iOS) return false;
  final size = MediaQuery.maybeSizeOf(context);
  if (size == null) return false;
  return size.shortestSide < 600;
}

/// 横屏（紧凑高度）判定：iOS Phone 模式下用于收紧 TabBar / Pill 高度。
bool isIosCompactHeight(BuildContext context) {
  final size = MediaQuery.maybeSizeOf(context);
  if (size == null) return false;
  return size.height < 500;
}
