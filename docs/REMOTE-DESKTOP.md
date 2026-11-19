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

## Android 直接连接

Android 上 RDP/VNC 只走直接连接，在会话标签和分屏内显示：VNC 由应用内 RFB 实现连接目标地址；RDP 由 APK 内引擎连接。连接使用系统路由和当前 VPN，不绑定特定网络，也不读取进程环境中的 HTTP(S) 代理；VPN 阻断目标时连接照常失败。任何模式（含已登录账户）都不会回退到本机 `127.0.0.1:4822` 或服务端桌面网关。未打包引擎的 APK 中，RDP 明确报告“无法启动 RDP 引擎”。

证书流程与 Windows 相同：首次或变化的证书显示 SHA-256，用户确认保存后按该指纹重连。Android 引擎不读取系统 CA 库，CA 签发证书同样需要确认指纹。引擎包含 RDPDR 磁盘重定向：默认映射本机已挂载的内部存储和 SD 卡/USB 存储卷，可按主机关闭，也可另加文件夹；需要“所有文件访问权限”，未授权时跳过这些存储卷并提示，连接照常进行，详见[存储映射](#storage-mappings-and-direct-touch)。不提供打印机、智能卡、音频、摄像头、USB 重定向，相关选项按引擎能力禁用；文本剪贴板与显示调整保留。引擎的 FreeRDP 配置目录位于应用私有目录。WinPR 需要 JavaVM，`MainActivity` 启动时以 `System.loadLibrary` 加载引擎以运行其 `JNI_OnLoad`；未注册 JavaVM 时引擎拒绝创建连接，RDP 报告不可用而不会使应用退出。

引擎构建：`apps/client/native/desktop/android/build_engine.sh` 用 NDK r28+ 及 `deps.lock` 中固定摘要的官方 OpenSSL 3.5.9 与 FreeRDP 3.33.0 源码包，生成每个 ABI 一个自包含 `.so`（依赖静态链接，16 KB 页对齐），并由 `verify_engine.py` 检查导出、依赖和对齐。脚本不联网，源码包需预先放入 `--deps` 目录。随后以 `-Patermius.rdpEngineDir=<输出目录>`（可加 `-Patermius.requireRdpEngine=true`）构建 APK，许可证随包放在 `assets/licenses/atermius_rdp/`；用 `integration/native/android_apk_abi_check.py --require-lib libatermius_rdp.so` 核对 APK。

## 网关部署

网关可访问目标登录信息、画面和输入，是受信组件。仅将 guacd 放在受控私有网络，限制目标范围，不向外发布 4822。普通 SSH 字节 Relay 不需要 guacd。

使用[服务端部署指南](install/server.md)组装独立 API/Web；常规远程桌面添加 `compose.desktop.yaml` 并配置 Relay 目标策略。临时分享另加 `compose.share.yaml`，参考[分享配置](CLOUD-SHARING.md)。操作时保留原来的 TLS/Web/其他覆盖文件，并在仓库根目录执行 Compose 命令。

Windows 直接 RDP 构建步骤见[桌面版构建指南](install/desktop.md)。使用配套 FreeRDP 源码摘要与许可证，不引用历史测试机器的构建目录，也不单独替换 Dart 程序或 DLL。

## 已知边界与验证

RDP 目标的 NLA、域策略、所有键盘布局、资源/剪贴板组合仍需相应环境验证。VNC 支持的传统 RFB 传输不提供端到端加密，未实现所有专有/VeNCrypt 认证；传统剪贴板按 Latin-1 处理，不承诺完整 Unicode 剪贴板。当前源码 CI 的组件/协议检查不等于新的 Windows/macOS/Android/iOS 可视 GUI 验收。

针对性测试入口为 `apps/client/test/desktop_protocol_test.dart`、`desktop_host_editor_test.dart`、Android 路由的 `android_direct_desktop_test.dart`/`android_desktop_route_test.dart` 及显式启用的网关/Console 验收文件。前后端链路参考[集成说明](INTEGRATION.md)。环境条件不足的跳过不算真实目标通过；物理硬件和当前安装包验收单独记录。

参考：[Guacamole 协议](https://guacamole.apache.org/doc/gug/guacamole-protocol.html)、[RDP 配置](https://guacamole.apache.org/doc/gug/configuring-guacamole.html)、[Flutter Windows 分发](https://docs.flutter.dev/platform-integration/windows/building)。


## Text clipboard sharing

Direct RDP and VNC sessions share text automatically when the Host's **Clipboard text** setting is enabled. Windows uses clipboard change notifications while the desktop has focus; returning to a session also offers the latest local text. Remote text is copied to this device's clipboard, including in detached and monitor windows. Repeated text is not echoed back. RDP supports Unicode; the standard VNC clipboard supports Latin-1 only. Text is limited to 64 KiB in UTF-8. Files remain explicit actions in the session menu; image clipboard formats are not synchronized.

Atermius-copied credentials, recovery codes and tokens are skipped by automatic sharing. The session menu's explicit Paste remains available. Connections opened through MCP do not offer the local clipboard at startup. Gateway sessions keep the manual clipboard actions. On platforms which prompt for unattended clipboard reads, only incoming text is automatic.

直连 RDP/VNC 在主机“剪贴板文字”开启时自动同步文字。Windows 在远程桌面获得焦点时监听剪贴板变更，切回会话时也会同步最新文字；远端复制的文字自动写入本机，独立窗口和多显示器窗口同样适用。RDP 支持中文和 Emoji；标准 VNC 仅支持 Latin-1。文字上限为 UTF-8 64 KiB；文件仍由会话菜单主动发送或保存，图片不自动同步。应用复制的凭据、令牌及恢复码不会自动发送，仍可通过菜单主动粘贴。

## Keyboard, pointer and fullscreen controls

Android 首页及设置页进入全屏后保留导航和 Tools 菜单，始终可以选择退出全屏；选中会话时仍隐藏导航，仅放大当前面板。

Android 设置 → 远程桌面提供两种键盘模式，默认“悬浮叠加（保持分辨率）”：软键盘及特殊键栏覆盖画面，保持原有远端尺寸及本地缩放。选择“跟随键盘调整”则缩小可见区域，并让跟随窗口的会话调整远端分辨率；固定分辨率或服务器决定尺寸的会话仍保留其分辨率。选择仅保存在当前设备，不进入云端 Vault。悬浮叠加模式下键盘和特殊键栏会盖住画面下方：这时键栏上方右侧出现一个上下箭头的滑动手柄，向上拖动可以把被盖住的部分移上来（最多移到画面底边露出为止），远程分辨率不变；收起键盘后画面回到原位。直接触控和鼠标模式都可用。

面板顶部白色小横条可展开全屏/退出全屏、复制、取消分屏和关闭操作。在 Windows、macOS、Linux 上，RDP/VNC 的会话菜单（显示器图标）也在这一行里，不再浮在远程画面右上角遮挡内容；Ctrl+Alt+Home 仍可直接打开它。三个远程桌面悬浮按钮作为一个整体拖动：贴左/右边缘时纵向排列，贴上/下边缘时横向排列，键盘弹出后仍位于其上方。鼠标/触控板模式由客户端绘制光标；直连 RDP 接收 FreeRDP 解码及缓存的形状、热点、默认/隐藏状态与位置更新，VNC 使用 RichCursor/PointerPos，光标不烘焙进远端帧缓冲。

SSH/Telnet 的终端菜单和标签右键菜单（Android 长按标签）提供 Disconnect／断开连接。主动断开保留原标签、分屏及终端记录，并暂停自动重连；点击“恢复连接”后重新建立连接并恢复后续自动重连。组合标签只断开当前选中的面板。关闭标签仍通过原关闭入口执行。断开时也会取消尚未完成的连接，延迟返回的旧连接不能重新接管面板。

Android 的键盘、触摸/鼠标切换和三点参数菜单位于同一个贴边悬浮按钮组，可共同拖动。常规手机及左右分屏内横向并排，极窄面板改为纵向排列。Android 全屏会隐藏应用标签栏和状态栏，将当前面板铺满内容区；退出按钮或系统返回恢复原有分屏和会话。组合标签也可以拖动其中当前选中的会话，以重新排列分屏；连接与终端记录不会复制或重建。

账户与本地配置下的 SSH、Telnet、RDP、VNC 会话断开后可点击“恢复连接”。SSH/Telnet 已建立的会话中断后自动重连：默认每 5 秒尝试一次，最多持续 1 分钟，“连接已中断”卡片上显示距离放弃重连的倒计时和下一次尝试的时间；到达时限后停止自动重连并提示未能自动恢复连接，仍可点击“恢复连接”手动重连（若再次失败，重新开始一轮自动重连）或直接关闭标签。是否自动重连、重连间隔（2–60 秒）和重连时限（30 秒至 10 分钟，或不限时）在设置 → 主题 的“自动重连”中调整，仅保存在当前设备，修改对正在重连的会话同样生效。RDP/VNC 不自动重连，只能手动恢复。Android 上为自动重连保留的后台保活不会超过重连时限。首次连接失败由用户手动重试，主机密钥拒绝停止自动弹窗重试。恢复连接使用最新保存的主机设置（例如 RDP 磁盘映射），保留原标签、分屏位置及终端记录，不重放先前输入。关闭标签、锁定配置、切换账户或 Vault 后，旧作用域不能继续重连；主机密钥和 RDP 证书仍执行原有验证流程。

On Android, RDP and VNC show a dock on the edge of each pane. The keyboard button opens the system keyboard together with a special-key bar. Ctrl/Alt/Shift/Win apply to the next key after a single tap; double-tap to lock, then tap again to release. The first button of the special-key bar switches how the system keyboard types. Input method mode (the default) lets the keyboard compose any language, including Chinese, Japanese and Korean: the text being composed is shown in a small bubble above the key bar and is sent when the keyboard commits it, so with word suggestions a Latin word is sent once it is finished. Direct key mode sends every key at once and offers only the Latin keyboard; use it for passwords, commands and games. The choice applies immediately, also while the keyboard is open, and is kept until the app is closed. With Ctrl/Alt/Shift/Win active, a typed key is sent at once in either mode so shortcuts work. The button next to the keyboard button switches between direct touch and a relative mouse touchpad. In touchpad mode, tap clicks at the cursor, slide moves it, two fingers scroll or right-click, and a second tap held down drags. The dock can move vertically or to the opposite edge and stays inside the resized pane above the keyboard.

Android 上，特殊键栏的第一个按钮用于切换系统键盘的输入方式。输入法模式（默认）支持中文、日文、韩文等各种语言：正在组字的内容显示在特殊键栏上方的小气泡里，输入法上屏后才发送到远程电脑，因此开启联想时英文单词要在完成后才发送。直接按键模式下每个按键立即发送，键盘只提供英文布局，适合输入密码、命令和玩游戏。切换立即生效（键盘打开时也可切换），并保持到应用关闭。Ctrl/Alt/Shift/Win 生效时，两种模式下按下的键都会立即发送，以便使用快捷键。

The navigation bar's Tools menu and the remote desktop session menu provide Enter fullscreen / Exit fullscreen. On Windows, macOS and Linux a pane shows that session menu (monitor icon) among the actions of its white top handle, so nothing floats over the remote screen; Ctrl+Alt+Home still opens it from the keyboard. Windows covers the current monitor and restores its saved placement; macOS uses native fullscreen Spaces; Android hides system bars through its own-window insets controller; iOS uses supported manual overlays. Web uses the browser fullscreen API and follows browser exit events. An unavailable platform operation keeps the normal window and reports the failure. System-owned window captions may remain visible in Android desktop windowing mode.

On Android/iOS, pull a tab down to lift it from a scrolling strip, then drag to a highlighted pane edge. A diagonal pull is accepted while a horizontal swipe still scrolls tabs. A drop in the centre leaves the layout intact; a small amount of corner jitter keeps the highlighted direction. Stationary long-press still opens the tab/group context menu.

VNC IME text retains legacy Latin-1 keysyms where available, and uses Unicode keysyms for additional characters, as required for maximum compatibility by [RFC 6143 §7.5.4](https://www.rfc-editor.org/rfc/rfc6143.html#section-7.5.4). RDP uses Unicode text events when no soft modifier is active.

On Windows, the local input method is switched off while an RDP or VNC desktop has the keyboard focus, so every key reaches the remote computer and its own input method composes the text (as in the Windows Remote Desktop client). SSH and Telnet terminals, and every text field, keep the local input method; it is back as soon as one of them takes the focus.

Windows 上，RDP 或 VNC 桌面获得键盘焦点时会关闭本机输入法，按键原样送到远程电脑，由远程电脑自己的输入法组字（与 Windows 自带的远程桌面一致）。SSH、Telnet 终端和所有文本框仍使用本机输入法，焦点回到它们时立即恢复。

Minimizing the window never changes the remote resolution: a session that follows the window size keeps the size it had, and asks for a new one only when the restored window really has a different size.

最小化窗口不会改变远程分辨率：跟随窗口大小的会话保持原有尺寸，只有窗口恢复后大小确实变了才会重新调整。

On Windows, macOS, Linux and the web, touchpad gestures over an RDP or VNC desktop are sent to the remote computer, in tabs, split panes, detached windows and monitor windows alike. Sliding two fingers scrolls vertically and horizontally by as much as the fingers moved, in the direction set on this computer, and a pinch zooms the way Windows reports a touchpad pinch to applications: Ctrl held with the wheel, so browsers and Office zoom. A gesture is either a scroll or a pinch for its whole length, and the Ctrl of a pinch is released when the gesture ends or the desktop loses the focus. Mouse wheels turn by the amount the device reports instead of one notch per event, and tilt or horizontal wheels scroll sideways. Direct RDP forwards fractions of a notch; VNC, gateway sessions and an RDP engine from an older installation scroll once per full notch, and gateway sessions and such an older engine have no horizontal scrolling. Moving the pointer, tapping and the two-finger tap arrive as mouse input as before. Android and iOS keep their own touch scrolling.

Three- and four-finger gestures normally stay with this computer: Windows performs them itself and an application cannot take them away. On Windows with a precision touchpad, Atermius sends a gesture to the remote computer instead when this computer is set to do nothing with it: in Windows Settings > Bluetooth & devices > Touchpad, set "Three-finger gestures" and "Four-finger gestures" (swipes) and their taps to "Nothing". While an RDP or VNC desktop has the keyboard focus and the pointer is over it, the gestures then become the shortcuts they stand for on Windows: three or four fingers up open Task view (Win+Tab) and down show the desktop (Win+D); three fingers left or right switch apps (Alt stays held while the fingers are down, and moving further steps through the switcher with Tab or Shift+Tab); four fingers left or right switch virtual desktops (Ctrl+Win+Right or Left, the desktops follow the fingers); a three-finger tap opens search (Win+S) and a four-finger tap the notification or quick settings panel (Win+A). A gesture whose local setting is anything else is left to this computer, so nothing happens twice. This does not depend on the "Full keyboard mapping" setting. macOS and Linux keep these gestures to themselves.

在 Windows、macOS、Linux 和网页版上，触控板手势会发送到 RDP 或 VNC 远程电脑，标签、分屏、独立窗口和按显示器拆分的窗口都一样。双指滑动可上下、左右滚动，滚动量跟随手指移动的距离，方向沿用本机的设置；双指捏合按 Windows 向应用程序报告触控板捏合的方式缩放：按住 Ctrl 加滚轮，因此浏览器和 Office 都能缩放。一次手势从头到尾要么是滚动、要么是捏合；捏合时按下的 Ctrl 在手势结束或桌面失去焦点时松开。鼠标滚轮按设备报告的幅度滚动，不再每次固定一格，倾斜滚轮或横向滚轮可左右滚动。直连 RDP 能发送不足一格的滚动量；VNC、网关会话以及旧安装留下的 RDP 引擎每满一格滚动一次，其中网关会话和旧引擎不支持横向滚动。移动指针、轻点和双指轻点仍按鼠标输入处理。Android 和 iOS 仍使用各自的触摸滚动。

三指、四指手势默认由本机系统处理：Windows 自己执行这些手势，应用程序无法把它们拿走。在带精确式触控板的 Windows 上，只要本机被设置成不处理某个手势，Atermius 就把它发给远程电脑：在 Windows 设置 > 蓝牙和其他设备 > 触摸板里，把「三指手势」「四指手势」的轻扫和点击都设为「无」。之后当 RDP 或 VNC 桌面拥有键盘焦点且指针在其上方时，这些手势会变成它们在 Windows 上对应的快捷键：三指或四指上滑打开任务视图（Win+Tab），下滑显示桌面（Win+D）；三指左右滑动切换应用（手指按住期间保持 Alt，继续滑动用 Tab 或 Shift+Tab 在切换器里前进后退）；四指左右滑动切换虚拟桌面（Ctrl+Win+右/左，桌面跟随手指方向）；三指点击打开搜索（Win+S），四指点击打开通知或快速设置面板（Win+A）。本机设置为其他动作的手势仍留给本机，不会两边同时触发。这与「键盘全面映射」设置无关。macOS 和 Linux 上这些手势仍由系统处理。

## Storage mappings and direct touch

On Windows and Android, RDP maps this device's local disks by default. Each Host has a switch to turn this off. The switch is stored only on this device and is not synchronized with the Host, so a choice made on one device never exposes another device's disks. The file is kept out of Android Auto Backup and device transfer, and on Windows it lives under Local AppData rather than the roaming profile. The switch fails closed: a choice that could not be saved stays in force in that window and is written again later, and the editor says so. If the stored choices exist but cannot be read, no local disks are mapped until they can be, with a notice. At connect time the app lists the volumes present at that moment and sends each one as an explicit mapping. The engine never enables FreeRDP's all-drives or home-drive redirection, and it does not add drives inserted during the session.

- Windows: fixed, removable, optical and RAM disks that are ready. Network drives are excluded. Each drive is named by its letter and appears on the server as `\\tsclient\C`.
- Android: mounted internal storage and SD card/USB volumes. They require the system All files access permission. Without it they are skipped with a notice and the connection proceeds; connecting never opens Settings automatically.

A volume that is missing at connect time, such as a removed USB drive or a card reader without media, is skipped with a notice and does not stop the connection. Add disk and Add folder in RDP options still add explicit mappings to a Host. On Android, adding one first opens the system All files access setting, because the native RDP drive channel needs live filesystem access rather than a copied document URI. Explicitly added folders that are missing, blocked by revoked permission or synchronized from another operating system are reported before connecting. A Host stores at most 8 folders, which keeps it readable by earlier versions that share the synchronized settings; a connection carries at most 32 mappings, Host folders and local disks together. A new mapping's path is limited to 259 UTF-8 bytes because FreeRDP's drive channel truncates longer paths; a longer path saved by an earlier version keeps the Host's settings readable and is skipped with a notice when connecting. On Windows the app turns off the system "There is no disk in the drive" dialog for its process, so a card reader or optical drive whose media is removed during a session only fails the remote file operation. Restore connection reconnects with the latest saved Host settings, so changes to mappings or to the switch apply on the next reconnect.

The Android native engine includes RDPDR drive redirection and RDPEI native touch. When the server negotiates RDPEI, direct touch forwards separate contact IDs, movement, release and cancellation; changing panes, input modes or app focus releases the contacts. Servers without RDPEI use pointer fallback. Standard VNC has no native Windows touch channel: direct mode provides tap, drag, long-press right-click and two-finger natural scrolling; relative touchpad mode remains available.

Android file lists open a regular file with one tap through the system Open with chooser. The selected application receives a private, writable content URI for that file only. Local changes remain pending in the file manager footer until Upload is selected; remote conflicts still require confirmation. Long-press retains the file operations menu.

SSH/Telnet's Android keybar includes Shift alongside Ctrl and Alt: tap for the next key, double-tap to lock, tap again or Reset to release. The default terminal palette uses brighter, more saturated text; saved custom palettes and presets keep their colors.

Connection attempts open their tab before asynchronous credential lookup and network setup. The tab reports actual stages and provides Stop loading, Retry and Close. Retry uses the current saved settings in the same tab; late results from cancelled attempts cannot take over. An established session that later drops continues to use the existing reconnect controls.

Windows precision-touchpad reports are assembled by scan time, including one- and two-contact hybrid reports. Report IDs, physical axis dimensions and contact confidence are checked; palm input, unplugging a device, changing panes and losing focus cancel the gesture and release its remote modifiers. Missing final reports have a timeout. Unsupported touchpads retain their ordinary mouse, wheel and pinch behavior. Three- and four-finger forwarding still requires the corresponding Windows setting to be **Nothing**.

SSH connections resend the terminal's measured columns and rows whenever a new SSH transport attaches, in both local and account workspaces. This includes manual restore and automatic reconnect when the window did not resize; the remote PTY follows the same grid as a fresh connection.
