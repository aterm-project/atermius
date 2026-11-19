# Apple App Store 全新 App 首次上架完整提审手册

本手册面向将本项目作为**一款全新独立 App** 首次发布至 **Apple App Store（iOS / iPadOS，并零成本覆盖 Apple Silicon Mac App Store）** 的完整实操流程，所有关键提审文案均提供 **简体中文 (`zh-Hans`) / 英文 (`en-US`) / 日文 (`ja`) / 俄文 (`ru`)** 现成可复制文本，并严格对齐工程源码、`Info.plist`、`PrivacyInfo.xcprivacy` 及 App Store Review Guidelines 审计结论。

---

## 上架前核心合规基线速览（Phase 1 五维审计结论对齐）

在提交二进制构建前，请确认以下机器扫描（`ITMS-*`）与人工审核红线均已由自动化流水线及归档门禁闭环：

| 审核域 | 核心规则 / 错误码 | 合规状态与工程对齐要求 |
| :--- | :--- | :--- |
| **隐式敏感 API 权限串** | `ITMS-90683` | 主程序及静态链接依赖（`file_picker` / `DKImagePickerController` / `flutter_secure_storage`）涉及的 **6 项权限用途串**必须在 `ios/Runner/Info.plist` 与 `en`/`zh-Hans`/`ja`/`ru` 四语 `InfoPlist.strings` 完整声明：`NSLocalNetworkUsageDescription`、`NSPhotoLibraryUsageDescription`、`NSPhotoLibraryAddUsageDescription`、`NSCameraUsageDescription`、`NSLocationWhenInUseUsageDescription`、`NSAppleMusicUsageDescription`、`NSFaceIDUsageDescription`。<br>**严禁误加**：切勿添加无业务对应的 `NSMotionUsageDescription` 或 `NSHealthShareUsageDescription`，以免触发人工审核问询。 |
| **隐私清单与受限 API** | `ITMS-91053` | `ios/Runner/PrivacyInfo.xcprivacy` 已挂载至 `PBXResourcesBuildPhase`，声明 `NSPrivacyTracking = false` 及 4 类 Required Reason API：`CA92.1` (`UserDefaults`)、`C617.1` (`FileTimestamp`)、`E174.1` (`DiskSpace`)、`35F9.1` (`SystemBootTime`)。 |
| **零私有数据泄漏** | Guideline `2.3` | 严禁将 `atermius-local-seed.json`、`termius-export/`、`ssh_config` 等开发者私有测试种子打入 `.xcarchive` 或 `.ipa`（专用归档脚本 `archive_appstore.sh` 已内置强制阻断断言）。 |
| **图标与内嵌框架切片** | `ITMS-90717` / `ITMS-90087` / `ITMS-90562` | `AppIcon.appiconset` 全部 15 张 PNG（含 `1024x1024`）均为 24-bit RGB 无透明通道（`hasAlpha: no`）；`atermius_rdp.framework` 及全部内嵌 `.framework` 均为纯 `arm64` 真机切片且 `MinimumOSVersion = 15.0`。 |
| **免登录可用与账号注销** | Guideline `2.1` / `4.2` / `5.1.1(v)` | 首次启动默认自动创建受本机 Keychain 保护的本地加密配置库（零登录墙）；可选自托管云同步账户在应用内支持直接发起永久注销与会话即时吊销。 |

---

## 第一步：Apple Developer 后台新 App ID 注册清单

### 1.1 注册显式 App ID（Explicit Bundle ID）

1. 登录 [Apple Developer — Identifiers](https://developer.apple.com/account/resources/identifiers/list)。
2. 点击左上角 **`+`** 按钮 -> 选择 **App IDs** -> 点击 **Continue** -> 选择类型 **App** -> 点击 **Continue**。
3. 按下表填写 **Register an App ID** 表单：

| 字段 | 填写要求与标准配置 |
| :--- | :--- |
| **Description** | 仅内部可见英文备注，例如：`Aterm Encrypted SSH and SFTP Client` |
| **Bundle ID** | **必须选择 `Explicit`（显式 ID，严禁选择 `Wildcard` 通配符 `*`）**。<br>填入全新的反向域名标识（推荐示例：`com.yourcompany.aterm` 或 `io.atermius.ssh`，避免与历史内部测试包 ID 冲突，后续构建命令 `--bundle-id` 须与此完全一致）。 |

### 1.2 Capabilities（能力权限）勾选清单

当前 iOS 主工程默认签名权限文件 `ios/apps/client/ios/Runner/Runner.entitlements` 为空字典（`<dict/>`），遵循**最小权限原则**：

- **默认首发配置（强烈推荐）**：
  - **无需额外勾选任何特殊受限 Capability / Entitlement**（保留系统默认的 `In-App Purchase` / `Game Center` 默认状态即可，无需在工程中添加 Entitlement）。
  - **切勿多余勾选**以下未使用的受限项：`iCloud`、`App Groups`、`Associated Domains`、`Access WiFi Information`、`Multipath`、`Network Extensions`、`HealthKit`、`HomeKit`，防止 Provisioning Profile 与 `Runner.entitlements` 不一致或引发审核额外质询。
- **可选扩展配置（仅当启用自托管后台同步提示 Push Hints 时勾选）**：
  - 勾选 **Push Notifications**，并为该 App ID 创建 APNs 密钥（`.p8`）配置至自托管服务端；同时在客户端打包时启用 `RunnerPush.entitlements`（配置 `ATERMIUS_APS_ENVIRONMENT=production` 及对应 FCM/APNs 构建宏，详见 `ios/docs/MOBILE-PUSH.md`）。若首发版不部署推送网关，**请保持不勾选 Push Notifications**。

点击右上角 **Continue** -> **Register** 完成 App ID 注册。

### 1.3 在 App Store Connect 创建新 App 记录

1. 登录 [App Store Connect — Apps](https://appstoreconnect.apple.com/apps)，点击 **`+`** -> **新建 App (New App)**。
2. 填写新建弹窗：
   - **平台 (Platforms)**：勾选 **iOS**（工程配置 `TARGETED_DEVICE_FAMILY = "1,2"`，勾选 iOS 即同时提供原生 iPhone 与 iPad 界面）。
   - **名称 (Name)**：填入下方第三步选定的新 App 名称（30 字符内）。
   - **主要语言 (Primary Language)**：选择 **简体中文 (Simplified Chinese)** 或 **English (U.S.)**。
   - **套装 ID (Bundle ID)**：在下拉框选择刚刚注册的显式 App ID。
   - **SKU**：填入唯一内部产品编码（仅自己可见，例如：`ATERM-IOS-2026-01`）。
   - **用户访问权限 (User Access)**：选择 **完全访问权限 (Full Access)**。
3. 创建完成后，在页面右上角语言下拉菜单中依次添加完整的四种本地化商店语言（与客户端 `CFBundleLocalizations` 严格对齐）：
   - **简体中文 (Simplified Chinese)**
   - **English (U.S.)**
   - **日本語 (Japanese)**
   - **Русский (Russian)**

---

## 第二步：一键构建 App Store 正式包与上传命令

### 2.1 执行归档前静态合规预检（Pre-flight Check）

在正式编译归档前，可先运行秒级静态预检，验证无任何私有测试种子（如 `atermius-local-seed.json`）、`PrivacyInfo.xcprivacy` 合法、四语权限串完整、1024px 图标无 Alpha 且 `atermius_rdp.framework` 为纯 `arm64` 切片：

```bash
cd /Users/yang/Downloads/aterm-project/ios

./scripts/archive_appstore.sh \
  --preflight-only \
  --bundle-id <新BundleID> \
  --team-id 2QJ8K75QL2 \
  --version 1.0.0 \
  --build-number 1
```

### 2.2 一键生成 App Store 正式 `.ipa` 归档包

将 `<新BundleID>` 替换为您在第一步注册的显式 Bundle ID（如需同步覆盖桌面图标下的显示名称，可追加 `--display-name "<新App名称>"`）：

```bash
cd /Users/yang/Downloads/aterm-project/ios

./scripts/archive_appstore.sh \
  --bundle-id <新BundleID> \
  --team-id 2QJ8K75QL2 \
  --version 1.0.0 \
  --build-number 1
```

> **构建说明**：
> - 脚本将使用干净的归档工作流执行 Release 编译、`xcodebuild archive` 与 `-exportArchive`（基于 `ExportOptions-AppStore.plist` 自动启用 Apple Distribution 安全时间戳重签并剥离开发头文件），并在导出后二次校验 `.xcarchive` 与 `.ipa` 内绝无 `atermius-local-seed.json` / `*termius*` / `ssh_config` 残留。
> - 最终可交付产物位于 `/Users/yang/Downloads/aterm-project/ios/dist/appstore/` 目录下。
> - 同一版本号（如 `1.0.0`）若需重新上传修复包，请将 `--build-number` 递增（`2`、`3`...）。

### 2.3 上传构建包至 App Store Connect（任选其一）

#### 方式 A：使用 macOS 官方 Transporter 应用（可视化推荐）

1. 在 Mac App Store 搜索并安装 Apple 官方 **Transporter** 应用，使用您的 Apple Developer 账号登录。
2. 将 `/Users/yang/Downloads/aterm-project/ios/dist/appstore/` 下生成的 `.ipa` 文件直接拖入 Transporter 窗口。
3. 点击右侧 **`...`** 菜单 -> 选择 **验证 (Verify)**，确认云端静态扫描零报错后，点击 **交付 (Deliver)**。
4. 上传完成后等待约 5–15 分钟（Apple 后台完成符号解析与 `ITMS-*` 二进制扫描），即可在 App Store Connect 对应版本的 **构建版本 (Build)** 区域选中该包。

#### 方式 B：使用命令行 `xcrun altool` 上传（自动化 / CI 推荐）

1. 前往 [App Store Connect -> 用户和访问 -> 整合 -> App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api) 生成 API 密钥（权限选 `App Manager` 或 `Developer`），记录 **Key ID** 与 **Issuer ID**，并将下载的 `AuthKey_<KEY_ID>.p8` 放入本机 `~/.private_keys/` 目录。
2. 运行验证与上传命令：

```bash
# 1. 上传前执行 Apple 服务端二进制预验证
xcrun altool --validate-app \
  -f /Users/yang/Downloads/aterm-project/ios/dist/appstore/*.ipa \
  -t ios \
  --apiKey <YOUR_API_KEY_ID> \
  --apiIssuer <YOUR_ISSUER_ID>

# 2. 验证通过后正式上传至 App Store Connect
xcrun altool --upload-app \
  -f /Users/yang/Downloads/aterm-project/ios/dist/appstore/*.ipa \
  -t ios \
  --apiKey <YOUR_API_KEY_ID> \
  --apiIssuer <YOUR_ISSUER_ID>
```

---

## 第三步：App Store Connect 元数据直接复制表

### 3.1 新 App 名称候选（App Name，严格 <= 30 字符）

若首选名在 App Store Connect 提示已被其他开发者占用，请依次选用备选方案（全部控制在 30 字符上限内）：

| 方案 | 简体中文 (`zh-Hans`) | 英文 (`en-US`) | 日文 (`ja`) | 俄文 (`ru`) |
| :--- | :--- | :--- | :--- | :--- |
| **候选 A（首选）** | `Aterm - SSH 与 SFTP 加密终端` (23) | `Aterm: SSH, SFTP & RDP Client` (29) | `Aterm - SSH・SFTP・リモート端末` (23) | `Aterm: SSH, SFTP и терминал` (27) |
| **候选 B（独立品牌）** | `VaultTerm - 加密 SSH 与终端` (22) | `VaultTerm: SSH, SFTP & RDP` (26) | `VaultTerm - 暗号化SSH・SFTP` (23) | `VaultTerm: SSH, SFTP клиент` (27) |
| **候选 C（极客运维）** | `CipherShell - SSH 与远程运维` (23) | `CipherShell: SSH, SFTP & RDP` (28) | `CipherShell - SSH・SFTP端末` (24) | `CipherShell: SSH и терминал` (27) |

### 3.2 副标题（Subtitle，严格 <= 30 字符，四语直接复制）

- **简体中文 (`zh-Hans`)**（20 字符）：
```text
端到端加密 SSH、SFTP 与远程桌面
```

- **English (`en-US`)**（29 字符）：
```text
Encrypted SSH, SFTP & Desktop
```

- **日本語 (`ja`)**（18 字符）：
```text
暗号化SSH・SFTP・リモート接続
```

- **Русский (`ru`)**（28 字符）：
```text
SSH, SFTP и удалённый доступ
```

### 3.3 宣传文本（Promotional Text，严格 <= 170 字符，上线后可免审随时修改）

- **简体中文 (`zh-Hans`)**（108 字符）：
```text
开箱即用的专业 SSH、SFTP、Telnet、RDP 与 VNC 客户端。免注册即可创建受本机钥匙串保护的加密工作区，支持端口转发、Ed25519 密钥生成、分屏终端与代码片段，并可按需接入自托管零知识加密同步。
```

- **English (`en-US`)**（156 字符）：
```text
Modern SSH, SFTP, Telnet, RDP & VNC client. Start instantly with a Keychain-protected local vault, port forwarding, snippets & optional zero-knowledge sync.
```

- **日本語 (`ja`)**（101 字符）：
```text
登録不要ですぐ使える暗号化SSH・SFTP・Telnet・RDP・VNCクライアント。Keychain保護のローカル保管庫、ポート転送、鍵生成、スニペット管理を備え、ゼロ知識E2E暗号化同期にも対応。
```

- **Русский (`ru`)**（163 字符）：
```text
Клиент SSH, SFTP, Telnet, RDP и VNC без обязательной регистрации. Локальное хранилище под защитой Keychain, проброс портов, генерация ключей и сквозное шифрование.
```

### 3.4 关键词（Keywords，严格 <= 100 字符，半角逗号分隔、逗号后不加空格）

- **核心高权重词组（通用 / `en-US` 首选，67 字符）**：
```text
ssh,sftp,terminal,rdp,vnc,telnet,devops,linux,server,shell,keychain
```

- **`en-US` 满额高转化扩展词组（98 字符，前段完整保留全部核心高权重词）**：
```text
ssh,sftp,terminal,rdp,vnc,telnet,devops,linux,server,shell,keychain,scp,tunnel,ed25519,sysadmin,it
```

- **简体中文 (`zh-Hans`) 本地化词组（94 字符，融合英文高频协议词与中文搜索词）**：
```text
ssh,sftp,terminal,rdp,vnc,telnet,devops,linux,server,shell,keychain,终端,远程桌面,服务器,运维,端口转发,密钥,文件传输
```

- **日本語 (`ja`) 本地化词组（96 字符）**：
```text
ssh,sftp,terminal,rdp,vnc,telnet,devops,linux,server,shell,keychain,ターミナル,リモートデスクトップ,サーバー,鍵管理,転送
```

- **Русский (`ru`) 本地化词组（98 字符）**：
```text
ssh,sftp,terminal,rdp,vnc,telnet,devops,linux,server,shell,keychain,терминал,сервер,консоль,ключи
```

### 3.5 完整应用描述（Description，中/英详尽版 + 日/俄本地化版，直接复制）

#### 简体中文 (`zh-Hans`) 描述

```text
专为系统工程师、DevOps 与开发者打造的安全远程终端与服务器管理工作区。在一个原生应用内统一管理 SSH、SFTP/SCP、Telnet、RDP 与 VNC 连接，兼顾开箱即用的本机离线体验与端到端零知识加密架构。

【免注册开箱即用 · 本机钥匙串保护】
• 首次打开即可直接使用，无强制账号注册墙。
• 自动创建受 iOS / iPadOS 系统钥匙串（Keychain）与生物识别（Face ID / Touch ID）保护的本地加密配置库，所有服务器地址、登录凭证与私钥默认仅加密存储在您的设备本地。

【多协议一体化远程连接】
• SSH 终端：高速流畅的终端渲染，支持多标签页、工作区分屏（Split Panes）、断线重连恢复、外接硬件键盘快捷键与移动端专属修饰键扩展栏（Ctrl / Alt / Shift / Esc / Tab）。
• SFTP / SCP 文件传输：可视化远程文件管理，支持上传、下载、权限查看、断点续传及主机加密附件管理。
• 远程桌面与传统设备支持：内置 Telnet、RDP 与 VNC 客户端连接管理，支持证书 SHA-256 指纹核验、自定义分辨率缩放以及直接触控 / 虚拟触控板双操作模式。

【专业网络与密钥管理能力】
• 本机密钥库：在设备端离线生成、导入与管理 Ed25519、RSA 等 SSH 密钥对及主机指纹，私钥永不明文落盘。
• SSH 端口转发与跳板：支持本地转发（Local）、远程转发（Remote）与动态 SOCKS 转发规则编排，支持多级堡垒机 / 跳板连接。
• 代码片段（Snippets）与分组管理：按环境、标签与目录整理成百上千台主机，将常用运维指令保存为可复用片段一键下发。
• 加密备份与迁移：支持标准 SSH 配置及加密归档导入导出。

【可选自托管端到端零知识同步】
• 面向拥有自有基础设施的用户与团队，支持按需连接自托管（Self-Hosted）同步服务。
• 采用严格的客户端 AEAD 端到端加密与设备数字签名：所有主机记录、密钥与附件均在本地完成加密后再传输，服务端仅存储不透明密文，无法读取您的任何明文凭证。

【原生体验与多语言支持】
• 深度适配 iPhone 与 iPad 分屏多任务，支持自定义终端配色方案、字体字号与深浅色外观，内置简体中文、英文、日文、俄文四语界面。
```

#### English (`en-US`) Description

```text
A secure, native remote operations workspace built for developers, sysadmins, and DevOps engineers. Manage SSH, SFTP/SCP, Telnet, RDP, and VNC connections in one unified interface—combining instant offline local vaults with optional zero-knowledge end-to-end encrypted synchronization.

INSTANT OFFLINE ACCESS — NO SIGN-UP REQUIRED
• Launch and connect immediately with zero mandatory registration or login walls.
• Your local encrypted profile is automatically protected by the iOS / iPadOS Keychain and optional Face ID / Touch ID authentication. All host profiles, credentials, and private keys stay encrypted on your device by default.

ALL-IN-ONE MULTI-PROTOCOL WORKSPACE
• SSH Terminal: Responsive terminal emulation with multi-tab sessions, split panes, session reconnect controls, hardware keyboard shortcuts, and an ergonomic on-screen modifier bar (Ctrl, Alt, Shift, Esc, Tab).
• SFTP & SCP File Manager: Browse remote directories, upload and download files with transfer progress and resume support, and manage encrypted host attachments.
• RDP, VNC & Telnet Clients: Connect to remote desktops and network gear with SHA-256 certificate fingerprint verification, flexible display scaling, and switchable direct-touch or relative trackpad pointer modes.

BUILT FOR SERIOUS INFRASTRUCTURE WORKFLOWS
• On-Device Keychain & Key Generator: Generate, import, and manage Ed25519 and RSA SSH keys directly on your device.
• Port Forwarding & Jump Hosts: Configure local, remote, and dynamic port forwarding tunnels alongside multi-hop SSH bastion hosts.
• Snippets & Host Organization: Group servers with tags and folders, and save frequently used shell commands as reusable snippets.
• Encrypted Import & Export: Easily back up or migrate configurations via encrypted archives and standard SSH config imports.

OPTIONAL SELF-HOSTED ZERO-KNOWLEDGE SYNC
• Teams and power users running their own self-hosted server can optionally enable cross-device Vault synchronization.
• Powered by client-side AEAD encryption and cryptographic device signatures: every host record, credential, key, and chunked attachment is encrypted before leaving your device. The server stores opaque ciphertext only and never sees plaintext secrets.

DESIGNED FOR iPHONE & iPAD
• Full support for iPad multitasking, custom terminal color palettes, adjustable typography, and localized interfaces in English, Simplified Chinese, Japanese, and Russian.
```

#### 日本語 (`ja`) 描述

```text
開発者・インフラエンジニア・システム管理者向けのセキュアな統合リモート接続クライアントです。SSH、SFTP/SCP、Telnet、RDP、VNC をひとつのネイティブワークスペースに統合し、登録不要のローカル暗号化保管庫とゼロ知識エンドツーエンド暗号化アーキテクチャを提供します。

【アカウント登録不要・すぐに利用開始】
• 初回起動時からログイン不要で全機能を利用可能。
• iOS / iPadOS キーチェーンと Face ID / Touch ID で保護されたローカル暗号化プロファイルを自動作成し、接続先や秘密鍵を端末内で安全に管理します。

【主な機能】
• SSH ターミナル & SFTP/SCP ファイル転送：タブ管理、画面分割（Split Panes）、自動再接続、ハードウェアキーボードおよび専用修飾キーバーに対応。
• RDP / VNC / Telnet 対応：SHA-256 証明書フィンガープリント検証、画面スケーリング、タッチ／トラックパッド操作モード切替をサポート。
• 鍵管理・ポート転送・スニペット：端末内での Ed25519 / RSA 鍵ペア生成、ローカル／リモート／ダイナミックポート転送、踏み台（Jump Host）接続、よく使うコマンドのスニペット保存に対応。
• 任意のセルフホスト型ゼロ知識同期：独自サーバーを利用する場合のみオプションで有効化でき、すべてのデータはクライアント側で AEAD 暗号化・署名されてから送信されます。
```

#### Русский (`ru`) 描述

```text
Безопасное рабочее пространство для системных администраторов, DevOps-инженеров и разработчиков. Управляйте подключениями SSH, SFTP/SCP, Telnet, RDP и VNC в едином нативном приложении с локальным шифрованием и опциональной сквозной (zero-knowledge) синхронизацией.

【РАБОТА БЕЗ РЕГИСТРАЦИИ С ПЕРВОГО ЗАПУСКА】
• Не требует создания учётной записи для работы.
• Локальное зашифрованное хранилище защищено системной связкой ключей iOS / iPadOS Keychain и биометрией Face ID / Touch ID.

【ОСНОВНЫЕ ВОЗМОЖНОСТИ】
• Терминал SSH и файловый менеджер SFTP/SCP: вкладки, разделение экрана (Split Panes), быстрое переподключение, поддержка внешних клавиатур и панели клавиш-модификаторов.
• Клиенты RDP, VNC и Telnet: проверка SHA-256 отпечатков сертификатов, масштабирование экрана и режимы прямого касания или виртуального тачпада.
• Ключи, туннели и сниппеты: локальная генерация ключей Ed25519/RSA, проброс портов (Local / Remote / Dynamic), работа через jump-хосты и шаблоны команд.
• Опциональная self-hosted синхронизация с нулевым разглашением: все записи и ключи шифруются на устройстве до отправки на ваш сервер.
```

### 3.6 分类建议、网址字段与年龄分级问卷（4+）标准答案

#### 1) 分类与必填 URL 配置

| App Store Connect 字段 | 标准配置值 |
| :--- | :--- |
| **主要类别 (Primary Category)** | **开发者工具 (Developer Tools)** |
| **次要类别 (Secondary Category)** | **效率 (Productivity)** |
| **隐私政策网址 (Privacy Policy URL)** | 部署 `ios/docs/PRIVACY_POLICY.md` 后的公开 HTTPS 链接（如 `https://<your-domain>/privacy`） |
| **技术支持网址 (Support URL)** | 部署同一页面并指向支持锚点（如 `https://<your-domain>/privacy#support`） |
| **版权 (Copyright)** | `2026 <您的个人英文姓名或公司法定名称>`（例如：`2026 Fusho Yang`） |

#### 2) 年龄分级问卷（Age Rating -> 最终评级 `4+`）逐项答案表

在 App Store Connect -> **App 信息** -> **年龄分级** 点击编辑，按以下标准逐项勾选以确保获得全区通用的 **`4+`** 评级（同时兼容企业 Apple Business Manager 批量采购）：

| 问卷调查项目 | 标准勾选答案 | 合规说明 |
| :--- | :--- | :--- |
| 卡通或奇幻暴力 (Cartoon or Fantasy Violence) | **无 (None)** | 纯生产力与开发者工具 |
| 现实暴力 (Realistic Violence) | **无 (None)** | 无相关内容 |
| 持续或残酷的现实暴力 (Prolonged Graphic or Sadistic Realistic Violence) | **无 (None)** | 无相关内容 |
| 色情或裸露内容 (Profanity or Crude Humor / Mature/Suggestive Themes / Sexual Content or Nudity) | **全部选 无 (None)** | 无相关内容 |
| 恐怖/惊悚主题 (Horror/Fear Themes) | **无 (None)** | 无相关内容 |
| 医疗/治疗信息 (Medical/Treatment Information) | **无 (None)** | 无相关内容 |
| 饮酒、烟草或毒品使用或提及 (Alcohol, Tobacco, or Drug Use or References) | **无 (None)** | 无相关内容 |
| 模拟赌博 (Simulated Gambling) | **无 (None)** | 无相关内容 |
| **无限制的网页访问 (Unrestricted Web Access)** | **否 (No)** | **关键避坑项**：本应用为 SSH/SFTP/RDP/VNC 客户端，未内置任意网址自由浏览的通用 Web 浏览器；若误选“是”会被强制锁定为 `17+` |
| **赌博与竞赛 (Gambling and Contests)** | **否 (No)** | 无相关内容 |
| **计算得出的最终分级** | **`4+`** | 全球所有国家与地区（含韩国、巴西等特殊分级区）均可直接上架 |

---

### 3.7 App Privacy（隐私营养标签）后台逐项勾选指南

> **重要合规对齐原则（防止因勾选与二进制 `.xcprivacy` 冲突被拒）**：
> 1. 主工程 `PrivacyInfo.xcprivacy` 声明了可选云同步账户所需的电子邮箱（`NSPrivacyCollectedDataTypeEmailAddress`），且 `NSPrivacyTracking = false`（零跨应用追踪）。
> 2. 同时，当前工程内嵌的推送依赖组件（`FirebaseMessaging` / `FirebaseInstallations` / `GoogleDataTransport`）在其各自 Bundle 的 `.xcprivacy` 中声明了设备推送标识与基础传输诊断项。Apple 在审核时会对照合并后的隐私清单校验网页端填写的营养标签，**请勿盲目勾选“不收集任何数据”**，请严格按下表如实勾选！
> 3. **操作校验技巧**：每次在 Xcode 完成 Archive 后，可在 **Xcode -> Window -> Organizer -> 右键您的 Archive -> Generate Privacy Report** 导出合并 PDF，与下表一对一核对。

#### 第一步：总开关

- 问题：**“您或您的第三方合作伙伴是否从此 App 收集数据？”**
- 勾选：**是，我们会从此 App 收集数据 (Yes, we collect data from this app)** -> 点击下一步。

#### 第二步：勾选收集的数据类型（共勾选以下对应项）

| 大类 | 勾选的具体数据类型 | 用途勾选 (Purpose) | 是否与用户身份关联 (Linked to User) | 是否用于追踪目的 (Used for Tracking) | 代码与 `.xcprivacy` 对应依据 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **联系信息 (Contact Info)** | **电子邮件地址 (Email Address)** | 仅勾选 **App 功能 (App Functionality)** | **是 (Yes)** | **否 (No)** | 对应主工程 `PrivacyInfo.xcprivacy` 中的 `NSPrivacyCollectedDataTypeEmailAddress`：仅在用户主动注册/登录可选自托管同步账户时用于身份验证与安全恢复；纯本地模式不收集。 |
| **标识符 (Identifiers)** | **设备 ID (Device ID)** | 仅勾选 **App 功能 (App Functionality)** | **是 (Yes)**（关联已登录同步会话设备） | **否 (No)** | 对应同步账户设备管理及内嵌 `FirebaseInstallations` / APNs 推送令牌（仅用于投递可选后台同步提示）。 |
| **诊断 (Diagnostics)** *(仅保留 Firebase 依赖时勾选)* | **其他诊断数据 (Other Diagnostic Data)** | 勾选 **App 功能 (App Functionality)**（若 SDK 报告含 Analytics 可同步勾选 **分析 (Analytics)**） | **否 (No)** | **否 (No)** | 对应内嵌 `GoogleDataTransport` / `FirebaseMessaging` bundle 自带 `.xcprivacy` 的聚合声明；若打包时已移除 Firebase 依赖则无需勾选本项。 |
| **其他数据 (Other Data)** *(覆盖加密同步密文及 SDK 聚合项)* | **其他数据类型 (Other Data Types)** | 仅勾选 **App 功能 (App Functionality)** | **是 (Yes)** | **否 (No)** | 对应可选自托管同步上传的客户端端到端加密记录密文（服务端不可解密）及内嵌传输组件元数据。 |

> **补充说明（无需在网页勾选的本地 API 项）**：`PrivacyInfo.xcprivacy` 中声明的 `CA92.1` (`UserDefaults`)、`C617.1` (`FileTimestamp`)、`E174.1` (`DiskSpace`)、`35F9.1` (`SystemBootTime`) 属于 **Required Reason API（设备本地 API 访问原因）**，由 App Store Connect 机器自动扫描 `.xcprivacy` 验证，无需也不应在网页端“数据收集”表单中重复填报。

---

### 3.8 出口合规（Export Compliance）问卷标准答案

1. **二进制自动豁免（推荐默认生效）**：
   - `ios/apps/client/ios/Runner/Info.plist`（及 macOS `Info.plist`）已写入：
     ```xml
     <key>ITSAppUsesNonExemptEncryption</key>
     <false/>
     ```
   - 应用仅将标准密码学算法（SSH、TLS、RDP 传输加密与本地 Keychain / AEAD 密码库保护）用于远程 IT 系统运维、身份认证及密码保护，完全符合美国《出口管理条例》(**EAR Category 5, Part 2, Note 4** 及 **15 CFR § 740.17(b)**) 豁免范围，上传构建后将自动显示“无需提供出口合规文档”，直接可提交审核与 TestFlight 测试。

2. **若首次上架或分发地区变更时 App Store Connect 网页端弹出加密问卷，请按以下标准作答**：

| 后台问卷问题 | 标准选择答案 |
| :--- | :--- |
| **您的 App 是否使用加密？** (Does your app use encryption?) | **是 (Yes)** |
| **您的 App 是否符合任何加密豁免条件？** / 用途范围 | 勾选：**仅限于身份验证、密码保护或远程 IT 运维标准安全通信（Exempt — Authentication / Password Protection / Standard OS & Open-Source SSH/TLS Transport）**（若界面问“是否调用除 Apple 操作系统以外的专有/非豁免加密算法”，针对非豁免专有算法选 **否 / 符合标准豁免**）。 |
| **法国地区分发提示（实战经验）** | 若后台因包含法国（France）市场额外弹出 ANSSI 法国加密申报上传框：首发追求最快过审可在“价格与销售范围”暂时取消勾选法国，待 1.0.0 过审上线后再补充简表开启法国市场；或直接上传标准法文自分类声明即可。 |

---

### 3.9 App Review 审核备注（Notes for Review）中英双语现成模板

在 App Store Connect -> 版本页面底部 **App 审核信息 (App Review Information)**：
- **需要登录 (Sign-in required)**：**取消勾选（Unchecked / 不需要登录）**——因为本应用启动即默认进入完整可用的免注册本地加密模式！
- **备注 (Notes)**：直接复制以下**中英双语审核员指引模板**粘贴进去（一次性打消 Guideline `2.1` 功能可测性、Guideline `5.1.1(v)` 账号删除位置及系统权限用途三大人工审核疑虑）：

```text
[English — Notes for App Review]

1. No Login Required — Instant Full Functionality (Guidelines 2.1 & 4.2):
Upon first launch, the app automatically creates and unlocks a local encrypted profile protected by the iOS Keychain ("Local Mode") with zero sign-up or login required. All core client features work immediately out of the box:
- Create and organize SSH, SFTP, Telnet, RDP, and VNC host profiles ("+" button in the Hosts workspace).
- Generate Ed25519 / RSA SSH key pairs locally on the device (Keys section).
- Create reusable command Snippets and configure SSH Port Forwarding rules.
- Export and import encrypted backup archives.
(Note: If you navigate to the optional self-hosted Cloud Sync sign-in screen, you can switch back to Local Mode at any time via the Mode menu button in the top-right corner without entering any server URL.)

2. Optional Self-Hosted Cloud Account & In-App Account Deletion (Guideline 5.1.1(v)):
Cloud Vault synchronization is strictly optional and designed for users who run their own self-hosted server. When signed into a cloud account, users can permanently delete their account directly inside the app without contacting support:
- Navigation Path: Settings -> Account & sign-in -> tap "Password, two-factor and recovery" (or select Category: "Account security" from the Settings category selector) -> scroll to "Account deletion" -> tap "Schedule account deletion" -> enter "DELETE" and confirm with the account password.
- Effect: Immediately revokes all active sessions and device tokens, clears local authenticated state, and permanently purges the account and personal encrypted Vault data on the server at the scheduled deadline.

3. Purpose of System Permissions:
- Local Network: Used only when the user connects directly to SSH, SFTP, Telnet, RDP, or VNC servers on their local network (LAN).
- Face ID: Used optionally on-device to unlock the local encrypted vault and protected SSH keys.
- Photo Library / Camera / Media Picker: Triggered only when a user chooses a custom terminal/workspace image or attaches local files to an encrypted host record.
- Location (When In Use): Referenced only by the embedded photo/camera attachment picker metadata component; the app never tracks or uploads user location.

------------------------------------------------------------

【简体中文 — 审核员测试与合规说明】

1. 免注册开箱即用说明（符合 Guideline 2.1 & 4.2）：
本应用首次启动即自动创建并进入受 iOS Keychain 保护的“本地加密配置库（Local Mode）”，无任何强制登录墙，可直接完整体验全部核心客户端功能：
- 在主机（Hosts）工作区点击“+”新建与管理 SSH、SFTP、Telnet、RDP、VNC 主机配置；
- 在密钥（Keys）页面离线生成与管理 Ed25519 / RSA 密钥对；
- 创建可复用命令片段（Snippets）、配置端口转发规则及执行加密归档导入导出。
（注：若手动切换至可选的自托管云端同步登录页，无需填写服务器地址，点击右上角模式菜单即可随时一键切回本地工作区。）

2. 可选云端账户应用内永久删除指引（符合 Guideline 5.1.1(v)）：
云端同步仅面向自建服务端（Self-Hosted）用户可选启用。登录云账户后，用户可在应用内直接永久注销并删除账户（逻辑路径：设置 -> 账户 -> 删除账户）：
- 精确界面路径：进入“设置 (Settings)” -> 在“账户与登录 (Account & sign-in)”中点击“密码、两步验证与恢复”（或在顶部设置分类切换至“账户安全 / Account security”）-> 滑动至底部“账户删除 (Account deletion)”区域 -> 点击“安排账户删除 (Schedule account deletion)” -> 输入 DELETE 并验证密码确认。
- 执行效果：服务端立即吊销全部登录会话与设备凭证，客户端即时清除本地认证状态，并在宽限期截止后永久物理清除账户与个人保险库密文。

3. 系统权限触发说明：
- 本地网络权限：仅在用户主动连接局域网内的 SSH / SFTP / Telnet / RDP / VNC 主机时触发；
- Face ID：用于可选的本地加密配置库与私钥解锁验证；
- 相册 / 相机 / 文件与媒体选择：仅在用户主动选择自定义终端背景或上传主机加密附件时按需触发，绝无后台静默采集。
```

> **可选附加建议**：若您手头有一台仅供审核期间临时开放的测试 Linux 容器（仅开放低权限受限演示账号），可在上述备注末尾追加一行测试 SSH 主机 IP / 端口 / 演示用户名与密码，能进一步加速审核员验证实时终端会话；若不提供，凭借完整的离线主机管理、本机密钥生成与上述免登录说明同样符合远程运维工具上架惯例。

---

## 第四步：Mac App Store 上架补充说明（双轨与三形态演进策略）

根据 Phase 1 第 5 项 **Mac App Store (MAS) 沙盒合规专项审计（Guideline 2.4.5）** 结论，本项目在 macOS 平台推荐采用**“首发零成本兼容覆盖 + 独立发行双轨隔离”**方案：

### 4.1 方案一（首发强烈推荐，零改造成本）：iPadOS 应用直接上架 Apple Silicon Mac App Store

- **原理与优势**：当前 iOS 工程已配置 `SDKROOT = iphoneos` 与 `TARGETED_DEVICE_FAMILY = "1,2"`，默认完全兼容 **Designed for iPad on Apple Silicon Mac**。应用在 M1/M2/M3/M4 Mac 上天然运行于 Apple 官方 iOS 容器沙盒内，不涉及宿主机 PTY 逃逸风险，**无需单独编写 macOS 沙盒配置、无需单独送审即可同步出现在 Mac App Store**。
- **开启步骤**：在 App Store Connect -> **价格与销售范围 (Pricing and Availability)** -> **iPhone 和 iPad App 在 Apple 芯片的 Mac 上提供 (Make this app available on Apple silicon Macs)** -> **保持勾选**即可。

### 4.2 方案二：独立原生 macOS 沙盒版上架 Mac App Store（后续进阶选配）

> **注意**：一旦使用同一 Bundle ID 提交独立原生 macOS 构建并通过审核，Mac App Store 将自动以原生 macOS 包接管并替代方案一的 iPad 兼容版。

若后续计划将 `desktop/apps/client/macos` 作为独立原生 macOS 包（`3rd Party Mac Developer Application` + `3rd Party Mac Developer Installer` `.pkg`）提交 Mac App Store，必须先完成以下 **5 项 Guideline `2.4.5` 硬性沙盒改造**（切勿直接提交现有的非沙盒 `Release.entitlements`）：

1. **专用沙盒权限文件 `Release-MAS.entitlements`**：
   - 必须启用 `com.apple.security.app-sandbox = true`；
   - 仅保留最小必要权限：`com.apple.security.network.client = true`、`com.apple.security.files.user-selected.read-write = true`（契合 `MainFlutterWindow.swift` 中的标准 `NSOpenPanel` Powerbox 授权；若保留串口控制台再按需添加 `com.apple.security.device.serial = true`）；
   - **严禁包含** `com.apple.security.cs.disable-library-validation = true`，并移除易受审核问询的 `files.downloads.read-write`。
2. **彻底剥离宿主机伪终端 `flutter_pty`（消除 `_fork` / `_execvp` 沙盒逃逸符号）**：
   - 构建时传入 `--dart-define=ATERMIUS_MAS_SANDBOX=true` 关闭 `localConsoleSupported`，隐藏全部 UI 与 MCP 中的本机 Shell（Local Console）入口；
   - 在 `desktop/apps/client/macos/Podfile` 中按环境变量条件剔除 `flutter_pty` Pod，确保最终二进制不含 `open('/dev/ptmx')`、`fork()`、`execvp()` 调用。
3. **沙盒不兼容子进程调用降级**：
   - 禁用 `Process.start(Platform.resolvedExecutable, ['--new-window', ...])` 跨进程新建窗口；
   - 将 `/usr/bin/open` 与 `/bin/chmod` 子进程调用替换为原生 `NSWorkspace.shared.open` 与 POSIX `chmod(2)` FFI；
   - 隐藏调用 `/usr/bin/security` 跨容器读取第三方钥匙串的一键迁移入口，仅保留 `NSOpenPanel` 文件导入。
4. **隐私清单与加密豁免对齐**：确保 `macos/Runner/PrivacyInfo.xcprivacy` 已挂载至 `PBXResourcesBuildPhase`，且 `macos/Runner/Info.plist` 包含 `<key>ITSAppUsesNonExemptEncryption</key><false/>`。
5. **商店物料与防导流红线（Guideline `2.3` & `3.1.1`）**：MAS 版的商店截图与描述严禁展示“本机宿主机 Shell”，且应用内严禁弹窗诱导用户前往外部官网下载非沙盒版。

### 4.3 方案三：官网直发全功能桌面版（Developer ID + Apple Notarization 公证）

针对需要**本机交互式 Shell (`flutter_pty`)、多独立 OS 进程窗口、外部编辑器直调与本地回环 MCP 服务**的重度桌面用户，保持通过官网 / GitHub Releases 独立分发 macOS `.dmg` / `.zip`：
- 保留 `app-sandbox = false`，开启 Hardened Runtime（`codesign --options runtime --timestamp`）；
- 使用 `Developer ID Application` 证书签名后，调用 `xcrun notarytool submit --wait` 完成 Apple 官方公证，并执行 `xcrun stapler staple` 钉合离线公证票据。

---

## 第五步：`1.0.1 (Build 2)` 迭代升级与全自动换图提审流水线

1. **折叠屏 iPhone Duo 与动态视口自适应**：
   - 将 Swift 后台 SSH 保活与 MCP 生命周期判定全面迁移至 `SceneDelegate` (`UIScene` activationState)，替代进程级通知；
   - 借助 `GlobalKey` 锚定 `TerminalView` 树并在折叠/分屏切换（`shortestSide < 600` ⇄ `>= 600`）时保持活跃 SSH 连接不断流、历史缓冲区零丢失，同时补全非对称水平 `SafeArea` 避让；
   - `archive_appstore.sh` Step 3c 增加清理未剥离的 `Flutter.framework/{Headers,Modules}` 目录，确保 Release IPA 重签洁净。
2. **原生 AI 预留接口与在线 SSH 只读小工具**：
   - 预留无网络端口的进程内原生 MCP 网关（`McpService.createNativeGateway` / `McpNativeBridge` 与 `MethodChannel('atermius/mcp_native')`，iOS `AtermiusNativeMcpBridge.shared`），复用逐机权限策略与锁屏撤销且完全遵守 iOS 不开放本地 HTTP 监听端口规范；
   - 新增 4 项只读在线 SSH 诊断工具（`ssh_system_overview`、`ssh_network_probe`、`ssh_process_snapshot`、`ssh_service_logs`）及客户端弹窗 `showSshLiveToolsSheet`。
3. **生图 AI 赋能 + 32 张四语高精度海报与 API 自动发布**：
   - 配合 `scripts/build_appstore_posters.py --bg-dir <AI_BG_DIR>` 将 5 张 3D 液态玻璃工作室背景与来自真实 `iPhone 16 Pro Max` (`1320×2868`) / `iPad Pro 13-inch (M4)` (`2064×2752`) 模拟器的 RFC 5737 脱敏截图合成为 32 张 24-bit RGB 无 Alpha 通道高清海报；
   - 通过 `scripts/publish_appstore_api.py --version 1.0.1 --build-number 2 --create-version --replace-screenshots --wait-and-submit` 全自动完成 IPA 上传、四语（`zh-Hans` / `en-US` / `ja` / `ru`）32 张海报替换、`whatsNew` 写入、Build `2` 绑定及提审。
   - 环境变量与私钥凭据始终保存在本机 `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`，严禁写入仓库或脚本。
