# Apple Human Interface Guidelines (HIG) 原生重构规范清单

本文档定义 Atermius 在 **iOS / iPadOS** 与 **macOS** 平台上的原生体验改造准则与测试安全红线。

---

## 一、核心视觉与几何规范

1. **连续曲率超椭圆圆角（Apple Continuous Squircle）**
   - 在 `TargetPlatform.iOS` 与 `TargetPlatform.macOS` 上，所有容器、卡片、对话框、弹出菜单、按钮、芯片（Chip）与输入框优先使用 Flutter 原生 `RoundedSuperellipseBorder`（通过 `appleSquircleBorder(borderRadius, side: ...)` 统一封装），替代普通圆弧 `RoundedRectangleBorder`，呈现纯正 Apple 硬件级连续曲率过渡。
   - 非 Apple 平台保持原有 `RoundedRectangleBorder` 不变。

2. **彻底移除 Android Material 水波纹（Ripple）与边缘泛光**
   - Apple 平台 `ThemeData.splashFactory` 必须设为 `NoSplash.splashFactory`，`splashColor: Colors.transparent`，依靠细腻的 `highlightColor` / `hoverColor` 与按压态颜色过渡表达反馈。
   - 全局 `ScrollBehavior` 在 iOS / macOS 上使用 `BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())`，绝不渲染 Android 风格的 `GlowingOverscrollIndicator` 或 `StretchingOverscrollIndicator`。

2.5 **Apple Liquid Glass 实时高斯模糊毛玻璃材质与镜面高光（Vibrancy & Translucent Blur）**
   - 在 iOS / macOS 上，顶栏（`WorkspaceTabBar`）、左侧导航栏（`HomeSidebar`）、iOS 终端键盘快捷工具栏（`TerminalKeybar`）、锁屏解锁卡片（`LockedWorkspaceScreen`）与模态对话框背景路由（`AppDialogRoute`）统一采用 `AppleGlassBar` / `AppleGlassSurface`（`BackdropFilter` 高斯模糊 `sigma: 22~26` + 半透明色调叠加 + Retina `0.5pt` `appleGlassRimColor` 镜面微高光边框）。
   - 遵循无障碍规范：在 `MediaQuery.highContrastOf(context) == true` 或非 Apple 平台时自动优雅降级为不透明纯色表面。

2.6 **iOS 软键盘终端退格（IME Sentinel Delete Detection）与自适应毛玻璃键盘**
   - `packages/xterm` 在原生 iOS / Android 上默认启用双零宽空格哨兵（`\u200b\u200b`）`deleteDetection`，确保软键盘在空缓冲区按下删除键（⌫ Backspace）以及长按连删时稳定发送 `0x7F`（`DEL`）并兼容软修饰键（`Alt + Backspace` 删词），同时杜绝普通空格触发 iOS“双击空格变句号”副作用。
   - `TerminalView.keyboardAppearance` 必须跟随当前 `Theme.of(context).brightness`，使 iOS 系统键盘自身呈现匹配的深/浅色原生毛玻璃材质。

3. **Apple 风格圆润控件（Switch / Popup / SearchField）**
   - **Switch（开关）**：Material 3 默认 Switch 带有未选中态粗边框与缩放圆点；在 Apple 平台上通过 `SwitchThemeData` 去除轨道描边（`trackOutlineColor: Colors.transparent`、`trackOutlineWidth: 0`），未选中轨道使用柔和中性填充色，选中态使用饱满主题色，滑块保持纯白恒定饱满圆点。
   - **SearchField（搜索框）**：采用 Apple Spotlight / `UISearchTextField` 柔和圆润底槽（`surfaceRaised` / `surfaceSoft`），聚焦态使用柔和半透明主题色细边，不跳变布局高度。
   - **Menu & Popover（上下文菜单）**：使用超椭圆圆角 + 柔和多层投影 + `0.5pt~1pt` 精细描边，呼出与收起动画控制在 `160ms` `Curves.easeOutCubic`。

4. **iOS 分组列表与系统“设置”质感（Settings & Host Cards）**
   - 窄屏（iPhone）下的设置分类导航项采用 iOS 系统“设置”风格的 **28×28 超椭圆主题色柔和底座图标 + 标题/精简说明 + 右侧 `Icons.chevron_right_rounded` 指示符**。
   - 主机卡片（`HostCardLayout`）在 Apple 平台使用连续曲率圆角卡片与细腻高光悬停/按压态，保持所有触控热区 `>= 44×44 pt`。

---

## 二、原生交互、帧率与硬件协同

1. **120Hz ProMotion 满帧自适应（iOS）**
   - `ios/Runner/Info.plist` 必须包含 `<key>CADisableMinimumFrameDurationOnPhone</key><true/>`，解锁 iPhone Air / Pro 系列 120Hz 高刷终端滚动与动画帧率。

2. **克制、精准的触觉反馈（iOS Haptics）**
   - 通过 `AppleHaptics` 统一管理，仅在 `TargetPlatform.iOS` 触发：
     - `AppleHaptics.selection()`：侧边栏导航切换、设置分类切换、分段按钮切换；
     - `AppleHaptics.light()`：点击快速连接主机、触发一键导入等明确主动作。

3. **macOS 原生窗口外观与防首帧白闪**
   - `MainFlutterWindow.swift` 在窗口初始化阶段即设置 `NSAppearance(named: .darkAqua)` 默认深色底色（`#0B0F10`）与 `fullSizeContentView` 一体化透明标题栏，确保冷启动与新建独立终端窗口零白闪，交通灯避让精准平滑。

---

## 三、严禁破坏的回归测试红线（Invariants）

1. **禁止更改或移除现有 `ValueKey`、Semantics 标签与对外 Widget 构造签名**。
2. **禁止替换已有测试中通过 `find.byIcon(Icons.xxx)` 断言的 `Icons.*` 常量**（且项目未引入 `cupertino_icons` 字体包，严禁使用 `CupertinoIcons.*`，统一使用 Material Rounded / Outlined 图标避免缺字方块）。
3. **禁止违反配色无障碍约束**：
   - 浅色主题 `scaffoldBackgroundColor` 与 `cardTheme.color` 必须保持 `Color(0xFFFFFFFF)`；
   - 深浅两套主题的 `tooltipBackground.computeLuminance()` 必须 `< 0.05`，且文本对比度满足 `app_theme_mode_test.dart` 与 `wallpaper_test.dart` 的 WCAG AA/AAA 断言；
   - 终端 ANSI 配色（`terminal_color_theme.dart`）与 UI Chrome 配色保持完全独立。
4. **保持 `HomeSidebar` 响应式左栏宽度契约**：`labelled = 200`、`rail = 72`、`phoneRail = 52` 不可更改。
