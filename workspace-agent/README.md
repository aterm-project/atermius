# Atermius 工作区 Agent

外挂机主动通过 mTLS 和 HTTP/2 连接 Atermius Server 旁的 `workspace-hub`。节点无需开放入站端口。可以只接入机器已有的 SSH 服务，也可以在登记节点时分配一个 Debian 工作区，安装 Agent 后会自动创建工作区。浏览器仍通过 Atermius 的 SSH Relay 登录，现有 SSH 客户端和 SFTP 文件面板都可使用。

本版中，一个 **cluster** 是一个有固定名称、SSH 入口和独立数据卷的 Linux 工作区。每个 cluster 可以授予一把或多把 SSH 公钥。需要相互隔离的用户应分配不同的 cluster。同一 cluster 内的授权密钥登录同一个 `sandbox` 账户，共享工作目录。中心管理操作由有权访问 Hub 状态目录的实例运维人员执行。

## 准备中心端

以下示例在仓库根目录执行。使用 Linux、Rust 1.94.1、`protoc`、OpenSSL 和 Python 3。下载的 Linux 工具包内已包含 `bin/atermius-agent`，可直接将 `AGENT_BIN` 指向它。

```sh
cargo build --manifest-path workspace-agent/Cargo.toml --release --locked
AGENT_BIN="$PWD/workspace-agent/target/release/atermius-agent"
INSTANCE=/srv/atermius-workspaces
sudo python3 workspace-agent/deploy/provision.py init "$INSTANCE" \
  --hostname hub.example.net --hub-uid 10001 --hub-gid 10001
```

将 `hub.example.net` 替换为节点实际访问的 DNS 名称或 IP。初始化命令生成本实例专用的 CA、Hub 证书及工作区命名空间。备份 `authority/`，并限制发证机器和私有登记包的访问权限。运行中的 Hub 容器只挂载 `hub/`。节点证书的有效期为一年。

在现有 Compose 配置上追加 `-f deploy/compose.agent.yaml`。示例单独启动 Hub，并将 mTLS 端口放到节点可达的接口。SSH 工作区端口只监听内部 `workspace-relay` 网络。已有服务端使用的其他 Compose 文件继续传给 Compose。

```sh
export ATERMIUS_AGENT_HUB_STATE="$INSTANCE/hub"
export ATERMIUS_AGENT_BIND=0.0.0.0
docker compose -f deploy/compose.yaml -f deploy/compose.agent.yaml up -d --build workspace-hub
```

首次启用时，现有 `server` 服务也需要接入覆盖文件定义的 `workspace-relay` 网络。在实例维护窗口，用完整的 Compose 文件列表对 `server` 应用配置。默认 Hub 私网地址为 `172.30.83.2`，子网与地址可通过 `ATERMIUS_AGENT_RELAY_SUBNET`、`ATERMIUS_AGENT_RELAY_IP` 配置。按现有 Relay 配置和用户/组策略仅授权所选 Hub 地址和对应工作区端口。[Web Relay 部署说明](../docs/install/server.md)

也可以前台运行 Hub，便于本机验证。第二个地址参数是 **SSH 访问端口的绑定 IP**。使用环回地址时，SSH 入口供本机客户端验证。

```sh
sudo "$AGENT_BIN" hub "$INSTANCE/hub" 0.0.0.0:8443 127.0.0.1
```

## 新服务器一键安装

1. 管理员构建一次工作区镜像。参考模板使用 Debian 13 slim，内含 OpenSSH、curl、jq、nano 和 tmux。自有工具可通过派生 Dockerfile 的 `COPY` 指令加入 `/usr/local/bin`，然后把派生镜像传给登记命令。

   ```sh
   docker build -f workspace-agent/deploy/Dockerfile.workspace \
     -t atermius-workspace:debian13 workspace-agent/deploy
   ```

2. 在发证机为每台服务器生成独立的私有安装包。下例在节点 `node-a` 首次连回时自动启动 `engineering` 工作区。公钥文件每行一把公钥，无 authorized_keys 选项。登记时固定镜像 ID，包内包含这个镜像，节点无需登录镜像仓库。工具包、容器镜像和目标机器需使用相容的 Linux 架构。

   ```sh
   sudo python3 workspace-agent/deploy/provision.py enroll "$INSTANCE" \
     --binary "$AGENT_BIN" --node node-a --server https://hub.example.net:8443 \
     --image atermius-workspace:debian13 --cluster engineering --port 24001 \
     --keys ./engineering.pub --output ./node-a.private.tar
   ```

3. 通过可信渠道把 `install-node.sh` 和这台机器自己的安装包送到新的 Debian/systemd 服务器，执行一条命令。

   ```sh
   sudo bash install-node.sh node-a.private.tar
   ```

   安装器在需要时安装 Docker、导入并校验镜像、安装 systemd 服务并确认新进程已经通过 Hub 认证。网络中断后服务自动退避重连。用 `journalctl -u atermius-agent` 查看节点日志。

4. 在中心端执行 `sudo "$AGENT_BIN" status "$INSTANCE/hub"`。当 `engineering` 为 `Running` 时，在 Atermius 的主机列表添加一条 SSH 记录。以上 Compose 示例使用 `172.30.83.2:24001`、用户 `sandbox` 和对应的用户私钥。首次连接要核对工作区 SSH 主机指纹。管理员可在节点上通过容器标签找到该工作区，并执行 `ssh-keygen -lf /workspace/identity/host_ed25519.pub` 核对。

仅接入已有 SSH 服务时，登记参数使用 `--host-ssh-port 22`，省略 `--image` 及初始工作区参数。节点安装器会跳过 Docker。中心端执行 `publish-host "$INSTANCE/hub" office node-a 24002`（前面加 `sudo "$AGENT_BIN"`）后，`24002` 只接到该节点本机登记的 SSH 端口。用户在 SSH 协议内用自己的远端账户认证。此类主机入口固定在对应机器上。Docker 工作区才支持下述跨节点迁移。

## 跨 Agent 迁移

用同一镜像登记并安装 `node-b`。备用节点的登记命令可以省略 `--cluster`、`--port`、`--keys`。两个节点只需能连回 Hub。对正在运行的 cluster 执行：

```sh
sudo "$AGENT_BIN" migrate "$INSTANCE/hub" engineering node-b
sudo "$AGENT_BIN" status "$INSTANCE/hub"
```

| 状态 | 实际行为 |
| --- | --- |
| `Snapshot` | 停止接受新 SSH 连接，源节点持久记录禁止启动的代数，停止容器并确认停止。把包含主目录和主机密钥的数据卷归档，分块传回 Hub。 |
| `Restore` | 目标节点下载快照，验证长度和 SHA-256，恢复到本次迁移专用的新卷。准备记录写入磁盘后启动 SSH 服务。 |
| `Running` | 目标报告就绪后，Hub 原子切换归属并重新接通原 SSH 地址。源节点随后按旧卷代数清理数据，`pending_cleanup` 显示剩余清理数。现有工作区可继续使用和迁移。 |

迁移保留 cluster 名称、入口地址、SSH 主机指纹、文件和权限。它是**停机迁移**，内存、进程、tmux 会话和原 TCP 连接在停止时结束。一个 cluster 的迁移不停止其他 cluster。源节点离线时等待其重新上线并完成停写，目标节点离线时等待恢复。Hub 重启后从磁盘继续。

中途取消使用 `sudo "$AGENT_BIN" abort "$INSTANCE/hub" engineering`。若目标已经开始恢复，Hub 先等待目标确认停止，再从保留的源卷恢复服务。源卷会一直保留到验证过的目标就绪。快照是迁移中间文件，单份未压缩 tar 上限 **512 MiB**。超限时迁移停留在源端，可以取消。需要独立的工作区备份和磁盘监控。

## 权限、网络和容量

- Hub 和 Agent 使用独立的节点证书，每项操作核对节点身份、cluster、迁移代数和角色。节点从固定模板创建工作区，传输入口仅支持该工作区的 SSH 或登记时批准的本机 SSH 服务。可用 `disable STATE NODE` 暂停节点访问，用 `enable STATE NODE` 恢复。
- SSH 用户以 UID 1000 运行。工作区根文件系统只读，`/tmp` 和 `/run` 是临时文件系统。用户文件位于 `/workspace/home`，主机私钥位于独立的 root 私有目录。持久卷中可能有用户数据和私钥。迁移会在两端和受信 Hub 上处理这些数据，适宜使用加密磁盘。该状态目录独立于实例数据库备份。
- 默认工作区使用 Docker `none` 网络。SSH 入口通过 Agent 内部固定通道进入容器。如果工作台需要访问批准的业务网络，管理员先在各候选节点配置出口防火墙和专用 Docker bridge，再在登记时传 `--network NAME`。Agent 要求 bridge 带 `com.atermius.workspace.egress=true` 标签并关闭 `com.docker.network.bridge.enable_icc`。同一 cluster 的迁移目标须具有相同网络配置名和镜像 ID。固定公网 IP 取决于出口的 NAT 配置，容器内出网策略由运维方执行。
- 每个工作区限制 1 核、512 MiB 内存、128 个进程。每个 SSH 入口最多 16 个并发连接，Hub 合计 128 个。持久卷的**运行时磁盘硬配额由底层卷存储提供**，512 MiB 快照上限不是写入配额。普通 Docker 容器与节点共享内核。运行工作区的 Agent 有 Docker 管理权限，应部署在受信专用机器上。
- 本版的服务端管理入口是本地运维 CLI。节点端支持 Debian/systemd，示例镜像支持 Linux 工作区。已有 SSH 入口继续使用实例与组的 Relay 授权。将多个 cluster 分别授权给不同用户时使用不同 SSH 密钥，并按各自端口配置组策略。
- 状态目录由同一 Hub 实例持有。节点私钥及数据目录都应一机一份。迁移中保留当前状态目录，不要把旧的 Hub 备份恢复到仍在提供写服务的节点集群。

## 验证

```sh
cargo test --manifest-path workspace-agent/Cargo.toml --locked
python3 workspace-agent/tests/two_nodes.py --binary "$AGENT_BIN" \
  --image atermius-workspace:debian13
```

端到端测试使用临时 CA、真实 Docker 容器、SSH 和 SFTP，覆盖首次开通、跨 Agent 往返迁移、中心重启、身份不匹配、独立工作区、停用节点、快照损坏以及回滚。测试只清理其自身命名空间的容器和卷。

如需连同真实 Atermius API、登录设备票据和浏览器使用的 WebSocket Relay 一起验证，可先编译 `atermius-server`，再在仅有环回接口的临时网络命名空间运行测试。此项使用仓库既有的 Python 集成测试依赖以及 Paramiko。

```sh
sudo unshare -n sh -c '
  ip link set lo up &&
  ip address add 192.0.2.11/32 dev lo &&
  exec python3 workspace-agent/tests/two_nodes.py --image atermius-workspace:debian13 \
    --binary workspace-agent/target/release/atermius-agent \
    --server-binary server/target/debug/atermius-server'
```
