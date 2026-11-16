---
name: appstore-launch-audit
description: Apple App Store 新 App 上架合规审计与自动整备工作流。用于执行 ITMS 二进制静态扫描（ITMS-90683 隐式敏感权限、ITMS-91053 隐私清单 PrivacyInfo.xcprivacy、ITMS-90087/90562 XCFramework 切片与签名、图标无 Alpha 检查）、出口合规声明、Guideline 5.1.1(v) 账号注销核验、一键 App Store Connect Archive 归档脚本构建及新 App 提审全套物料生成。
---

# Apple App Store 新 App 上架合规审计与整备工作流 (`appstore-launch-audit`)

本技能基于 `run_workflow` 多智能体编排引擎，面向 **作为全新 App 首次提交 Apple App Store（iOS / iPadOS 及 Mac App Store 评估）** 的完整合规闭环：不仅发现拒审风险，还自动补齐工程配置、隐私清单、多语言权限用途说明、App Store 归档导出流水线及提审物料文档，并通过自动化单测锁死合规基线。

## 触发场景

- 准备将应用作为**新 App 首次提交 App Store Connect / TestFlight** 时；
- 引入新的原生插件（CocoaPods / SwiftPM / FFI XCFramework）后排查 `ITMS-90683`、`ITMS-91053`、`ITMS-90087` 等机器秒拒隐患时；
- 用户要求“创建 workflow 审计符合上架 Apple Store 规范”、“上架新 App 准备”或输入 `/appstore-launch-audit` 时。

## 权威审核准则参考

- [references/appstore_review_guidelines.md](references/appstore_review_guidelines.md)

## 一键运行多智能体审计与整备流水线

调用 `run_workflow` 执行 [scripts/appstore_audit_workflow.py](scripts/appstore_audit_workflow.py)：

```python
run_workflow(
    ScriptPath="/Users/yang/Downloads/aterm-project/.agents/skills/appstore-launch-audit/scripts/appstore_audit_workflow.py",
    Description="Apple App Store 新 App 上架 4 阶段多智能体合规审计、自动整备与门禁验证流水线",
)
```

## 工作流四阶段设计

1. **Phase 1 — 5 路并发全方位合规审计 (`parallel` Read-Only Auditors)**
   - **Binary & Pod API Auditor**：使用 `nm` / `otool` / 源码扫描所有第三方 Pod / SwiftPM 包（如 `DKImagePickerController`、`file_picker`、`flutter_secure_storage`）与 `atermius_rdp.framework`，排查未声明的敏感权限符号（相册、相机、麦克风、定位、蓝牙、本地网络）及模拟器残留架构切片。
   - **Privacy Manifest Auditor (`ITMS-91053`)**：扫描主工程与原生插件调用的 Apple Required Reason APIs（`UserDefaults` `CA92.1`、File Timestamp `C617.1`、System Boot Time `35F9.1`、Disk Space `E174.1`），核查 `PrivacyInfo.xcprivacy` 完整性与 Xcode `PBXResourcesBuildPhase` 挂载状态。
   - **App Review Policy Auditor (Guidelines 2.1 / 4.2 / 5.1.1)**：核查新 App 免登录本地模式完整可用性、云端账号应用内删除链路（Guideline `5.1.1(v)`）、出口加密豁免（`ITSAppUsesNonExemptEncryption`）、私有测试种子零残留及开源许可证披露。
   - **Assets, Signing & Metadata Auditor (`ITMS-90022` / `ITMS-90717`)**：校验 1024×1024 App Icon 是否为 24-bit RGB 无 Alpha 通道、LaunchScreen 全尺寸适配、Bundle ID / 版本号参数化与 `atermius_rdp.framework/Info.plist` 规范。
   - **Mac App Store (MAS) Sandbox Evaluator (`Guideline 2.4.5`)**：专项评估 macOS 端 `app-sandbox` 与 `flutter_pty` 在 Mac App Store 沙盒规则下的边界，给出 MAS 版与 Developer ID 公证版的双轨策略。

2. **Phase 2 — 3 路严格无冲突自动合规整备 (`parallel` Disjoint Remediation Workers)**
   - **Worker A (Privacy Manifest & Info.plist / L10n Remediation)**：创建并向 `project.pbxproj` 注册 `ios/Runner/PrivacyInfo.xcprivacy`（及 macOS `PrivacyInfo.xcprivacy`），补齐 `ITSAppUsesNonExemptEncryption` 及 `en`/`zh-Hans`/`ja`/`ru` 四语 `InfoPlist.strings` 权限说明（消除 `ITMS-90683`）。
   - **Worker B (New-App Archive Pipeline & XCFramework Hardening)**：构建面向新 App 上架的 `ios/scripts/archive_appstore.sh` 与 `ios/Runner/ExportOptions-AppStore.plist`（支持一行命令传入新 App 的 `--bundle-id`、`--app-name`、`--version`、`--build-number`、`--team-id`，并内置上传前自动洁净度/隐私/切片预检门禁）。
   - **Worker C (App Store Connect Submission Kit & Privacy Policy)**：生成可直接复制填入 App Store Connect 后台的新 App 完整提审手册 `ios/docs/APP_STORE_SUBMISSION.md`（应用名称建议、副标题、关键词、四语简介、隐私营养标签勾选表、加密合规答复、App Review 审核员指引）与双语隐私政策模板 `ios/docs/PRIVACY_POLICY.md`。

3. **Phase 3 — 自动化上架合规门禁测试与编译预检 (`Compliance Gate Agent`)**
   - 编写并运行 `test/appstore_compliance_test.dart`，将全部 App Store 硬性机器规则（`PrivacyInfo.xcprivacy` 合法性与挂载、敏感 API 权限串四语齐全、1024px 图标无 Alpha、出口加密配置、零测试种子残留、账号删除入口可达）固化为自动化测试，并在双仓验证 100% 通过。
