# Features and platform boundaries / 功能与平台边界

[English first use](GETTING_STARTED.en.md) · [中文上手](GETTING_STARTED.md)

| Workflow / 功能 | Native clients / 原生客户端 | Browser / 浏览器 |
| --- | --- | --- |
| SSH + SFTP/SCP | Direct SSH; OS/network permissions apply / 直接连接 | Regular account workspace uses the server's restricted Relay / 账户模式需 Relay |
| Local encrypted profile / 加密本地资料 | Device-local persistence / 设备端保存 | Browser-origin storage; no direct OS TCP / 站点存储，无直接系统 TCP |
| Encrypted sync / 加密同步 | Optional self-hosted account / 可选自托管账户 | Same Vault/device protocol / 同一 Vault 与设备协议 |
| Local shell + serial Console / 本机终端与串口 | Desktop only; installed shell/device required / 桌面需已安装 Shell/设备 | Unavailable / 不支持 |
| SSH forwarding / SSH 转发 | Native socket runtime; remote SSH policy also applies / 系统套接字与 SSH 服务端策略约束 | Rules can be represented; no OS TCP listener / 不创建系统 TCP 监听 |
| Native RDP / 原生 RDP | Windows with matching bundled FreeRDP engine; Android with the engine packaged in the APK; macOS/iOS engine builds are in their [install guides](INSTALLATION.en.md) / Windows 需配套引擎，Android 使用 APK 内引擎，macOS/iOS 见[安装指南](INSTALLATION.md) | Uses the optional server gateway / 使用可选服务端网关 |
| RDP/VNC display / 远程桌面画面 | Available transport depends on platform/build / 依平台与构建能力 | guacd, target policy and account prerequisites apply / 需网关、目标策略与账户 |
| Split panes and saved sets / 分屏与窗口组合 | Workspace support; OS windows on desktop / 工作区支持，系统窗口限桌面 | Browser workspace panes / 浏览器工作区面板 |
| Organizations and member Host sharing / 组织与成员分享 | Requires server capabilities / 需服务端能力 | Requires server capabilities / 需服务端能力 |
| Temporary guest SSH/RDP / 临时访客访问 | Open its URL in a supported browser / 在支持的浏览器打开链接 | Separate account-free trusted-gateway flow / 独立免账户受信网关流程 |
| External MCP / 外部 MCP | Desktop and Android loopback service, explicit opt-in; iOS has no listener / 桌面与 Android 回环服务，显式启用；iOS 不监听 | No OS listener / 不监听系统端口 |

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

Source availability is not a native-device acceptance claim. macOS/iOS runners require their own build/signing/device validation; Android does not bundle the native Windows RDP engine. Physical USB, camera, microphone, smart-card, printer and multiple-monitor workflows need compatible systems/hardware and separate acceptance. Atermius installs no USB driver. / 源码存在不等于已完成设备验收；macOS/iOS 需要相应构建、签名与设备验证，Android 不含 Windows 原生 RDP 引擎。USB、摄像头、麦克风、智能卡、打印机及物理多显示器须另行验证，应用不安装 USB 驱动。

Regular browser SSH is an encrypted byte Relay; a desktop/guest gateway can access the remote login/session. See [sharing](SHARING.en.md), [远程桌面](REMOTE-DESKTOP.md), [本机 Shell](LOCAL-SHELL.md), [Telnet](TELNET.md), [导入导出](IMPORT_EXPORT.md) and [MCP](MCP.md).
