# RDP、VNC 与本机 Console

[文档导航](README.md) · [平台矩阵](FEATURES.md) · [安装构建](INSTALLATION.md)

## 选择连接路径

| 路径 | 前提与范围 |
| --- | --- |
| Windows 原生 RDP | 与应用匹配的 `atermius_rdp.dll` bundle，直接连接目标，不依赖 guacd |
| Android 原生 RDP | APK 内的 `libatermius_rdp.so`（arm64-v8a、x86_64），直接连接目标，不依赖 guacd 或外部查看器 |
| 原生 VNC | 使用应用中的直接 RFB 实现，具体平台取决于构建和运行能力 |
| 账户模式浏览器 RDP/VNC | 服务端配置 guacd、来源和目标策略 |
| 临时访客 SSH/RDP | 单独的可信分享网关，要求 SQLite、HTTPS、胶囊与链接策略 |
| 本机 Shell / 串口 Console | 桌面操作系统和相应 Shell/设备；浏览器不能创建系统进程或串口 |

添加主机时选择协议并检查端口，默认 SSH/RDP/VNC 分别为 22/3389/5900；保留自定义端口。密码、证书指纹及协议设置随主机加密保存。SSH 跳板、转发、tmux 和 SSH 文件管理不是 RDP/VNC 设置。

## 证书与登录

Windows 在取得被拒证书时显示目标和证书 DER 的 SHA-256。先与可信渠道核对，再选择信任保存；指纹变化需要再次确认。取消、保存失败或工作区切换不会放行，不使用忽略证书验证来绕过问题。`20008` 是通用 TLS 握手错误，没有取得证书时也可能是端口或 TLS 配置错误。

可在主机编辑器录入管理员提供的证书 SHA-256。Windows 引擎严格匹配；网关要求支持 `cert-fingerprints`，不会自动接受首次证书。目标使用 NLA 时需提前保存用户名、密码和必要域信息；当前没有登录过程中补填 NLA 凭据的完整对话框。

## 显示、窗口与资源

主机编辑器提供 RDP/VNC 显示选项，包括自动、预设或自定义尺寸。RDP 实时调整依赖目标的显示控制能力；VNC 仅在协商 ExtendedDesktopSize 后尝试改变远端尺寸，否则提供本地适应/实际大小缩放。多显示器、独立窗口和分屏依赖当前平台与引擎能力，不等于每台设备都具备这些能力。

Windows 原生引擎提供文本/文件剪贴板与可用资源重定向的设置，能力不可用时应保持禁用或显示原因。摄像头、麦克风、智能卡、打印机、USB 和物理多显示器仍需要真实硬件验收。应用不安装或替换 USB 驱动；设备须具备兼容现有系统绑定。临时访客网关不开放文件、驱动器、打印或录制通道。

远程桌面获得焦点后，按键发往远端；Windows 的 **Ctrl+Alt+Home** 打开本机会话菜单，其他绑定按应用设置处理。

直接连接的 RDP/VNC 会话在主机“剪贴板文本”开启（默认开启）时自动双向同步文本剪贴板；iOS、macOS 与浏览器只自动同步远端到本机。规则与 Android 的限制见 [Clipboard](#clipboard)。

## Android 直接连接

Android 上 RDP/VNC 只走直接连接，在会话标签和分屏内显示：VNC 由应用内 RFB 实现连接目标地址；RDP 由 APK 内引擎连接。连接使用系统路由和当前 VPN，不绑定特定网络，也不读取进程环境中的 HTTP(S) 代理；VPN 阻断目标时连接照常失败。任何模式（含已登录账户）都不会回退到本机 `127.0.0.1:4822` 或服务端桌面网关。未打包引擎的 APK 中，RDP 明确报告“无法启动 RDP 引擎”。

证书流程与 Windows 相同：首次或变化的证书显示 SHA-256，用户确认保存后按该指纹重连。Android 引擎不读取系统 CA 库，CA 签发证书同样需要确认指纹。引擎包含 RDPDR 磁盘重定向：默认映射本机已挂载的内部存储和 SD 卡/USB 存储卷，可按主机关闭，也可另加文件夹；需要“所有文件访问权限”，未授权时跳过这些存储卷并提示，连接照常进行，详见[存储映射](#storage-mappings-and-direct-touch)。引擎还提供远程音频本机播放、麦克风重定向（OpenSL ES）和摄像头重定向（NDK Camera2 采集，由设备自带的 MediaCodec H.264 编码器编码；无该编码器的设备摄像头不出画面）；音频以 PCM 传输，不启用实验性的 MediaCodec AAC。麦克风需要系统录音权限，摄像头需要相机权限；设备打不开（例如未授权）时引擎记录错误，该方向无声或无画面，会话照常继续。不提供打印机、智能卡、USB 重定向，相关选项按引擎能力禁用；文本剪贴板与显示调整保留。引擎的 FreeRDP 配置目录位于应用私有目录。WinPR 需要 JavaVM，`MainActivity` 启动时以 `System.loadLibrary` 加载引擎以运行其 `JNI_OnLoad`；未注册 JavaVM 时引擎拒绝创建连接，RDP 报告不可用而不会使应用退出。

Android 运行时权限只在用户发起 RDP 连接（打开连接、重试或“恢复连接”）时、握手之前询问；外部 AI（MCP）发起的连接不会弹出任何权限请求，缺少的权限只会让该次连接跳过相应重定向。映射本机磁盘（或主机含本机文件夹）而尚未授予“所有文件访问权限”时，先在会话标签内显示说明：“允许访问”随后打开系统的所有文件访问设置页（Android 10 及以下为系统权限对话框），“暂不”本次不映射，“此主机不映射磁盘”只关闭本设备上的开关。主机开启麦克风或摄像头且引擎支持该重定向时，以系统对话框请求麦克风（RECORD_AUDIO）或摄像头（CAMERA）权限。同一主机的每项权限在应用进程内只询问一次，重连不会反复打扰；标签不可见时不询问。被拒绝时本次连接去掉该重定向，同步的主机设置保持不变，会话内提示跳过了什么以及在哪里开启。在主机 RDP 选项中打开麦克风或摄像头开关会立即请求对应权限，并在开关下显示“已在本设备上允许”，或提供“允许”/“打开应用设置”（系统不再弹出对话框时）。

引擎构建：`apps/client/native/desktop/android/build_engine.sh` 用 NDK r28+ 及 `deps.lock` 中固定摘要的官方 OpenSSL 3.5.9 与 FreeRDP 3.33.0 源码包，生成每个 ABI 一个自包含 `.so`（依赖静态链接，16 KB 页对齐），并由 `verify_engine.py` 检查导出、依赖（系统库及其每个导入符号在 API 24 即存在，更新版 API 只能经运行时检查的弱引用使用）和对齐。脚本不联网，源码包需预先放入 `--deps` 目录。随后以 `-Patermius.rdpEngineDir=<输出目录>`（可加 `-Patermius.requireRdpEngine=true`）构建 APK，许可证随包放在 `assets/licenses/atermius_rdp/`；用 `integration/native/android_apk_abi_check.py --require-lib libatermius_rdp.so` 核对 APK。

## 网关部署

网关可访问目标登录信息、画面和输入，是受信组件。仅将 guacd 放在受控私有网络，限制目标范围，不向外发布 4822。普通 SSH 字节 Relay 不需要 guacd。

使用[服务端部署指南](install/server.md)组装独立 API/Web；常规远程桌面添加 `compose.desktop.yaml` 并配置 Relay 目标策略。临时分享另加 `compose.share.yaml`，参考[分享配置](CLOUD-SHARING.md)。操作时保留原来的 TLS/Web/其他覆盖文件，并在仓库根目录执行 Compose 命令。

Windows 直接 RDP 构建步骤见[桌面版构建指南](install/desktop.md)。使用配套 FreeRDP 源码摘要与许可证，不引用历史测试机器的构建目录，也不单独替换 Dart 程序或 DLL。

## 已知边界与验证

RDP 目标的 NLA、域策略、所有键盘布局、资源/剪贴板组合仍需相应环境验证。VNC 支持的传统 RFB 传输不提供端到端加密，未实现所有专有/VeNCrypt 认证；传统剪贴板按 Latin-1 处理，不承诺完整 Unicode 剪贴板，含其他字符的文本不会发送并给出提示。当前源码 CI 的组件/协议检查不等于新的 Windows/macOS/Android/iOS 可视 GUI 验收。

针对性测试入口为 `apps/client/test/desktop_protocol_test.dart`、`desktop_host_editor_test.dart`、剪贴板的 `desktop_clipboard_sync_test.dart`/`desktop_clipboard_session_test.dart`/`desktop_clipboard_view_test.dart`/`local_clipboard_test.dart`、Android 路由的 `android_direct_desktop_test.dart`/`android_desktop_route_test.dart` 及显式启用的网关/Console 验收文件。前后端链路参考[集成说明](INTEGRATION.md)。环境条件不足的跳过不算真实目标通过；物理硬件和当前安装包验收单独记录。

参考：[Guacamole 协议](https://guacamole.apache.org/doc/gug/guacamole-protocol.html)、[RDP 配置](https://guacamole.apache.org/doc/gug/configuring-guacamole.html)、[Flutter Windows 分发](https://docs.flutter.dev/platform-integration/windows/building)。


## Keyboard, pointer and fullscreen controls

Android 首页及设置页进入全屏后保留导航和 Tools 菜单，始终可以选择退出全屏；选中会话时仍隐藏导航，仅放大当前面板。

Android 设置 → 远程桌面提供两种键盘模式，默认“悬浮叠加（保持分辨率）”：软键盘及特殊键栏覆盖画面，保持原有远端尺寸及本地缩放。选择“跟随键盘调整”则缩小可见区域，并让跟随窗口的会话调整远端分辨率；固定分辨率或服务器决定尺寸的会话仍保留其分辨率。选择仅保存在当前设备，不进入云端 Vault。

面板顶部白色小横条可展开全屏/退出全屏、复制、取消分屏和关闭操作。三个远程桌面悬浮按钮作为一个整体拖动：贴左/右边缘时纵向排列，贴上/下边缘时横向排列，键盘弹出后仍位于其上方。鼠标/触控板模式由客户端绘制光标；直连 RDP 接收 FreeRDP 解码及缓存的形状、热点、默认/隐藏状态与位置更新，VNC 使用 RichCursor/PointerPos，光标不烘焙进远端帧缓冲。

SSH/Telnet 的终端菜单和标签右键菜单（Android 长按标签）提供 Disconnect／断开连接。主动断开保留原标签、分屏及终端记录，并暂停每 5 秒自动重连；点击“恢复连接”后重新建立连接并恢复后续自动重连。组合标签只断开当前选中的面板。关闭标签仍通过原关闭入口执行。断开时也会取消尚未完成的连接，延迟返回的旧连接不能重新接管面板。

Android 的键盘、触摸/鼠标切换和三点参数菜单位于同一个贴边悬浮按钮组，可共同拖动。常规手机及左右分屏内横向并排，极窄面板改为纵向排列。Android 全屏会隐藏应用标签栏和状态栏，将当前面板铺满内容区；退出按钮或系统返回恢复原有分屏和会话。组合标签也可以拖动其中当前选中的会话，以重新排列分屏；连接与终端记录不会复制或重建。

账户与本地配置下的 SSH、Telnet、RDP、VNC 会话断开后可点击“恢复连接”。SSH/Telnet 已建立的会话中断后每 5 秒尝试重连；首次连接失败由用户手动重试，主机密钥拒绝停止自动弹窗重试。恢复连接使用最新保存的主机设置（例如 RDP 磁盘映射），保留原标签、分屏位置及终端记录，不重放先前输入。关闭标签、锁定配置、切换账户或 Vault 后，旧作用域不能继续重连；主机密钥和 RDP 证书仍执行原有验证流程。

On Android, RDP and VNC show a dock on the edge of each pane. The keyboard button opens the system keyboard together with a special-key bar. Ctrl/Alt/Shift/Win apply to the next key after a single tap; double-tap to lock, then tap again to release. Composed text is sent when the IME commits it. The adjacent button switches between direct touch and a relative mouse touchpad. In touchpad mode, tap clicks at the cursor, slide moves it, two fingers scroll or right-click, and a second tap held down drags. The dock can move vertically or to the opposite edge and stays inside the resized pane above the keyboard.

The navigation bar's Tools menu and remote desktop's three-dot menu provide Enter fullscreen / Exit fullscreen. Windows covers the current monitor and restores its saved placement; macOS uses native fullscreen Spaces; Android hides system bars through its own-window insets controller; iOS uses supported manual overlays. Web uses the browser fullscreen API and follows browser exit events. An unavailable platform operation keeps the normal window and reports the failure. System-owned window captions may remain visible in Android desktop windowing mode.

On Android/iOS, pull a tab down to lift it from a scrolling strip, then drag to a highlighted pane edge. A diagonal pull is accepted while a horizontal swipe still scrolls tabs. A drop in the centre leaves the layout intact; a small amount of corner jitter keeps the highlighted direction. Stationary long-press still opens the tab/group context menu.

VNC IME text retains legacy Latin-1 keysyms where available, and uses Unicode keysyms for additional characters, as required for maximum compatibility by [RFC 6143 §7.5.4](https://www.rfc-editor.org/rfc/rfc6143.html#section-7.5.4). RDP uses Unicode text events when no soft modifier is active.

## Clipboard

Direct RDP (built-in engine) and VNC sessions sync text automatically while connected when the Host's **Clipboard text** option is on. It is on by default; VNC Hosts have the same switch under VNC display. Turning it off drops remote text and refuses pastes for that Host. Gateway sessions (account-mode browser RDP/VNC and guest links) keep the manual menu items only.

- Remote to this device: text copied on the remote computer is placed on this device's clipboard. Text over 64 KiB is not copied, with a notice. Remote clipboard content from before the connection was established never replaces the local clipboard.
- This device to remote: like mstsc, each new connection first offers the local text. After that the local clipboard is checked when the desktop gains focus, when the app returns to the foreground and, on Android, when the clip changes while Atermius has focus (for example in the keyboard's clipboard). Only text that changed since the last sync is sent, and text that came from the remote is never sent back.
- Never sent automatically: secrets Atermius copied itself (credentials from the credential viewer, recovery codes, invitation tokens, the MCP configuration, share and organization invitation links) and clips another app marked sensitive, such as an Android password manager. A notice says so; **Paste local clipboard text** in the session menu still sends them on request.
- iOS, macOS and browsers ask the user before an app reads the clipboard on its own, so there only remote to local is automatic; send local text with **Paste local clipboard text**.
- Detached and per-monitor windows on Windows offer local text through the main window, so one text is sent once.
- The session menu keeps **Paste local clipboard text** and **Copy remote clipboard text** as a fallback. They report an empty clipboard, content that is not text, a refused read or text over 64 KiB instead of doing nothing. If the RDP server has its clipboard channel turned off, a notice says so once and automatic sending stops for that connection.

On Android no app can request a clipboard permission, and none is granted at install time. Since Android 10 only the app in front can read the clipboard, so Atermius reads it only while it has window focus. Android 12 and later show "Atermius pasted from your clipboard" when it reads text copied in another app; automatic sync checks the clip's timestamp first and reads only a changed clip, so the message appears once per new copy. Some phones (MIUI/HyperOS, ColorOS, OriginOS and others) add their own clipboard permission, often set to Ask or Deny. When it refuses, paste and sync say so, and a paste offers a Settings button for Atermius' app page. Atermius reads every item of a clip: plain text, HTML as text, and links copied as a URI. A document behind a content URI is read only for a paste you start, and only when the copying app shared it through the clipboard; access Atermius has of its own, such as All files access, is never used for it. Terminal paste (keybar Paste, the touch toolbar's Paste and the paste shortcut) uses the same reader and messages and pastes up to 16 MiB at once.

## Storage mappings and direct touch

On Windows and Android, RDP maps this device's local disks by default. Each Host has a switch to turn this off. The switch is stored only on this device and is not synchronized with the Host, so a choice made on one device never exposes another device's disks. The file is kept out of Android Auto Backup and device transfer, and on Windows it lives under Local AppData rather than the roaming profile. The switch fails closed: a choice that could not be saved stays in force in that window and is written again later, and the editor says so. If the stored choices exist but cannot be read, no local disks are mapped until they can be, with a notice. At connect time the app lists the volumes present at that moment and sends each one as an explicit mapping. The engine never enables FreeRDP's all-drives or home-drive redirection, and it does not add drives inserted during the session.

- Windows: fixed, removable, optical and RAM disks that are ready. Network drives are excluded. Each drive is named by its letter and appears on the server as `\\tsclient\C`.
- Android: mounted internal storage and SD card/USB volumes. They require the system All files access permission. When the user starts a connection (open, Retry or Restore connection) without it, the session tab first explains why: Allow access then opens the system All files access page (the runtime permission dialog on Android 10 and earlier), Not now connects without local storage, and Don't map disks for this host turns this device's switch off. This is asked at most once per Host while the app runs, never for a hidden tab and never for a connection an external AI (MCP) starts. Without access the volumes are skipped with a notice and the connection proceeds.

A volume that is missing at connect time, such as a removed USB drive or a card reader without media, is skipped with a notice and does not stop the connection. Add disk and Add folder in RDP options still add explicit mappings to a Host. On Android, adding one first opens the system All files access setting, because the native RDP drive channel needs live filesystem access rather than a copied document URI. Explicitly added folders that are missing or synchronized from another operating system are reported before connecting. On Android, a Host folder is skipped with a notice while All files access is off, and the connection proceeds without it. A Host stores at most 8 folders, which keeps it readable by earlier versions that share the synchronized settings; a connection carries at most 32 mappings, Host folders and local disks together. A new mapping's path is limited to 259 UTF-8 bytes because FreeRDP's drive channel truncates longer paths; a longer path saved by an earlier version keeps the Host's settings readable and is skipped with a notice when connecting. On Windows the app turns off the system "There is no disk in the drive" dialog for its process, so a card reader or optical drive whose media is removed during a session only fails the remote file operation. Restore connection reconnects with the latest saved Host settings, so changes to mappings or to the switch apply on the next reconnect.

On Android the microphone and camera need the RECORD_AUDIO and CAMERA runtime permissions, and they are requested only where the RDP engine can redirect that device. Turning a Host's Microphone or Cameras switch on in RDP options asks right away; the switch then shows "Allowed on this device", or Allow or Open app settings when Android no longer shows its dialog. When the user starts a connection whose Host has either switch on and the permission is missing, Android's dialog appears before the handshake, with the same once-per-Host, visible-tab and no-MCP rules as storage. A refused device is left out of that connection only: the synchronized Host setting stays on, because another device may allow it, and the session names what was skipped and where to allow it. The manifest declares the microphone and camera as optional hardware, so devices without them can still install the app.

The Android native engine includes RDPDR drive redirection, RDPEI native touch, audio playback and microphone redirection (OpenSL ES) and camera redirection (NDK Camera2, encoded to H.264 by the device's MediaCodec encoder). The microphone and camera need the system microphone and camera permissions; a device that cannot be opened is logged and the session continues without it. When the server negotiates RDPEI, direct touch forwards separate contact IDs, movement, release and cancellation; changing panes, input modes or app focus releases the contacts. Servers without RDPEI use pointer fallback. Standard VNC has no native Windows touch channel: direct mode provides tap, drag, long-press right-click and two-finger natural scrolling; relative touchpad mode remains available.

Android file lists open a regular file with one tap through the system Open with chooser. The selected application receives a private, writable content URI for that file only. Local changes remain pending in the file manager footer until Upload is selected; remote conflicts still require confirmation. Long-press retains the file operations menu.

SSH/Telnet's Android keybar includes Shift alongside Ctrl and Alt: tap for the next key, double-tap to lock, tap again or Reset to release. The default terminal palette uses brighter, more saturated text; saved custom palettes and presets keep their colors.

Connection attempts open their tab before asynchronous credential lookup and network setup. The tab reports actual stages and provides Stop loading, Retry and Close. Retry uses the current saved settings in the same tab; late results from cancelled attempts cannot take over. An established session that later drops continues to use the existing reconnect controls.
