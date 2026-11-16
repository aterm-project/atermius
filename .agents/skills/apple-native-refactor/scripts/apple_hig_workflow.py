"""
Apple Human Interface Guidelines (HIG) Multi-Agent Refactoring Workflow.

Orchestrates 4 stages:
  1. Parallel read-only HIG gap audit across 4 subsystem domains.
  2. Foundation primitives (`apple_hig.dart`, `app_theme.dart`, `main.dart`).
  3. Strictly disjoint parallel UI & Native Runner refactoring (3 slices).
  4. Conformance test authoring, `flutter analyze` + widget test gate, and
     cross-repo synchronization (`desktop` -> `ios`).
"""

import json

ROOT = "/Users/yang/Downloads/aterm-project"
CHECKLIST = f"{ROOT}/.agents/skills/apple-native-refactor/references/apple_hig_checklist.md"
TOOL_PATH = (
    f"{ROOT}/.tooling/flutter-sdk/flutter/bin:"
    f"{ROOT}/.tooling/venv/bin:"
    f"{ROOT}/.tooling/ruby-env/bin:"
    "$HOME/.local/bin:$PATH"
)

AUDIT_SCHEMA = {
    "type": "object",
    "properties": {
        "domain": {"type": "string"},
        "findings": {"type": "array", "items": {"type": "string"}},
        "test_invariants": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["domain", "findings", "test_invariants"],
}

SLICE_SCHEMA = {
    "type": "object",
    "properties": {
        "slice": {"type": "string"},
        "modified_files": {"type": "array", "items": {"type": "string"}},
        "summary": {"type": "string"},
    },
    "required": ["slice", "modified_files", "summary"],
}

GATE_SCHEMA = {
    "type": "object",
    "properties": {
        "analyze_passed": {"type": "boolean"},
        "tests_passed": {"type": "boolean"},
        "synced_files_count": {"type": "integer"},
        "summary": {"type": "string"},
    },
    "required": ["analyze_passed", "tests_passed", "synced_files_count", "summary"],
}

# ---------------------------------------------------------------------------
# Phase 1: Parallel Read-Only Apple HIG Audit
# ---------------------------------------------------------------------------
phase("Phase 1: Parallel Apple HIG Audit")
log("Launching 4 concurrent read-only Apple HIG auditors...")

audit_targets = [
    (
        "Theme, Motion & Scroll Auditor",
        "theme_motion",
        [
            f"{ROOT}/desktop/apps/client/lib/ui/app_theme.dart",
            f"{ROOT}/desktop/apps/client/lib/ui/app_motion.dart",
            f"{ROOT}/desktop/apps/client/lib/main.dart",
            f"{ROOT}/desktop/apps/client/test/app_theme_mode_test.dart",
            f"{ROOT}/desktop/apps/client/test/wallpaper_test.dart",
        ],
    ),
    (
        "Navigation, Search & Controls Auditor",
        "nav_search",
        [
            f"{ROOT}/desktop/apps/client/lib/ui/home_sidebar.dart",
            f"{ROOT}/desktop/apps/client/lib/ui/host_search_field.dart",
            f"{ROOT}/desktop/apps/client/lib/ui/workspace_controls.dart",
            f"{ROOT}/desktop/apps/client/lib/ui/home_add_sharing_row.dart",
            f"{ROOT}/desktop/apps/client/test/home_add_sharing_row_test.dart",
        ],
    ),
    (
        "Host Cards & Settings Auditor",
        "cards_settings",
        [
            f"{ROOT}/desktop/apps/client/lib/ui/host_card_layout.dart",
            f"{ROOT}/desktop/apps/client/lib/ui/settings_scaffold.dart",
            f"{ROOT}/desktop/apps/client/lib/ui/locked_workspace_screen.dart",
        ],
    ),
    (
        "iOS & macOS Native Runner Auditor",
        "native_runners",
        [
            f"{ROOT}/ios/apps/client/ios/Runner/Info.plist",
            f"{ROOT}/ios/apps/client/ios/Runner/AppDelegate.swift",
            f"{ROOT}/desktop/apps/client/macos/Runner/MainFlutterWindow.swift",
        ],
    ),
]

audits = await parallel(
    audit_targets,
    lambda item: agent(
        prompt=(
            f"你是 Apple HIG 架构审计专家（{item[0]}）。\n"
            f"请先阅读规范清单 {CHECKLIST}，然后只读检查以下文件（严禁修改任何文件）：\n"
            + "\n".join(f"- {p}" for p in item[2])
            + "\n也可以 grep `desktop/apps/client/test/` 中针对这些文件的测试断言。"
            "\n请输出最多 6 条最关键的 Apple 原生规范升级点（findings）以及必须遵守的测试不变量（test_invariants）。"
        ),
        schema=AUDIT_SCHEMA,
        role=item[0],
    ),
)

audit_by_domain = {a["domain"]: a for a in audits}
for a in audits:
    log(f"[{a['domain']}] {len(a['findings'])} findings, {len(a['test_invariants'])} invariants")

# ---------------------------------------------------------------------------
# Phase 2: Apple HIG Foundation Primitives (`apple_hig.dart`, `app_theme.dart`, `main.dart`)
# ---------------------------------------------------------------------------
phase("Phase 2: Apple HIG Foundation")
log("Building Apple HIG primitives, Squircle borders, BouncingScrollPhysics, and Switch/NoSplash theme...")

foundation_audit_json = json.dumps(audit_by_domain.get("theme_motion", {}), ensure_ascii=False, indent=2)

foundation_result = await agent(
    prompt=f"""你是 Apple HIG 基础架构工程师。请阅读 {CHECKLIST} 以及 Phase 1 审计结论：
{foundation_audit_json}

请仅在 `{ROOT}/desktop/apps/client/` 中创建/修改以下 3 个文件（不要修改其他文件，也不要运行 git commit）：

1. **新建 `{ROOT}/desktop/apps/client/lib/ui/apple_hig.dart`**：
   - 提供 `bool isApplePlatform(TargetPlatform platform) => platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;`
   - 提供 `bool isAppleContext(BuildContext context) => isApplePlatform(Theme.of(context).platform);`
   - 提供 `OutlinedBorder appleSquircleBorder(BorderRadiusGeometry borderRadius, {{TargetPlatform? platform, BorderSide side = BorderSide.none}})`：
     当 `platform == null || isApplePlatform(platform)` 时返回 `RoundedSuperellipseBorder(borderRadius: borderRadius, side: side)`，否则返回 `RoundedRectangleBorder(borderRadius: borderRadius, side: side)`。
   - 提供 `double appleHairlineWidth(BuildContext context)`：在高分屏返回精细分割线宽度（如 `1.0 / MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0)`，即 Retina 屏 0.5pt、普通屏 1.0pt）。
   - 提供 `abstract final class AppleHaptics`：
     - `static void selection(BuildContext context)`：仅当 `!kIsWeb && Theme.of(context).platform == TargetPlatform.iOS` 时安全调用 `HapticFeedback.selectionClick()`（捕获任何异常避免测试报错）。
     - `static void light(BuildContext context)`：仅当 `!kIsWeb && Theme.of(context).platform == TargetPlatform.iOS` 时安全调用 `HapticFeedback.lightImpact()`。
   - 提供 `class AppleScrollBehavior extends MaterialScrollBehavior`：
     - 重写 `getScrollPhysics(BuildContext context)`：当 `isApplePlatform(getPlatform(context))` 时返回 `const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics())`，否则调用 `super.getScrollPhysics(context)`。
     - 重写 `buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details)`：当 `isApplePlatform(getPlatform(context))` 时直接返回 `child`（彻底禁用 Android 边缘泛光/拉伸指示器）。

2. **升级 `{ROOT}/desktop/apps/client/lib/ui/app_theme.dart`**：
   - 导入 `apple_hig.dart`。
   - 在 `buildAppTheme` 中检测 `final apple = isApplePlatform(effectivePlatform);`（其中 `effectivePlatform = platform ?? defaultTargetPlatform`）。
   - 当 `apple` 为 `true` 时：
     - 设置 `splashFactory: NoSplash.splashFactory`、`splashColor: Colors.transparent`，保留柔和细腻的 `highlightColor` 与 `hoverColor`（彻底告别 Android Material 水波纹）。
     - 将 `chipTheme`、`textButtonTheme`、`outlinedButtonTheme`、`filledButtonTheme`、`cardTheme`、`dialogTheme`、`popupMenuTheme`、`inputDecorationTheme`（若边框为 `OutlineInputBorder` 保持兼容，其他 `OutlinedBorder` 全部使用 `appleSquircleBorder(..., platform: effectivePlatform)`）升级为连续曲率超椭圆圆角！
     - 为 `popupMenuTheme` 增加柔和立体阴影 `elevation: apple ? 10 : 6`、`shadowColor: Colors.black.withValues(alpha: dark ? 0.45 : 0.14)`。
     - 新增 Apple 原生质感 `switchTheme: apple ? SwitchThemeData(...) : null`：去除 M3 粗黑轨道描边（`trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent)`、`trackOutlineWidth: const WidgetStatePropertyAll(0)`），选中轨道 `p.accent`、未选中轨道 `p.surfaceSoft`，滑块 `thumbColor` 选中态 `Colors.white`、未选中态 `dark ? const Color(0xFFD5E2E0) : Colors.white`。
   - **严格遵守红线**：绝不改变任何现有 `AppColors` / `AppPalette` 色值常量、`scaffoldBackgroundColor`、`cardTheme.color` 或 `tooltipTheme` 背景亮度，确保 `app_theme_mode_test.dart`、`terminal_color_theme_test.dart`、`wallpaper_test.dart` 100% 通过！

3. **升级 `{ROOT}/desktop/apps/client/lib/main.dart`**：
   - 查找根级 `MaterialApp`（或 `MaterialApp.router`），查看是否设置了 `scrollBehavior`。如果尚未设置自定义 `scrollBehavior`（或可以在保留原鼠标/触控拖拽能力的基础上升级），配置 `scrollBehavior: const AppleScrollBehavior()`（注意保留桌面鼠标滚轮/触控板滚动支持：`dragDevices` 保持默认即可）。
   - 注意严禁改动 `main.dart` 的业务启动参数、窗口注册与测试入口签名。

完成后返回修改摘要。""",
    schema=SLICE_SCHEMA,
    role="Apple HIG Foundation Engineer",
)
log(f"Foundation complete: {foundation_result['summary']}")

# ---------------------------------------------------------------------------
# Phase 3: Parallel Strictly-Partitioned Slice Refactoring (Disjoint Files)
# ---------------------------------------------------------------------------
phase("Phase 3: Parallel UI & Native Runner Refactoring")
log("Running 3 parallel refactoring agents on strictly disjoint file sets...")

slice_specs = [
    (
        "Slice A: Navigation, Search & Controls",
        "nav_search",
        f"""你是 Apple HIG 导航与控件重构专家。请阅读 {CHECKLIST}、已创建的 `{ROOT}/desktop/apps/client/lib/ui/apple_hig.dart`，以及审计记录：
{json.dumps(audit_by_domain.get("nav_search", {}), ensure_ascii=False, indent=2)}

**严格文件边界（你只能编辑以下 4 个文件，严禁触碰任何其他文件，不要运行 flutter 命令以免与并行任务争抢锁）**：
1. `{ROOT}/desktop/apps/client/lib/ui/home_sidebar.dart`
2. `{ROOT}/desktop/apps/client/lib/ui/host_search_field.dart`
3. `{ROOT}/desktop/apps/client/lib/ui/workspace_controls.dart`
4. `{ROOT}/desktop/apps/client/lib/ui/home_add_sharing_row.dart`

重构要求：
- **`home_sidebar.dart`**：
  - 保留 `HomeSidebar.widthFor`（200 / 72 / 52）、所有 `ValueKey`、`Semantics` 与 `Icons.*` 不变！
  - 在 Apple 平台（`isAppleContext(context)`）下，侧边栏右侧分割线使用精细发丝线或柔和渐变感边框，导航项选中胶囊升级为 `appleSquircleBorder(BorderRadius.circular(10), ...)`（通过 `ShapeDecoration` 替代生硬直角或普通圆角），点击切换目标时调用 `AppleHaptics.selection(context)`。
- **`host_search_field.dart`**：
  - 保留所有 `ValueKey`、控制器、快捷键、提交回调与测试合约不变！
  - 在 Apple 平台打造 Apple Spotlight / `UISearchTextField` 原生质感：柔和填充槽、圆润连续圆角、聚焦时细腻的半透明主题色光晕/细边，输入非空时的清除按钮圆润精致。
- **`workspace_controls.dart` & `home_add_sharing_row.dart`**：
  - 保留所有 `ValueKey`（如 `${{idPrefix}}_home_add`、`${{idPrefix}}_home_one_click_termius` 等）与菜单动作顺序不变！
  - 在 Apple 平台将按钮与菜单触发容器升级为 `ShapeDecoration(shape: appleSquircleBorder(...))` 连续曲率超椭圆圆角，点击主按钮或菜单触发时在 iOS 上调用 `AppleHaptics.selection(context)` / `AppleHaptics.light(context)`。""",
    ),
    (
        "Slice B: Host Cards & iOS Grouped Settings",
        "cards_settings",
        f"""你是 Apple HIG 卡片与设置体验重构专家。请阅读 {CHECKLIST}、已创建的 `{ROOT}/desktop/apps/client/lib/ui/apple_hig.dart`，以及审计记录：
{json.dumps(audit_by_domain.get("cards_settings", {}), ensure_ascii=False, indent=2)}

**严格文件边界（你只能编辑以下 3 个文件，严禁触碰任何其他文件，不要运行 flutter 命令以免与并行任务争抢锁）**：
1. `{ROOT}/desktop/apps/client/lib/ui/host_card_layout.dart`
2. `{ROOT}/desktop/apps/client/lib/ui/settings_scaffold.dart`
3. `{ROOT}/desktop/apps/client/lib/ui/locked_workspace_screen.dart`

重构要求：
- **`host_card_layout.dart`**：
  - 保留所有对外类/方法签名、`ValueKey`、文本展示与现有的 `Icons.*` 常量不变！
  - 在 Apple 平台（`isAppleContext(context)`）下，将主机卡片外框升级为连续曲率超椭圆圆角（`appleSquircleBorder(BorderRadius.circular(12), side: ...)`），优化悬停/按压态微光层次与协议徽标圆角底座质感。
- **`settings_scaffold.dart`**：
  - 保留所有 `ValueKey`（如 `settings_page_${{section.id}}` 等）、`SettingsScaffold.selectSection` 静态方法、`IndexedStack` 保活机制与窄屏/宽屏自适应阈值不变！
  - 在切换设置分类（`_select`）时调用 `AppleHaptics.selection(context)`。
  - 优化分类列表项在 Apple 平台下的视觉呈现：左侧图标放入精致的 `28x28` 超椭圆主题色柔和底座（类似 iOS / macOS 系统“设置”App 的圆角图标块），选中态使用超椭圆胶囊高亮，窄屏选择器更具原生 iOS 分组栏质感。
- **`locked_workspace_screen.dart`**：
  - 保留所有 `ValueKey` 与解锁逻辑不变，在 Apple 平台将解锁面板卡片升级为超椭圆连续圆角与细腻边框阴影，展现原生 Apple 密码解锁面板的沉稳质感。""",
    ),
    (
        "Slice C: iOS ProMotion & macOS Native Window Polish",
        "native_runners",
        f"""你是 Apple 原生宿主工程专家（Swift / Info.plist）。请阅读 {CHECKLIST} 以及审计记录：
{json.dumps(audit_by_domain.get("native_runners", {}), ensure_ascii=False, indent=2)}

**严格文件边界（你只能编辑以下原生宿主文件，严禁触碰 Dart 文件）**：
1. `{ROOT}/ios/apps/client/ios/Runner/Info.plist`
2. `{ROOT}/desktop/apps/client/macos/Runner/MainFlutterWindow.swift`

重构要求：
- **`{ROOT}/ios/apps/client/ios/Runner/Info.plist`**：
  - 增加 `<key>CADisableMinimumFrameDurationOnPhone</key><true/>`，在 iPhone Air / iPhone Pro 上开启满血 120Hz ProMotion 高帧率渲染！
  - 确保 `<key>UIViewControllerBasedStatusBarAppearance</key><true/>` 存在且 plist 语法严格合法（可用 `/usr/bin/plutil -lint` 校验）。
- **`{ROOT}/desktop/apps/client/macos/Runner/MainFlutterWindow.swift`**：
  - 保留所有现有 MethodChannel（`atermius/fullscreen`、`atermius/window_chrome`、`atermius/window_geometry`、`atermius/import_picker`）、交通灯边距计算和 5 个 `@_cdecl` C ABI 导出函数完全不变！
  - 在 `awakeFromNib()` 中为窗口设置初始深色底色 `self.backgroundColor = NSColor(srgbRed: 0x0B / 255.0, green: 0x0F / 255.0, blue: 0x10 / 255.0, alpha: 1.0)`（与 Obsidian Emerald 暗色画布 `#0B0F10` 精确一致），消除 macOS 窗口冷启动或新建终端窗口时的首帧白闪，并设置 `self.titlebarSeparatorStyle = .none`（macOS 11+）使一体化顶栏与内容区无缝融合！""",
    ),
]

slice_results = await parallel(
    slice_specs,
    lambda spec: agent(
        prompt=spec[2],
        schema=SLICE_SCHEMA,
        role=spec[0],
    ),
)

for res in slice_results:
    log(f"[{res['slice']}] Modified {len(res['modified_files'])} file(s): {res['summary']}")

# ---------------------------------------------------------------------------
# Phase 4: Conformance Tests, Verification Gate & Cross-Repo Sync
# ---------------------------------------------------------------------------
phase("Phase 4: Verification Gate & Cross-Repo Sync")
log("Writing Apple HIG conformance tests, running analyze + widget test suites, and syncing desktop -> ios...")

gate_result = await agent(
    prompt=f"""你是 Apple 原生规范质量门禁与多仓同步总控工程师。
工具链环境变量（每次执行 flutter/dart 命令都必须先 export）：
`export PATH="{TOOL_PATH}"`

请按顺序完成以下步骤：

1. **编写 `{ROOT}/desktop/apps/client/test/apple_hig_conformance_test.dart`**：
   全面测试本次 Apple HIG 原生重构的核心特性：
   - 验证 `buildAppTheme(platform: TargetPlatform.iOS)` 与 `buildAppTheme(platform: TargetPlatform.macOS)`：
     - `splashFactory` 为 `NoSplash.splashFactory` 且 `splashColor == Colors.transparent`；
     - `cardTheme.shape`、`dialogTheme.shape`、`popupMenuTheme.shape` 为 `RoundedSuperellipseBorder`；
     - `switchTheme.trackOutlineWidth?.resolve({{}})` 为 `0`；
   - 验证非 Apple 平台（`TargetPlatform.android` / `TargetPlatform.windows`）保持原有 `RoundedRectangleBorder` 与默认水波纹策略不受影响；
   - 验证 `AppleScrollBehavior` 在 `TargetPlatform.iOS` 与 `TargetPlatform.macOS` 下返回 `BouncingScrollPhysics`，且 `buildOverscrollIndicator` 直接返回原 `child`（不包 `GlowingOverscrollIndicator`）；
   - 验证 `{ROOT}/ios/apps/client/ios/Runner/Info.plist` 中包含 `CADisableMinimumFrameDurationOnPhone`。

2. **在 `{ROOT}/desktop/apps/client` 执行静态分析与全套回归测试**：
   - 运行 `flutter analyze --no-fatal-infos --no-fatal-warnings`（必须零 error；检查本次改动文件是否有新增 warning 并清理干净）。
   - 运行核心测试套件：
     `flutter test test/apple_hig_conformance_test.dart test/app_theme_mode_test.dart test/terminal_color_theme_test.dart test/wallpaper_test.dart test/motion_frames_capture_test.dart test/home_add_sharing_row_test.dart test/termius_local_one_click_test.dart test/macos_termius_and_ui_test.dart test/workspace_tab_drag_test.dart`
   - 如有任何回归测试文件（例如 `test/home_sidebar_test.dart`、`test/settings_scaffold_test.dart`、`test/host_search_field_test.dart` 等如果存在，先 `ls test/` 查一下并一并跑通！）。若发现任何编译或断言问题，立即定位修复，直到 100% 通过！

3. **同步共享客户端文件至 `{ROOT}/ios/apps/client` 并双重验证**：
   - 将 `{ROOT}/desktop/apps/client` 中本次新增和修改的所有共享 Dart 文件（`lib/main.dart`、`lib/ui/apple_hig.dart`、`lib/ui/app_theme.dart`、`lib/ui/home_sidebar.dart`、`lib/ui/host_search_field.dart`、`lib/ui/workspace_controls.dart`、`lib/ui/home_add_sharing_row.dart`、`lib/ui/host_card_layout.dart`、`lib/ui/settings_scaffold.dart`、`lib/ui/locked_workspace_screen.dart` 及 `test/apple_hig_conformance_test.dart`）同步复制到 `{ROOT}/ios/apps/client` 对应路径（注意 `apple_hig_conformance_test.dart` 里读取 `Info.plist` 时使用相对仓库路径 `ios/Runner/Info.plist` 兼容双仓或检查存在性）。
   - 运行 `/usr/bin/plutil -lint {ROOT}/ios/apps/client/ios/Runner/Info.plist`。
   - 在 `{ROOT}/ios/apps/client` 运行 `flutter analyze --no-fatal-infos --no-fatal-warnings` 与 `flutter test test/apple_hig_conformance_test.dart test/app_theme_mode_test.dart` 验证双仓 100% 绿灯！

不要执行 `git commit` 或 `git push`（交由主协调器统一构建真机包与提交）。""",
    schema=GATE_SCHEMA,
    role="Verification & Sync Gate",
)

log(f"Gate complete: {gate_result}")
print(json.dumps({
    "foundation": foundation_result,
    "slices": slice_results,
    "gate": gate_result,
}, ensure_ascii=False, indent=2))
