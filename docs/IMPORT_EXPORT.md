# 导入与导出 / Import and export

[首次使用](GETTING_STARTED.md) · [First use](GETTING_STARTED.en.md)

当前支持：Windows/macOS 本机 Termius 桌面版一键导入、Termius 兼容 CSV、未加密的 Termius JSON、OpenSSH 配置、OpenSSH 文件包，以及 MobaXterm 会话（`.mxtsessions` 导出或 `MobaXterm.ini`）。不登录 Termius 云端、不读取云端数据库，也不访问手机上的 Termius。/ Current transfer supports one-click import from the Termius Desktop app installed on this Windows/macOS computer, Termius-compatible CSV, unencrypted Termius JSON, OpenSSH config, OpenSSH bundles and MobaXterm sessions (a `.mxtsessions` export or `MobaXterm.ini`). It never signs in to Termius cloud, reads cloud data or touches Termius on a phone.

## 本机 Termius 一键导入（仅 Windows/macOS 桌面版） / One-click import from local Termius (Windows/macOS desktop only)

在本机安装并至少打开过一次 Termius 桌面版后，“导入/导出”对话框顶部、主机菜单和首页会出现“一键导入 Termius”。点击后无需选择文件：/ Once Termius Desktop is installed and has been opened on this computer, the Import/Export dialog, the host menu and the home page show "One-click Termius import". No file is picked:

- 数据位置 / Data location：Windows `%APPDATA%\Termius`；macOS `~/Library/Application Support/Termius`（官网下载版）或 `~/Library/Containers/*termius*/Data/Library/Application Support/Termius`（App Store 版）。发现多个资料时依次尝试，使用第一个能被解密的。/ Windows `%APPDATA%\Termius`; macOS `~/Library/Application Support/Termius` (downloaded build) or the App Store sandbox container. When several profiles exist they are tried in order and the first one that decrypts is used.
- 只读 / Read-only：只把 IndexedDB(LevelDB) 文件读入内存，不写入、不加锁、不打开/注入/结束 Termius；Termius 运行中也可导入。/ The IndexedDB (LevelDB) files are only copied into memory; nothing is written or locked, and Termius is never opened, injected into or closed. It may keep running.
- 密钥 / Key：从系统钥匙串（macOS）或凭据管理器（Windows）读取当前用户的 Termius `localKey`。macOS 可能弹出钥匙串授权，选择“允许”即可。密钥先用一个加密字段做 Poly1305 校验再使用，解码后的密钥字节用完即清零；Termius 密钥不记录、不导出、不上传，也不会另存明文副本。导入的主机与凭据和其他记录一样写入当前目标（本机资料或 Vault 的加密存储，Vault 照常加密同步）。/ The current user's Termius `localKey` is read from the macOS Keychain or Windows Credential Manager (macOS may ask for permission; choose Allow). A key is verified against one encrypted field (Poly1305) before use and its decoded bytes are wiped afterwards. The Termius key is never logged, exported or uploaded, and no plaintext copy is written; imported hosts and credentials are stored like any other record of the current target (the encrypted local profile, or the Vault, which encrypts and syncs as usual).
- 解密与失败即停 / Decryption and fail-closed：字段为 XSalsa20-Poly1305（`04 01` 版本头）。密钥不匹配、未知加密版本、无法解析的主机/密钥等记录、或超出大小/记录数/解压上限时整体停止，不会导入部分数据。已删除（墓碑/软删除）的记录不会导入。/ Fields are XSalsa20-Poly1305 with a `04 01` version header. A wrong key, an unknown cipher version, an undecodable imported record or exceeding the size/record/decompression bounds stops the whole import; nothing partial is written. Deleted (tombstoned or soft-deleted) records are not imported.
- 导入内容 / What is imported：主机、嵌套分组、标签、用户名、密码、SSH 私钥及其口令、端口转发和跳板机，写入当前资料或 Vault；已存在的主机按重复规则跳过。代理、known_hosts（主机信任）、代码片段与历史不导入，代理与 known_hosts 也不解密；这不是 Termius 完整加密备份的迁移。缺少必填信息（如用户名）的主机不会被猜测补全：此时会打开导入预览，可填写默认用户名或排除这些行后再确认导入；无需处理时则直接一键导入。导入期间若切换或重新登录了 Vault/资料，导入会中止。/ Hosts, nested groups, tags, usernames, passwords, SSH private keys with their passphrases, port forwards and jump hosts go to the current profile or Vault; existing hosts are skipped. Proxies, known_hosts (host trust), snippets and history are not imported, and proxies/known_hosts are not decrypted; this is not a full encrypted Termius backup migration. Hosts missing required data (such as a username) are never guessed: the import preview opens so you can enter a default username or exclude those rows before confirming; otherwise the import completes in one click. Switching or re-signing into the Vault/profile while the import runs aborts it.

如果提示未知加密版本或超出安全上限，请在 Termius 中导出 CSV 后使用下方文件导入。/ If an unknown cipher version or a safety limit is reported, export CSV from Termius and use the file import below.

## 文件导入（所有平台） / File import (all platforms)

Termius CSV 模板的八列顺序为 / The supported eight-column template is:

```csv
Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password
```

导入先预览分组、标签、协议、身份与遗漏项，再确认写入当前资料或 Vault。SSH/Mosh 形式按 SSH 处理，Telnet 有相应映射；RDP/VNC 属于扩展而非标准 Termius 模板能力。不要把“文件被接受”理解为所有字段都能无损往返。/ Review groups, tags, protocol, identity and reported losses before applying. Mosh-shaped entries map to SSH, Telnet is recognized, and RDP/VNC are extension protocols rather than standard template guarantees.

CSV 不能完整承载 SSH 私钥、证书、跳板和转发语义；导出会报告遗漏/降级。需要私钥文件时使用受支持的 OpenSSH 包并核对预览。包不是 Termius 加密 Vault 格式。/ CSV cannot represent every key/certificate/jump-host/forwarding field; inspect reported omissions. Use an OpenSSH bundle when supported key files are needed. It is not a native Termius vault archive.

## MobaXterm 会话导入（所有平台） / MobaXterm session import (all platforms)

在 MobaXterm 左侧 “User sessions” 上右键导出全部会话，得到 `.mxtsessions` 文件；也可以直接选 `MobaXterm.ini`（安装版在 `%APPDATA%\MobaXterm`，便携版在程序旁边）。在“导入 / 导出”对话框里点“选择 MobaXterm 会话”，用“选择 Termius CSV”选中这类文件也会自动识别。和其他来源一样，先预览再确认写入。/ In MobaXterm, right-click "User sessions" and export all sessions to a `.mxtsessions` file, or pick `MobaXterm.ini` (`%APPDATA%\MobaXterm` for the installed edition, next to the program for the portable one). Use "Choose MobaXterm sessions" in the Import/Export dialog; such a file picked with "Choose Termius CSV" is recognized too. As with every source, nothing is saved before you review the preview and confirm.

- 会话类型 / Session types：SSH、Telnet、RDP、VNC 照原样导入；SFTP 会话导入为 SSH 主机（文件从该主机打开）。Mosh、串口、本地 Shell、WSL、FTP、浏览器、XDMCP、Rsh、AWS S3 和文件会话在预览中标为不支持，不会导入。/ SSH, Telnet, RDP and VNC map directly; SFTP sessions become SSH hosts (open their files from the host). Mosh, Serial, Shell, WSL, FTP, Browser, XDMCP, Rsh, AWS S3 and File sessions are listed as unsupported and skipped.
- 文件夹 / Folders：`[Bookmarks_N]` 的 `SubRep`（如 `Prod\DB`）变为嵌套分组。/ Each `SubRep` folder path (for example `Prod\DB`) becomes nested groups.
- SSH 网关 / SSH gateways：SSH、RDP、VNC 会话里设置的网关变为跳板主机。网关与文件里某个 SSH 会话的地址、端口、用户名相同时直接引用该会话；否则新建一台名为 `用户@主机[:端口]` 的 SSH 主机并在预览中标出。多级网关按顺序串成跳板链。/ Gateways on SSH, RDP and VNC sessions become jump hosts. A gateway with the same address, port and username as an SSH session in the file uses that session; otherwise a new SSH host named `user@host[:port]` is added and marked in the preview. Several gateways become a jump chain in the same order.
- 不导入 / Not imported：MobaXterm 保存的密码在 `MobaXterm.ini` 的 `[Passwords]`/`[Credentials]` 中由主密码加密，不读取也不解密（存在时预览会提示）；会话导出本身不含密码。私钥文件只记录了路径，导入时不打开，预览列出文件名，请在导入后为主机添加密钥。引用已保存凭据（用户名写作 `[名称]`）的会话没有用户名，可在预览里填写默认用户名。登录后执行的命令和代理设置会被忽略并提示。/ Passwords saved in MobaXterm live in `[Passwords]`/`[Credentials]` of `MobaXterm.ini`, encrypted with the master password; they are never read or decrypted (the preview says so when they are present), and a session export has none. Private key files are referenced by path only and are never opened; the preview names the file so you can add the key afterwards. Sessions that use a saved credential (username written as `[name]`) have no username; enter a default username in the preview. Remote commands and proxy settings are ignored and reported.
- 编码 / Encoding：MobaXterm 按 Windows 的系统代码页保存文件。是 UTF-8 时按 UTF-8 读；否则按应用语言优先选代码页（中文 GBK、日文 Shift_JIS、俄文 Windows-1251，其他 Windows-1252），明显是中文或日文的内容在其他语言下也能识别。若预览中名称为乱码，请把应用语言切换为写出该文件的 Windows 所用语言后重新选择文件。/ MobaXterm writes the file in the Windows ANSI code page. UTF-8 is used when valid; otherwise the code page of the app language is preferred (Chinese GBK, Japanese Shift_JIS, Russian Windows-1251, others Windows-1252), and clearly Chinese or Japanese text is recognized under other languages too. If names look garbled in the preview, switch the app language to the one of the Windows that wrote the file and pick it again.

包含密码或私钥的导出文件是敏感明文资料，应使用明确授权的目标保存。CSV 保持模板值兼容，并不会把所有字段改写为电子表格安全公式；不要把不可信导出当电子表格执行。/ An export containing secrets is plaintext sensitive material. CSV preserves template values; do not execute untrusted CSV content as spreadsheet formulas.

恢复整个加密工作区时使用应用的加密备份/导出流程，遵守其相同实例/Vault 限制；主机格式迁移与完整备份恢复是不同操作。/ For complete encrypted workspace recovery, use the app's encrypted archive flow and its same-instance/Vault limits.

> 合并说明 / Merge note：2026-11-14 合并前，一键导入与未加密 Termius JSON 只写在 Desktop 仓库的本文中。Android、iOS、Web 仓库的版本只列出 Termius 兼容 CSV、OpenSSH 配置和 OpenSSH 文件包，并说明这些是已知格式的互操作，不读取 Termius 原生加密导出或云端数据库。/ Before the 2026-11-14 merge, one-click import and unencrypted Termius JSON were documented only in the Desktop repository. The Android, iOS and Web copies listed only Termius-compatible CSV, OpenSSH config and OpenSSH bundles, and stated that these interoperate with known formats and do not decrypt native Termius vault exports or cloud data.
