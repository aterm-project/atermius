---
name: apple-native-refactor
description: Apple Human Interface Guidelines (HIG) 原生体验审计与重构工作流。用于对 Flutter + Swift (iOS / iPadOS / macOS) 客户端执行多智能体并发 HIG 审计、连续曲率超椭圆圆角（Squircle）、无水波纹触控反馈、弹性滚动物理、iOS 触觉反馈、120Hz ProMotion 高刷、macOS 一体化窗口规范重构及双端回归测试验证。
---

# Apple 原生规范重构工作流 (`apple-native-refactor`)

本技能封装了一套基于 `run_workflow` 的多智能体分级重构流水线，专门用于将跨平台客户端在 Apple 平台（iOS / iPadOS / macOS）上的交互、动效、几何圆角、控件样式与原生宿主配置全面对齐最新 **Apple Human Interface Guidelines (HIG)**，同时 100% 保持现有业务语义与自动化测试契约不退化。

## 何时使用

- 用户要求“按 Apple 原生规范重构 UI / 交互”、“去掉 Android Material 感”、“优化 iOS / macOS 原生质感”或触发 `/apple-native-refactor` 时。
- 新增功能页面后，需要对 Apple 平台的圆角、过渡动画、触觉反馈、安全区与窗口顶栏做统一规范收敛时。

## 核心规范参考

执行任何手动或自动重构前，请先阅读同目录下的权威对照清单：
- [references/apple_hig_checklist.md](references/apple_hig_checklist.md)

## 一键启动动态多智能体工作流

调用 `run_workflow` 工具直接运行编排脚本 [scripts/apple_hig_workflow.py](scripts/apple_hig_workflow.py)：

```python
run_workflow(
    ScriptPath="/Users/yang/Downloads/aterm-project/.agents/skills/apple-native-refactor/scripts/apple_hig_workflow.py",
    Description="Apple HIG 原生规范多智能体审计、分片重构与双仓回归门禁流水线",
)
```

## 工作流四阶段架构

1. **Phase 1 — 并行 HIG 差距审计 (`parallel` 4 路并发 Agent)**
   - **Theme & Controls Auditor**：审查 `app_theme.dart`、`main.dart`、`app_motion.dart` 中的水波纹（Ripple）、圆角曲率（Squircle vs Circular）、Switch 轨道轮廓、Tooltip 与弹窗曲线。
   - **Navigation & Search Auditor**：审查 `home_sidebar.dart`、`host_search_field.dart`、`workspace_controls.dart`、`home_add_sharing_row.dart` 的选中态胶囊、Spotlight 搜索槽与 Popover 菜单阴影。
   - **Cards & Settings Auditor**：审查 `host_card_layout.dart`、`settings_scaffold.dart`、`locked_workspace_screen.dart` 的 iOS Grouped Inset 卡片层次、图标底座与触觉反馈。
   - **Native Runner Auditor**：审查 `ios/Runner/Info.plist`、`AppDelegate.swift` 与 `macos/Runner/MainFlutterWindow.swift` 的 120Hz ProMotion、首帧背景防白闪与 Unified Titlebar 配置。

2. **Phase 2 — Apple HIG 基础设计原语落地 (`Foundation Agent`)**
   - 构建/演进 `lib/ui/apple_hig.dart`（连续曲率 `RoundedSuperellipseBorder`、`AppleScrollBehavior` 弹性回弹物理、`AppleHaptics` 线性马达触觉封装、发丝边框宽度计算）。
   - 在 `lib/ui/app_theme.dart` 与 `lib/main.dart` 注入 Apple 平台专属 `NoSplash.splashFactory`、iOS 风格无黑边圆润 `SwitchThemeData`、超椭圆组件主题与全局弹性滚动行为。

3. **Phase 3 — 严格文件域分片并行重构 (`parallel` 3 路无冲突修改 Agent)**
   - **Slice A (`Navigation & Search`)**：仅修改 `home_sidebar.dart`、`host_search_field.dart`、`workspace_controls.dart`、`home_add_sharing_row.dart`。
   - **Slice B (`Host Cards & Settings`)**：仅修改 `host_card_layout.dart`、`settings_scaffold.dart`、`locked_workspace_screen.dart`。
   - **Slice C (`Apple Native Runners`)**：仅修改 `ios/apps/client/ios/Runner/Info.plist` 与 `desktop/apps/client/macos/Runner/MainFlutterWindow.swift`。

4. **Phase 4 — 跨仓同步、HIG 合规单测与质量门禁 (`Verification & Sync Agent`)**
   - 编写并运行 `test/apple_hig_conformance_test.dart`，校验 Apple 平台无水波纹、超椭圆几何、弹性滚动、120Hz ProMotion 及 WCAG 对比度不变量。
   - 将共享客户端代码同步至 `ios/apps/client`，并在 `desktop` 与 `ios` 双仓跑通 `flutter analyze` 与回归测试集。
