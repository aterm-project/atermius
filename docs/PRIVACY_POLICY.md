# Atermius 隐私政策与技术支持 / Privacy Policy & Technical Support

**应用名称 / Application:** Atermius  
**运营主体 / Developer:** Zenwalk LLC  
**生效日期 / Effective Date:** 2026-11-18  
**最后更新 / Last Updated:** 2026-11-18  
**快速跳转 / Quick Links:** [简体中文隐私政策](#隐私政策简体中文) · [Privacy Policy (English)](#privacy-policy-english) · [技术支持与联系我们 / Technical Support (`#support`)](#support)

---

## 隐私政策（简体中文）

欢迎使用 **Atermius**（以下简称“本应用”或“我们”）。本应用是一款面向开发者与系统运维人员的安全远程终端与文件管理客户端（支持 SSH、SFTP/SCP、Telnet、RDP 与 VNC）。我们坚持**“本地优先（Local-First）”**与**“端到端零知识加密（Zero-Knowledge End-to-End Encryption）”**设计原则，最大限度保护您的服务器凭证、密钥与个人隐私。

### 1. 我们的核心隐私架构

1. **免登录本地加密模式（默认工作模式）**  
   首次启动本应用无需注册或登录任何账户。您创建的本地配置库（包括主机 IP/域名、端口、用户名、密码、SSH 私钥、证书指纹、端口转发规则及命令片段）默认加密存储在您设备本机的应用沙盒内，加密主密钥受操作系统安全钥匙串（iOS / iPadOS / macOS Keychain）保护。**在纯本地模式下，您的任何配置与凭证均不会离开您的设备，我们无法访问、读取或恢复您的任何本地数据。**

2. **可选自托管云端同步模式（Self-Hosted Encrypted Vault）**  
   仅当您主动配置并登录自托管同步服务器时，跨设备同步功能才会启用。所有敏感业务记录（主机配置、密钥、凭证以及按 4 MiB 逻辑分块采用 AES-GCM 加密的主机附件）均在您的客户端设备本地完成认证加密（AEAD）与设备数字签名后再行上传。同步服务器仅存储不透明密文（Opaque Ciphertext）与签名引用，不持有您的主密码或解密密钥，无法查看任何明文主机信息或私钥。

### 2. 我们收集与处理的信息类型

我们遵循最小必要原则，**绝不嵌入第三方广告 SDK，绝不向数据经纪商出售任何用户数据，也绝不进行跨应用或跨网站追踪（`NSPrivacyTracking = false`）**。

根据您启用的功能范围，涉及的数据处理如下：

| 使用场景 | 数据类别 | 具体用途 | 是否关联身份 | 是否用于追踪 |
| :--- | :--- | :--- | :--- | :--- |
| **纯本地模式（默认）** | 不向开发者收集个人数据 | 所有数据仅保存在用户设备本地加密存储中 | 不适用 | 否 |
| **可选云端同步账户** | **电子邮箱地址（Email Address）** | 用于账户注册、登录身份验证、两步验证与安全恢复通知 | 是 | 否 |
| **可选云端同步与推送提示** | **设备标识符与推送令牌（Device ID / APNs & FCM Token）** | 用于管理已授权的同步设备列表；当您在设置中主动开启“后台同步提示”时，用于向设备投递不含明文业务数据的同步唤醒提示（不会在后台解密已锁定保险库） | 是（登录同步账户时） | 否 |
| **可选云端账户设备管理** | **浏览器 User-Agent、最近 IP 和最多 10 个历史 IP，或原生客户端的设备名称和平台** | 保存在您登录的服务端，用于在账户设备列表中识别和管理登录会话 | 是（登录同步账户时） | 否 |
| **可选云端同步负载** | **客户端端到端加密密文（Encrypted Vault Payload）** | 在您授权的多台设备之间同步经客户端本地加密后的配置记录与附件密文 | 是 | 否 |
| **基础传输诊断** | **最小化传输状态与崩溃诊断（Diagnostics）** | 当启用可选推送传输组件时，用于保障消息通道投递可靠性与排查客户端连接异常，绝不包含任何终端输入输出、SSH 私钥或服务器登录口令 | 否 | 否 |

### 3. 系统权限与设备端 API 使用说明

为提供完整的远程运维体验，本应用仅在您主动触发对应功能时按需请求以下系统权限或调用操作系统接口：

- **本地网络（Local Network）**：当您连接位于同一局域网（LAN / 子网）内的 SSH、SFTP、Telnet、RDP 或 VNC 主机时，系统将请求本地网络访问授权。直连流量仅在您的设备与您指定的目标主机之间直接传输。
- **面容 ID / 触控 ID（Face ID / Touch ID）**：当您启用生物识别保护时，通过 Apple 系统 `LocalAuthentication` 框架在设备安全隔区（Secure Enclave）本地完成验证以解锁加密配置库或私钥。本应用永不读取、存储或上传您的生物特征原始数据。
- **文件、相册、媒体库与相机（Files, Photo Library, Media & Camera）**：仅在您主动选择导入 SSH 密钥/配置文件、更换自定义工作区/终端背景图片、或向主机卡片添加/导出本地加密附件时在本地调用选择器组件，绝不在后台静默访问您的相册、麦克风或摄像头。
- **位置权限说明（Location Services — When In Use）**：仅由内嵌的系统媒体/拍摄附件选择器组件在您主动拍摄带元数据的照片附件时按需引用；本应用的核心终端与远程桌面功能绝不收集、记录或上传您的地理位置。
- **Apple 规定原因 API（Required Reason APIs）声明**：本应用在设备本地按 Apple 规范使用 `UserDefaults`（`CA92.1`，保存界面语言、主题配色与本机偏好设置）、文件时间戳接口（`C617.1`，展示本地配置文件与 SFTP 传输文件的修改时间）、磁盘空间查询接口（`E174.1`，写入本地加密数据库与下载文件前检查剩余存储空间）以及系统单调时钟（`35F9.1`，精确测量网络连接握手与超时时间）。上述接口严禁且绝不用于构建设备指纹（Fingerprinting）。

### 4. 网络直连、网关与第三方数据共享

- **直接远程连接**：当您在原生客户端发起 SSH、SFTP、Telnet、RDP 或 VNC 直连时，网络数据包由您的设备直接发往您自行填写的目标服务器；我们不会中转、截获或记录您的会话内容。
- **用户自配网关 / Relay**：若您主动使用自托管服务器提供的受限字节中继（Relay）或远程桌面网关（如 `guacd`），相关会话按您所连接服务端的管理员安全策略运行，请仅连接您信任的自建或组织基础设施。
- **法律合规披露**：除法律法规强制要求或保护系统免受恶意攻击所必需外，我们不会向任何无关第三方披露您的账户元数据。

### 5. 数据保留与账号应用内永久删除（符合 Apple Guideline 5.1.1(v)）

1. **本地数据清除**：您可以随时在应用内删除单条主机、密钥或整个本地加密配置库，也可以通过直接卸载本应用立即清除设备沙盒内的所有本地数据（卸载后如无提前导出的备份文件，数据无法找回）。
2. **可选云端账户应用内一键永久删除**：如果您注册并登录了云端同步账户，您拥有随时在应用内直接永久注销账户的完整权利，无需人工联系客服审批：
   - **操作路径**：打开本应用 -> 进入 **设置（Settings）** -> 打开 **账户与登录（Account & sign-in）** 并点击 **“密码、两步验证与恢复”**（或直接在顶部设置分类中切换至 **“账户安全 / Account security”**）-> 滑动至底部 **“账户删除（Account deletion）”** 面板 -> 点击 **“安排账户删除（Schedule account deletion）”** -> 输入 `DELETE` 并验证账户密码确认。
   - **删除效果**：确认提交后，服务器将**立即吊销该账户下的全部活动登录会话与设备授权令牌**，客户端同步清空本机登录状态；在服务器展示的宽限期（`purge_after`）截止时，您的个人账户信息、个人加密保险库密文及在其他共享保险库中的成员访问权限将被永久物理清除且不可恢复（宽限期内若属误操作，可重新验证身份取消注销）。您也可以随时发送邮件至 yangyifeifly@gmail.com 请求协助核销数据。

### 6. 儿童隐私保护

本应用属于专业信息技术与软件开发工具（年龄分级 `4+`），不针对未满 13 周岁（或您所在司法辖区规定的最低数字同意年龄）的儿童设计，也不会故意收集儿童的个人信息。如发现误收集情况，请立即联系 yangyifeifly@gmail.com，我们将第一时间予以彻底删除。

### 7. 您的全球隐私权利（GDPR / CCPA / APPI 等）

根据您所在国家或地区适用的数据保护法律（包括但不限于欧盟《通用数据保护条例》GDPR、美国加州消费者隐私法 CCPA/CPRA、日本《个人信息保护法》APPI 等），您对与您关联的账户信息享有知情权、访问权、更正权、可携带权（支持在应用内导出全部主机与配置归档）、限制处理权及删除权（被遗忘权）。您可直接通过应用内置的数据导出与账户删除功能自助行使上述权利，或通过下方联系方式与我们取得联系。

### 8. 本政策的变更

当我们因功能演进或法律法规更新对本隐私政策作出重大调整时，将在本页面更新“最后更新”日期并在应用版本说明中予以提示。

---

## Privacy Policy (English)

Welcome to **Atermius** ("the App", "we", "us", or "our"). Atermius is a security-focused remote terminal, file transfer, and remote desktop client supporting SSH, SFTP/SCP, Telnet, RDP, and VNC. We engineer our product around **Local-First architecture** and **Zero-Knowledge End-to-End Encryption** so that your infrastructure credentials and cryptographic keys remain exclusively under your control.

### 1. Core Security & Privacy Architecture

1. **Offline Local Mode by Default (Zero Mandatory Sign-Up)**  
   You can use the App's full client capabilities immediately after installation without registering an account. In Local Mode, all host configurations, IP addresses, usernames, passwords, SSH private keys, certificate fingerprints, port-forwarding rules, and snippets are stored encrypted inside the local app sandbox on your device, protected by the Apple Keychain (and optional Face ID / Touch ID). **In Local Mode, none of your configurations or credentials ever leave your device, and we have zero access to your data.**

2. **Optional Self-Hosted Encrypted Synchronization**  
   Cross-device Vault synchronization is strictly opt-in and only activates if you explicitly configure and sign into a compatible self-hosted server. Every Vault record (hosts, credentials, keys, and AES-GCM 4 MiB chunked attachments) is encrypted using Authenticated Encryption with Associated Data (AEAD) and digitally signed on your device *before* transmission. The server stores opaque ciphertext only and never possesses your master password or decryption keys.

### 2. Information We Collect and Process

We practice strict data minimization: **we embed zero third-party advertising SDKs, never sell personal data to third parties or data brokers, and never track you across third-party apps or websites (`NSPrivacyTracking = false`).**

| Mode / Feature | Data Category | Purpose of Processing | Linked to Identity | Used for Tracking |
| :--- | :--- | :--- | :--- | :--- |
| **Local Mode (Default)** | None collected by developer | Stored exclusively on your device in an encrypted local profile | N/A | No |
| **Optional Cloud Sync Account** | **Email Address** | Account authentication, two-factor security verification, and account recovery | Yes | No |
| **Optional Sync & Push Hints** | **Device Identifiers & Push Tokens (APNs / FCM)** | Managing authorized sync devices and, only when explicitly enabled in Settings, delivering payload-free background synchronization hints (never decrypts a locked Vault in the background) | Yes (when signed in) | No |
| **Optional Cloud Sync Vault** | **End-to-End Encrypted Ciphertext** | Synchronizing client-encrypted host records and encrypted attachments across your authorized devices | Yes | No |
| **Transport Diagnostics** | **Minimal Diagnostic Metadata** | Ensuring reliable push/transport delivery and diagnosing connectivity failures when push components are active; never includes terminal I/O, SSH keys, or server passwords | No | No |

### 3. System Permissions & Apple Required Reason APIs

The App requests operating-system permissions strictly on demand when you invoke a corresponding feature:

- **Local Network:** Requested when you initiate direct SSH, SFTP, Telnet, RDP, or VNC connections to servers or devices on your local area network (LAN). Traffic flows directly between your device and your target host.
- **Face ID / Touch ID:** Performed locally via Apple's `LocalAuthentication` framework and Secure Enclave to unlock your encrypted local profile or SSH keys. Biometric data is never accessed, stored, or transmitted by the App.
- **Files, Photo Library, Media & Camera:** Invoked locally only when you choose to import key/configuration files, customize workspace/terminal background images, or attach/export files for encrypted host records. The App never accesses your photos or camera silently in the background.
- **Location Services (When In Use):** Referenced solely by the embedded photo/camera attachment picker component if you capture media with metadata; the App never tracks, logs, or transmits your geographic location.
- **Apple Required Reason APIs:** On-device APIs are used strictly for their declared platform purposes: `UserDefaults` (`CA92.1`, storing local UI preferences, language, and terminal color themes), File Timestamp APIs (`C617.1`, managing local configuration files and SFTP transfer modification timestamps), Disk Space APIs (`E174.1`, verifying available storage prior to writing local databases and file transfers), and System Boot Time / Monotonic Clock APIs (`35F9.1`, measuring connection handshake intervals and timeouts). None of these APIs are ever used for device fingerprinting.

### 4. Direct Network Connections & Third-Party Sharing

- **Direct Connections:** Native SSH, SFTP, Telnet, RDP, and VNC connections are established directly from your device to the remote hosts you configure. We do not proxy, inspect, or log your remote sessions.
- **User-Configured Gateways / Relays:** If you connect through a self-hosted Relay or remote desktop gateway configured by your organization, session handling is governed by the administrator of that self-hosted server.
- **Legal Compliance:** We do not share account metadata with third parties except where strictly required by applicable law.

### 5. Data Retention & In-App Account Deletion (Apple Guideline 5.1.1(v))

1. **Local Data Deletion:** You may delete individual hosts, keys, or entire local profiles within the App at any time, or uninstall the App to immediately erase all sandboxed local data on your device.
2. **Direct In-App Cloud Account Deletion:** If you sign into an optional cloud synchronization account, you can permanently delete your account directly inside the App at any time without contacting customer support:
   - **In-App Path:** Open **Settings** -> **Account & sign-in** -> tap **"Password, two-factor and recovery"** (or select **"Account security"** from the Settings category selector) -> scroll to **"Account deletion"** -> tap **"Schedule account deletion"** -> type `DELETE` and confirm with your password.
   - **Immediate & Permanent Effect:** Confirming deletion immediately revokes all active login sessions and device tokens and clears local authenticated state on your device. Upon expiration of the server's displayed grace window (`purge_after`), your account record, personal encrypted Vault payloads, and memberships in shared Vaults are permanently and irreversibly purged from server storage. You may also contact us at yangyifeifly@gmail.com for assistance at any time.

### 6. Children's Privacy

The App is a professional software engineering and IT administration utility (rated `4+`) and does not knowingly collect personal information from children under the age of 13 (or the applicable age of digital consent in your jurisdiction). If you believe such information has been inadvertently provided, please contact yangyifeifly@gmail.com for immediate removal.

### 7. International User Rights (GDPR / CCPA / APPI)

Depending on your jurisdiction (including the EEA/UK under GDPR, California under CCPA/CPRA, and Japan under APPI), you have the right to access, rectify, export (via built-in archive export), restrict, or erase your personal account data. You can exercise data portability and permanent deletion directly inside the App or by emailing yangyifeifly@gmail.com.

### 8. Changes to This Policy

We may update this Privacy Policy periodically to reflect technical improvements or regulatory requirements. Material changes will be posted on this page with an updated "Last Updated" date.

---

<a id="support"></a>

## 技术支持与联系我们 / Technical Support & Contact Us

如果您在使用 **Atermius** 过程中遇到任何连接问题、功能建议、数据导出疑问或隐私合规问询，请参考以下快速自助指南或直接联系我们的支持团队。  
If you need technical assistance, troubleshooting guidance, or privacy support regarding **Atermius**, please review the quick FAQ below or reach out to us directly.

### 常见问题快速排障 / Quick Troubleshooting FAQ

1. **首次打开是否需要注册账号或自建服务器？ / Do I need an account or server to use the app?**
   - **不需要 / No.** 启动后默认进入受本机钥匙串保护的本地加密模式（Local Mode），即可完整使用 SSH、SFTP、Telnet、RDP、VNC 连接、密钥生成与端口转发。
2. **局域网内 SSH / RDP 无法连接怎么办？ / Cannot connect to a LAN host on iOS / iPadOS?**
   - 请前往系统 **设置 -> 隐私与安全性 -> 本地网络（Settings -> Privacy & Security -> Local Network）**，确认已开启本应用的本地网络开关，并核对目标服务器防火墙与端口号（默认 SSH `22` / RDP `3389` / VNC `5900`）。
3. **忘记本地密码或自托管同步主密码能否由官方找回？ / Can you recover my master password?**
   - 由于采用零知识加密设计，我们不保存您的密码或私钥副本。请妥善保管您导出的加密备份或恢复凭据；若遗忘本机独立密码库口令，可重置并新建本地配置库。
4. **如何永久注销云端同步账户？ / How do I delete my optional cloud sync account?**
   - 在应用内前往 **设置 -> 账户安全 -> 账户删除 -> 安排账户删除**（**Settings -> Account security -> Account deletion -> Schedule account deletion**）即可一键自助完成会话吊销与永久删除。

### 联系方式 / Contact Channels

- **支持与隐私联系邮箱 / Support & Privacy Email:** `mailto:yangyifeifly@gmail.com`
- **问题反馈需附带信息（请勿发送任何私钥或密码！）/ Helpful Diagnostics (Never include private keys or passwords!):**
  - 设备型号与系统版本 / Device model & iOS / iPadOS / macOS version
  - 应用版本号 / App version (e.g., `1.0.0 (1)`)
  - 目标协议与复现步骤（如 SSH / SFTP / RDP 错误码）/ Protocol & steps to reproduce
- **响应时效 / Response Time:** 我们通常在 **2–3 个工作日（2–3 business days）** 内回复所有技术支持请求，并在法定期限内处理所有隐私权利申请。
