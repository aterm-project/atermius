# Atermius 在线沙箱与出口设计（提案）

- 状态：**设计提案，未实现**。文中的表、路由、字段、环境变量都是待评审草案，不代表任何功能已交付。
- 日期：2026-11-18。
- 范围：Web 客户端（`serverHostedClient == true`）经服务端发起的 SSH/SFTP/Telnet/RDP/VNC 连接，其**发起位置**（目标看到的源 IP）和**可用环境**（Linux 工具环境、Windows 环境）如何提供、如何共享、如何由实例管理员管理。
- 安全门槛：沙箱是对外暴露的服务端执行与出网能力，按 [`../cloud-collaboration-design/DESIGN.md`](../cloud-collaboration-design/DESIGN.md) 头部同一条规则处理：对象级授权、目标策略复查、并发与速率上限、凭据与日志泄露防护以及对应的负向测试必须随功能一起交付，不归入「加固放最后」。
- 需要负责人拍板的事项集中在 §13，每项都给了建议；其余内容按建议写成了确定的设计。

---

## 0. 核心决策摘要

| # | 决策 | 理由 |
| --- | --- | --- |
| S1 | 把「沙箱」拆成两个独立对象：**出口（egress）**决定连接从哪里发出、目标看到哪个 IP；**环境（sandbox）**是一个可以打开终端的服务端容器，带工具和持久主目录。环境总是挂在某个出口上。 | 用户要的「SSH 发起 IP」只需要出口，不需要容器；要的「Windows/Linux 环境」才需要环境。拆开后第一阶段不碰 Docker 就能交付固定出口 IP。 |
| S2 | **出口是共享的，环境是每用户一个。** 出口按「实例 / 组 / 用户」授予；Linux 环境默认每用户一个容器。组共享、全实例共享的容器作为显式选项放到第三阶段，默认不开。 | 团队要的共享是「大家用同一个被目标防火墙放行的 IP」，这是出口的属性。共享容器等于共享主目录和进程空间，一个成员能读到其他成员在里面留下的一切。 |
| S3 | 「从出口 X 连接」对 SSH/SFTP/Telnet 仍然是**字节管道**：SSH 在浏览器与目标之间建立（`dartssh2`），Server 和出口转发 SSH 加密字节。Telnet 本身是明文，出口可见其内容。 | 现有 Relay 就是这个模型（`server/src/relay.rs` `relay_socket`，`apps/client/lib/ssh/ssh_service.dart:1083`）。换发起位置不需要改变信任边界。 |
| S4 | 服务端 API **没有任何接收 Vault 明文或登录秘密并写入沙箱的接口**。打开沙箱终端用浏览器当场生成的一次性 SSH 密钥；用户要在沙箱里用自己的密钥，只能自己放进去（并被明确告知运营者可见）。 | 「服务端永远看不到 Vault 明文」的不变量不为沙箱开例外。沙箱是受信环境，运营者能看到里面的一切，这一点如实写在 UI 上。 |
| S5 | 容器由独立的 **`sandbox-runner` 服务**创建和管理，只有它能接触 Docker；`server` 容器不挂 Docker socket。 | `server` 面向公网并解析不可信输入；把 Docker socket 给它等于把宿主机 root 给任何攻破它的人（§11）。 |
| S6 | 目标策略**复用现有 Relay 策略链**（部署 ∩ 实例 ∩ 用户 ∩ 组，`effective_policy_for_user_tx`），出口只能在其上再收窄。容器自己的出网由 runner 在容器网络上用同一份有效策略落成防火墙规则。 | 容器里有 shell，用户可以绕过逐连接的票据检查直接拨号，所以策略必须在网络层再执行一次。 |
| S7 | 出口与环境的授予沿用**服务端管理的 Relay 访问组**（`relay_access_groups`），不映射到 Vault 成员关系，也不与云端组织/团队合并。 | 沙箱是实例管理员的网络控制面，和 Relay 策略同一家族；Vault 内容对服务端是密文，无法也不应由它推导授权。 |
| S8 | 默认出口由**服务端**在签发票据时套用；管理员可把出口设为「必须」。旧客户端不带出口字段也会被正确路由。 | 强制出口是安全控制，不能依赖客户端配合。 |
| S9 | Windows 环境第三阶段先做**登记式**：管理员登记已有的 Windows 主机并分配给用户，经现有 guacd 管线打开。服务端不创建、不保管 Windows 虚拟机和它的登录凭据。 | 自动化 Windows 虚拟机涉及授权、KVM、镜像体积，运维负担与本项目自托管小实例的定位不符。 |

---

## 1. 目标与非目标

### 目标

1. 管理员可以定义若干出口，每个出口对应一个确定的源 IP，并决定哪些用户、哪些组、还是全实例可以用或必须用它。
2. 用户在 Web 客户端里能看到「这次连接从哪里发出」，可以按主机或按单次会话选择出口。
3. 用户可以打开一个属于自己的 Linux 环境：有 shell、常用工具、跨会话保留的主目录，出网走指定出口。
4. 管理员在管理面板的一个分区里看到并控制全部内容：模板、共享方式、分配、出口 IP、配额、正在运行的沙箱（停止、销毁）。
5. 上述一切不降低现有保证：Vault 明文与 SSH 凭据不离开客户端；Relay 的目标白名单、会话绑定、授权版本断开机制继续有效；服务端内部网络对沙箱不可达。

### 非目标

- 不做通用云 IDE、不做多租户公有云级别的强隔离。容器是防误用和一般越权的边界，不是对抗内核漏洞的边界（§8.3 说明残余风险，§13 Q4 给出加固选项）。
- 不在第一、二阶段自动创建 Windows 虚拟机。
- 不替用户把 Vault 里的凭据同步进沙箱，也不提供「服务端代持密钥自动登录目标」的模式（那是分享网关的受信模型，见 `docs/CLOUD-SHARING.md`，两者不混用）。
- 不改变原生客户端（Windows/macOS/Linux/Android/iOS）的直连方式。原生客户端可以在后续阶段选择「经服务端出口」，本设计不要求。
- 沙箱主目录不进入实例备份，不承诺持久性等级（§6.4）。

---

## 2. 现状（设计所依赖的代码事实）

| 领域 | 现在怎样 | 位置 |
| --- | --- | --- |
| Web 选传输 | `serverHostedClient => kIsWeb`；`SshService` 的 `_useRelay = useRelay ?? kIsWeb`。Web 上每条 SSH 连接先 `POST /api/v1/relay/tickets`，再用票据打开 `wss://…/relay/v1/connect`，其上跑完整的 SSH。Telnet、桌面走同一套票据。跳板链只有第一跳走 Relay，后面各跳是 SSH `direct-tcpip`。 | `apps/client/lib/platform/server_hosted.dart:8`、`lib/ssh/ssh_service.dart:862,1083-1124`、`lib/telnet/telnet_transport.dart:53`、`lib/desktop/desktop_session.dart:365` |
| Relay 拨号 | 票据 30 秒、单次、只存哈希，目标加密存放，绑定会话/设备/授权版本。消费后服务端 `TcpStream::connect(ip:port)`，所以**源 IP 就是 `server` 容器的出口 IP**。单连接上限 60 分钟、1 GiB，全局 256 条，每用户 `relay_max_connections_per_user` 条，每约 2 秒复查会话与策略。 | `server/src/relay.rs:43-50`、`create_ticket`(1498)、`consume_ticket`、`relay_socket`(2047 处拨号)、`relay_connection_active` |
| 目标策略 | 永久禁止环回、链路本地、组播、云元数据地址（`is_forbidden_ip`，不含私网段，私网靠白名单约束）。有效策略 = 部署环境变量上限 ∩ 实例策略 ∩ 用户策略 ∩ 该用户所在每个组的策略，全部是**收窄**语义。 | `relay.rs:154`、`effective_policy_tx`(335)、`effective_policy_for_user_tx`(452)、`restrict_effective_policy`(472)、`relay_groups.rs:1020` |
| 管理 API | `GET/PUT /api/v1/admin/relay-policy`、`…/relay-policy/users/{user_id}`、`…/relay-groups`、`…/relay-groups/{group_id}`、`…/{group_id}/members`、`…/{group_id}/relay-policy`。全部 CAS（`expected_revision`），写入实例管理员审计（`admin.relay_*`）。策略或成员变化推进 `relay_user_authorization_versions`，使已建立的连接在下一次复查时断开。 | `server/src/lib.rs:1527-1591`、迁移 `0030`、`0042`、`0043` |
| 桌面网关 | `/desktop/v1/connect` 用同一种票据；服务端连 guacd，浏览器首帧 `DesktopHello` 带**明文**用户名和密码，由服务端构造 guacd `connect`，目标 IP/端口取自票据。RDP/VNC 的凭据因此在传输中对服务端可见，这是已有且已写明的受信模式。 | `server/src/desktop.rs`、`relay.rs` `connect_desktop`(1705)、`deploy/compose.desktop.yaml` |
| 分享网关 | 访客链接用网关 X25519 密钥解封胶囊，由 guacd 终止 SSH/RDP。有独立的 `ATERMIUS_SHARE_ALLOW_CIDRS` 和 `ATERMIUS_SHARE_DENY_CIDRS`（默认拒绝 `172.16.0.0/12`，即 compose 网络）。 | `server/src/share_gateway.rs`、`deploy/compose.share.yaml` |
| 实例管理员 | `ATERMIUS_ADMIN_USERNAMES` 列出的账户。 | `server/src/audit.rs:660`、`cloud_orgs.rs:338` |
| PostgreSQL 模式 | 路由按精确路径白名单开放，新路由默认关闭。 | `server/src/lib.rs` `pg_sync_route_is_supported` |
| 部署 | `server` 容器无 Docker 权限，`no-new-privileges`，非 root 用户；guacd 不发布端口。 | `deploy/compose.yaml`、`server/Dockerfile` |
| 浏览器本机 Shell | 不存在；浏览器和移动端只显示「需要桌面应用」。 | `docs/LOCAL-SHELL.md` |

两个结论直接决定了设计：

- Relay 是字节管道，换一个拨号位置不触碰凭据。所以「出口」可以做得很轻。
- 当前只有一个拨号点（`TcpStream::connect`）和一条策略链。出口选择加在这两处即可，不需要第二套授权体系。

---

## 3. 沙箱是什么：方案比较

| 方案 | 物理形态 | 隔离 | 成本 | 出口 IP 控制 | 运维负担 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| A. 共享 Relay 出口（现状） | `server` 进程直接拨号 | 用户之间无环境可言；连接互不相干 | 零 | 无，恒为服务器 IP | 零 | 保留，作为内置出口 `server` |
| B. 外部出口节点 / 固定 IP 代理 | 管理员登记的 SOCKS5 代理（P1），或主动连回的 Rust 节点（P1b） | 同 A（仍是字节管道） | 每个 IP 一台小机器或一个附加 IP | **强**：一个出口一个确定的 IP，可分配给人或组 | 低：管理员自备代理，服务端只存地址和凭据 | **第一阶段交付** |
| C. 每用户 Linux 容器 | 每用户一个 Docker 容器加一个主目录卷 | 用户之间由容器边界隔开；与宿主共享内核 | 每个运行中的容器占内存（默认上限 1 GiB），空闲即停 | 取决于所挂出口 | 中：需要 runner、镜像、配额、清理 | **第二阶段交付，推荐默认的环境形态** |
| D. 每组一个容器 | 一组人共用一个容器 | **组内无隔离**：共享主目录、进程、历史 | 低于 C | 同 C | 中，另加「谁干的」不可分辨 | 第三阶段显式选项，默认关闭 |
| E. 全实例共享容器 | 全体用户共用一个容器 | 无 | 最低 | 同 C | 低，但一人弄坏全员受影响 | 第三阶段显式选项，仅建议单人或家庭实例 |
| F. Windows 环境 | 一台 Windows 虚拟机或物理机，经 RDP 打开 | 取决于那台机器的账户划分 | 高：授权、4 GiB 以上内存、KVM | 等于那台机器自己的 IP | 高 | 第三阶段先做登记式（S9），自动创建列为开放问题 |

**推荐默认**：

- 普通 SSH/SFTP 沿用既有 Relay。管理员可单独接入外挂节点并授权给团队，无需启用 Docker。
- 个人 Linux 工作台是可选项，默认关闭。管理员启用后，用户首次点击「打开沙箱」才分配容器和独立主目录。镜像由 Debian slim 和项目工具包构成。

**分阶段**：

| 阶段 | 内容 | 需要 Docker 权限 |
| --- | --- | --- |
| P1 出口 | `sandbox_egresses`（`socks5` 类型）、分配与默认/必须语义、票据带 `egress_id`、管理分区的「出口」与「分配」页、客户端的出口显示与选择。SSH/SFTP/Telnet 先行；RDP/VNC 经出口见 §7.4。 | 否 |
| P1b 外挂节点主动接入 | Rust 节点代理主动连回 Server。先支持 SSH/SFTP，每个连接单独授权。需要内网接入和节点管理的部署可独立启用，见 §7.5。 | 否 |
| P2 每用户 Linux 环境 | `sandbox-runner`、模板、容器生命周期、主目录卷、配额、容器网络防火墙、`runner_network` 类型出口、用户侧「打开沙箱」、管理分区的「模板」「运行中」页。 | 仅 runner |
| P3 扩展 | 组共享与实例共享容器、远端 runner（多节点、多出口 IP）、登记式 Windows 环境、可选的 SSH agent 转发（§8.2）。 | 仅 runner |

关闭工作台只停用沙箱接入。关闭外挂出口时，绑定该出口的票据和会话失效。对设有必须出口的用户，连接保持拒绝，直到管理员恢复出口或修改分配。

---

## 4. 概念与对象

```text
 浏览器（已解锁 Vault，SSH 在这里终止）
     │  wss /relay/v1/connect（票据）
     ▼
 server ──(内置出口 server)────────────────────────────► 目标
     │
     ├─(出口 socks5: 管理员自备的固定 IP 代理)──────────► 目标
     │
     └─ sandbox-runner（唯一持有 Docker 权限）
            ├─ 出口网络 E1（SNAT 到 IP₁）── 拨号器 ─────► 目标
            │        └─ 用户甲的容器、用户乙的容器 ─────► 目标（同为 IP₁）
            └─ 出口网络 E2（SNAT 到 IP₂）── …
```

- **出口（egress）**：一个命名的拨号位置。类型：
  - `server`：内置，不可删除，ID 固定为 `server`。
  - `socks5`（P1）：服务端经管理员填写的 SOCKS5 代理拨号，`CONNECT` 里只放已校验的 IP 字面量，不让代理解析域名。
  - `agent`（P1b）：由管理员登记的外围节点主动连入，节点代表获准会话连接目标。出口绑定节点身份，节点在线地址可以变化。
  - `runner_network`（P2）：runner 宿主机上的一个 Docker 网络，SNAT 到指定的宿主 IP；网络里常驻一个拨号器，容器也接在这个网络上，所以容器内发起的连接与「经此出口的 Relay 连接」源 IP 一致。
- **模板（template）**：管理员定义的环境规格：镜像（按摘要固定）、所挂出口、出网模式、CPU/内存/进程数/主目录配额、空闲停止时间、共享范围。
- **沙箱（sandbox）**：模板在某个范围上的一个实例。范围是 `user`（默认）、`group` 或 `instance`。同一模板在同一范围上至多一个沙箱。
- **分配（assignment）**：把出口或模板授予实例、组或用户，并带一个方式：`available`（可选）、`default`（默认）、`required`（必须，仅出口）。

---

## 5. 共享模型

### 5.1 谁能用什么

一个用户**可用**的出口和模板，是下面三处授予的**并集**：

1. 授予全实例的；
2. 授予该用户所在任一 Relay 访问组的（`relay_access_group_members`）；
3. 直接授予该用户的。

注意这与 Relay 策略的方向相反：策略是逐层**收窄**（交集），出口和模板是逐层**授予**（并集）。两者不冲突，因为拿到一个出口不等于能连任何目标，目标仍然受 §7.2 的策略约束。

### 5.2 默认与必须

- 用户的默认出口按「用户 > 组 > 实例」取第一个 `default`；同一层有多个时取名称规范键最小的那个，并在管理界面标出冲突。都没有则为 `server`。
- 任一层存在 `required` 的出口时，该用户**只能**使用标为 `required` 的出口（多个则可在其中选），内置出口 `server` 对他不可用。用来实现「这个组的所有连接必须从办公网出口出去」。
- 服务端在签发票据时套用以上规则（S8）：请求不带 `egress_id` 用默认出口；带了但不在可用集合内返回 `403 EGRESS_DENIED`。

### 5.3 与用户、组、Vault 的对应

| 概念 | 是否参与沙箱授权 | 说明 |
| --- | --- | --- |
| 账户 | 是 | 沙箱和票据都绑定账户、设备、会话，账户停用或会话吊销立即断开。 |
| Relay 访问组 | 是 | 唯一的组来源。管理面板的用户编辑里已经在维护它，沙箱分配直接引用 `group_id`。 |
| 云端组织 / 团队 | 否 | 由组织所有者管理，不是实例管理员的控制面。管理员想让一个团队共用出口，就建一个同名 Relay 访问组。合并两套组是更大的改动，列为 §13 Q6。 |
| Vault 成员关系 | 否 | Vault 是密码学单元，服务端只见密文，不从中推导授权。 |
| 主机记录 | 仅携带偏好 | 主机可以记住「经哪个出口连接」（§10.2）。这是加密记录里的一个字段，是偏好不是授权；共享 Vault 的另一位成员若没有该出口，客户端提示并回落到他的默认出口，「必须」出口的用户则始终用自己的必须出口。 |

### 5.4 共享容器（P3）的规则

组或实例范围的沙箱只有在模板显式设为该范围时才会出现，创建模板时界面提示：成员彼此能读写同一个主目录、看到彼此的进程。共享容器里所有人使用同一个 Unix 用户，不做容器内的多用户划分（那会给出一个并不成立的隔离印象）。审计按 Atermius 账户记录谁在何时接入，容器内的操作不可归因。

---

## 6. 生命周期（Linux 环境）

### 6.1 状态

```text
(不存在) ──首次打开──► creating ──► running ⇄ stopped ──销毁──► (不存在)
                           │            │
                           └─ 失败 ─► error（可重试或销毁）
```

- **创建**：用户第一次点「打开沙箱」时创建，不预建。`POST /api/v1/sandboxes` 幂等：同一模板同一范围已存在则返回它。
- **启动**：`stopped` 状态下再次打开会自动启动，目标是几秒内可用。
- **空闲停止**：没有任何接入会话持续 `idle_stop_seconds`（模板默认 1800 秒）后 runner 停止容器。停止只释放内存和 CPU，主目录保留。后台进程随之结束，界面在停止前的会话里不做提示，但在沙箱卡片上写明这一规则。
- **重置**：用户或管理员可销毁容器并从模板镜像重建，主目录保留。用于「把环境弄坏了」。
- **销毁**：管理员操作，或用户对自己的沙箱操作。可选是否同时删除主目录。
- **模板变更**：镜像或配额变更只影响下一次启动；管理员可在「运行中」页对旧版本的沙箱逐个或批量停止。出口或出网模式变更会推进授权版本，立即断开受影响的连接并重写防火墙。

### 6.2 持久化

- 只有主目录（`/home/sandbox`）持久，是一个按沙箱命名的 Docker 卷。根文件系统只读，`/tmp` 是有大小上限的 tmpfs。在容器里 `apt install` 的东西不会保留；要常驻的工具放进模板镜像。
- 主目录在以下情况被删除：销毁时选择删除；账户删除（挂在现有账户删除流程上，宽限期结束时执行）；连续 `home_retention_days`（默认 30 天）未使用，删除前 7 天在沙箱卡片和通知里提示。
- 账户被停用时容器立即停止，主目录按保留期处理。

### 6.3 配额与上限

| 项 | 默认 | 位置 |
| --- | --- | --- |
| CPU | 1 核 | 模板 |
| 内存 | 1024 MiB（不含 swap） | 模板 |
| 进程数 | 256 | 模板 |
| 主目录 | 2048 MiB | 模板 |
| 每沙箱同时接入会话 | 8 | 模板 |
| 实例同时运行的沙箱数 | 20 | 实例设置 |
| 每用户沙箱数 | 每模板 1 个 | 固定 |

达到实例运行上限时，新的启动请求返回 `429 SANDBOX_CAPACITY`，界面显示「实例的沙箱已满」，不排队。接入会话走 Relay，因此同时受 Relay 的每用户连接数、单连接 60 分钟与 1 GiB 上限约束（`relay.rs:44-49`）；这对长时间终端偏紧，P2 需要把沙箱接入的时长上限单独设为模板字段，默认 8 小时。

主目录硬配额依赖宿主文件系统（如 XFS 项目配额）。不支持时 runner 周期性统计用量，超限后拒绝下次启动并在卡片上说明；这种情况下它是软配额，部署文档如实写明。

### 6.4 备份与重启

- 实例备份不包含沙箱主目录和镜像。恢复实例后，数据库里的沙箱行若在 runner 上找不到对应容器或卷，标为 `error` 并允许重建。
- `server` 重启会断开 Relay 连接，但 runner 和容器继续运行；runner 重启不停止容器，启动时与数据库对账，清理数据库里不存在的孤儿容器。

---

## 7. 网络模型

### 7.1 出口 IP 如何确定

- `socks5`：目标看到的是代理机的 IP。管理员在出口上填写「显示 IP」，服务端不猜测。
- `agent`：目标看到节点的出站 IP。节点主动建立的控制连接只用于身份和会话调度；显示 IP 应从目标侧验证。
- `runner_network`：runner 为每个出口建一个独立的 Docker bridge 网络，关闭容器间互通，并把该网络的出站流量 SNAT 到管理员选定的宿主机 IP（Docker 的 `com.docker.network.host_ipv4` 网络选项，或由 runner 自己写 nftables SNAT 规则；实现时在目标 Docker 版本上验证）。宿主机需要事先配好这些附加 IP。IPv6 出口同理，单独配置。
- 管理界面的「测试」按钮经该出口向管理员给定的一个目标（必须通过当前策略）发起一次 TCP 连接，报告成功与耗时。它验证连通性，不验证对端看到的 IP；显示 IP 以管理员填写为准，并在界面上这样标注。

### 7.2 目标策略：复用，不新增体系

经任何出口发起的连接，允许的目标是：

```text
effective_policy_for_user(用户)            # 现有：部署 ∩ 实例 ∩ 用户 ∩ 各组
  ∩ 出口自带的 allow_cidrs / allow_ports    # 可选，只能收窄，用 restrict_effective_policy
  − is_forbidden_ip                          # 现有永久禁止项
  − 内部网络拒绝表（§7.3）
```

- 票据签发和票据消费两处都检查，和今天一样；域名在签发时解析，全部答案都必须被允许，拨号用已校验的 IP 字面量。
- 出口不能放宽策略。想让某个出口可达一个私网段，管理员需要先在部署上限和实例策略里放开，再用用户/组策略把其他人收窄。这保持「部署环境变量是硬上限」的现有约定。
- 出口、分配、模板出网模式的任何变更都推进受影响用户的 `relay_user_authorization_versions`，已建立的连接在约 2 秒内断开，未消费的票据作废。这是现有机制（`relay_connection_active`），不另造。

### 7.3 容器自己的出网

容器里的 shell 可以直接拨号，所以 runner 在每个容器的网络接口上落防火墙规则（宿主机 nftables，按容器地址匹配，容器内无权修改）：

1. **始终拒绝**：宿主机自身的全部地址与网关地址；compose 内部网络（默认 `172.16.0.0/12`，与 `ATERMIUS_SHARE_DENY_CIDRS` 的默认值一致，可用 `ATERMIUS_SANDBOX_DENY_CIDRS` 追加）；环回、链路本地、组播、云元数据（即 `is_forbidden_ip` 的集合）；同一出口网络里的其他容器。
2. **按模板的出网模式放行**：
   - `relay_policy`（默认）：只放行该沙箱所有者的有效 Relay 策略允许的地址和端口，加上 DNS。容器里能连的和 Web 客户端里能连的完全一致。
   - `open`：放行全部公网地址（仍受第 1 条约束），私网地址仍只按 Relay 策略放行。用于需要 `git clone`、下载工具的模板，管理员显式选择，模板卡片上标出。
3. 策略变更时 runner 重写规则并清除该容器的连接跟踪，使已建立的连接也断开。组或实例范围的共享容器取**全体可接入成员有效策略的交集**。

DNS 由 runner 指定的解析器提供，默认是宿主机配置的上游解析器，不指向 compose 网络里的任何内部服务。过滤按 IP 做，所以 DNS 重绑定不能绕过规则。

server、数据库、对象存储、guacd、runner 的控制端口对容器一律不可达，这一条有负向验收测试（从容器内逐个连接这些地址必须失败）。

### 7.4 RDP/VNC 经出口

guacd 自己拨号，不支持上游代理。做法：服务端为这一条连接开一个只接受一次连接、只接受来自 guacd 的本地转发端口，把 guacd 的 `hostname`/`port` 指向它，再由服务端经所选出口连到真正的目标。RDP 的 TLS 仍在 guacd 与目标之间，证书指纹校验不受影响。这部分排在 P1 的后半，SSH/SFTP/Telnet 先交付；在它完成前，被设了「必须」出口的用户发起 RDP/VNC 会被拒绝并给出明确原因，而不是悄悄从服务器 IP 出去。

---

### 7.5 外挂服务器主动接入（建议）

**接入哪种服务器。** 如果 Atermius Server 的 Relay 已能访问外部机器的 SSH 服务，管理员或用户按现有方式登记为主机即可。需要从内网主动连回中心，或者需要团队共用该机器的网络出口时，再登记节点。节点位于 NAT 后也能发起出站连接。目标看到的公网地址取决于节点所在网络的 NAT 或 SNAT 配置。

**两种传输。** 少数固定主机可以先试用反向 SSH。节点维持一条 SSH 连接，复用其 channel 访问事先登记的服务。中心的转发端点只供对应 Relay 适配器使用。节点身份、固定服务映射、用户票据和目标白名单均需校验，保留普通 Relay 对环回地址的既有拒绝规则。SSH 自身并不提供 Atermius 的组分配和会话审计。[SSH 连接协议](https://datatracker.ietf.org/doc/html/rfc4254#section-7)

**产品化的推荐路径。** 外挂机安装独立 Rust Agent，以节点证书和 mTLS 主动连接 Server 的 HTTPS 入口。管理员授予该节点出口能力。普通出口节点以非特权用户运行。需要在该机创建 Debian 工作台时，再单独部署与授权 §8.4 的容器 runner。节点入口须支持 HTTP/2 双向流并验证节点证书。部署在反向代理之后时，由可信入口验证证书并向后端传递经过认证的节点身份。控制接口带协议版本，Agent 可以独立升级或重启。

1. Agent 作为 gRPC 客户端打开持久的双向控制流，登记节点、报告心跳和容量。Server 按用户、设备、组和目标复查 Relay 票据后，在该控制流内通知节点受理会话。
2. Agent 在已建立的 HTTP/2 连接上为这次会话发起独立的双向数据流。Server 只接受该节点持有的一次性会话凭据，校验会话、节点和已核准的目标 IP/端口绑定。Agent 再按本机策略校验实际拨号目标。浏览器继续使用现有 Relay WebSocket 和 SSH 主机指纹校验。每位用户的 SSH 凭据与终端会话各自独立。[gRPC 双向流](https://grpc.io/docs/what-is-grpc/core-concepts/#bidirectional-streaming-rpc)
3. 每用户和每节点分别限制并发，数据流使用有界缓冲和背压。撤销用户权限时关闭该用户的流，撤销节点身份时关闭该节点全部流。节点重连要重新认证，新会话重新授权。个人工作台留在持有其主目录卷的节点，迁移需要单独转移数据。
4. 压测在相同链路、加密和限速条件下比较反向 SSH 与 Agent。测量空闲和 SFTP 满载时的终端按键回显 P95、聚合吞吐、每会话内存以及中心服务器带宽。HTTP/2 支持多流，底层 TCP 丢包仍可能拖慢其他流。如果大文件传输明显推高回显延迟，再将批量传输分配到单独的底层连接。共享同一 SSH 传输的 Shell 和 SFTP channel 应作为同一条不透明字节流处理。[HTTP/2 多路复用与流控](https://httpwg.org/specs/rfc9113.html#StreamsLayer)

---

## 8. 安全模型

### 8.1 凭据在哪里解密、怎么到达目标

| 场景 | 凭据在哪里 | 服务端 / 出口 / 容器能看到什么 |
| --- | --- | --- |
| SSH/SFTP 经出口 | 浏览器内存。SSH 握手和认证在浏览器与目标之间完成。 | 目标 IP 和端口、流量大小与时间。看不到用户名、密码、密钥、会话内容。与今天的 Relay 相同。 |
| Telnet 经出口 | 浏览器。Telnet 本身无加密。 | 全部明文。与今天相同，`docs/TELNET.md` 已说明。 |
| RDP/VNC 经出口 | 浏览器经 `DesktopHello` 把用户名和密码交给服务端，再给 guacd。 | 服务端和 guacd 在传输中可见凭据和画面。与今天的桌面网关相同，沙箱不改变也不扩大它。 |
| 打开沙箱终端 | 不使用任何 Vault 凭据。浏览器当场生成一对 Ed25519 密钥，公钥随票据请求提交，runner 写入容器的 `authorized_keys`，会话结束即删除；私钥只在浏览器内存里，不落盘、不同步。容器 sshd 的主机密钥指纹由 runner 经控制通道给服务端，随票据返回，客户端直接固定，不弹首次信任提示。 | 运营者控制容器，因此能看到沙箱里的一切。 |
| 在沙箱 shell 里 `ssh 目标` | 默认没有凭据。用户可以自己把密钥放进主目录，界面在沙箱卡片和首次打开时写明「沙箱内的文件和输入对实例运营者可见，不受 Vault 加密保护」。P3 可选的 SSH agent 转发见 §8.2。 | 用户放进去的任何东西。 |

为什么沙箱终端用「容器里跑 sshd + 浏览器当普通 SSH 主机去连」而不是服务端 `docker exec` 再转发字节：这样终端、SFTP 文件管理、分屏、重连、端口转发、MCP 工具全部沿用客户端现有的 SSH 实现，不新增协议；服务端也不需要解析终端流。安全上两者等价（运营者都控制容器），所以选改动小的。

### 8.2 可选：SSH agent 转发（P3，默认关闭）

用户在沙箱 shell 里想用 Vault 里的私钥登录别的机器时，可以在该次会话上打开 agent 转发：私钥留在浏览器，沙箱只能在会话存续期间请求签名。客户端目前没有 agent 实现，这是新增工作。它的风险必须写在开关旁边：会话期间，沙箱里的任何进程（以及运营者）都能用这把钥匙签名登录任意接受它的主机，只是拿不走钥匙本身。每次签名在浏览器端计数并可选逐次确认。

### 8.3 被攻破的沙箱能做什么、不能做什么

能做：

- 读写该沙箱主目录里的一切，包括用户自己放进去的密钥；共享容器则是所有成员的。
- 在模板出网模式与用户 Relay 策略允许的范围内，以出口 IP 的名义对外发起连接。这是沙箱固有的能力，靠策略和审计约束。
- 消耗到配额为止的 CPU、内存、磁盘。
- 若启用了 agent 转发，在会话期间滥用签名。

不能做：

- 读到 Vault 明文或 Vault 密钥：它们从不进入沙箱，也不进入服务端。
- 看到「经出口」的 SSH 连接内容：那些连接由拨号器转发，不经过用户容器，且本身是端到端加密的。
- 访问 server、数据库、对象存储、guacd、runner 控制端口、宿主机或同网络的其他容器（§7.3）。
- 调用 Atermius API：容器里没有任何会话令牌；runner 的控制接口只接受 server 的凭据。
- 提升到宿主机：容器以非 root 用户运行，丢弃全部 capabilities，`no-new-privileges`，默认 seccomp，只读根文件系统，不挂宿主路径和设备，启用用户命名空间映射。**残余风险**：容器与宿主共享内核，内核漏洞可以逃逸。面向不完全受信用户的实例应使用 gVisor 之类的沙箱运行时或把 runner 放在独立机器上（§13 Q4）。

`socks5` 出口的代理机是第三方：它能看到目标地址和密文流量，能丢弃或拖延连接，不能解密 SSH。对 Telnet 和未加密的 VNC 它能看到明文，界面在选择出口时对这两种协议给出提示。

### 8.4 runner 的信任

runner 持有 Docker 权限，等同宿主机 root，因此：

- 它的 API 不发布到宿主机端口，只在 compose 内部网络上监听，用独立卷里的共享密钥文件做双向认证（与网关密钥一样放在 `/data` 之外，不进备份）。
- 它不接受自由形式的容器参数。创建请求只带模板 ID、沙箱 ID 和配额数值；镜像必须是模板里登记的摘要；容器的安全选项在 runner 里写死，服务端无法通过 API 关掉任何一项。这样即使 `server` 被攻破，攻击者经 runner 能得到的也只是「按模板创建受限容器」。
- 它不接触数据库，不接触 Vault 数据。

### 8.5 审计事件

沿用现有两类审计：账户范围（`record_account_event_tx`）和实例管理员范围（`record_instance_admin_event_tx`）。只记元数据，不记目标主机名之外的任何会话内容，不记公钥私钥。

| 事件 | 范围 | 何时 |
| --- | --- | --- |
| `relay.ticket_issued`、`relay.connected`（已有） | 账户 | 详情里增加 `egress_id` |
| `sandbox.created`、`sandbox.started`、`sandbox.stopped`、`sandbox.reset`、`sandbox.destroyed` | 账户 | 生命周期变化，注明触发者是用户、管理员还是空闲回收 |
| `sandbox.session_opened`、`sandbox.session_closed` | 账户 | 有人接入沙箱终端 |
| `sandbox.egress_denied` | 账户 | 请求了无权使用的出口，或必须出口不可用 |
| `admin.sandbox_settings_updated` | 实例 | 实例开关与上限 |
| `admin.sandbox_egress_created` / `_updated` / `_deleted` | 实例 | 出口变更（不记代理密码） |
| `admin.sandbox_template_created` / `_updated` / `_deleted` | 实例 | 模板变更 |
| `admin.sandbox_assignments_updated` | 实例 | 分配变更 |
| `admin.sandbox_stopped`、`admin.sandbox_destroyed` | 实例 | 管理员对某个沙箱的操作 |

容器内执行了什么命令不审计，也不承诺能审计。

---

## 9. 数据模型与 API 草案

命名、CAS、`name_key`（NFKC 规范化）沿用 `0043_server_managed_relay_groups.sql` 的风格。SQLite 先行；PostgreSQL 模式需要单独的 repository 和 `pg_sync_route_is_supported` 白名单项，在那之前这些路由在 PG 模式下保持关闭。

### 9.1 表（迁移 `0057_online_sandbox.sql`，P1 建出口与分配表，P1b 增加节点登记）

```sql
-- 实例级开关与上限；无行表示功能关闭、revision 0。
CREATE TABLE instance_sandbox_settings (
    settings_id INTEGER PRIMARY KEY CHECK (settings_id = 1),
    external_egresses_enabled INTEGER NOT NULL CHECK (external_egresses_enabled IN (0, 1)),
    sandboxes_enabled INTEGER NOT NULL CHECK (sandboxes_enabled IN (0, 1)),
    max_running_sandboxes INTEGER NOT NULL CHECK (max_running_sandboxes BETWEEN 0 AND 1000),
    revision INTEGER NOT NULL,
    updated_at TEXT NOT NULL
);

-- 内置出口 server 不入表。
CREATE TABLE sandbox_egresses (
    egress_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    name_key TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL CHECK (kind IN ('socks5', 'agent', 'runner_network')),
    config_json TEXT NOT NULL,          -- socks5: 地址、端口；agent: 登记的 node_id；runner_network: runner_id、宿主 IP
    secret_ciphertext TEXT,             -- socks5 口令，用服务端密钥派生的密钥加密，API 只写不读
    display_ip TEXT NOT NULL,           -- 管理员填写的对外 IP，仅展示
    allow_cidrs TEXT,                   -- 可选收窄，NULL 表示不收窄
    allow_ports TEXT,
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    revision INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE sandbox_assignments (
    principal_type TEXT NOT NULL CHECK (principal_type IN ('instance', 'group', 'user')),
    principal_id TEXT NOT NULL,         -- instance 时为 ''；group 引用 relay_access_groups；user 引用 users
    resource_type TEXT NOT NULL CHECK (resource_type IN ('egress', 'template')),
    resource_id TEXT NOT NULL,          -- 'server' 表示内置出口
    mode TEXT NOT NULL CHECK (mode IN ('available', 'default', 'required')),
    created_at TEXT NOT NULL,
    PRIMARY KEY (principal_type, principal_id, resource_type, resource_id)
);
-- 整张分配表一个 CAS 版本，写法同组成员的全量替换。
CREATE TABLE sandbox_assignment_revisions (
    revision_id INTEGER PRIMARY KEY CHECK (revision_id = 1),
    revision INTEGER NOT NULL
);

ALTER TABLE relay_tickets ADD COLUMN egress_id TEXT;   -- NULL = server
ALTER TABLE relay_tickets ADD COLUMN sandbox_id TEXT;  -- 非 NULL = 接入沙箱终端的票据

-- P2
CREATE TABLE sandbox_templates (
    template_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    name_key TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL CHECK (kind IN ('linux_container', 'windows_host')),
    scope TEXT NOT NULL CHECK (scope IN ('user', 'group', 'instance')),
    image_ref TEXT NOT NULL,            -- 必须带 @sha256: 摘要
    egress_id TEXT NOT NULL,            -- 'server' 或 sandbox_egresses.egress_id（须为 runner_network）
    outbound_mode TEXT NOT NULL CHECK (outbound_mode IN ('relay_policy', 'open')),
    cpu_millis INTEGER NOT NULL,
    memory_mb INTEGER NOT NULL,
    pids_limit INTEGER NOT NULL,
    home_quota_mb INTEGER NOT NULL,
    max_sessions INTEGER NOT NULL,
    max_session_seconds INTEGER NOT NULL,
    idle_stop_seconds INTEGER NOT NULL,
    home_retention_days INTEGER NOT NULL,
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    revision INTEGER NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE sandboxes (
    sandbox_id TEXT PRIMARY KEY,
    template_id TEXT NOT NULL REFERENCES sandbox_templates(template_id),
    scope_type TEXT NOT NULL CHECK (scope_type IN ('user', 'group', 'instance')),
    scope_id TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('creating', 'running', 'stopped', 'error')),
    template_revision INTEGER NOT NULL, -- 创建或上次启动时的模板版本
    runner_id TEXT NOT NULL,
    host_key_sha256 TEXT,
    home_bytes INTEGER,
    created_at TEXT NOT NULL,
    last_started_at TEXT,
    last_active_at TEXT,
    UNIQUE (template_id, scope_type, scope_id)
);

CREATE TABLE sandbox_sessions (
    sandbox_session_id TEXT PRIMARY KEY,
    sandbox_id TEXT NOT NULL REFERENCES sandboxes(sandbox_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    session_id TEXT NOT NULL,           -- API 会话，吊销即断开
    opened_at TEXT NOT NULL,
    closed_at TEXT
);

-- P3：远端 runner 登记（本机 runner 用环境变量配置，不入表）。
CREATE TABLE sandbox_runners (
    runner_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    name_key TEXT NOT NULL UNIQUE,
    token_hash TEXT NOT NULL,
    last_seen_at TEXT,
    created_at TEXT NOT NULL
);
```

P1b 的节点登记记录包含稳定的节点 ID、实例、证书身份与吊销状态、获准能力和最近心跳。出口引用已登记的节点，用户或组通过既有出口分配获得使用权。节点登记与 P3 的 Docker runner 登记分别授权。

Windows 登记式环境（P3）在 `sandbox_templates` 里用 `kind='windows_host'`，`image_ref` 留空，另加一张 `sandbox_windows_hosts(host_id, template_id, address, port, certificate_sha256, assigned_user_id)`；不存任何登录凭据。

### 9.2 管理端点（实例管理员，全部 CAS，全部写实例审计）

| 方法与路径 | 作用 |
| --- | --- |
| `GET` / `PUT /api/v1/admin/sandbox-settings` | 分别设置外挂出口、在线沙箱的实例开关和运行上限，返回节点及 runner 在线状态 |
| `GET` / `POST /api/v1/admin/sandbox-egresses` | 列出（含内置 `server`）、新建 |
| `GET` / `PUT` / `DELETE /api/v1/admin/sandbox-egresses/{egress_id}` | 读、改、删；被模板或分配引用时删除返回 `409` 并列出引用者 |
| `POST /api/v1/admin/sandbox-egresses/{egress_id}/test` | 经该出口向给定目标做一次连通测试（目标须通过管理员本人的有效策略） |
| `GET` / `POST /api/v1/admin/sandbox-templates`，`GET` / `PUT` / `DELETE …/{template_id}` | 模板 |
| `GET` / `PUT /api/v1/admin/sandbox-assignments` | 全量读取与替换分配表；响应带每个用户解析后的默认/必须出口，便于界面预览 |
| `GET /api/v1/admin/sandboxes` | 全部沙箱：所有者、模板、状态、出口、接入会话数、用量、是否落后于模板版本 |
| `POST /api/v1/admin/sandboxes/{sandbox_id}/stop` | 停止 |
| `POST /api/v1/admin/sandboxes/{sandbox_id}/destroy` | 销毁，`{"delete_home": true|false}` |
| `GET /api/v1/admin/accounts/{user_id}/sandbox` | 某用户解析后的可用出口、默认出口、沙箱列表，供用户编辑页嵌入 |

### 9.3 用户端点

| 方法与路径 | 作用 |
| --- | --- |
| `GET /api/v1/sandbox/options` | 当前用户可用的出口（ID、名称、显示 IP、方式）、解析后的默认出口、是否被强制、可用模板、自己的沙箱及状态。旧服务端返回 404，客户端据此判断不支持并隐藏全部入口。 |
| `POST /api/v1/relay/tickets` | 现有。请求体增加可选的 `egress_id`。`TicketRequest` 是 `deny_unknown_fields`，所以客户端只在 `options` 可用时才发送这个字段。 |
| `POST /api/v1/sandboxes` | `{"template_id": …}`，创建或返回已有的沙箱 |
| `POST /api/v1/sandboxes/{sandbox_id}/start` / `stop` / `reset` | 生命周期 |
| `DELETE /api/v1/sandboxes/{sandbox_id}` | 销毁自己的沙箱，`?delete_home=true` |
| `POST /api/v1/sandboxes/{sandbox_id}/tickets` | `{"device_id": …, "public_key": "ssh-ed25519 …"}` → `{"ticket", "expires_at", "host_key_sha256", "username"}`。票据在现有 `/relay/v1/connect` 上消费，服务端经 runner 接到该容器的 sshd；目标不可由请求指定。 |

对象级授权：每个带 `sandbox_id` 的请求都核对调用者是该沙箱范围内的成员；不是则统一返回 404。沙箱票据与普通票据一样绑定会话、设备、授权版本，并且每约 2 秒复查。

### 9.4 server 与 runner 之间（内部，不对外）

`ensure_network(egress)`、`dial(egress_id, ip, port)`（返回一条字节流）、`create(sandbox_id, template 规格)`、`start`、`stop`、`destroy(delete_home)`、`authorize_key(sandbox_id, public_key, ttl)`、`attach(sandbox_id)`（接到容器 sshd 的字节流）、`apply_policy(sandbox_id, 允许的 CIDR 与端口)`、`list`（对账与用量）。

---

## 10. 界面

### 10.1 管理面板分区「沙箱与出口」

作为管理面板分区注册表里的一个分区，与「用户」「Relay 策略」并列。分为五页：

| 页 | 管理员配置什么 | 管理员看到什么 |
| --- | --- | --- |
| 概览 | 外挂出口开关、独立的在线沙箱开关、实例同时运行上限 | runner 是否在线及版本；运行中 / 已停止沙箱数；各出口当前连接数；主目录总用量 |
| 出口 | 新建、编辑、停用、删除出口：名称、类型、代理地址与口令或宿主 IP、显示 IP、可选的目标收窄；「测试」 | 每个出口的显示 IP、类型、启用状态、谁在用（分配数、当前连接数）；内置 `server` 固定在首行，只读 |
| 模板 | 镜像（摘要）、共享范围（每用户 / 每组 / 全实例）、所挂出口、出网模式、CPU / 内存 / 进程数 / 主目录配额、会话数与时长、空闲停止、主目录保留天数 | 每个模板的沙箱数、落后于当前版本的沙箱数 |
| 分配 | 一张「对象 × 资源」表：对实例、组、用户分别授予出口或模板，并选「可选 / 默认 / 必须」 | 每个用户解析后的结果（默认出口、是否被强制、可用模板）；同层多个默认时的冲突提示 |
| 运行中 | 对单个或多选沙箱：停止、销毁（可选删除主目录） | 所有者、模板、状态、出口 IP、接入会话数、最近活动、CPU / 内存 / 磁盘用量、是否需要重启以应用新模板 |

用户编辑页里嵌一块「沙箱与出口」：该用户解析后的默认出口和可用出口、所在组带来的授予、他的沙箱及停止/销毁按钮，以及「为此用户单独分配」的入口。这样「用户编辑」与「全局功能」两处看到的是同一份数据。

分区内所有字符串进入四个 ARB 文件；状态、类型、方式一律用枚举值判断，不从显示文字推导。

### 10.2 用户侧

- **看得见从哪里发出**：会话的连接进度与状态栏显示「经 办公网出口（203.0.113.10）」。出口是 `server` 且用户没有其他可选出口时不显示，保持今天的界面不变。
- **主机编辑器**：协议下方增加「连接出口」：`跟随默认` / 具体出口。只在 `options` 返回两个以上可用出口时出现。它存进加密的主机记录（新增可选字段 `egress_id`，旧客户端忽略未知字段的行为需要按现有集成测试方式验证），只是偏好。
- **单次覆盖**：主机右键菜单「从…连接」列出可用出口，只影响这一次会话，不改主机记录。
- **被强制时**：选择控件显示为只读并写明「管理员要求经此出口连接」。
- **出口不可用**：记录里的出口对当前用户不可用（被收回、或来自别人共享的 Vault）时，提示一次并改用默认出口；若用户被强制而必须出口当前不可达，则连接失败并说明原因，不回落到服务器 IP。
- **跳板机**：出口决定第一跳从哪里发出，后续各跳不变。
- **打开沙箱**：工作区 **+** 菜单里，原先在浏览器上显示「需要桌面应用」的本机 Shell 位置，增加「在线沙箱」项（每个可用模板一项）。点击后在标签页里显示创建/启动进度，然后是一个普通的终端标签，分屏、复制、SFTP 文件面板都可用。沙箱不出现在主机列表里，也不写入 Vault。
- **沙箱卡片**（设置 → 在线沙箱）：状态、出口 IP、主目录用量与配额、空闲停止规则、数据保留期限；按钮：停止、重置、删除数据。卡片上固定一行说明：沙箱内的文件和输入对实例运营者可见。
- 原生客户端第一阶段不显示这些入口。

---

## 11. 部署

### 11.1 P1：沿用现有中心服务

出口是 `server` 内部的拨号选择。`deploy/compose.yaml` 不变；新增环境变量：

| 变量 | 默认 | 含义 |
| --- | --- | --- |
| `ATERMIUS_EXTERNAL_EGRESSES_ENABLED` | `false` | 允许管理员启用外挂出口。P1b 使用 Agent 时在指定外部机器安装节点服务。 |
| `ATERMIUS_SANDBOX_ENABLED` | `false` | 允许管理员启用容器工作台。关闭时仍可使用获准的普通主机和外挂出口。 |

### 11.2 P2：覆盖文件 `deploy/compose.sandbox.yaml`

```yaml
# docker compose -f deploy/compose.yaml -f deploy/compose.sandbox.yaml up -d --build
services:
  server:
    environment:
      ATERMIUS_SANDBOX_ENABLED: "true"
      ATERMIUS_SANDBOX_RUNNER_ADDRESS: sandbox-runner:8090
      ATERMIUS_SANDBOX_RUNNER_KEY_FILE: /sandbox-runner-key/runner.key
      ATERMIUS_SANDBOX_DENY_CIDRS: "${ATERMIUS_SANDBOX_DENY_CIDRS:-172.16.0.0/12}"
    volumes:
      - sandbox-runner-key:/sandbox-runner-key:ro
  sandbox-runner:
    build: { context: .., dockerfile: sandbox-runner/Dockerfile }
    restart: unless-stopped
    # 不发布端口：只有 server 能访问。
    environment:
      ATERMIUS_SANDBOX_RUNNER_KEY_FILE: /sandbox-runner-key/runner.key
    volumes:
      - sandbox-runner-key:/sandbox-runner-key
      - /var/run/docker.sock:/var/run/docker.sock
    # 防火墙与 SNAT 规则要写在宿主网络命名空间里，由谁来写见下文。
volumes:
  sandbox-runner-key:
```

实现时要定的一点：防火墙规则必须落在宿主网络命名空间里。两种做法，建议前者：runner 的控制 API 仍在 compose 网络上，另起一个只做 nftables 的最小特权辅助容器用 `network_mode: host`；或者 runner 整体用宿主网络并只监听一个仅 `server` 可达的地址。

### 11.3 为什么不把 Docker socket 给 `server`

- 能访问 Docker socket 就能启动特权容器、挂载宿主根目录，等于宿主机 root。
- `server` 面向公网，处理登录、同步、WebSocket、上传等大量不可信输入，是整个部署里最可能被攻破的进程；它今天以非 root、`no-new-privileges`、无任何宿主权限运行，这是现有安全基线的一部分。
- 把 socket 给它，一次服务端漏洞的后果从「泄露密文数据库」（Vault 仍是端到端加密的）升级为「接管宿主机及其上的全部其他服务」。在预览机这类与其他业务容器混部的机器上尤其不可接受。

独立 runner 把这项权限关进一个不面向公网、接口只有十来个固定操作、参数不可自由指定的小服务里（§8.4）。可进一步收紧的选项，按代价从低到高：

1. runner 前面放一个只放行所需 Docker API 路径的 socket 代理。
2. runner 使用 rootless Docker 或 Podman：被攻破时拿到的是一个普通用户而不是 root。代价是固定出口 IP 的 SNAT 需要额外配置。
3. runner 部署在另一台机器上（P3 的远端 runner）：沙箱与实例数据彻底分机，并自然得到另一个出口 IP。

### 11.4 镜像

仓库提供一个参考模板镜像 `deploy/sandbox/Dockerfile`（Debian slim、sshd 仅公钥认证且仅监听容器网络、非 root 用户 `sandbox`、常用工具：`openssh-client`、`curl`、`git`、`dnsutils`、`iputils-ping`、`traceroute`、`nmap`、`mtr`、`vim`、`tmux`）。管理员可登记自己的镜像，要求：按摘要引用、能以非 root 运行、含 sshd。runner 只从模板登记的摘要拉取。

### 11.5 预览机

预览机上还有其他业务容器。P1 可以直接部署验证（不涉及 Docker 权限）。P2 在预览机上启用前，需要确认 runner 的防火墙规则只作用于它自己创建的网络，不改动宿主机上其他容器的规则链；这一点列为 P2 的验收项。

---

## 12. 验收要点（随功能交付的负向测试）

1. 不带 `egress_id` 的票据使用解析后的默认出口；被强制的用户请求 `server` 出口或任何未授予的出口得到 `403 EGRESS_DENIED`，且有审计。
2. 出口被停用、分配被收回、用户被移出组后，约 2 秒内已建立的连接断开，未消费的票据失效。
3. 经任何出口都不能到达 Relay 策略之外的目标；域名解析出任一不允许的地址即拒绝。
4. 被强制出口的用户在出口不可达时连接失败，流量不会从服务器 IP 发出（抓包验证）。
5. 沙箱票据只能接到调用者有权的沙箱；猜测他人的 `sandbox_id` 得到 404。
6. 从容器内连接 server、数据库、对象存储、guacd、runner 控制端口、宿主机地址、云元数据地址、同网络其他容器，全部失败。
7. 容器内无法提权：不是 root、无 capabilities、根文件系统只读、超出进程数与内存上限时被限制而不影响其他容器。
8. 伪造的 runner 请求（无密钥、错误密钥）被拒绝；带任意镜像名或额外容器参数的创建请求被拒绝。
9. 账户停用即停止其沙箱并断开会话；账户删除在宽限期结束时删除主目录。
10. 日志、审计、错误响应里不出现代理口令、公钥对应的私钥材料或任何会话内容。

外挂节点另验收三种行为。关闭沙箱且未部署 runner 时，两名获准用户能经同一节点建立各自的 SSH/SFTP 会话。撤销其中一名用户的授权后，另一名用户的会话继续。节点掉线时，设有必须出口的连接按原策略失败，节点恢复后新会话可重新授权连接。

---

## 13. 需要负责人决定的问题

| # | 问题 | 选项 | 建议 |
| --- | --- | --- | --- |
| Q1 | 先做哪一步？ | (a) 先出口后容器；(b) 直接做容器 | **(a)**。出口不需要 Docker 权限，改动集中在票据和一个拨号点，能立刻解决「SSH 发起 IP」；容器在它之上叠加。 |
| Q2 | 环境的默认共享方式？ | 每用户 / 每组 / 全实例 | **每用户**。组与实例共享只作为模板上的显式选项（P3），并在界面上写明成员互相可见。 |
| Q3 | 容器的默认出网范围？ | (a) 与 Relay 策略一致；(b) 开放公网 | **(a) 为默认**，(b) 由管理员按模板打开。默认开放公网等于把服务器变成任何账户都能用的通用出口。 |
| Q4 | 容器隔离强度要到哪一级？ | (a) 标准容器加固；(b) 要求 gVisor 等沙箱运行时；(c) runner 独立机器 | 仅自己人使用的实例 **(a)** 即可；对外发放账户的实例至少 **(b)**，模板增加运行时字段，runner 检测到未安装时拒绝启动并说明。 |
| Q5 | Windows 环境做到什么程度？ | (a) 登记已有 Windows 主机并分配（服务端不建机、不存凭据）；(b) runner 自动创建 Windows 虚拟机 | **(a)**，放在 P3。(b) 需要 KVM、Windows 授权和每台 4 GiB 以上内存，先不承诺；若确有需要，另写一份设计。 |
| Q6 | 分配用的「组」取哪一套？ | (a) Relay 访问组；(b) 云端组织的团队；(c) 合并两者 | **(a)**。它已由实例管理员维护并承载 Relay 策略。(c) 是值得做的整理，但范围大于本功能，不应捆绑。 |
| Q7 | 沙箱终端的接入方式？ | (a) 容器内 sshd，浏览器按普通 SSH 连接；(b) 服务端 `docker exec` 转发 | **(a)**。复用客户端全部 SSH 能力（SFTP、分屏、重连），不新增协议。 |
| Q8 | 是否提供把 Vault 密钥带进沙箱的办法？ | (a) 不提供，用户自行放置并被告知风险；(b) P3 提供默认关闭的 agent 转发；(c) 服务端注入 | **(a) 加 (b)**。永不做 (c)，它直接违背「服务端不见 Vault 明文」。 |
| Q9 | 原生客户端是否也能选「经服务端出口」？ | 是 / 否 | 第一阶段**否**。原生客户端直连是它的优点；等出口稳定后作为可选项加入，服务端接口不需要变化。 |
| Q10 | 被强制出口的用户，RDP/VNC 在 §7.4 的转发完成前怎么办？ | (a) 拒绝并说明；(b) 允许从服务器 IP 出去 | **(a)**。强制出口是安全承诺，不能有静默例外。 |
| Q11 | 是否允许普通用户自己添加出口（自带代理）？ | 是 / 否 | **否**。出口由实例管理员集中管理；用户自带代理会让服务端替任意第三方转发流量，也绕开了管理员对出口 IP 的掌控。 |
