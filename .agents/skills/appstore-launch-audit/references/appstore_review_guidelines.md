# Apple App Store 新 App 上架审核与机器校验规范清单

本清单汇总 Apple App Store Connect 自动二进制扫描（`ITMS-*`）与人工审核（App Store Review Guidelines）的核心否决项，作为 `appstore-launch-audit` 工作流的权威依据。

---

## 一、App Store Connect 二进制机器校验红线（Upload Blockers）

1. **`ITMS-91053` / `ITMS-91061`：缺少隐私清单（`PrivacyInfo.xcprivacy`）或 Required Reason API 声明**
   - `ios/Runner/PrivacyInfo.xcprivacy` 必须存在并加入 `Runner` Target 的 **Copy Bundle Resources (`PBXResourcesBuildPhase`)**。
   - 必须包含：
     - `NSPrivacyTracking = false`
     - `NSPrivacyTrackingDomains = []`
     - `NSPrivacyCollectedDataTypes`（如实声明可选云同步账户邮箱/加密同步数据，纯本地模式不收集数据）
     - `NSPrivacyAccessedAPITypes`：
       - `NSPrivacyAccessedAPICategoryUserDefaults` (`CA92.1`：应用自身读写偏好配置)
       - `NSPrivacyAccessedAPICategoryFileTimestamp` (`C617.1`：访问应用容器/用户选定文件时间戳以管理本地配置库、SFTP 传输与导入导出)
       - `NSPrivacyAccessedAPICategoryDiskSpace` (`E174.1`：写入本地加密数据库与传输文件前检查可用空间)
       - `NSPrivacyAccessedAPICategorySystemBootTime` (`35F9.1`：测量连接超时与单调时钟间隔)

2. **`ITMS-90683`：缺少敏感 API 用途说明（Missing Purpose String）**
   - 即使主业务未直接打开相机或相册，只要链接的第三方库（如 `DKImagePickerController` / `file_picker` / 图片附件选择器）在二进制中包含 `PHPhotoLibrary`、`AVCaptureDevice` 等符号，Apple 静态扫描器就会强制要求 `Info.plist` 提供非空、具体说明实际用途（如设置自定义终端背景壁纸或上传主机附件）的描述串，否则上传后数秒内直接判为 **Invalid Binary**！
   - 必须检查并覆盖所有已链接框架涉及的权限键，并在 `en.lproj`、`zh-Hans.lproj`、`ja.lproj`、`ru.lproj` 的 `InfoPlist.strings` 中同步四语本地化文案：
     - `NSLocalNetworkUsageDescription`（连接局域网内的 SSH / SFTP / Telnet / RDP / VNC 主机）
     - `NSPhotoLibraryUsageDescription` & `NSPhotoLibraryAddUsageDescription`（从相册选择自定义工作区/终端背景壁纸或主机附件）
     - `NSCameraUsageDescription`（拍摄照片作为主机附件或扫描配置凭证）
   - 文案严禁敷衍（如 `"Need permission"`），必须具体写明用户触发场景与用途。

3. **`ITMS-90087` / `ITMS-90562` / `ITMS-90205`：内嵌 Framework 切片与 Bundle 结构**
   - 正式归档（`iphoneos`）内嵌的 `Frameworks/atermius_rdp.framework` 只能包含 `arm64` 设备架构切片，严禁混入 `x86_64` 或模拟器切片。
   - 每个内嵌 `.framework` 必须包含合法的 `Info.plist`（含 `CFBundleIdentifier`、`CFBundleExecutable`、`CFBundleShortVersionString`、`CFBundleVersion`、`CFBundlePackageType = FMWK`、`MinimumOSVersion`），且内部严禁残留嵌套子目录 `_CodeSignature` 冲突或未签名二进制。

4. **`ITMS-90717` / `ITMS-90022`：应用图标规范**
   - `AppIcon.appiconset` 中全部 PNG（尤其是 `1024x1024` App Store 图标）必须为不带 Alpha 透明通道的 RGB 图像（`hasAlpha: no`），四角直角满铺（由系统自动裁切超椭圆圆角）。

5. **出口加密合规（Export Compliance）**
   - 在 `Info.plist` 中声明 `<key>ITSAppUsesNonExemptEncryption</key><false/>`（应用仅使用操作系统及标准开源库提供的 SSH/TLS/RDP 远程管理传输加密与本地密码库保护，符合 EAR 5D002 Note 4 / 医疗/金融/远程IT运维标准密码豁免），免除每次构建上传 TestFlight 时的人工审批拦截。

---

## 二、人工审核一票否决项（App Review Guidelines）

1. **Guideline `5.1.1(v)`：账号删除（Account Deletion）**
   - 若应用内提供账号注册/云端登录，必须在应用内设置页提供直接发起的**删除账号**流程（而非仅提供退出登录或发邮件联系客服），明确告知将永久删除云端账户与同步密文。

2. **Guideline `2.1` / `4.2`：开箱即用与审核员测试可测性**
   - 应用首次安装打开必须支持**免注册直接创建本地配置库（Local Profile）**完整体验主机管理、密钥生成、导入导出与 SSH/Telnet/RDP/VNC 客户端功能。
   - 在 App Store Connect 的 **App Review Information（审核备注）** 中提供清晰的功能测试路径与测试用 SSH 演示说明（或说明无需强制账号登录）。

3. **Guideline `2.3` / 新 App 独立身份与洁净打包（Zero Private Data Leak）**
   - 作为新 App 上架时，支持通过构建参数一键指定全新的 `PRODUCT_BUNDLE_IDENTIFIER`、显示名称与版本号（`1.0.0` Build `1`）。
   - **上架归档包严禁包含任何开发者本地测试文件（如 `atermius-local-seed.json`、`termius-export` 等）**，归档脚本必须在打包后对 `.xcarchive` 执行自动洁净度断言校验！

4. **Guideline `2.4.5`（若同步上架 Mac App Store）**
   - Mac App Store 强制要求启用 App Sandbox（`com.apple.security.app-sandbox = true`），且沙盒内无法直接 fork 任意宿主机登录 Shell（`flutter_pty`）。若上架 Mac App Store 需提供沙盒化构建配置（仅开启远程 SSH/SFTP/Telnet/RDP/VNC 客户端与 `network.client` + `files.user-selected.read-write`）；本机终端功能保留在官网 Developer ID Notarized 直发版中。
