# 在线测试环境

本实例用于在线功能测试。使用自签名 HTTPS，不申请公共 CA 证书。

| 项目 | 配置 |
| --- | --- |
| Web 与客户端服务端地址 | `https://200.180.166.253` |
| 健康检查 | `https://200.180.166.253/health/ready` |
| 实例能力 | `https://200.180.166.253/api/v1/instance` |
| IPv4 | `200.180.166.253` |
| IPv6 | `2602:f864:248:45::a` |
| SSH 运维 | `root`，端口 `22`；凭据单独保管 |
| 首次部署源码 | `252b5ef55acbeffbd285328af4e776567a6e4ea0`，加上 Web Dockerfile 的资源复制修复；2026-11-16 |
| 服务器 | Debian 13，8 核，8 GB 内存 |
| 运行方式 | Docker Compose；API、Web、Caddy 三个服务 |

使用 IPv4 HTTPS 地址作为统一入口，尤其是浏览器 Relay 的来源校验。HTTP 80 重定向到该地址；公网入口为 HTTPS 443，API/Web 内部端口不对宿主机发布。

## 首次使用

浏览器需信任测试证书，或在证书提示页允许继续访问。原生客户端可按[开发服务器说明](GETTING_STARTED.md#开发服务器允许不安全连接)启用该地址的「允许不安全连接」。

Web 会自动连接同源 API 并显示首次注册页面；原生客户端选择服务端账户，填写上述 HTTPS 地址。初始管理员允许名单是 `admin@atermius.test`；首次创建账户时使用该用户名、自选主密码和一次性 bootstrap 令牌。令牌保存在服务器的 `/opt/atermius/private/bootstrap.txt`，不要提交到 Git。通过 SSH 读取：

```sh
cat /opt/atermius/private/bootstrap.txt
```

首次注册完成后该令牌失效。公开注册默认关闭，后续账户通过邀请创建；首次账户注册前，不存在预设的应用登录密码。

浏览器 SSH/SFTP Relay 已启用，目标仅允许这台机器的 IPv4/IPv6 和 TCP 22。其他目标需要另行调整允许名单。临时访客 SSH/RDP 网关未启用。

## 运维入口

部署目录为 `/opt/atermius`：

- `source/`：部署时的 Git 源码快照，不含 `.git` 和本地工作区文件。
- `config/test.env`：实例环境配置，权限 `0600`。
- `config/compose.test.yaml`、`config/Caddyfile`：本机覆盖配置和自签名 HTTPS 代理。
- `manage`：封装完整 Compose 文件列表的运维命令。
- `build.log`：首次构建日志。
- `private/tls/server.crt`、`private/tls/server.key`：测试证书及私钥。

在服务器上执行：

```sh
/opt/atermius/manage ps
/opt/atermius/manage logs --tail=100 server web edge
/opt/atermius/manage restart
curl --cacert /opt/atermius/private/tls/server.crt \
  --fail https://200.180.166.253/health/ready
```

三个服务均配置 `restart: unless-stopped`，Docker 随系统启动。数据库使用 SQLCipher；数据卷为 `atermius-test-data`，独立密钥卷为 `atermius-test-keys`。更新时保留环境配置、数据卷、密钥卷及证书，按[备份恢复手册](runbooks/instance-backup-restore.md)处理备份。`build-and-start.sh` 是首次安装脚本，包含生成密钥和 bootstrap 的步骤，不能作为日常更新命令重复执行。

服务端构建使用部署机上的 `source/server/Dockerfile.test`，与仓库 Dockerfile 的区别仅是为 Cargo 设置 `CARGO_BUILD_JOBS=2`，限制首次编译内存占用。Web Dockerfile 已补充 `COPY apps/client/assets ./assets`，将 `pubspec.yaml` 声明的图标字体打包进镜像；该修复同时保留在本地仓库。

## 测试证书

证书同时包含上述 IPv4 和 IPv6，有效期至 **2027-11-16 09:22:49 UTC**。当前 SHA-256 指纹：

```text
A5:F7:49:C8:96:A1:BD:70:3F:85:31:45:39:3B:10:E6:95:6E:60:1D:32:EF:06:AA:49:E3:E1:02:53:51:EE:EC
```

更新证书后需同步更新此记录并重启 `edge`。SSH 密码、bootstrap 令牌、数据库密钥和 TLS 私钥均不写入仓库文档。

## 部署验证记录

2026-11-16 完成首次部署验证：

- API、Web、Caddy 三个容器均为 `healthy`，Docker 已启用开机启动。
- 从另一台机器使用该证书进行 TLS 校验，IPv4 和 IPv6 的 `/health/ready` 均返回 HTTP 200、`{"status":"ready"}`。
- HTTP 80 返回 301，重定向至统一 HTTPS 入口。
- `/api/v1/instance` 返回实例能力；未登录访问管理员概览返回 HTTP 401。
- Chromium 能打开首次账户注册表单；页面为安全上下文，未观察到脚本错误或资源加载失败，图标字体返回 HTTP 200。

验证范围为部署、TLS、服务健康及首次注册页面，不代表所有客户端和业务流程均已验收。
