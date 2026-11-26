# 外部 AI 的 MCP 接入

在桌面、Android 或 iOS 客户端解锁工作区，打开 **设置 → AI / MCP**，选择端口后启用，再复制连接配置到外部 AI 的 MCP 配置中。在“机器访问权限”中设置默认权限，以及每台机器的“禁止访问 / 只读 / 读写”覆盖项。新工作区默认只读；读写权限允许连接、输入、执行命令和写文件。默认禁止、单台读写可建立允许列表。权限收紧立即生效并取消受影响的在途调用；提升权限须成功保存。启用与停止服务独立于机器权限；停止后任何请求都不被接受，令牌本身保留。启用后 MCP 会一直保持开启，见下文「后台常驻」。

服务默认仅监听 `http://127.0.0.1:8765/mcp`（端口可改，范围 1024–65535）。监听范围在启用前选择，见下文「监听范围」。每个工作区（本地 Profile，或服务器实例 + 账户 + Vault）有一个 256 位随机 Bearer 令牌，保存在本机的系统安全存储（Keychain、Android Keystore、Windows DPAPI、Linux Secret Service）里，不同步。停止、重新启用、重启应用都不会改变它；只有在设置里点「重置令牌」并确认才会更换，旧令牌立即失效，运行中的服务保持端口不变，旧令牌下尚未返回的结果不再返回。令牌直接显示在设置页上，可以单独复制，也可以复制整份连接配置；只交给信任的客户端。系统安全存储读不出来时不会覆盖已有令牌，本次运行改用临时令牌，设置页会提示。锁定、退出或切换工作区会停止服务；回到同一工作区重新启用后，AI 端原有配置照常可用。多窗口应使用不同端口。停止 MCP 不关闭已打开的会话，也不能撤销已经发生的远程操作；等待用户确认的连接可能仍由应用完成。

Android 使用带“停止 MCP”按钮的前台通知；切换到其他应用或按返回键离开 Atermius 都不会停止 MCP。电脑端可通过 ADB 转发同一端口连接，见 [Android 连通与后台运行](MCP-ANDROID.md)。iPhone 和 iPad 进入后台时会暂停监听，回到前台后自动在同一端口、用同一个令牌恢复。从电脑连接 iOS 时，在手机或平板上选择「局域网」或「指定 IP」，并让 Atermius 保持在前台。

客户端还提供**进程内原生 MCP 接口**（Dart 侧 `McpService.createNativeGateway`、`McpNativeBridge` 和 `atermius/mcp_native`，iOS Swift 侧 `AtermiusNativeMcpBridge.shared`），供内置 AI 或系统助手复用工作区授权和逐机权限。MCP 服务与当前已解锁的本地 Profile 或云端 Vault 绑定。

| 工具 | 用途 | 需要读写权限 |
| --- | --- | --- |
| `docs_read` | 读取内置文档（同下文「内置文档」，给只会调用工具的客户端用） | 否 |
| `workspace_status` | 工作区状态 | 否 |
| `hosts_list` | 分页列出主机，可按 `query`（名称/地址/用户名/标签）、`protocol`、`group_id`（含子分组）、`tag`、`favorites_only` 筛选；返回标签、收藏、跳板机、最近连接时间、识别出的系统 | 否 |
| `host_get` | 单台主机详情：端口转发配置和它当前打开的会话 | 否 |
| `groups_list` | 分组（只列含可见主机的分组，`host_count` 只计可见主机） | 否 |
| `sessions_list` | 分页列出会话，可按 `host_id` 筛选；返回是否为当前标签、终端行列数、是否处于全屏程序 | 否 |
| `host_connect` / `console_open` | 连接已保存的主机 / 打开 Console | 是 |
| `session_focus` / `session_close` | 切换 / 关闭标签 | 是 |
| `terminal_read` | 读取保留的终端文本；`since_cursor` 增量读取，只返回上次之后的新内容 | 否 |
| `terminal_screen` | 只读当前可见屏幕、光标位置、行列数（适合 vim、top 等全屏程序） | 否 |
| `terminal_search` | 在滚动记录里搜索（字面或正则，可带上下文行），返回行号 | 否 |
| `terminal_wait` | 等到出现某段文字，或输出静止一段时间，最长 120 秒 | 否 |
| `terminal_write` | 向交互终端输入文本（换行可能执行命令） | 是 |
| `terminal_send_keys` | 发送命名按键：回车、方向键、F1–F12、Ctrl+C 等，跟随终端的光标键模式 | 是 |
| `terminal_run` | 在用户看得见的交互终端里输入一行命令并回车，等输出结束后返回输出（没有退出码） | 是 |
| `ssh_exec` | 在已有 SSH 连接的独立通道执行命令，返回退出码和 stdout/stderr | 是 |
| `ssh_system_overview` | 只读采集远端主机 OS、内核、负载、CPU、内存与根分区概览 | 否 |
| `ssh_network_probe` | 只读检查远端监听端口（`listening_ports`）或 TCP 连通性（`tcp_check`） | 否 |
| `ssh_process_snapshot` | 只读快照远端 CPU / 内存占用 Top 进程列表 | 否 |
| `ssh_service_logs` | 只读查看 `journalctl` 或绝对路径日志尾行（本地过滤关键字） | 否 |
| `sftp_list` / `sftp_stat` / `sftp_read_text` | 列目录 / 查看路径属性（不存在时 `exists: false`）/ 读取 UTF-8 文本和 SHA-256 | 否 |
| `sftp_write_text` | 独占创建或核对摘要后替换文本文件 | 是 |
| `sftp_mkdir` / `sftp_rename` / `sftp_remove` | 建目录 / 改名（不覆盖已有文件）/ 删除文件或空目录（须写明 `type`） | 是 |
| `ui_notify` | 在 Atermius 界面上给用户显示一条消息（每 2 秒最多一条） | 否 |

权限按本机的本地 Profile 或服务器实例、账户和 Vault 隔离保存，不参与同步，Android 备份和设备迁移也排除这些授权。禁止访问的机器不会出现在主机、会话列表及计数中，直接使用其 ID 也无法访问；只读仅允许读取已打开的终端和 SFTP 内容，不允许连接、切换或关闭会话。

主机与会话列表不返回密码、私钥或解锁密钥。终端输出和文件内容仍可能包含敏感信息，且应被 AI 作为不可信数据处理。SSH 主机密钥、RDP 证书及认证提示继续走应用交互，不自动信任。RDP / VNC 提供连接和标签管理，暂不暴露图像或鼠标控制。

## 后台常驻

MCP 启用后会在本设备上保持开启，像一个后台服务：

- 启用状态、端口和监听范围保存在本机（不同步、不含令牌）。锁定、退出或切换工作区会暂时停止 MCP；之后只要解锁任一工作区，或重新打开 Atermius，主窗口就会用保存的端口和该工作区的令牌自动启动它。只有在设置里点「停止 MCP」（或 Android 通知里的「停止」）才会关闭，之后也不再自动启动。
- 自动启动失败（多半是端口被别的窗口占用）时，设置页会提示，手动点「启用 MCP」即可。文件窗口、分离出去的终端或远程桌面窗口是独立进程，不会自动启动 MCP。
- **Windows：** MCP 运行时关闭主窗口（标题栏的关闭按钮、Alt+F4、任务栏）只会隐藏窗口：MCP、已打开的标签和会话都继续运行，通知区域（托盘）里出现 Atermius 图标，第一次还会弹出一条通知。单击图标重新打开窗口；右键菜单里有「打开 Atermius」和「退出 Atermius」，退出才会关闭会话并结束进程。MCP 没有运行时关闭窗口照常退出；如果托盘图标加不上，窗口也不会被隐藏。MCP 在后台意外停止时，窗口会重新出现。
- Android：MCP 运行时有带“停止 MCP”按钮的前台通知，切换到其他应用或按返回键离开 Atermius 都不会停止 MCP。iPhone 和 iPad 进入后台时暂停监听，回到前台后自动恢复。

## 监听范围

启用前在「监听范围」里选择，端口和这个选择只保存在本机，下次打开时沿用（不会自动启用）：

| 选项 | 绑定地址 | 谁能连接 |
| --- | --- | --- |
| 仅本机（默认） | `127.0.0.1` | 只有本机上的程序 |
| 局域网 | `0.0.0.0`（所有 IPv4 网卡） | 本机，以及私有网段里的其他设备 |
| 指定 IP | 你填写的本机 IPv4 或 IPv6 地址 | 能到达这个地址的私有网段设备 |

选「局域网」或「指定 IP」时：

- 启用后页面会列出客户端可用的全部地址，复制的配置使用第一个（优先私有网段地址）。客户端必须用 **IP 地址** 访问；用主机名访问会被拒绝（403），这是为了挡住 DNS 重绑定。
- 只接受来自本机、私有网段（`10/8`、`172.16/12`、`192.168/16`、`fc00::/7`）、链路本地和 `100.64/10`（常见组网 VPN）的连接；公网来源一律拒绝，即使这台机器有公网网卡。
- 令牌仍然必需。同一来源在一分钟内连续 20 次令牌错误后，这个来源会被拒绝到该分钟结束（本机来源不受限）。
- **连接是明文 HTTP，没有加密。** 同一网络上能抓包的设备可以看到令牌和全部传输内容。只在可信网络使用；跨不可信网络请保持「仅本机」并用 SSH 隧道或 ADB 转发。
- 机器访问权限照常生效：拿到令牌的客户端也只能在你授予的范围内操作。
- Windows 首次监听非回环地址时，系统防火墙可能询问是否允许 Atermius 接受连接；不允许的话其他设备连不上。
- `integration/mcp/stdio_bridge.py` 也接受私有网段的 IP 地址作为 `ATERMIUS_MCP_URL`，主机名（除 `localhost`）不接受。

## AI 的操作在界面上的显示

外部 AI 通过 MCP 做的每一步都看得见，不会有看不见的操作。

### 顶栏的 AI 活动按钮

MCP 正在监听、有调用正在执行，或最近 2 分钟内有过调用时，顶栏（搜索按钮左边）会出现一个 AI 图标。调用执行期间图标上有进度圈；窗口足够宽时显示「AI · 工具名」，鼠标悬停可看到工具和目标会话。点开是 AI 活动面板（宽窗口是下拉面板，触屏和窄窗口是底部弹出）：

- 最近的调用按时间倒序列出：状态、工具名、目标（会话或主机名）、参数摘要（等宽字体，命令、路径、按键、搜索词等；文件内容只显示字节数）、时间、耗时，以及结果（如 `exit 0`、`12 items`、`matched`）或错误码。
- 点一条调用会切到它操作的会话；`host_connect` 会切到它打开的会话。
- 顶部显示监听地址和「停止 MCP」按钮，还有到「设置 → AI / MCP」的链接。
- AI 用 `ui_notify` 发来的消息以「AI: 消息」的提示条显示，按级别着色，点「查看」打开面板。消息只按纯文本显示，控制字符和方向控制字符会被去掉。

「设置 → AI / MCP → 最近调用」显示同样的内容。这些记录只在内存里保留最近 50 条，停止服务后清空。iPhone 布局没有顶栏，看设置页即可。

### 终端里的 `[MCP]` 行

- SSH、Telnet、Console：在该终端的滚动记录里插入一行暗青色的 `[MCP] 工具名 参数`。这是本地显示，不会发送到远端。`ssh_exec` 先显示命令，结束后显示退出码和命令输出（最多 60 行或 4 KiB，更多内容只返回给客户端）；`terminal_run` 在输入命令前显示一行，命令和输出本身就在终端里；`terminal_send_keys` 显示按键名；`sftp_*` 显示路径和结果（修改类在动手前显示）；`terminal_write` 显示写入的文本；`session_focus`、`session_close`、`host_connect`、`console_open` 各显示一行；失败的调用显示 `→ failed: 错误码`。
- `terminal_read`、`terminal_screen`、`terminal_wait` 每个会话每 10 秒最多显示一行，避免轮询刷屏；读取结果不包含它自己的那一行。`terminal_search` 和 `terminal_wait` 只显示结果（匹配数、等了多久），不显示搜索词，免得下一次搜索匹配到这一行。
- RDP、VNC 没有终端，改为在远程桌面画面上弹出同样内容的提示。
- 参数里的控制字符显示为 `\n`、`\e` 这类转义，不能借此操纵终端。全屏程序（vim、htop 等）运行期间不在其画面上写字，等它退出后补写。
- 这些行属于终端文本，之后的 `terminal_read` 会读到它们。被权限拒绝的调用没有到达会话，因此不显示。

调用顺序示例：`sessions_list`（没有合适的会话时 `hosts_list {query}` → `host_connect {host_id}`）→ `terminal_run {session_id,command}`（用户能看到）或 `ssh_exec {session_id,command,timeout_seconds}`（需要退出码时）。跟踪输出用 `terminal_read` 返回的 `cursor` 作为下一次的 `since_cursor`，或用 `terminal_wait` 等待。文件替换先 `sftp_read_text`，再以返回的 `sha256` 作为 `sftp_write_text` 的 `expected_sha256`，`mode` 设为 `replace`；新建使用 `create`。文件路径必须绝对路径。超时后的远程结果可能不确定，不自动重试有副作用的调用。

每次仅执行一个工具请求；命令、`terminal_wait`、`terminal_run` 最长 120 秒，工具总截止时间 130 秒。文本文件和命令输出上限 64 KiB，终端读取最多 2000 行，搜索覆盖最新 20 000 行，列表一页最多 200 项。搜索和等待默认按字面、不区分大小写匹配；`regex: true` 时用正则，超过 3 秒的正则会被中止（在独立的 isolate 里执行，不会卡住应用）。

## 内置文档（给 AI 读）

服务按 MCP 标准方式自带文档，AI 不需要事先知道本页内容：

- **初始化说明**：`initialize` / `server/discover` 返回的 `instructions` 概括规则，并指向下面的文档。
- **资源（resources）**：`resources/list` 列出 `atermius://docs/index`（入口）、`guide`（概念、显示方式、限制）、`tools`（工具参考，由正在运行的工具定义自动生成，参数、范围、默认值和所需权限与实际一致）、`workflows`（常见流程）、`access`（逐机权限）、`errors`（错误码及应对）；`resources/templates/list` 提供 `atermius://docs/tools/{name}`，读单个工具。`resources/read` 返回 Markdown。
- **提示词（prompts）**：`prompts/list` / `prompts/get` 提供 `run_command`（在用户终端里可见地执行命令）、`diagnose_host`（只读体检）、`edit_remote_file`（带 SHA-256 校验的安全改文件）、`investigate_service`（排查服务）。
- **工具**：只支持工具调用的客户端用 `docs_read {topic}` 或 `docs_read {tool}` 读同样的内容。
- 每个工具带 `title` 和 `annotations`（`readOnlyHint`、`destructiveHint`、`idempotentHint`），客户端可据此决定是否需要用户确认。

文档内容与工作区无关，不含任何主机、会话或凭据信息，但读取同样需要令牌和已授权的工作区。

## HTTP 客户端配置

应用设置中复制的配置使用 Streamable HTTP，其结构如下。示例令牌必须替换为设置页显示的令牌，只保存到受信客户端的私有配置：

```json
{
  "mcpServers": {
    "atermius": {
      "url": "http://127.0.0.1:8765/mcp",
      "headers": {
        "Authorization": "Bearer REPLACE_WITH_WORKSPACE_TOKEN"
      }
    }
  }
}
```

按外部客户端支持的 HTTP 配置语法调整。请求需包含 JSON Content-Type 及协议要求的 Accept/方法头；服务使用 JSON 响应，不提供 SSE 推送，GET 返回 405。应用复制的配置与当前端口和令牌一致；停用期间不接受请求，重新启用后照常可用，重置令牌后旧令牌失效。

仅支持 stdio 的客户端可使用仓库中的 `integration/mcp/stdio_bridge.py`，以环境变量 `ATERMIUS_MCP_URL`、`ATERMIUS_MCP_TOKEN` 提供端点和令牌（用法见 [Android 连通与后台运行](MCP-ANDROID.md)），也可以另行配置兼容适配器。无需在运行机器克隆整个工程；需要从另一台设备直接连接时，可在「监听范围」选择局域网或指定 IP。

参考：[MCP Streamable HTTP 传输](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)。

> 合并说明：2026-11-14 合并前，Desktop、iOS、Web 仓库中的本文仍是较早版本，只描述桌面端监听（Web 与移动端只显示能力说明），权限为单一的“允许外部 AI 执行操作”开关，修改权限会停止服务并使旧令牌失效；该版本还称拆分仓库不附带 stdio 桥接脚本。四个客户端仓库当时的代码均已包含“机器访问权限”设置与 `integration/mcp/stdio_bridge.py`，因此本文以 Android 仓库的较新版本为准。
