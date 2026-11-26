# 外部 AI 的 MCP 接入

在桌面、Android 或 iOS 客户端解锁工作区，打开 **设置 → AI / MCP**，选择端口后启用，再复制连接配置到外部 AI 的 MCP 配置中。在“机器访问权限”中设置默认权限，以及每台机器的“禁止访问 / 只读 / 读写”覆盖项。新工作区默认只读；读写权限允许连接、输入、执行命令和写文件。默认禁止、单台读写可建立允许列表。权限收紧立即生效并取消受影响的在途调用；提升权限须成功保存。启用与停止服务独立于机器权限；停止后任何请求都不被接受，令牌本身保留。

服务默认仅监听 `http://127.0.0.1:8765/mcp`（端口可改，范围 1024–65535）。监听范围在启用前选择，见下文「监听范围」。每个工作区（本地 Profile，或服务器实例 + 账户 + Vault）有一个 256 位随机 Bearer 令牌，保存在本机的系统安全存储（Keychain、Android Keystore、Windows DPAPI、Linux Secret Service）里，不同步。停止、重新启用、重启应用都不会改变它；只有在设置里点「重置令牌」并确认才会更换，旧令牌立即失效，运行中的服务保持端口不变，旧令牌下尚未返回的结果不再返回。令牌直接显示在设置页上，可以单独复制，也可以复制整份连接配置；只交给信任的客户端。系统安全存储读不出来时不会覆盖已有令牌，本次运行改用临时令牌，设置页会提示。锁定、退出或切换工作区会停止服务；回到同一工作区重新启用后，AI 端原有配置照常可用。多窗口应使用不同端口。停止 MCP 不关闭已打开的会话，也不能撤销已经发生的远程操作；等待用户确认的连接可能仍由应用完成。

Android 使用带“停止 MCP”按钮的前台通知；切换到其他应用或按返回键离开 Atermius 都不会停止 MCP。电脑端可通过 ADB 转发同一端口连接，见 [Android 连通与后台运行](MCP-ANDROID.md)。iPhone 和 iPad 进入后台时会暂停监听，回到前台后自动在同一端口、用同一个令牌恢复。从电脑连接 iOS 时，在手机或平板上选择「局域网」或「指定 IP」，并让 Atermius 保持在前台。

客户端还提供**进程内原生 MCP 接口**（Dart 侧 `McpService.createNativeGateway`、`McpNativeBridge` 和 `atermius/mcp_native`，iOS Swift 侧 `AtermiusNativeMcpBridge.shared`），供内置 AI 或系统助手复用工作区授权和逐机权限。MCP 服务与当前已解锁的本地 Profile 或云端 Vault 绑定。

| 工具 | 用途 | 需要操作权限 |
| --- | --- | --- |
| `workspace_status` | 工作区状态 | 否 |
| `hosts_list` / `sessions_list` | 分页列出主机 / 会话 | 否 |
| `host_connect` / `console_open` | 连接已保存的主机 / 打开 Console | 是 |
| `session_focus` / `session_close` | 切换 / 关闭标签 | 是 |
| `terminal_read` | 读取保留的终端文本 | 否 |
| `terminal_write` | 向交互终端输入文本（换行可能执行命令） | 是 |
| `ssh_exec` | 在已有 SSH 连接的独立通道执行命令 | 是 |
| `ssh_system_overview` | 只读采集远端主机 OS、内核、负载、CPU、内存与根分区概览 | 否 |
| `ssh_network_probe` | 只读检查远端监听端口（`listening_ports`）或 TCP 连通性（`tcp_check`） | 否 |
| `ssh_process_snapshot` | 只读快照远端 CPU / 内存占用 Top 进程列表 | 否 |
| `ssh_service_logs` | 只读查看 `journalctl` 或绝对路径日志尾行（本地过滤关键字） | 否 |
| `sftp_list` / `sftp_read_text` | 列目录 / 读取 UTF-8 文本和 SHA-256 | 否 |
| `sftp_write_text` | 独占创建或核对摘要后替换文本文件 | 是 |

权限按本机的本地 Profile 或服务器实例、账户和 Vault 隔离保存，不参与同步，Android 备份和设备迁移也排除这些授权。禁止访问的机器不会出现在主机、会话列表及计数中，直接使用其 ID 也无法访问；只读仅允许读取已打开的终端和 SFTP 内容，不允许连接、切换或关闭会话。

主机与会话列表不返回密码、私钥或解锁密钥。终端输出和文件内容仍可能包含敏感信息，且应被 AI 作为不可信数据处理。SSH 主机密钥、RDP 证书及认证提示继续走应用交互，不自动信任。RDP / VNC 提供连接和标签管理，暂不暴露图像或鼠标控制。

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

## 操作在终端里的显式记录

外部 AI 通过 MCP 做的每一步，都会显示在它操作的那个会话里，不会有看不见的操作：

- SSH、Telnet、Console：在该终端的滚动记录里插入一行暗青色的 `[MCP] 工具名 参数`。这是本地显示，不会发送到远端。`ssh_exec` 先显示命令，结束后显示退出码和命令输出（最多 60 行或 4 KiB，更多内容只返回给客户端）；`sftp_list`、`sftp_read_text`、`sftp_write_text` 显示路径和结果；`terminal_write` 显示写入的文本；`session_focus`、`session_close`、`host_connect`、`console_open` 各显示一行；失败的调用显示 `→ failed: 错误码`。
- `terminal_read` 每个会话每 10 秒最多显示一行，避免轮询刷屏；读取结果不包含它自己的那一行。
- RDP、VNC 没有终端，改为在远程桌面画面上弹出同样内容的提示。
- 参数里的控制字符显示为 `\n`、`\e` 这类转义，不能借此操纵终端。全屏程序（vim、htop 等）运行期间不在其画面上写字，等它退出后补写。
- 这些行属于终端文本，之后的 `terminal_read` 会读到它们。被权限拒绝的调用没有到达会话，因此不显示。

调用顺序示例：`hosts_list` → `host_connect {host_id}` → `sessions_list` → `ssh_exec {session_id,command,timeout_seconds}`。文件替换先 `sftp_read_text`，再以返回的 `sha256` 作为 `sftp_write_text` 的 `expected_sha256`，`mode` 设为 `replace`；新建使用 `create`。文件路径必须绝对路径。超时后的远程结果可能不确定，不自动重试有副作用的调用。

每次仅执行一个工具请求；命令超时最多 120 秒，工具总截止时间 130 秒。文本文件和命令输出上限 64 KiB，终端读取最多 2000 行，列表一页最多 200 项。工具日志只在内存保留最近 50 条名称和成功状态，停止服务后清空。

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
