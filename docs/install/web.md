# 浏览器前端构建与部署

[English](web.en.md) · [安装总览](../INSTALLATION.md) · [README](../../README.zh-CN.md)

先按[安装总览](../INSTALLATION.md)完成仓库权限、克隆与 Flutter 工具链准备。以下命令都从仓库根目录开始。

## 构建站点

```sh
cd apps/client
flutter pub get --enforce-lockfile
flutter build web --release --no-web-resources-cdn
dart run tool/web_cache_manifest.dart build/web
```

第二条命令生成 `atermius-cache-manifest.json`（构建标识和每个文件的 SHA-256）。有了它，浏览器会保存一份完整的网页包：

- 再次打开时直接从浏览器缓存启动，不再重新下载。只缓存清单里列出的文件，并逐个校验哈希；API 响应、访客分享页和加入链接从不缓存。
- 服务器有新版本时，已打开的页面继续运行当前版本，同时在后台下载新版本。新版本完整保存之后才提示更新；用户确认重新加载后，页面从已保存的新版本启动。在此之前刷新仍是旧版本。
- 缓存需要安全来源（HTTPS 或 `localhost`）。明文 `http://`、不支持 Service Worker 的浏览器，或构建时没有生成清单的网页包，都不会缓存，页面照旧从服务器加载。

`atermius-sw.js`、`flutter_bootstrap.js` 和 `atermius-cache-manifest.json` 须以 `Cache-Control: no-cache` 提供（自带的 `deploy/nginx.conf` 已如此），并且一次部署要整体替换所有文件。

部署 **`apps/client/build/web/` 完整目录**。`--no-web-resources-cdn` 保证 CanvasKit 同源，仓库也包含 Unicode 回退字体与许可证。使用真正的 HTTP 服务，不使用 `file://` 打开。

## 与 API 一起部署

浏览器版属于提供它的那台服务器：打开后直接是这台服务器的登录页，只需要账号和密码。它没有本地模式，也不能填写或更换服务器地址；地址固定为网页所在的来源（协议、主机名和端口）。首次创建账户、受邀注册和找回账户仍在登录页上。页面是从其他电脑以明文 `http://` 打开的时，客户端照常连接，但会一直显示“不安全连接”的提示。本地模式只在桌面和手机客户端里提供。

推荐按[服务端部署指南](server.md)操作。API 与前端现在位于同一仓库：服务端 Compose 的 `deploy/compose.web.yaml` 使用仓库根目录的 `Dockerfile` 构建前端镜像，并代理 API/WebSocket，形成同一浏览器来源，不再需要同级 `web` 目录。

手动构建镜像时，在仓库根目录执行：

```sh
docker build -t atermius-web:local .
```

镜像在 **8080** 监听，以 nginx 用户运行，使用 `deploy/nginx.conf`，要求 Docker 网络内存在 `server:8080`。仅单独启动 Web 容器不是完整部署；网络、TLS 与持久 API 数据按服务端 Compose 栈配置，不假定已有 GHCR 镜像或公网托管实例。

## 临时链接与常规 SSH

提供的 nginx 为 `/s/*`、`/join` 设置禁止缓存、referrer 与 CSP 响应头，并为 `/gateway/*` 保留 WebSocket 升级。保留 Flutter 之前加载的 `share-bootstrap.js`，先移除访问链接片段，再启动路由/请求。仅上传静态文件而不配置这些路由和代理不足以提供访客访问。

账户模式常规 SSH 需要服务端启用 Relay；临时 SSH/RDP 使用另一个受信网关。云端协作要求 SQLite，访客 Cookie 要求 HTTPS；浏览器本地资料不能创建直接 TCP 或本机 Shell。

## 验证构建后的运行环境

在仓库根目录、Docker 可用时运行：

```sh
python3 tools/verify_cloud_proxy.py --web-root apps/client/build/web
```

只启动可清理的回环测试环境，验证真实 nginx 响应头、API 转发与 WebSocket 回显，不会上线公网，也不代替真实访客/目标连接测试。

更新已有版本前请先阅读[安装总览](../INSTALLATION.md)中的“更新已有版本”。

[首次使用](../GETTING_STARTED.md) · [常见问题](../TROUBLESHOOTING.md) · [开发验证](../DEVELOPMENT.md)
