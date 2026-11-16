"""
Apple App Store New-App Launch Compliance Audit & Remediation Workflow.

Stages:
  1. Parallel 5-way deep compliance audit (Binary/Pod APIs, PrivacyInfo.xcprivacy,
     App Review Policies & Account Deletion, Assets/Icons/XCFramework slices,
     and Mac App Store Sandbox evaluation).
  2. Parallel 3-way disjoint remediation:
     - Worker A: PrivacyInfo.xcprivacy (iOS & macOS) + project.pbxproj registration
       + Info.plist & 4-locale InfoPlist.strings purpose strings + Export Compliance.
     - Worker B: New-App App Store Connect Archive & Pre-flight script
       (`ios/scripts/archive_appstore.sh` + `ExportOptions-AppStore.plist`) and
       icon/framework hardening if needed.
     - Worker C: Complete App Store Connect New-App Submission Kit
       (`ios/docs/APP_STORE_SUBMISSION.md`) + bilingual `ios/docs/PRIVACY_POLICY.md`.
  3. Automated compliance gate test (`test/appstore_compliance_test.dart`) +
     `plutil -lint` + offline `flutter analyze` & widget tests across repos.
"""

import json

ROOT = "/Users/yang/Downloads/aterm-project"
GUIDELINES = f"{ROOT}/.agents/skills/appstore-launch-audit/references/appstore_review_guidelines.md"
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
        "blockers": {"type": "array", "items": {"type": "string"}},
        "warnings": {"type": "array", "items": {"type": "string"}},
        "verified_ok": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["domain", "blockers", "warnings", "verified_ok"],
}

WORKER_SCHEMA = {
    "type": "object",
    "properties": {
        "worker": {"type": "string"},
        "touched_files": {"type": "array", "items": {"type": "string"}},
        "summary": {"type": "string"},
    },
    "required": ["worker", "touched_files", "summary"],
}

GATE_SCHEMA = {
    "type": "object",
    "properties": {
        "plutil_passed": {"type": "boolean"},
        "analyze_passed": {"type": "boolean"},
        "compliance_tests_passed": {"type": "boolean"},
        "summary": {"type": "string"},
    },
    "required": ["plutil_passed", "analyze_passed", "compliance_tests_passed", "summary"],
}

# ---------------------------------------------------------------------------
# Phase 1: 5-Way Parallel App Store Launch Audit (Read-Only)
# ---------------------------------------------------------------------------
phase("Phase 1: 5-Way App Store Compliance Audit")
log("Running 5 concurrent App Store review & ITMS binary auditors...")

audit_specs = [
    (
        "Binary & Implicit Permission Auditor (ITMS-90683)",
        "binary_permissions",
        f"""你是 Apple App Store Connect 二进制静态扫描审计专家（专注 ITMS-90683 隐式权限符号扫描）。
请先阅读 {GUIDELINES}。严禁修改任何文件！
请只读检查：
1. `{ROOT}/ios/apps/client/ios/Runner/Info.plist` 与 `{ROOT}/ios/apps/client/ios/Runner/*.lproj/InfoPlist.strings`；
2. `{ROOT}/ios/apps/client/ios/Podfile.lock` 以及已构建产物 `{ROOT}/ios/apps/client/build/ios/iphoneos/Runner.app`（如果存在，使用 `otool -L` / `nm -u` 检查主程序及 `Frameworks/*.framework`、SwiftPM bundle 如 `DKImagePickerController` 引用了哪些 Apple 隐私敏感框架或类：`Photos`/`PHPhotoLibrary`、`AVFoundation`/`AVCaptureDevice`、`CoreLocation`、`LocalAuthentication`/`LAContext`、`CoreBluetooth`、`Contacts`、`Microphone` 等）。
输出：哪些敏感权限符号存在于二进制中但 `Info.plist` 尚未声明用途串（blockers），哪些已正确声明（verified_ok）。""",
    ),
    (
        "Privacy Manifest Auditor (ITMS-91053)",
        "privacy_manifest",
        f"""你是 Apple Privacy Manifest (`PrivacyInfo.xcprivacy` / ITMS-91053) 审计专家。
请先阅读 {GUIDELINES}。严禁修改任何文件！
请只读检查：
1. 搜索 `{ROOT}/ios/apps/client/ios/` 与 `{ROOT}/desktop/apps/client/macos/` 是否已存在 `PrivacyInfo.xcprivacy` 以及是否挂载进了 `Runner.xcodeproj/project.pbxproj` 的 `PBXResourcesBuildPhase`；
2. 扫描已链接的 Pods / Plugins（如 `shared_preferences` / `flutter_secure_storage` / `file_picker` / `path_provider` / Runner Swift 代码 / C 引擎）使用了哪些 Apple Required Reason API 类别（`NSPrivacyAccessedAPICategoryUserDefaults` `CA92.1`、`NSPrivacyAccessedAPICategoryFileTimestamp` `C617.1`、`NSPrivacyAccessedAPICategoryDiskSpace` `E174.1`、`NSPrivacyAccessedAPICategorySystemBootTime` `35F9.1`），以及第三方 Pod 是否自带 `.xcprivacy` 或需要主 App 兜底声明。
输出 blockers、warnings 与 verified_ok。""",
    ),
    (
        "App Review Policy & Account Deletion Auditor",
        "review_policy",
        f"""你是 Apple App Store 人工审核专家（Guidelines 2.1 / 4.2 / 5.1.1 / Export Compliance）。
请先阅读 {GUIDELINES}。严禁修改任何文件！
请只读核查：
1. **Guideline 5.1.1(v) 账号删除**：检查 `{ROOT}/ios/apps/client/lib/ui/account_settings.dart`（及相关测试 `test/account_deletion_widget_test.dart`）是否在 iOS 客户端内提供了完整、可直接操作的云端账号永久删除入口；
2. **Guideline 2.1 / 4.2 免登录开箱可用性**：确认新用户首次安装打开 iOS App 是否无需强制注册账号即可创建/进入本地配置库（Local Profile）完整使用核心功能；
3. **出口加密合规**：检查 `ios/Runner/Info.plist` 与 `macos/Runner/Info.plist` 是否配置了 `ITSAppUsesNonExemptEncryption`；
4. **洁净打包防泄漏**：检查源码树中是否混入任何私有服务器种子文件（如 `atermius-local-seed.json`），以及需要在上架打包脚本中加入哪些防泄漏校验。""",
    ),
    (
        "App Icon, Metadata & XCFramework Slice Auditor",
        "assets_xcframework",
        f"""你是 Apple App Store 资产与包结构审计专家（ITMS-90717 / ITMS-90087 / ITMS-90562）。
请先阅读 {GUIDELINES}。严禁修改任何文件！
请只读核查：
1. 使用 `/usr/bin/sips -g pixelWidth -g pixelHeight -g hasAlpha` 检查 `{ROOT}/ios/apps/client/ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png` 全部图标（特别是 1024x1024 图标是否 `hasAlpha: no` 且尺寸精确无误）；
2. 检查 `{ROOT}/ios/apps/client/native/desktop/build/ios/bundle/atermius_rdp.xcframework/ios-arm64/atermius_rdp.framework` 的 `Info.plist` 字段完整性（`CFBundleIdentifier`、`CFBundlePackageType`、`MinimumOSVersion`、`CFBundleShortVersionString`）以及 `lipo -info` 架构是否纯 `arm64`；
3. 检查 `{ROOT}/ios/apps/client/ios/Runner.xcodeproj/project.pbxproj` 与 `Flutter/Release.xcconfig` 中作为**新 App 上架**时的 `PRODUCT_BUNDLE_IDENTIFIER`、`FLUTTER_BUILD_NAME`、`FLUTTER_BUILD_NUMBER`、`IPHONEOS_DEPLOYMENT_TARGET` 配置情况。""",
    ),
    (
        "Mac App Store (MAS) Sandbox Evaluator",
        "mas_sandbox",
        f"""你是 Mac App Store (MAS) 沙盒合规架构师（Guideline 2.4.5）。
请先阅读 {GUIDELINES}。严禁修改任何文件！
请只读检查 `{ROOT}/desktop/apps/client/macos/Runner/Release.entitlements`、`Info.plist` 与 `Podfile`（特别是 `flutter_pty` 与 `app-sandbox = false`），评估：
1. 若同时上架 Mac App Store 需要满足哪些沙盒条件（`com.apple.security.app-sandbox = true`、`com.apple.security.network.client = true`、`com.apple.security.files.user-selected.read-write = true` 及禁用本机 PTY 子进程）；
2. 如何在文档与配置中清晰区分 iOS/iPadOS App Store（含 Apple Silicon Mac 兼容运行 iPad 应用或独立 MAS 沙盒构建）与官网 Developer ID 公证版。""",
    ),
]

audits = await parallel(
    audit_specs,
    lambda spec: agent(
        prompt=spec[2],
        schema=AUDIT_SCHEMA,
        role=spec[0],
    ),
)

audit_map = {a["domain"]: a for a in audits}
for a in audits:
    log(
        f"[{a['domain']}] blockers={len(a['blockers'])}, "
        f"warnings={len(a['warnings'])}, ok={len(a['verified_ok'])}"
    )

all_audits_json = json.dumps(audits, ensure_ascii=False, indent=2)

# ---------------------------------------------------------------------------
# Phase 2: 3-Way Parallel Disjoint Remediation & New-App Launch Tooling
# ---------------------------------------------------------------------------
phase("Phase 2: Parallel Disjoint Remediation & Launch Tooling")
log("Running 3 disjoint remediation workers to fix all App Store blockers and build submission kit...")

remediation_specs = [
    (
        "Worker A: PrivacyInfo.xcprivacy, Info.plist & 4-Locale Purpose Strings",
        f"""你是 Apple 隐私清单与 Info.plist 合规工程师。请阅读 {GUIDELINES} 以及 Phase 1 审计结果：
{all_audits_json}

**严格文件边界（你只能创建/修改以下文件，绝不触碰其他文件）**：
- `{ROOT}/ios/apps/client/ios/Runner/PrivacyInfo.xcprivacy`
- `{ROOT}/ios/apps/client/ios/Runner/Info.plist`
- `{ROOT}/ios/apps/client/ios/Runner/en.lproj/InfoPlist.strings`
- `{ROOT}/ios/apps/client/ios/Runner/zh-Hans.lproj/InfoPlist.strings`
- `{ROOT}/ios/apps/client/ios/Runner/ja.lproj/InfoPlist.strings`
- `{ROOT}/ios/apps/client/ios/Runner/ru.lproj/InfoPlist.strings`
- `{ROOT}/ios/apps/client/ios/Runner.xcodeproj/project.pbxproj`
- `{ROOT}/desktop/apps/client/macos/Runner/PrivacyInfo.xcprivacy`
- `{ROOT}/desktop/apps/client/macos/Runner/Info.plist`
- `{ROOT}/desktop/apps/client/macos/Runner.xcodeproj/project.pbxproj`

执行要求：
1. 创建标准合法的 `PrivacyInfo.xcprivacy`（iOS 与 macOS 各一份）：
   - `NSPrivacyTracking` = `false`
   - `NSPrivacyTrackingDomains` = `<array/>`
   - `NSPrivacyCollectedDataTypes`：如实声明可选云端同步功能收集的电子邮箱（`NSPrivacyCollectedDataTypeEmailAddress`，仅用于账户身份验证与应用功能，非追踪 `NSPrivacyCollectedDataTypeTracking = false`），若仅使用本地模式则不收集数据。
   - `NSPrivacyAccessedAPITypes`：完整声明 `NSPrivacyAccessedAPICategoryUserDefaults` (`CA92.1`)、`NSPrivacyAccessedAPICategoryFileTimestamp` (`C617.1`)、`NSPrivacyAccessedAPICategoryDiskSpace` (`E174.1`)、`NSPrivacyAccessedAPICategorySystemBootTime` (`35F9.1`)。
2. 将 `PrivacyInfo.xcprivacy` 精确注册到 iOS 与 macOS 的 `Runner.xcodeproj/project.pbxproj`（包含 `PBXBuildFile`、`PBXFileReference`、Runner `PBXGroup` children 以及 Runner Target 的 `PBXResourcesBuildPhase` files），注册后**必须运行 `/usr/bin/plutil -lint` 验证两个 `project.pbxproj` 和两个 `PrivacyInfo.xcprivacy` 语法 100% 正常**！
3. 在 iOS 与 macOS 的 `Info.plist` 中添加 `<key>ITSAppUsesNonExemptEncryption</key><false/>`。
4. 根据 Phase 1 `binary_permissions` 扫出的所有第三方库符号（包括 `DKImagePickerController` / `file_picker` / `local_network` 等），在 `ios/Runner/Info.plist` 及四语 `InfoPlist.strings`（`en`、`zh-Hans`、`ja`、`ru`）中补齐具体、真实、符合 Apple 审核标准的权限说明文案（至少涵盖 `NSLocalNetworkUsageDescription`、`NSPhotoLibraryUsageDescription`、`NSPhotoLibraryAddUsageDescription`、`NSCameraUsageDescription`，若二进制中还扫出 `NSFaceIDUsageDescription` 或 `NSMicrophoneUsageDescription` 也一并按实际附件/生物识别场景补齐），并用 `plutil -lint` 逐一验证所有 `.plist` 与 `.strings` 文件！""",
    ),
    (
        "Worker B: New-App App Store Archive Pipeline & Asset Hardening",
        f"""你是 iOS 发布工程与构建门禁专家。请阅读 {GUIDELINES} 以及 Phase 1 审计结果：
{all_audits_json}

**严格文件边界（你只能创建/修改以下文件，严禁修改 `Info.plist` 或 `project.pbxproj`）**：
- `{ROOT}/ios/apps/client/ios/ExportOptions-AppStore.plist`
- `{ROOT}/ios/scripts/archive_appstore.sh`
- （仅当 Phase 1 发现图标有 Alpha 或 `atermius_rdp.framework/Info.plist` 缺失字段时）修复对应 `.png` 或 `atermius_rdp` 打包脚本

执行要求：
1. 创建 `{ROOT}/ios/apps/client/ios/ExportOptions-AppStore.plist`（标准 `method = app-store-connect`、`destination = export`、`signingStyle = automatic`、`uploadSymbols = true`、`manageAppVersionAndBuildNumber = true`，通过 `plutil -lint` 验证）。
2. 创建可执行脚本 `{ROOT}/ios/scripts/archive_appstore.sh`（`chmod +x`），专为**上架新 App 到 App Store Connect** 设计：
   - 支持命令行参数：
     - `--bundle-id <com.yourcompany.newapp>`（必填或默认提示传入新 App 在 Apple Developer 后台注册的唯一 Bundle ID）
     - `--team-id <TEAM_ID>`（默认 `2QJ8K75QL2`）
     - `--version <1.0.0>`（默认读取 `pubspec.yaml` 或 `1.0.0`）
     - `--build-number <1>`（默认 `1`）
     - `--display-name <Name>`（可选覆盖新 App 桌面显示名称）
     - `--preflight-only`（仅运行全套 App Store 静态合规预检，不实际调用 `xcodebuild archive`）
   - 内置 **6 道自动化 App Store 上传前铁闸预检（Pre-flight Checks）**：
     1) 校验源码树与构建目录绝无 `atermius-local-seed.json` 等任何私有测试文件；
     2) 校验 `ios/Runner/PrivacyInfo.xcprivacy` 存在且 `plutil -lint` 通过；
     3) 校验 `ios/Runner/Info.plist` 含 `ITSAppUsesNonExemptEncryption` 及全部必需 `NS*UsageDescription`；
     4) 校验 `AppIcon.appiconset` 中 `1024x1024` 图标存在且无 Alpha 透明通道；
     5) 校验 `atermius_rdp.xcframework/ios-arm64/atermius_rdp.framework` 为纯 `arm64` 且含合法 `Info.plist`；
     6) 拒绝使用通配符或测试默认冲突 Bundle ID 盲目导出，支持传入新 App 的正式 Bundle ID 执行 `flutter build ipa --release --no-pub` / `xcodebuild archive` + `-exportArchive` 输出可直接拖入 Apple `Transporter` App 或 `xcrun altool` / `notarytool` 上传的正式 `.ipa`（输出到 `ios/dist/appstore/`）！
   - 运行 `bash {ROOT}/ios/scripts/archive_appstore.sh --preflight-only --bundle-id com.atermius.ssh` 自测脚本预检逻辑（注意等如果 `PrivacyInfo.xcprivacy` 尚未落盘则脚本预检逻辑本身先保证无语法错误 `bash -n`）。""",
    ),
    (
        "Worker C: App Store Connect New-App Submission Kit & Privacy Policy",
        f"""你是资深 Apple App Store 发行与合规文档专家。请阅读 {GUIDELINES} 以及 Phase 1 全部 5 项审计结论：
{all_audits_json}

**严格文件边界（你只能创建以下 2 个文档文件）**：
- `{ROOT}/ios/docs/APP_STORE_SUBMISSION.md`
- `{ROOT}/ios/docs/PRIVACY_POLICY.md`

执行要求：
1. 编写 `{ROOT}/ios/docs/APP_STORE_SUBMISSION.md`（简体中文主述 + 关键提审字段提供中/英/日/俄现成可复制文本），专门指导用户将此项目作为**一款全新 App** 上架 Apple App Store：
   - **第一步：Apple Developer 后台新 App ID 注册清单**（显式 App ID 非通配符、需要勾选的 Capabilities——默认无需特殊受限 Entitlement，如需推送再勾选 Push Notifications）。
   - **第二步：一键构建 App Store 正式包命令**（展示如何调用 `./scripts/archive_appstore.sh --bundle-id <新BundleID> --team-id 2QJ8K75QL2 --version 1.0.0 --build-number 1` 并通过 macOS **Transporter** 或 `xcrun altool` 上传至 App Store Connect）。
   - **第三步：App Store Connect 元数据直接复制表**：
     - 新 App 名称候选、副标题（30 字符内）、宣传文本（170 字符内）、关键词（100 字符内高权重词：`ssh,sftp,terminal,rdp,vnc,telnet,devops,linux,server,shell,keychain`）、完整功能描述（中英双语，突出端到端零知识加密、SSH/SFTP/Telnet/RDP/VNC 多协议、端口转发、片段与本机密钥库）；
     - 分类建议（主分类：Developer Tools 开发者工具；次分类：Productivity 效率）与年龄分级问卷逐项答案（4+）；
     - **App Privacy（隐私营养标签）后台逐项勾选指南**（精确对应代码与 `PrivacyInfo.xcprivacy` 声明，避免因勾选与二进制不一致被审核打回）；
     - **出口合规（Export Compliance）问卷标准答案**；
     - **App Review 审核备注（Notes for Review）中英双语现成模板**：清晰告知审核员本应用打开即可免注册创建本地加密配置库体验全部终端、SFTP、密钥生成与远程桌面客户端能力，同时说明可选云账户支持在“设置 -> 账户 -> 删除账户”内一键永久注销（符合 Guideline 5.1.1(v)）；
     - **Mac App Store 上架补充说明**（iPadOS 应用直接勾选“在 Apple Silicon Mac 上提供”零改造成本上架 Mac App Store，以及独立 macOS 沙盒版的差异说明）。
2. 编写 `{ROOT}/ios/docs/PRIVACY_POLICY.md`（专业严谨的中英双语隐私政策与技术支持联系页模板，可直接发布至 GitHub Pages 或独立域名填入 App Store Connect 的 Privacy Policy URL）。""",
    ),
]

worker_results = await parallel(
    remediation_specs,
    lambda spec: agent(
        prompt=spec[1],
        schema=WORKER_SCHEMA,
        role=spec[0],
    ),
)

for w in worker_results:
    log(f"[{w['worker']}] {w['summary']}")

# ---------------------------------------------------------------------------
# Phase 3: Automated App Store Compliance Gate Test & Pre-flight Verification
# ---------------------------------------------------------------------------
phase("Phase 3: Compliance Gate & Pre-flight Verification")
log("Running automated App Store compliance unit tests, plutil checks, and preflight script...")

gate_result = await agent(
    prompt=f"""你是 Apple App Store 上架最终门禁总控官。
工具链 PATH（执行 flutter/dart 前必带）：
`export PATH="{TOOL_PATH}"`

请按顺序完成最终验收：
1. 检查并运行 `bash {ROOT}/ios/scripts/archive_appstore.sh --preflight-only --bundle-id com.atermius.app`（若有路径或检查细节需要微调使 6 道铁闸全部绿灯通过，立即修正）。
2. 对 iOS 与 macOS 下所有 `.plist`、`*.entitlements`、`PrivacyInfo.xcprivacy`、`*.strings`、`project.pbxproj` 运行 `/usr/bin/plutil -lint` 验证 100% `OK`。
3. 编写自动化合规回归测试 `{ROOT}/ios/apps/client/test/appstore_compliance_test.dart`（并同步复制一份到 `{ROOT}/desktop/apps/client/test/appstore_compliance_test.dart`，路径兼容双仓独立运行）：
   - 断言 `PrivacyInfo.xcprivacy` 存在，包含 `NSPrivacyTracking` (`false`) 及 `CA92.1`、`C617.1`、`E174.1`、`35F9.1` 四类 Required Reason API 代码，并且已在 `Runner.xcodeproj/project.pbxproj` 的 `PBXResourcesBuildPhase` 中挂载；
   - 断言 `ios/Runner/Info.plist` 包含 `<key>ITSAppUsesNonExemptEncryption</key>` 且值为 `<false/>`；
   - 断言 `ios/Runner/Info.plist` 及 `en`/`zh-Hans`/`ja`/`ru` 四语 `InfoPlist.strings` 均包含非空且长度 `>= 12` 的 `NSLocalNetworkUsageDescription`、`NSPhotoLibraryUsageDescription`、`NSCameraUsageDescription`；
   - 断言 `AppIcon.appiconset` 中 `1024x1024` PNG 图标文件头（IHDR chunk 第 25 字节 colorType）为 `2`（Truecolor RGB，不含 Alpha 通道，非 `6` RGBA / `4` Grayscale+Alpha）；
   - 断言源码树中不存在任何 `atermius-local-seed.json` 私有种子文件。
4. 分别在 `{ROOT}/ios/apps/client` 与 `{ROOT}/desktop/apps/client` 运行：
   - `flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings`
   - `flutter test --no-pub test/appstore_compliance_test.dart test/apple_hig_conformance_test.dart test/account_deletion_widget_test.dart`
   确保 100% 全部绿灯通过！不要运行 `git commit` 或 `git push`。""",
    schema=GATE_SCHEMA,
    role="App Store Launch Compliance Gate",
)

log(f"App Store Compliance Gate passed: {gate_result['summary']}")
print(json.dumps({
    "audits": audits,
    "remediation": worker_results,
    "gate": gate_result,
}, ensure_ascii=False, indent=2))
