#!/usr/bin/env python3
"""
Atermius — Apple App Store Connect 全自动一键上架与版本更新脚本 (零第三方依赖)

功能：
1. 纯标准库 + OpenSSL 生成 Apple ES256 JWT，无需安装 PyJWT / cryptography。
2. 自动定位 ~/Downloads 或 ~/.appstoreconnect/private_keys 下的 AuthKey_<KEY_ID>.p8，
   并安装至 ~/.appstoreconnect/private_keys/ (权限 0600) 供 xcrun altool 共用。
3. 支持通过 --create-version 自动创建新版本（如 1.0.1），按目标 versionString 精准定位，
   绝对不会误操作已上线的 1.0.0 版本。
4. 通过 xcrun altool 上传正式商店签名包 IPA，并按 --build-number 精准等待与绑定目标 Build。
5. 全自动填写四语 (zh-Hans / en-US / ja / ru) App 名称、副标题、隐私政策网址、版权、
   关键词、描述、宣传文本、营销网址、技术支持网址及新版更新说明 (whatsNew)。
6. 支持 --replace-screenshots 先清除继承旧图，再按分语种目录 (<dir>/<locale>/{iphone_69,ipad_13})
   自动分块上传 24-bit 无 Alpha 高清海报并轮询等待 COMPLETE。
7. 可选 (--wait-and-submit) 轮询等待目标 Build 解析为 VALID 后，自动绑定并提交 Apple 审核！
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

API_BASE = "https://api.appstoreconnect.apple.com/v1"
PRIVACY_URL = "https://github.com/aterm-project/atermius/blob/main/docs/PRIVACY_POLICY.md"
MARKETING_URL = "https://github.com/aterm-project/atermius"
SUPPORT_URL = "https://github.com/aterm-project/atermius/issues"
COPYRIGHT_TEXT = "2026 Zenwalk LLC"

LOCALIZED_METADATA: dict[str, dict[str, str]] = {
    "zh-Hans": {
        "name": "Atermius - SSH 终端与远程桌面",
        "subtitle": "SFTP、Mosh 与本地加密钥匙串",
        "promotionalText": (
            "1.0.1 重磅升级！全面适配折叠屏与多窗口自适应；免注册开箱即用，支持 48+ 服务器系统图标、SSH/SFTP/RDP/VNC、端口转发与本机加密钥匙串。"
        ),
        "keywords": "ssh,sftp,mosh,rdp,vnc,telnet,terminal,linux,devops,tunnel,ed25519,keygen,tmux,终端,远程桌面,端口转发,运维",
        "whatsNew": """• 全面适配折叠屏 iPhone 与 iPad 动态窗口调整：展开/合盖与分屏拖拽实时自适应，活跃 SSH 会话零中断、零缓冲丢失，横屏非对称安全区全面加固。
• 新增「在线 SSH 诊断小工具」：独立只读 exec 通道查看系统概览、监听端口与 TCP 连通性、Top 进程与服务日志，不干扰当前交互终端。
• 预留无端口原生 MCP 接口（atermius/mcp_native）与 4 项只读诊断工具，为未来内置 AI 与系统智能体协同做好准备。
• 修复 SSH 断线重连后 PTY 终端网格尺寸未重放的问题，优化 xterm 解析与四语展示体验。""",
        "description": """专为系统工程师、DevOps 与开发者打造的安全远程终端与服务器管理工作区。在一个原生应用内统一管理 SSH、SFTP/SCP、Telnet、RDP 与 VNC 连接，兼顾开箱即用的本机离线体验与端到端零知识加密架构。

【免注册开箱即用 · 本机钥匙串保护】
• 首次打开即可直接使用，无强制账号注册墙。
• 自动创建受 iOS / iPadOS 系统钥匙串（Keychain）与生物识别（Face ID / Touch ID）保护的本地加密配置库，所有服务器地址、登录凭证与私钥默认仅加密存储在您的设备本地。

【纯正原生 Liquid Glass · 折叠屏与分屏自适应】
• 深度适配 iPhone、折叠屏自适应视口与 iPad 多任务分屏，运行时尺寸切换不断连、不丢滚动历史。
• 顶部毛玻璃会话控制栏与底部翡翠实时会话胶囊，一键切回任意活跃终端。

【多协议一体化远程连接】
• SSH 终端：高速流畅的终端渲染，自动识别 48+ Linux/BSD 发行版系统图标，支持多会话切换、断线重连与 PTY 网格恢复、外接硬件键盘快捷键捕获及移动端专属修饰键扩展栏（Esc / Tab / Ctrl / Alt）。
• SFTP / SCP 文件传输：可视化远程文件管理，支持上传、下载、权限查看与加密附件。
• 远程桌面与传统设备支持：内置 Telnet、RDP 与 VNC 客户端，支持 NLA 服务端系统识别、SHA-256 证书指纹核验、自由缩放与直接触控 / 虚拟触控板模式。

【专业网络与密钥管理能力】
• 本机密钥库：在设备端离线生成、导入与管理 Ed25519、RSA 密钥对及主机指纹。
• SSH 端口转发与跳板：支持 Local、Remote 与动态 SOCKS5 转发规则编排及多级堡垒机连接。
• 代码片段与加密归档：按环境与目录分组管理主机，一键从本机 SSH 配置及加密备份迁移。

【可选自托管端到端零知识同步】
• 面向拥有自有基础设施的开发者与团队，支持按需接入自托管同步服务，全数据均由客户端 AEAD 端到端加密签名，服务端仅存密文。""",
    },
    "en-US": {
        "name": "Atermius: SSH, SFTP & RDP",
        "subtitle": "Encrypted Terminal & Keychain",
        "promotionalText": (
            "New in 1.0.1: Seamless foldable & resizable window support, 48+ OS marks, SSH PTY reconnect size fix, SFTP, RDP/VNC, tunnels & local Keychain—no sign-up needed."
        ),
        "keywords": "mosh,vnc,telnet,devops,linux,shell,tunnel,ed25519,keygen,bastion,tmux,sysadmin,cli,scp,it,server",
        "whatsNew": """• Foldable & Resizable Window Ready: Dynamically adapts between compact and unfolded / Split View layouts without disconnecting active SSH sessions or losing scrollback history, with asymmetric horizontal Safe Area support.
• New Live SSH Diagnostic Tools: Read-only out-of-band inspection for system overview, listening ports, TCP reachability, top processes, and service logs without disturbing your interactive shell.
• Native In-Process MCP Bridge: Port-free native MCP interface reserved for future AI workflows alongside 48+ automatic OS marks and SSH PTY reconnect sizing fixes.""",
        "description": """A secure, native remote operations workspace built for developers, sysadmins, and DevOps engineers. Manage SSH, SFTP/SCP, Telnet, RDP, and VNC connections in one unified interface—combining instant offline local vaults with optional zero-knowledge end-to-end encrypted synchronization.

INSTANT OFFLINE ACCESS — NO SIGN-UP REQUIRED
• Launch and connect immediately with zero mandatory registration or login walls.
• Your local encrypted profile is automatically protected by the iOS / iPadOS Keychain and Face ID / Touch ID. Host profiles, credentials, and private keys remain encrypted on your device by default.

NATIVE LIQUID GLASS & RESIZABLE WORKSPACE
• Adaptive layout built for iPhone, foldable displays, and iPad Split View / Stage Manager—resizing mid-session without dropping SSH connections or terminal scrollback.
• Tinted emerald Live Session Pill lets you jump back into active shells from anywhere in the app.

ALL-IN-ONE MULTI-PROTOCOL CONNECTIONS
• SSH Terminal: Fast ANSI-256 terminal emulation with 48+ automatic OS distro icons, split panes, reconnect PTY size restoration, hardware keyboard shortcut capture, and an ergonomic touch modifier bar (Esc, Tab, Ctrl, Alt).
• SFTP & SCP File Manager: Browse remote directories, upload/download files cleanly, and inspect permissions.
• RDP, VNC & Telnet Clients: Connect to Windows (NLA OS detection), Linux desktops, and serial/network gear with SHA-256 certificate verification and touch/trackpad pointer modes.

KEYS, TUNNELS & SNIPPETS
• On-Device Keychain: Generate, import, and manage Ed25519 and RSA SSH keys offline.
• Port Forwarding & Jump Hosts: Configure Local, Remote, and SOCKS5 tunnels alongside multi-hop SSH bastions.
• Optional Self-Hosted Zero-Knowledge Sync: Teams running their own server can optionally sync encrypted vaults using client-side AEAD cryptography—servers never see plaintext secrets.""",
    },
    "ja": {
        "name": "Atermius - SSH・SFTP・リモートデスクトップ",
        "subtitle": "ローカル暗号化キーチェーン搭載",
        "promotionalText": (
            "1.0.1登場：可変ウィンドウと折りたたみ画面に完全対応。48種以上のOSアイコン自動判別、SSH再接続時のPTYサイズ復元、ポート転送・Keychain保護を登録不要で。"
        ),
        "keywords": "ssh,sftp,mosh,rdp,vnc,telnet,terminal,devops,linux,tunnel,ed25519,keygen,ターミナル,サーバー,リモート,転送",
        "whatsNew": """• 折りたたみiPhone・可変ウィンドウ対応：コンパクト表示と大画面間の切替時にSSHセッションやスクロール履歴を破棄せず適応し、非対称セーフエリアにも対応。
• 「ライブ SSH 診断ツール」を新搭載：操作中の端末を妨げず、別チャネルでシステム概要・待受ポート/TCP疎通・上位プロセス・サービスログを読み取り専用で即座に確認可能。
• 将来のAI連携に向けたポート不要のネイティブ MCP ブリッジ基盤を予約実装し、SSH再接続時のPTYサイズ復元と48種以上のOS識別を強化しました。""",
        "description": """開発者・インフラエンジニア・システム管理者向けのセキュアな統合リモート接続クライアントです。SSH、SFTP/SCP、Telnet、RDP、VNC をひとつのネイティブワークスペースに統合し、登録不要のローカル暗号化保管庫とゼロ知識エンドツーエンド暗号化アーキテクチャを提供します。

【アカウント登録不要・すぐに利用開始】
• 初回起動時からログイン不要で全機能を利用可能。
• iOS / iPadOS キーチェーンと Face ID / Touch ID で保護されたローカル暗号化プロファイルを自動作成し、接続先や秘密鍵を端末内で安全に管理します。

【進化したネイティブ操作感と適応レイアウト】
• 折りたたみディスプレイや iPad 分割表示でのリアルタイムサイズ変更に完全対応。作業中のターミナルを切らずにレイアウトをシームレス切替。
• 下部のライブセッションカプセルから進行中のターミナルへ瞬時に復帰できます。

【主な機能】
• SSH ターミナル & SFTP/SCP ファイル転送：48種類以上のOSディストリビューション自動認識、再接続時のPTYサイズ自動復元、画面分割、外付けキーボード＆修飾キーバー対応。
• RDP / VNC / Telnet 対応：NLA サーバーOS検出、SHA-256 証明書フィンガープリント検証、タッチ／トラックパッド操作モード切替をサポート。
• 鍵管理・ポート転送・スニペット：端末内での Ed25519 / RSA 鍵生成、Local / Remote / SOCKS5 転送、多段踏み台ホスト、コマンドスニペット保存に対応。
• 任意のセルフホスト型ゼロ知識同期：独自サーバーを利用する場合のみオプションで有効化でき、全データはクライアント側で AEAD 暗号化・署名されます。""",
    },
    "ru": {
        "name": "Atermius — SSH, SFTP и RDP",
        "subtitle": "Терминал и локальный сейф",
        "promotionalText": (
            "Версия 1.0.1: адаптация к складным и изменяемым экранам без разрыва SSH, 48+ иконок ОС, исправление размера PTY при переподключении, туннели и локальный Keychain."
        ),
        "keywords": "ssh,sftp,mosh,rdp,vnc,telnet,terminal,devops,linux,tunnel,ed25519,keygen,сервер,консоль,ключи",
        "whatsNew": """• Адаптация для складных экранов и гибких окон: бесшовное переключение режимов без разрыва активных SSH-сессий и потери истории прокрутки, с поддержкой асимметричных Safe Area.
• Новые инструменты диагностики SSH: просмотр сводки системы, открытых портов, проверки TCP, топ-процессов и журналов служб в отдельном read-only канале без вмешательства в терминал.
• Заложен нативный in-process шлюз MCP для будущей интеграции ИИ, а также исправлено восстановление сетки PTY и добавлены 48+ иконок ОС.""",
        "description": """Безопасное рабочее пространство для системных администраторов, DevOps-инженеров и разработчиков. Управляйте подключениями SSH, SFTP/SCP, Telnet, RDP и VNC в едином нативном приложении с локальным шифрованием и опциональной сквозной (zero-knowledge) синхронизацией.

【РАБОТА БЕЗ РЕГИСТРАЦИИ С ПЕРВОГО ЗАПУСКА】
• Не требует создания учётной записи — запускайте и подключайтесь сразу.
• Локальное зашифрованное хранилище защищено системной связкой ключей iOS / iPadOS Keychain и биометрией Face ID / Touch ID.

【АДАПТИВНЫЙ НАТИВНЫЙ ИНТЕРФЕЙС】
• Поддержка складных дисплеев, Split View и асимметричных вырезов: при изменении размера окна активные терминалы и прокрутка полностью сохраняются.
• Изумрудная капсула живой сессии позволяет в одно касание вернуться в активную консоль.

【ОСНОВНЫЕ ВОЗМОЖНОСТИ】
• Терминал SSH и SFTP/SCP: 48+ иконок ОС серверов, восстановление размера PTY при переподключении, сплит-панели, аппаратные шорткаты и панель клавиш-модификаторов.
• Клиенты RDP, VNC и Telnet: определение ОС сервера через NLA, проверка SHA-256 сертификатов, режимы касания и виртуального тачпада.
• Ключи, туннели и сниппеты: локальная генерация Ed25519/RSA, проброс портов (Local / Remote / SOCKS5), jump-хосты и шаблоны команд.
• Опциональная self-hosted E2E-синхронизация с нулевым разглашением: все секреты шифруются AEAD на устройстве до отправки.""",
    },
}

REVIEW_NOTES = """1. What's New in 1.0.1:
- Added foldable display & dynamic window resizability support (migrated scene lifecycle observers to UISceneDelegate callbacks, preserved active SSH TerminalView state across compact/expanded viewport transitions, and hardened asymmetric horizontal Safe Area insets).
- Added read-only "SSH Live Tools" diagnostic sheet (system overview, listening ports / TCP probe, process snapshot, service logs via out-of-band SSH exec channel) and reserved an internal port-free native MCP bridge (`atermius/mcp_native`, zero network port listener opened on iOS).
- Included upstream stability fixes for SSH PTY reconnect sizing, xterm escape parsing, OS distro detection badges, and hardware keyboard capture.
- Updated localized screenshots (5 iPhone 6.9" + 3 iPad 13" scenes across en-US, zh-Hans, ja, ru) showing only RFC 5737 synthetic hosts.

2. No Login Required — Instant Full Functionality (Guidelines 2.1 & 4.2):
Upon first launch, the app automatically creates and unlocks a local encrypted profile protected by the iOS Keychain ("Local Mode") with zero sign-up or login required. All core client features work immediately out of the box:
- Create and organize SSH, SFTP, Telnet, RDP, and VNC host profiles ("+" button in the Hosts tab).
- Generate Ed25519 / RSA SSH key pairs locally on the device (Keychain tab).
- Create reusable command Snippets and configure SSH Port Forwarding rules.
- Export and import encrypted backup archives.

3. Optional Self-Hosted Cloud Account & In-App Account Deletion (Guideline 5.1.1(v)):
Cloud Vault synchronization is strictly optional for self-hosted server users. Signed-in users can schedule permanent deletion directly in Settings -> Account & sign-in -> Account security -> Account deletion.

4. Purpose of System Permissions:
- Local Network: Connecting directly to user-configured SSH/SFTP/Telnet/RDP/VNC servers on LAN.
- Face ID: Optional local vault & SSH key unlock.
- Photo Library / Media Picker: Only triggered when choosing custom terminal wallpaper or host attachments."""


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _der_ecdsa_to_raw_rs(der: bytes, size: int = 32) -> bytes:
    """Parse ASN.1 DER ECDSA signature SEQUENCE { INTEGER r, INTEGER s } into fixed 64-byte r||s."""
    idx = 0
    if der[idx] != 0x30:
        raise ValueError("Invalid DER signature header")
    idx += 1
    if der[idx] & 0x80:
        len_bytes = der[idx] & 0x7F
        idx += 1 + len_bytes
    else:
        idx += 1

    parts: list[bytes] = []
    for _ in range(2):
        if der[idx] != 0x02:
            raise ValueError("Expected ASN.1 INTEGER in DER signature")
        idx += 1
        length = der[idx]
        idx += 1
        val = der[idx : idx + length]
        idx += length
        val = val.lstrip(b"\x00")
        if len(val) > size:
            raise ValueError(f"ECDSA integer larger than {size} bytes")
        parts.append(val.rjust(size, b"\x00"))
    return parts[0] + parts[1]


def generate_asc_jwt(issuer_id: str, key_id: str, p8_path: Path) -> str:
    now = int(time.time())
    header = _b64url(
        json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode()
    )
    payload = _b64url(
        json.dumps(
            {
                "iss": issuer_id,
                "iat": now - 10,
                "exp": now + 1100,
                "aud": "appstoreconnect-v1",
            },
            separators=(",", ":"),
        ).encode()
    )
    signing_input = f"{header}.{payload}".encode("ascii")
    openssl_bin = shutil.which("openssl") or "/usr/bin/openssl"
    proc = subprocess.run(
        [openssl_bin, "dgst", "-sha256", "-sign", str(p8_path)],
        input=signing_input,
        capture_output=True,
        check=True,
    )
    raw_sig = _der_ecdsa_to_raw_rs(proc.stdout, 32)
    return f"{header}.{payload}.{_b64url(raw_sig)}"


class AscHttpError(RuntimeError):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


class AscClient:
    def __init__(self, issuer_id: str, key_id: str, p8_path: Path) -> None:
        self.issuer_id = issuer_id
        self.key_id = key_id
        self.p8_path = p8_path
        self._token: str | None = None
        self._token_ts: float = 0.0

    def token(self) -> str:
        if self._token is None or (time.time() - self._token_ts) > 800:
            self._token = generate_asc_jwt(self.issuer_id, self.key_id, self.p8_path)
            self._token_ts = time.time()
        return self._token

    def request(
        self,
        method: str,
        path_or_url: str,
        body: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        url = path_or_url if path_or_url.startswith("http") else f"{API_BASE}{path_or_url}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {
            "Authorization": f"Bearer {self.token()}",
            "Accept": "application/json",
        }
        if data is not None:
            headers["Content-Type"] = "application/json"

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=45) as resp:
                raw = resp.read()
                return json.loads(raw.decode("utf-8")) if raw else {}
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")
            raise AscHttpError(e.code, f"ASC API {method} {url} -> HTTP {e.code}:\n{err_body}") from e


def resolve_and_install_p8(key_id: str, explicit_path: str | None) -> Path:
    asc_dir = Path.home() / ".appstoreconnect" / "private_keys"
    asc_dir.mkdir(parents=True, exist_ok=True)
    target = asc_dir / f"AuthKey_{key_id}.p8"

    candidates: list[Path] = []
    if explicit_path:
        candidates.append(Path(explicit_path).expanduser())
    candidates.extend(
        [
            target,
            Path.home() / "Downloads" / f"AuthKey_{key_id}.p8",
            Path.home() / ".private_keys" / f"AuthKey_{key_id}.p8",
            Path.home() / "Desktop" / f"AuthKey_{key_id}.p8",
        ]
    )
    found = next((c for c in candidates if c.is_file()), None)
    if found is None:
        raise FileNotFoundError(
            f"未找到私钥文件 AuthKey_{key_id}.p8！请确保已下载至 ~/Downloads/ 或通过 --key-path 指定路径。"
        )
    if found.resolve() != target.resolve():
        shutil.copy2(found, target)
    os.chmod(target, 0o600)
    return target


def upload_ipa_via_altool(ipa_path: Path, issuer_id: str, key_id: str) -> None:
    print(f"==> [1/6] 正在通过 xcrun altool 上传正式构建包: {ipa_path.name} ...")
    cmd = [
        "xcrun",
        "altool",
        "--upload-app",
        "--type",
        "ios",
        "-f",
        str(ipa_path),
        "--apiKey",
        key_id,
        "--apiIssuer",
        issuer_id,
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    out = (res.stdout or "") + "\n" + (res.stderr or "")
    if res.returncode != 0:
        if "Redundant Binary Upload" in out or "already been uploaded" in out or "90189" in out:
            print(f"    [OK] 构建 {ipa_path.name} 先前已上传至 App Store Connect，跳过重复上传。")
            return
        raise RuntimeError(f"xcrun altool 上传失败 (exit {res.returncode}):\n{out}")
    print("    [OK] IPA 二进制包上传成功！Apple 后台正在异步处理符号与静态扫描。")


def configure_categories_and_age_rating(client: AscClient, app_id: str) -> str:
    print("==> [2/6] 选择可编辑 appInfo 并核验分类与 4+ 年龄分级...")
    infos = client.request("GET", f"/apps/{app_id}/appInfos")["data"]
    editable_states = {
        "PREPARE_FOR_SUBMISSION",
        "READY_FOR_REVIEW",
        "WAITING_FOR_REVIEW",
        "DEVELOPER_REJECTED",
        "REJECTED",
        "METADATA_REJECTED",
    }
    editable = [
        i for i in infos if i.get("attributes", {}).get("appStoreState") in editable_states
    ]
    editable.sort(
        key=lambda i: 0
        if i.get("attributes", {}).get("appStoreState") == "PREPARE_FOR_SUBMISSION"
        else 1
    )
    app_info = editable[0] if editable else infos[0]
    app_info_id = app_info["id"]
    print(
        f"    选中 appInfo {app_info_id} (state={app_info.get('attributes', {}).get('appStoreState')})"
    )

    try:
        client.request(
            "PATCH",
            f"/appInfos/{app_info_id}",
            {
                "data": {
                    "type": "appInfos",
                    "id": app_info_id,
                    "relationships": {
                        "primaryCategory": {
                            "data": {"type": "appCategories", "id": "DEVELOPER_TOOLS"}
                        },
                        "secondaryCategory": {
                            "data": {"type": "appCategories", "id": "PRODUCTIVITY"}
                        },
                    },
                }
            },
        )
        print("    [OK] 主次分类已设为 DEVELOPER_TOOLS / PRODUCTIVITY。")
    except Exception as exc:
        print(f"    [WARN] 设置分类提示: {exc}")

    age_resp = client.request("GET", f"/appInfos/{app_info_id}/ageRatingDeclaration")["data"]
    age_id = age_resp["id"]
    existing_attrs: dict[str, Any] = age_resp.get("attributes", {})

    desired_none_enums = {
        "alcoholTobaccoOrDrugUseOrReferences",
        "contests",
        "gamblingSimulated",
        "horrorOrFearThemes",
        "matureOrSuggestiveThemes",
        "medicalOrTreatmentInformation",
        "profanityOrCrudeHumor",
        "sexualContentGraphicAndNudity",
        "sexualContentOrNudity",
        "violenceCartoonOrFantasy",
        "violenceRealistic",
        "violenceRealisticProlongedGraphicOrSadistic",
        "gunsOrOtherWeapons",
    }
    desired_false_bools = {
        "gambling",
        "unrestrictedWebAccess",
        "lootBox",
        "advertising",
        "healthOrWellnessTopics",
        "messagingAndChat",
        "parentalControls",
        "ageAssurance",
        "userGeneratedContent",
        "socialMedia",
        "socialMediaAgeRestricted",
    }
    patch_attrs: dict[str, Any] = {}
    for k in existing_attrs:
        if k in desired_none_enums:
            patch_attrs[k] = "NONE"
        elif k in desired_false_bools:
            patch_attrs[k] = False
        elif k == "kidsAgeBand":
            patch_attrs[k] = None

    if patch_attrs:
        client.request(
            "PATCH",
            f"/ageRatingDeclarations/{age_id}",
            {"data": {"type": "ageRatingDeclarations", "id": age_id, "attributes": patch_attrs}},
        )
        print("    [OK] 年龄分级问卷已全部确认 4+。")
    return app_info_id


def configure_app_info_localizations(client: AscClient, app_info_id: str) -> None:
    print("==> [3/6] 配置四语 ASO 应用名 (含 409 回退)、副标题与隐私政策 URL...")
    locs = client.request("GET", f"/appInfos/{app_info_id}/appInfoLocalizations")["data"]
    by_locale = {item["attributes"]["locale"]: item for item in locs}

    for locale, meta in LOCALIZED_METADATA.items():
        desired_name = meta["name"]
        assert len(desired_name) <= 30, f"[{locale}] name exceeds 30 chars: {desired_name}"
        assert len(meta["subtitle"]) <= 30, f"[{locale}] subtitle exceeds 30 chars"

        base_attrs = {
            "subtitle": meta["subtitle"],
            "privacyPolicyUrl": PRIVACY_URL,
        }
        if locale in by_locale:
            loc_id = by_locale[locale]["id"]
            try:
                client.request(
                    "PATCH",
                    f"/appInfoLocalizations/{loc_id}",
                    {
                        "data": {
                            "type": "appInfoLocalizations",
                            "id": loc_id,
                            "attributes": {"name": desired_name, **base_attrs},
                        }
                    },
                )
            except AscHttpError as exc:
                if exc.status == 409:
                    print(f"    [INFO] [{locale}] name '{desired_name}' 遇到 409，自动回退为 'Atermius'")
                    client.request(
                        "PATCH",
                        f"/appInfoLocalizations/{loc_id}",
                        {
                            "data": {
                                "type": "appInfoLocalizations",
                                "id": loc_id,
                                "attributes": {"name": "Atermius", **base_attrs},
                            }
                        },
                    )
                else:
                    raise
        else:
            try:
                client.request(
                    "POST",
                    "/appInfoLocalizations",
                    {
                        "data": {
                            "type": "appInfoLocalizations",
                            "attributes": {"locale": locale, "name": desired_name, **base_attrs},
                            "relationships": {
                                "appInfo": {"data": {"type": "appInfos", "id": app_info_id}}
                            },
                        }
                    },
                )
            except AscHttpError as exc:
                if exc.status == 409:
                    client.request(
                        "POST",
                        "/appInfoLocalizations",
                        {
                            "data": {
                                "type": "appInfoLocalizations",
                                "attributes": {"locale": locale, "name": "Atermius", **base_attrs},
                                "relationships": {
                                    "appInfo": {"data": {"type": "appInfos", "id": app_info_id}}
                                },
                            }
                        },
                    )
                else:
                    raise
        print(f"    [OK] appInfoLocalization [{locale}] 已保存。")


def configure_version_and_localizations(
    client: AscClient,
    app_id: str,
    version_str: str,
    *,
    create_version: bool,
) -> tuple[str, dict[str, str]]:
    print(f"==> [4/6] 精准匹配/创建版本 {version_str} 并写入四语元数据与 whatsNew...")
    versions = client.request("GET", f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS")[
        "data"
    ]
    target = next(
        (v for v in versions if v.get("attributes", {}).get("versionString") == version_str),
        None,
    )
    if target is None:
        if not create_version:
            available = [
                f"{v.get('attributes', {}).get('versionString')}({v.get('attributes', {}).get('appStoreState')})"
                for v in versions
            ]
            raise RuntimeError(
                f"未找到版本 {version_str}（当前已有：{available}）。如需创建新版本请传入 --create-version。"
            )
        created = client.request(
            "POST",
            "/appStoreVersions",
            {
                "data": {
                    "type": "appStoreVersions",
                    "attributes": {
                        "platform": "IOS",
                        "versionString": version_str,
                        "copyright": COPYRIGHT_TEXT,
                        "releaseType": "AFTER_APPROVAL",
                    },
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )["data"]
        version_id = created["id"]
        print(f"    [OK] 已新建 iOS 版本 {version_str} ({version_id})。")
    else:
        version_id = target["id"]
        state = target.get("attributes", {}).get("appStoreState")
        print(f"    [OK] 已锁定版本 {version_str} ({version_id}, state={state})。")
        client.request(
            "PATCH",
            f"/appStoreVersions/{version_id}",
            {
                "data": {
                    "type": "appStoreVersions",
                    "id": version_id,
                    "attributes": {
                        "copyright": COPYRIGHT_TEXT,
                        "releaseType": "AFTER_APPROVAL",
                    },
                }
            },
        )

    vlocs = client.request("GET", f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")[
        "data"
    ]
    by_locale = {item["attributes"]["locale"]: item["id"] for item in vlocs}

    is_update_version = version_str != "1.0.0"

    for locale, meta in LOCALIZED_METADATA.items():
        assert len(meta["keywords"]) <= 100, (
            f"[{locale}] keywords len={len(meta['keywords'])} exceeds 100: {meta['keywords']}"
        )
        assert len(meta["promotionalText"]) <= 170, (
            f"[{locale}] promotionalText exceeds 170"
        )
        attrs: dict[str, Any] = {
            "description": meta["description"],
            "keywords": meta["keywords"],
            "promotionalText": meta["promotionalText"],
            "marketingUrl": MARKETING_URL,
            "supportUrl": SUPPORT_URL,
        }
        if is_update_version and meta.get("whatsNew"):
            attrs["whatsNew"] = meta["whatsNew"]

        if locale in by_locale:
            loc_id = by_locale[locale]
            client.request(
                "PATCH",
                f"/appStoreVersionLocalizations/{loc_id}",
                {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": loc_id,
                        "attributes": attrs,
                    }
                },
            )
        else:
            res = client.request(
                "POST",
                "/appStoreVersionLocalizations",
                {
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "attributes": {"locale": locale, **attrs},
                        "relationships": {
                            "appStoreVersion": {
                                "data": {"type": "appStoreVersions", "id": version_id}
                            }
                        },
                    }
                },
            )["data"]
            by_locale[locale] = res["id"]
        print(f"    [OK] appStoreVersionLocalization [{locale}] 已保存。")

    return version_id, by_locale


def _upload_single_screenshot(client: AscClient, set_id: str, file_path: Path) -> str:
    raw_bytes = file_path.read_bytes()
    md5_hex = hashlib.md5(raw_bytes).hexdigest()

    reservation = client.request(
        "POST",
        "/appScreenshots",
        {
            "data": {
                "type": "appScreenshots",
                "attributes": {"fileSize": len(raw_bytes), "fileName": file_path.name},
                "relationships": {
                    "appScreenshotSet": {
                        "data": {"type": "appScreenshotSets", "id": set_id}
                    }
                },
            }
        },
    )["data"]
    shot_id = reservation["id"]
    ops = reservation["attributes"].get("uploadOperations", [])

    for op in ops:
        method = op["method"]
        url = op["url"]
        offset = op["offset"]
        length = op["length"]
        chunk = raw_bytes[offset : offset + length]
        req_headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        req = urllib.request.Request(url, data=chunk, headers=req_headers, method=method)
        with urllib.request.urlopen(req, timeout=60) as resp:
            resp.read()

    client.request(
        "PATCH",
        f"/appScreenshots/{shot_id}",
        {
            "data": {
                "type": "appScreenshots",
                "id": shot_id,
                "attributes": {"uploaded": True, "sourceFileChecksum": md5_hex},
            }
        },
    )
    return shot_id


def _resolve_locale_files(screenshots_root: Path, locale: str) -> tuple[list[Path], list[Path]]:
    locale_dir = screenshots_root / locale
    base = locale_dir if locale_dir.is_dir() else screenshots_root
    iphone_files = sorted((base / "iphone_69").glob("*.png"))
    ipad_files = sorted((base / "ipad_13").glob("*.png"))
    return iphone_files, ipad_files


def _wait_screenshots_complete(
    client: AscClient, set_id: str, expected_count: int, *, label: str, locale: str
) -> None:
    deadline = time.time() + 180
    while time.time() < deadline:
        shots = client.request("GET", f"/appScreenshotSets/{set_id}/appScreenshots")["data"]
        states = [
            s.get("attributes", {}).get("assetDeliveryState", {}).get("state")
            for s in shots
        ]
        if any(st == "FAILED" for st in states):
            raise RuntimeError(f"[{locale}] {label} 存在上传失败截图: {shots}")
        if len(shots) == expected_count and all(st == "COMPLETE" for st in states):
            return
        time.sleep(3)
    raise TimeoutError(f"[{locale}] {label} 等待截图处理 COMPLETE 超时！")


def upload_screenshots_for_locales(
    client: AscClient,
    version_loc_ids: dict[str, str],
    screenshots_root: Path,
    *,
    replace_existing: bool,
) -> None:
    print("==> [5/6] 上传分语种高清无 Alpha 精装营销海报 (iPhone 6.9\" + iPad 13\")...")

    for locale, vloc_id in version_loc_ids.items():
        iphone_files, ipad_files = _resolve_locale_files(screenshots_root, locale)
        if not iphone_files and not ipad_files:
            print(f"    [SKIP] [{locale}] 未在 {screenshots_root} 找到截图文件。")
            continue

        display_groups = [
            (["APP_IPHONE_67", "APP_IPHONE_65"], iphone_files, "iPhone 6.9\""),
            (["APP_IPAD_PRO_3GEN_129"], ipad_files, "iPad 13\""),
        ]

        existing_sets = client.request(
            "GET", f"/appStoreVersionLocalizations/{vloc_id}/appScreenshotSets"
        )["data"]
        sets_by_type = {s["attributes"]["screenshotDisplayType"]: s["id"] for s in existing_sets}

        for candidate_types, files, label in display_groups:
            if not files:
                continue
            set_id: str | None = None
            chosen_type: str | None = None
            for dt in candidate_types:
                if dt in sets_by_type:
                    set_id = sets_by_type[dt]
                    chosen_type = dt
                    break
            if set_id is None:
                for dt in candidate_types:
                    try:
                        created = client.request(
                            "POST",
                            "/appScreenshotSets",
                            {
                                "data": {
                                    "type": "appScreenshotSets",
                                    "attributes": {"screenshotDisplayType": dt},
                                    "relationships": {
                                        "appStoreVersionLocalization": {
                                            "data": {
                                                "type": "appStoreVersionLocalizations",
                                                "id": vloc_id,
                                            }
                                        }
                                    },
                                }
                            },
                        )["data"]
                        set_id = created["id"]
                        chosen_type = dt
                        break
                    except Exception:
                        continue
            if set_id is None:
                print(f"    [WARN] [{locale}] 无法创建 {label} 截图集，跳过。")
                continue

            existing_shots = client.request(
                "GET", f"/appScreenshotSets/{set_id}/appScreenshots"
            )["data"]
            if existing_shots and replace_existing:
                for shot in existing_shots:
                    client.request("DELETE", f"/appScreenshots/{shot['id']}")
                print(
                    f"    [CLEAN] [{locale}] {label} ({chosen_type}) 已清除 {len(existing_shots)} 张旧截图。"
                )
            elif len(existing_shots) >= len(files) and not replace_existing:
                print(
                    f"    [OK] [{locale}] {label} ({chosen_type}) 已有 {len(existing_shots)} 张截图，跳过重复上传。"
                )
                continue

            for f in files:
                _upload_single_screenshot(client, set_id, f)
            _wait_screenshots_complete(
                client, set_id, len(files), label=label, locale=locale
            )
            print(
                f"    [OK] [{locale}] {label} ({chosen_type}) 已上传 {len(files)} 张精装海报并校验 COMPLETE。"
            )


def configure_review_details(
    client: AscClient,
    version_id: str,
    contact_first: str,
    contact_last: str,
    contact_email: str,
    contact_phone: str | None,
) -> None:
    print("==> [6/6] 配置 App Review 免登录审核说明与联系人...")
    attrs: dict[str, Any] = {
        "demoAccountRequired": False,
        "notes": REVIEW_NOTES,
        "contactFirstName": contact_first,
        "contactLastName": contact_last,
        "contactEmail": contact_email,
    }
    if contact_phone:
        attrs["contactPhone"] = contact_phone

    existing: dict[str, Any] | None = None
    try:
        resp = client.request("GET", f"/appStoreVersions/{version_id}/appStoreReviewDetail")
        existing = resp.get("data")
    except Exception:
        existing = None

    try:
        if existing:
            detail_id = existing["id"]
            client.request(
                "PATCH",
                f"/appStoreReviewDetails/{detail_id}",
                {"data": {"type": "appStoreReviewDetails", "id": detail_id, "attributes": attrs}},
            )
        else:
            client.request(
                "POST",
                "/appStoreReviewDetails",
                {
                    "data": {
                        "type": "appStoreReviewDetails",
                        "attributes": attrs,
                        "relationships": {
                            "appStoreVersion": {
                                "data": {"type": "appStoreVersions", "id": version_id}
                            }
                        },
                    }
                },
            )
        print("    [OK] App Review 审核备注与免登录标记已保存。")
    except Exception as exc:
        print(f"    [WARN] 保存审核详情时提示: {exc}")


def bind_build_and_submit(
    client: AscClient,
    app_id: str,
    version_id: str,
    version_str: str,
    *,
    build_number: str | None,
    submit: bool,
) -> None:
    target_desc = f"Build {build_number}" if build_number else "最新 VALID 构建"
    print(f"==> 正在查询 App Store Connect 上的目标构建 ({version_str} / {target_desc})...")
    deadline = time.time() + (900 if submit else 15)
    valid_build_id: str | None = None
    matched_ver: str | None = None

    while time.time() < deadline:
        builds = client.request(
            "GET",
            f"/builds?filter[app]={app_id}&filter[preReleaseVersion.platform]=IOS&sort=-uploadedDate&limit=10",
        ).get("data", [])
        for b in builds:
            state = b.get("attributes", {}).get("processingState")
            ver = str(b.get("attributes", {}).get("version", ""))
            print(f"    检测到构建 Build {ver}: processingState={state}")
            if build_number is not None and ver != str(build_number):
                continue
            if state == "VALID":
                valid_build_id = b["id"]
                matched_ver = ver
                break
        if valid_build_id or not submit:
            break
        print("    等待 Apple 完成目标 Build 处理 (每 25 秒轮询一次)...")
        time.sleep(25)

    if not valid_build_id:
        print(
            f"    [INFO] {target_desc} 仍在 Apple 云端处理中，稍后带 --wait-and-submit 重跑即可完成绑定并提交！"
        )
        return

    client.request(
        "PATCH",
        f"/appStoreVersions/{version_id}/relationships/build",
        {"data": {"type": "builds", "id": valid_build_id}},
    )
    print(f"    [OK] 已将 Build {matched_ver} ({valid_build_id}) 精准绑定至版本 {version_str}！")

    if submit:
        sub = client.request(
            "POST",
            "/reviewSubmissions",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": "IOS"},
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )["data"]
        sub_id = sub["id"]
        client.request(
            "POST",
            "/reviewSubmissionItems",
            {
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {
                            "data": {"type": "reviewSubmissions", "id": sub_id}
                        },
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        },
                    },
                }
            },
        )
        client.request(
            "PATCH",
            f"/reviewSubmissions/{sub_id}",
            {
                "data": {
                    "type": "reviewSubmissions",
                    "id": sub_id,
                    "attributes": {"submitted": True},
                }
            },
        )
        print(f"    🎉 [SUBMITTED] 版本 {version_str} (Build {matched_ver}) 已正式提交 Apple 审核！")


def _self_test_jwt() -> None:
    with tempfile.TemporaryDirectory() as td:
        key_file = Path(td) / "test_ec.p8"
        openssl_bin = shutil.which("openssl") or "/usr/bin/openssl"
        subprocess.run(
            [openssl_bin, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(key_file)],
            check=True,
        )
        jwt_tok = generate_asc_jwt("00000000-0000-0000-0000-000000000000", "TESTKEY123", key_file)
        parts = jwt_tok.split(".")
        assert len(parts) == 3, "JWT must have 3 segments"
        raw_sig = base64.urlsafe_b64decode(parts[2] + "==")
        assert len(raw_sig) == 64, f"ES256 raw signature must be 64 bytes, got {len(raw_sig)}"
    for locale, meta in LOCALIZED_METADATA.items():
        assert len(meta["name"]) <= 30, f"[{locale}] name > 30 chars"
        assert len(meta["subtitle"]) <= 30, f"[{locale}] subtitle > 30 chars"
        assert len(meta["keywords"]) <= 100, f"[{locale}] keywords > 100 chars"
        assert len(meta["promotionalText"]) <= 170, f"[{locale}] promotionalText > 170 chars"
        assert "termius" not in meta["keywords"].lower(), f"[{locale}] competitor word in keywords"
        assert "termius" not in meta["description"].lower(), f"[{locale}] competitor word in description"
    print("[SELF-TEST OK] JWT signer (64-byte r||s) and 4-locale ASO length/compliance guards passed.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Atermius App Store Connect 全自动一键发布与更新工具")
    parser.add_argument("--self-test", action="store_true", help="运行本地 JWT 签名与 ASO 长度合规自检并退出")
    parser.add_argument("--issuer-id", help="App Store Connect API Issuer ID (UUID)")
    parser.add_argument("--key-id", help="App Store Connect API Key ID")
    parser.add_argument("--key-path", "--key-file", dest="key_path", help="AuthKey_<KEY_ID>.p8 路径")
    parser.add_argument("--bundle-id", default="com.atermius.ios", help="App Bundle ID")
    parser.add_argument("--version", default="1.0.1", help="目标上架版本号")
    parser.add_argument("--build-number", help="精准绑定目标 Build 号（如 2）")
    parser.add_argument("--create-version", action="store_true", help="目标版本不存在时自动创建 iOS 版本")
    parser.add_argument(
        "--ipa",
        default="/Users/yang/Downloads/aterm-project/ios/build/appstore/export/Atermius-1.0.1-build2.ipa",
        help="待上传的正式 IPA 路径",
    )
    parser.add_argument(
        "--screenshots-dir",
        default="/Users/yang/Downloads/aterm-project/ios/build/appstore_posters",
        help="海报根目录（支持按语种 <locale>/{iphone_69,ipad_13} 或单套目录）",
    )
    parser.add_argument(
        "--replace-screenshots",
        action="store_true",
        help="上传前清除当前版本继承的旧截图再重新上传",
    )
    parser.add_argument("--skip-ipa-upload", action="store_true", help="跳过 IPA 二进制上传")
    parser.add_argument("--contact-first", "--contact-first-name", dest="contact_first", default="Yifei")
    parser.add_argument("--contact-last", "--contact-last-name", dest="contact_last", default="Yang")
    parser.add_argument("--contact-email", default="yangyifeifly@gmail.com")
    parser.add_argument("--contact-phone", help="App Review 审核联系人电话（含国际区号）")
    parser.add_argument("--wait-and-submit", action="store_true", help="等待构建处理完成并直接提交审核")
    args = parser.parse_args()

    if args.self_test:
        _self_test_jwt()
        return

    if not args.issuer_id or not args.key_id:
        parser.error("必须提供 --issuer-id 与 --key-id")

    p8_path = resolve_and_install_p8(args.key_id, args.key_path)
    client = AscClient(args.issuer_id, args.key_id, p8_path)

    apps = client.request("GET", f"/apps?filter[bundleId]={urllib.parse.quote(args.bundle_id)}").get(
        "data", []
    )
    if not apps:
        raise SystemExit(
            f"[BLOCKED] App Store Connect 中尚未找到 Bundle ID '{args.bundle_id}' 的 App 记录！"
        )
    app_id = apps[0]["id"]
    app_name = apps[0]["attributes"].get("name", args.bundle_id)
    print(f"==> 已连接 App Store Connect 应用: {app_name} (ID: {app_id}, Bundle: {args.bundle_id})")

    ipa_path = Path(args.ipa)
    if not args.skip_ipa_upload:
        if not ipa_path.is_file():
            raise FileNotFoundError(f"未找到指定 IPA 文件: {ipa_path}")
        upload_ipa_via_altool(ipa_path, args.issuer_id, args.key_id)

    version_id, vloc_ids = configure_version_and_localizations(
        client, app_id, args.version, create_version=args.create_version
    )
    app_info_id = configure_categories_and_age_rating(client, app_id)
    configure_app_info_localizations(client, app_info_id)
    upload_screenshots_for_locales(
        client,
        vloc_ids,
        Path(args.screenshots_dir),
        replace_existing=args.replace_screenshots,
    )
    configure_review_details(
        client,
        version_id,
        args.contact_first,
        args.contact_last,
        args.contact_email,
        args.contact_phone,
    )
    bind_build_and_submit(
        client,
        app_id,
        version_id,
        args.version,
        build_number=args.build_number,
        submit=args.wait_and_submit,
    )
    print("\n==> 全部自动化配置与提审操作已完成！")


if __name__ == "__main__":
    main()
