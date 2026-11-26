# Features and platform boundaries / 功能与平台边界

[English first use](GETTING_STARTED.en.md) · [中文上手](GETTING_STARTED.md)

| Workflow / 功能 | Native clients / 原生客户端 | Browser / 浏览器 |
| --- | --- | --- |
| SSH + SFTP/SCP | Direct SSH; OS/network permissions apply / 直接连接 | Regular account workspace uses the server's Relay / 账户模式需 Relay |
| Local encrypted profile / 加密本地资料 | Device-local persistence / 设备端保存 | Browser-origin storage; no direct OS TCP / 站点存储，无直接系统 TCP |
| Encrypted sync / 加密同步 | Optional self-hosted account / 可选自托管账户 | Same Vault/device protocol / 同一 Vault 与设备协议 |
| Local shell / 本机终端 | Windows, Linux and macOS; installed shell required / 桌面端，需已安装 Shell | Unavailable / 不支持 |
| Serial Console / 串口 Console | Windows COM ports and macOS `/dev/cu.*`; Android with a USB-to-serial adapter on USB OTG (CDC-ACM, FTDI, CP210x, CH34x, PL2303) / Windows COM、macOS `/dev/cu.*`；Android 经 OTG 连接 USB 转串口适配器 | Unavailable / 不支持 |
| SSH forwarding / SSH 转发 | Native socket runtime; remote SSH policy also applies / 系统套接字与 SSH 服务端策略约束 | Rules can be represented; no OS TCP listener / 不创建系统 TCP 监听 |
| Native RDP / 原生 RDP | Windows with matching bundled FreeRDP engine; Android with the engine packaged in the APK (folders, audio, microphone, camera); macOS/iOS engine builds are in their [install guides](INSTALLATION.en.md) / Windows 需配套引擎，Android 使用 APK 内引擎（文件夹、音频、麦克风、摄像头），macOS/iOS 见[安装指南](INSTALLATION.md) | Uses the optional server gateway / 使用可选服务端网关 |
| RDP/VNC display / 远程桌面画面 | Available transport depends on platform/build / 依平台与构建能力 | guacd, target policy and account prerequisites apply / 需网关、目标策略与账户 |
| Split panes and saved sets / 分屏与窗口组合 | Workspace support; OS windows on desktop / 工作区支持，系统窗口限桌面 | Browser workspace panes / 浏览器工作区面板 |
| Organizations and member Host sharing / 组织与成员分享 | Requires server capabilities / 需服务端能力 | Requires server capabilities / 需服务端能力 |
| Temporary guest SSH/RDP / 临时访客访问 | Open its URL in a supported browser / 在支持的浏览器打开链接 | Separate account-free trusted-gateway flow / 独立免账户受信网关流程 |
| External MCP / 外部 MCP | Opt-in listener on desktop, Android and iOS. iOS revokes the token on backgrounding. / 桌面、Android 和 iOS 可显式启用监听。iOS 进入后台时撤销令牌。 | No OS listener / 不监听系统端口 |

## Dialogs stay in their pane / 弹窗只盖住所在窗格

Dialogs, side sheets (the Host editor, Host properties), confirmations and prompts open over the pane they belong to, not over the whole window. In a split, the Host editor of one pane fills only that pane, and the tab row and the other panes stay usable. On Home a dialog covers the Home area below the tab row. A dialog that belongs to a tab stays with it: selecting another tab hides it with everything typed so far, and it is back when the tab is selected again. Closing the tab cancels it. Dialogs opened from the tab row or the ☰ menu use the pane that is selected (or Home). Android Back closes the dialog on screen first. On iPhone, sheets and alerts keep the full-screen system style.

弹窗、侧边面板（主机编辑、主机属性）、确认框和提示都只盖住所属的窗格，不再覆盖整个窗口。分屏时，某个窗格的主机编辑器只占这个窗格，顶部标签栏和其他窗格照常可用；在 Home 上，弹窗只盖住标签栏下方的 Home 区域。属于某个标签的弹窗跟着这个标签：切到别的标签时它连同已输入的内容一起隐藏，切回来时还在；关闭标签则取消这个弹窗。从标签栏或 ☰ 菜单打开的弹窗出现在当前选中的窗格（或 Home）。Android 返回键先关闭屏幕上的弹窗。iPhone 上的表单和提示仍是系统的全屏样式。

## Terminal scrollback / 终端回滚缓冲

A terminal keeps up to **100,000 lines** of earlier output by default. Settings → Theme → **Scrollback** (both the account workspace and the local profile) offers 10,000, 50,000, 100,000, 500,000, 1,000,000 and 5,000,000 lines. The choice is stored on this device only and applies to terminals opened afterwards; open terminals, detached terminal windows included, keep the limit they were created with.

The history is held in three tiers so that a long scrollback does not cost the memory of that many screen lines:

1. **Recent lines** (the screen plus the 2,048 lines above it) stay as they are, about 2.2 KB per 80-column line.
2. **Older lines** are packed in blocks of 256 lines and compressed **in memory**: roughly 26 bytes per line for ordinary log output, 55 for heavily colored output, 95 for wide CJK text and 60 to 150 for lines of random characters. 100,000 lines of log output take about 7 MiB including the recent lines (about 200 MiB uncompressed). The compressed part is capped at 16 MiB per terminal.
3. **Beyond that**, on Windows, macOS, Linux, Android and iOS, the oldest blocks move to an **encrypted temporary file** in the application cache directory, at most 512 MiB per terminal (about 26 bytes per line of log output: 1,000,000 lines leave about 9 MiB on disk, 5,000,000 about 107 MiB). Each block is sealed with XChaCha20-Poly1305 under a random key that exists only in the memory of the running terminal, so the file cannot be read by anything else or after the app exits. The file is deleted when the tab or window is closed and when the scrollback is cleared; leftovers of a crashed app are removed at the next start. Nothing is synced or uploaded. If the disk cannot be written, the terminal carries on with the in-memory part only.

The browser build has no file tier: it keeps up to 32 MiB of compressed history in memory (about 1,200,000 lines of log output).

Whichever limit is reached first — the line count, or the budget of the last tier — the oldest lines are dropped. Scrolling, selecting, copying, searching and MCP `terminal_read` read archived lines exactly as they were written, colors included.

Two things to know:

- **Resizing.** Only the recent lines are wrapped again when the window width changes. Older lines keep the wrapping they had: in a wider window they stay as narrow as they were, and in a narrower window the part beyond the right edge is hidden (also from copy and search) until the window is widened again.
- **Search** still covers the most recent 10,000 rows, as before, and says so when results are limited.

终端默认最多保留 **100,000 行**历史输出。在 设置 → 主题 → **回滚缓冲区**（账户工作区与本地资料两种模式都有）可选 10,000、50,000、100,000、500,000、1,000,000、5,000,000 行。该选项只保存在本设备，对之后打开的终端生效；已打开的终端（包括分离出去的终端窗口）沿用创建时的上限。

为了让很长的历史不占用同样多屏幕行的内存，历史分三层保存：

1. **最近的行**（当前屏幕加上方 2,048 行）保持原样，80 列时每行约 2.2 KB。
2. **更早的行**每 256 行打包并**在内存中压缩**：普通日志约 26 字节/行，大量着色输出约 55，中日韩宽字符约 95，随机字符整行约 60–150。10 万行日志连同最近的行共约 7 MiB（不压缩约 200 MiB）。每个终端的压缩部分上限为 16 MiB。
3. **再往前**，在 Windows、macOS、Linux、Android、iOS 上，最旧的块会移到应用缓存目录中的**加密临时文件**，每个终端最多 512 MiB（日志约 26 字节/行：100 万行约占 9 MiB 磁盘，500 万行约 107 MiB）。每个块用 XChaCha20-Poly1305 加密，密钥随机生成且只存在于运行中终端的内存里，因此其他程序或应用退出后都无法读取该文件。关闭标签页或窗口、清除回滚内容时文件即被删除；应用崩溃留下的文件在下次启动时清理。不会同步或上传任何内容。磁盘无法写入时，终端只用内存部分继续工作。

浏览器版本没有文件层：最多在内存中保留 32 MiB 压缩历史（日志约 120 万行）。

行数上限或最后一层的容量上限，先到者生效，此时丢弃最旧的行。滚动、选择、复制、搜索和 MCP `terminal_read` 读到的已归档行与写入时完全一致，包括颜色。

需要了解的两点：

- **调整窗口大小。** 窗口宽度变化时只有最近的行会重新折行。更早的行保持归档时的折行：窗口变宽时它们仍是原来的宽度；窗口变窄时超出右边缘的部分会被隐藏（复制和搜索也看不到），重新加宽窗口后恢复。
- **搜索**仍然只覆盖最近 10,000 行（与之前相同），结果受限时会有提示。

Chinese, Japanese, English and Russian UI catalogs are included. Application accents and terminal palettes are separate settings. / 界面包含中、日、英、俄四种语言；应用强调色与终端配色分开设置。

## Terminal keyword highlighting / 终端关键词高亮

Terminals (SSH, Telnet, local shell, serial Console, separate terminal windows and shared terminal views) color recognized words in plain output so they stand out in command output and logs, even when the remote program emits no color:

- **Errors** (red): `error`, `failed`, `fatal`, `denied`, `refused`, `not found`, `no such file`, `down` …
- **Warnings** (yellow): `warning`, `deprecated`, `timeout`, `timed out`, `retry`, `disabled` …
- **Success** (green): `ok`, `success`, `done`, `passed`, `completed`, `active (running)`, `connected`, `up` …
- **Information** (cyan): `info`, `notice`, `note`, `debug`, `trace`, `hint`
- **IP and MAC addresses** (magenta): IPv4, IPv6 and MAC addresses; **Links** (blue, underlined): `scheme://…`

Matching ignores case and respects word boundaries (`terror` and `book` do not match `error` and `ok`); phrases are supported. Colors are the terminal palette's own ANSI colors, so they follow the palette you chose. It is display only: copied text, search, session logs and what MCP `terminal_read` returns are unchanged, and nothing is sent to the remote. Text a program already colored keeps its colors, and full-screen programs (vim, htop, less, tmux …) are never recolored.

Settings → Theme → **Keyword highlighting** (in both the account and the local-profile UI) has the master switch, a switch and a color per group, the editable word list of each group, custom groups and **Restore defaults**. Changes apply to open terminals at once. The setting is stored on this device only and is never synced; a separate terminal window that is already open picks it up the next time it is opened.

终端（SSH、Telnet、本机 Shell、串口 Console、独立终端窗口以及共享终端视图）会为普通输出中识别到的词语着色，即使远端程序本身不输出颜色，也能在命令输出和日志中一眼看到：

- **错误**（红色）：`error`、`failed`、`fatal`、`denied`、`refused`、`not found`、`no such file`、`down` 等
- **警告**（黄色）：`warning`、`deprecated`、`timeout`、`timed out`、`retry`、`disabled` 等
- **成功**（绿色）：`ok`、`success`、`done`、`passed`、`completed`、`active (running)`、`connected`、`up` 等
- **信息**（青色）：`info`、`notice`、`note`、`debug`、`trace`、`hint`
- **IP 和 MAC 地址**（品红）：IPv4、IPv6、MAC 地址；**链接**（蓝色带下划线）：`scheme://…`

匹配不区分大小写并遵守单词边界（`terror`、`book` 不会匹配 `error`、`ok`），支持多词短语。颜色取自终端配色自身的 ANSI 颜色，因此会跟随所选配色。该功能只影响显示：复制的文本、搜索、会话日志以及 MCP `terminal_read` 返回的内容都不变，也不会向远端发送任何内容。程序自己着色的文本保持原色，全屏程序（vim、htop、less、tmux 等）不会被着色。

在 设置 → 主题 → **关键词高亮**（账户界面和本地资料界面都有）中可以设置总开关、每个分组的开关和颜色、编辑每个分组的词语列表、添加自定义分组，以及**恢复默认设置**。更改会立即应用到已打开的终端。该设置仅保存在本设备，不会同步；已经打开的独立终端窗口会在下次打开时生效。

Source availability is not a native-device acceptance claim. macOS/iOS runners require their own build/signing/device validation; Android does not bundle the native Windows RDP engine. Physical USB, camera, microphone, smart-card, printer and multiple-monitor workflows need compatible systems/hardware and separate acceptance. Atermius installs no system USB driver; the Android serial Console drives USB-to-serial adapters inside the app through Android's USB host API, and its serial I/O has not yet been accepted with a physical adapter. / 源码存在不等于已完成设备验收；macOS/iOS 需要相应构建、签名与设备验证，Android 不含 Windows 原生 RDP 引擎。USB、摄像头、麦克风、智能卡、打印机及物理多显示器须另行验证。应用不安装系统 USB 驱动；Android 串口 Console 在应用内经 Android USB 主机 API 驱动 USB 转串口适配器，尚未用实体适配器完成收发验收。

Regular browser SSH is an encrypted byte Relay; a desktop/guest gateway can access the remote login/session. See [sharing](SHARING.en.md), [远程桌面](REMOTE-DESKTOP.md), [本机 Shell](LOCAL-SHELL.md), [Telnet](TELNET.md), [导入导出](IMPORT_EXPORT.md) and [MCP](MCP.md).

## Wallpaper sync / 壁纸同步

In the account workspace, Settings → Theme → **Wallpaper** has **Sync across my devices** (on by default). The same account then sees the same wallpaper image, layout, blur and overlay on every device, browser included. Local profiles keep their wallpaper on the device.

How it is stored:

- **Record.** One encrypted Vault record of its own type, `wallpaper`. It holds the layout values, the time of the change and the manifest of the image (with the image's random key). It is written only to a Vault whose sole member is this account (its Owner) and that belongs to no organization, normally the personal Vault; while the active Vault is shared or a team Vault, sync pauses and says so.
- **Image.** Encrypted on the device as an attachment (`atermius-host-attachment-v1`: random 256-bit key, 4 MiB AES-GCM chunks, at most 16 MiB) and uploaded to that Vault's object store. The record lists the objects in its signed `object_refs`, so the server keeps them while a revision of the record refers to them (earlier images stay with the record's history, like attachment history, until that history is purged) and collects them afterwards as usual. The server only ever has ciphertext; the original file name and path are never sent.
- **On each device.** A decrypted copy stays in the device-local wallpaper store as before, so startup, offline use and separate windows never wait for the account.
- **Conflicts.** The newer change wins: each change carries its time, and a device applies the account value when it is newer than its own and publishes its own when that is newer. Choosing or removing an image, the layout, the blur and the overlay are changes; applying the account value is not. With sync off, the device neither applies nor publishes.
- **No server changes.** Records, objects, quotas and backups use the existing Vault protocol. It is a record type rather than a preference key because older clients keep unknown record types encrypted and count them as unreadable, while an unknown preference key would block their other synced preferences. Two devices editing the wallpaper offline at the same time end up with an ordinary sync conflict to resolve. If the account enabled administrator-visible credentials, administrators who can open the Vault can also open this image.

在账户工作区的 设置 → 主题 → **壁纸** 里有 **在我的设备间同步**（默认开启）。同一账户在每台设备（包括浏览器）上看到相同的壁纸图片、布局、模糊和遮罩。本地资料的壁纸仍只保存在本设备。

存储方式：

- **记录**：一条独立类型的加密 Vault 记录（类型 `wallpaper`），里面是布局参数、修改时间和图片清单（含该图片的随机密钥）。只写入「成员只有本账户（Owner）且不属于任何组织」的 Vault，通常就是个人 Vault；当前 Vault 是共享或团队 Vault 时同步暂停，并在设置里说明原因。
- **图片**：在本机按附件格式加密（`atermius-host-attachment-v1`：随机 256 位密钥、4 MiB 分块 AES-GCM，最大 16 MiB）后上传到该 Vault 的对象存储。记录在签名的 `object_refs` 里引用这些对象，只要记录的某个修订还引用它们服务端就保留（旧图片和附件历史一样随记录历史保留，直到历史被清除），之后按现有对象回收流程删除。服务端只有密文，原文件名和路径从不上传。
- **各设备本地**：解密后的副本仍放在设备本地壁纸存储里，启动、离线和独立窗口都不依赖账户。
- **冲突**：以较新的修改为准。每次修改带有时间；账户里的值比本机新就应用，本机的比账户新就上传。选图、移除图片、布局、模糊和遮罩都算修改，应用账户里的值不算。关闭同步后，本机既不应用也不上传。
- **服务端无改动**：记录、对象、配额和备份都沿用现有 Vault 协议。用独立记录类型而不是偏好键，是因为旧版客户端会把不认识的记录类型加密保留、只计入「无法读取的记录」，而不认识的偏好键会让它们无法修改其他同步偏好。两台设备同时离线修改壁纸时，会出现一个普通的同步冲突需要处理。如果账户开启了管理员可见凭据，能打开该 Vault 的管理员也能打开这张图片。

## Home host sorting / 主页主机排序

Every client (Windows, macOS, Linux, Android, iPhone/iPad and Web) offers Recently requested (the default), Name A–Z, Name Z–A, Address, Protocol and Favorites first. The sort control sits beside the home search; the iPhone native home uses its sort menu and applies the same choice inside folders. Address sorting compares numeric chunks so `192.0.2.3` comes before `192.0.2.20`.

A request is recorded as soon as the user starts connecting, even if credentials are missing or the connection fails. Manual Retry/Restore updates it; automatic retry, browser tab restoration and MCP-started connections do not. Never-requested hosts and tied requests use a stable name/ID order. Search filters continue to apply before sorting.

The choice persists on this device. Recent requests are isolated by local profile or server/account/Vault, kept outside synchronized Host records, and excluded from Android backup. The history is bounded to the latest 1,000 host entries.

所有客户端的主页均提供最近请求（默认）、名称升序、名称降序、地址、协议及收藏优先。发起连接时立即记录请求，不要求连接成功；手动重试或恢复会更新记录，自动重连、浏览器恢复标签及 MCP 自动连接不会更新。排序选择在本机重启后保留，最近请求记录按本地配置或服务器／账户／Vault 隔离，不写入云端主机记录。
