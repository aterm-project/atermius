#!/usr/bin/env python3
"""
Atermius — Apple App Store Connect 全自动一键上架脚本 (零第三方依赖)

功能：
1. 纯标准库 + OpenSSL 生成 Apple ES256 JWT，无需安装 PyJWT / cryptography。
2. 自动定位 ~/Downloads 或 ~/.appstoreconnect/private_keys 下的 AuthKey_<KEY_ID>.p8，
   并安装至 ~/.appstoreconnect/private_keys/ (权限 0600) 供 xcrun altool 共用。
3. 调用 xcrun altool 上传正式商店签名包 ios/dist/appstore/Atermius-1.0.0-build1.ipa。
4. 通过 App Store Connect REST API v1 全自动填写：
   - 主/次分类 (Developer Tools / Productivity)
   - 年龄分级问卷 (全套 NONE/False -> 4+ 全区评级)
   - 四语 (zh-Hans / en-US / ja / ru) 副标题、隐私政策网址、宣传文本、关键词、完整描述、技术支持网址
   - 版权声明 (2026 Zenwalk LLC)
   - 高清无 Alpha 商店截图自动分块上传与 MD5 校验提交 (iPhone 6.9"/6.7" + iPad Pro 13")
   - App Review 免登录审核备注与审核联系人信息
5. 可选 (--wait-and-submit) 轮询等待二进制构建解析为 VALID 后，自动绑定构建并提交人工审核！
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
SUPPORT_URL = "https://github.com/aterm-project/atermius/blob/main/docs/PRIVACY_POLICY.md#support"
COPYRIGHT_TEXT = "2026 Zenwalk LLC"

LOCALIZED_METADATA: dict[str, dict[str, str]] = {
    "zh-Hans": {
        "subtitle": "端到端加密 SSH、SFTP 与远程桌面",
        "promotionalText": (
            "开箱即用的专业 SSH、SFTP、Telnet、RDP 与 VNC 客户端。免注册即可创建受本机钥匙串保护的"
            "加密工作区，支持端口转发、Ed25519 密钥生成、分屏终端与代码片段，并可按需接入自托管零知识加密同步。"
        ),
        "keywords": "ssh,sftp,terminal,rdp,vnc,telnet,devops,linux,server,shell,keychain,终端,远程桌面,服务器,运维,端口转发,密钥,文件传输",
        "description": """专为系统工程师、DevOps 与开发者打造的安全远程终端与服务器管理工作区。在一个原生应用内统一管理 SSH、SFTP/SCP、Telnet、RDP 与 VNC 连接，兼顾开箱即用的本机离线体验与端到端零知识加密架构。

【免注册开箱即用 · 本机钥匙串保护】
• 首次打开即可直接使用，无强制账号注册墙。
• 自动创建受 iOS / iPadOS 系统钥匙串（Keychain）与生物识别（Face ID / Touch ID）保护的本地加密配置库，所有服务器地址、登录凭证与私钥默认仅加密存储在您的设备本地。

【多协议一体化远程连接】
• SSH 终端：高速流畅的终端渲染，支持多会话实时切换、工作区分屏、断线重连恢复、外接硬件键盘快捷键与移动端专属修饰键扩展栏（Ctrl / Alt / Shift / Esc / Tab）。
• SFTP / SCP 文件传输：可视化远程文件管理，支持上传、下载、权限查看、断点续传及主机加密附件管理。
• 远程桌面与传统设备支持：内置 Telnet、RDP 与 VNC 客户端连接管理，支持证书 SHA-256 指纹核验、自定义分辨率缩放以及直接触控 / 虚拟触控板双操作模式。

【专业网络与密钥管理能力】
• 本机密钥库：在设备端离线生成、导入与管理 Ed25519、RSA 等 SSH 密钥对及主机指纹，私钥永不明文落盘。
• SSH 端口转发与跳板：支持本地转发（Local）、远程转发（Remote）与动态 SOCKS 转发规则编排，支持多级堡垒机 / 跳板连接。
• 代码片段（Snippets）与分组管理：按环境、标签与目录整理主机，将常用运维指令保存为可复用片段一键下发。
• 加密备份与迁移：支持标准 SSH 配置及加密归档导入导出。

【可选自托管端到端零知识同步】
• 面向拥有自有基础设施的用户与团队，支持按需连接自托管（Self-Hosted）同步服务。
• 采用严格的客户端 AEAD 端到端加密与设备数字签名：所有主机记录、密钥与附件均在本地完成加密后再传输，服务端仅存储不透明密文，无法读取您的任何明文凭证。

【纯正原生体验与多语言支持】
• 采用原生 Liquid Glass 与 Cupertino 交互设计，深度适配 iPhone 与 iPad 分屏多任务，支持自定义终端配色方案、字体字号与深浅色外观，内置简体中文、英文、日文、俄文四语界面。""",
    },
    "en-US": {
        "subtitle": "Encrypted SSH, SFTP & Desktop",
        "promotionalText": (
            "Modern SSH, SFTP, Telnet, RDP & VNC client. Start instantly with a Keychain-protected "
            "local vault, port forwarding, snippets & optional zero-knowledge sync."
        ),
        "keywords": "ssh,sftp,terminal,rdp,vnc,telnet,devops,linux,server,shell,keychain,scp,tunnel,ed25519,sysadmin,it",
        "description": """A secure, native remote operations workspace built for developers, sysadmins, and DevOps engineers. Manage SSH, SFTP/SCP, Telnet, RDP, and VNC connections in one unified interface—combining instant offline local vaults with optional zero-knowledge end-to-end encrypted synchronization.

INSTANT OFFLINE ACCESS — NO SIGN-UP REQUIRED
• Launch and connect immediately with zero mandatory registration or login walls.
• Your local encrypted profile is automatically protected by the iOS / iPadOS Keychain and optional Face ID / Touch ID authentication. All host profiles, credentials, and private keys stay encrypted on your device by default.

ALL-IN-ONE MULTI-PROTOCOL WORKSPACE
• SSH Terminal: Responsive terminal emulation with live session switching, split panes, session reconnect controls, hardware keyboard shortcuts, and an ergonomic on-screen modifier bar (Ctrl, Alt, Shift, Esc, Tab).
• SFTP & SCP File Manager: Browse remote directories, upload and download files with transfer progress and resume support, and manage encrypted host attachments.
• RDP, VNC & Telnet Clients: Connect to remote desktops and network gear with SHA-256 certificate fingerprint verification, flexible display scaling, and switchable direct-touch or relative trackpad pointer modes.

BUILT FOR SERIOUS INFRASTRUCTURE WORKFLOWS
• On-Device Keychain & Key Generator: Generate, import, and manage Ed25519 and RSA SSH keys directly on your device.
• Port Forwarding & Jump Hosts: Configure local, remote, and dynamic port forwarding tunnels alongside multi-hop SSH bastion hosts.
• Snippets & Host Organization: Group servers with tags and folders, and save frequently used shell commands as reusable snippets.
• Encrypted Import & Export: Easily back up or migrate configurations via encrypted archives and standard SSH config imports.

OPTIONAL SELF-HOSTED ZERO-KNOWLEDGE SYNC
• Teams and power users running their own self-hosted server can optionally enable cross-device Vault synchronization.
• Powered by client-side AEAD encryption and cryptographic device signatures: every host record, credential, key, and chunked attachment is encrypted before leaving your device. The server stores opaque ciphertext only and never sees plaintext secrets.

DESIGNED FOR iPHONE & iPAD
• Native Liquid Glass & Cupertino experience with full support for iPad multitasking, custom terminal color palettes, adjustable typography, and localized interfaces in English, Simplified Chinese, Japanese, and Russian.""",
    },
    "ja": {
        "subtitle": "暗号化SSH・SFTP・リモート接続",
        "promotionalText": (
            "登録不要ですぐ使える暗号化SSH・SFTP・Telnet・RDP・VNCクライアント。Keychain保護のローカル保管庫、"
            "ポート転送、鍵生成、スニペット管理を備え、ゼロ知識E2E暗号化同期にも対応。"
        ),
        "keywords": "ssh,sftp,terminal,rdp,vnc,telnet,devops,linux,server,shell,keychain,ターミナル,リモートデスクトップ,サーバー,鍵管理,転送",
        "description": """開発者・インフラエンジニア・システム管理者向けのセキュアな統合リモート接続クライアントです。SSH、SFTP/SCP、Telnet、RDP、VNC をひとつのネイティブワークスペースに統合し、登録不要のローカル暗号化保管庫とゼロ知識エンドツーエンド暗号化アーキテクチャを提供します。

【アカウント登録不要・すぐに利用開始】
• 初回起動時からログイン不要で全機能を利用可能。
• iOS / iPadOS キーチェーンと Face ID / Touch ID で保護されたローカル暗号化プロファイルを自動作成し、接続先や秘密鍵を端末内で安全に管理します。

【主な機能】
• SSH ターミナル & SFTP/SCP ファイル転送：ライブセッション切替、画面分割（Split Panes）、自動再接続、ハードウェアキーボードおよび専用修飾キーバーに対応。
• RDP / VNC / Telnet 対応：SHA-256 証明書フィンガープリント検証、画面スケーリング、タッチ／トラックパッド操作モード切替をサポート。
• 鍵管理・ポート転送・スニペット：端末内での Ed25519 / RSA 鍵ペア生成、ローカル／リモート／ダイナミックポート転送、踏み台接続、よく使うコマンドのスニペット保存に対応。
• 任意のセルフホスト型ゼロ知識同期：独自サーバーを利用する場合のみオプションで有効化でき、すべてのデータはクライアント側で AEAD 暗号化・署名されてから送信されます。""",
    },
    "ru": {
        "subtitle": "SSH, SFTP и удалённый доступ",
        "promotionalText": (
            "Клиент SSH, SFTP, Telnet, RDP и VNC без обязательной регистрации. Локальное хранилище "
            "под защитой Keychain, проброс портов, генерация ключей и сквозное шифрование."
        ),
        "keywords": "ssh,sftp,terminal,rdp,vnc,telnet,devops,linux,server,shell,keychain,терминал,сервер,консоль,ключи",
        "description": """Безопасное рабочее пространство для системных администраторов, DevOps-инженеров и разработчиков. Управляйте подключениями SSH, SFTP/SCP, Telnet, RDP и VNC в едином нативном приложении с локальным шифрованием и опциональной сквозной (zero-knowledge) синхронизацией.

【РАБОТА БЕЗ РЕГИСТРАЦИИ С ПЕРВОГО ЗАПУСКА】
• Не требует создания учётной записи для работы.
• Локальное зашифрованное хранилище защищено системной связкой ключей iOS / iPadOS Keychain и биометрией Face ID / Touch ID.

【ОСНОВНЫЕ ВОЗМОЖНОСТИ】
• Терминал SSH и файловый менеджер SFTP/SCP: быстрое переключение сессий, разделение экрана, переподключение, поддержка внешних клавиатур и панели клавиш-модификаторов.
• Клиенты RDP, VNC и Telnet: проверка SHA-256 отпечатков сертификатов, масштабирование экрана и режимы прямого касания или виртуального тачпада.
• Ключи, туннели и сниппеты: локальная генерация ключей Ed25519/RSA, проброс портов (Local / Remote / Dynamic), работа через jump-хосты и шаблоны команд.
• Опциональная self-hosted синхронизация с нулевым разглашением: все записи и ключи шифруются на устройстве до отправки на ваш сервер.""",
    },
}

REVIEW_NOTES = """1. No Login Required — Instant Full Functionality (Guidelines 2.1 & 4.2):
Upon first launch, the app automatically creates and unlocks a local encrypted profile protected by the iOS Keychain ("Local Mode") with zero sign-up or login required. All core client features work immediately out of the box:
- Create and organize SSH, SFTP, Telnet, RDP, and VNC host profiles ("+" button in the Hosts tab).
- Generate Ed25519 / RSA SSH key pairs locally on the device (Keychain tab).
- Create reusable command Snippets and configure SSH Port Forwarding rules.
- Export and import encrypted backup archives.
(Note: If you navigate to the optional self-hosted Cloud Sync sign-in screen, you can switch back to Local Mode at any time via the top-right Mode menu without entering any server URL.)

2. Optional Self-Hosted Cloud Account & In-App Account Deletion (Guideline 5.1.1(v)):
Cloud Vault synchronization is strictly optional and designed for users who run their own self-hosted server. When signed into a cloud account, users can permanently delete their account directly inside the app without contacting support:
- Navigation Path: Settings -> Account & sign-in -> Account security -> Account deletion -> tap "Schedule account deletion" -> enter "DELETE" and confirm with the account password.

3. Purpose of System Permissions:
- Local Network: Used only when connecting directly to SSH, SFTP, Telnet, RDP, or VNC servers on the local network (LAN).
- Face ID: Used optionally on-device to unlock the local encrypted vault and protected SSH keys.
- Photo Library / Camera / Media Picker: Triggered only when a user chooses a custom terminal wallpaper or attaches local files to an encrypted host record.

------------------------------------------------------------
【简体中文审核说明】
1. 免注册开箱即用：首次启动自动进入受 iOS Keychain 保护的本地加密模式，无需任何账号登录即可新建管理 SSH/SFTP/RDP/VNC 主机、离线生成 Ed25519/RSA 密钥对、配置端口转发与代码片段。
2. 可选自托管云账号应用内永久删除路径：设置 -> 账户与登录 -> 账户安全 -> 账户删除 -> 安排账户删除，立即吊销全部会话并物理清除服务端密文。"""


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
            raise RuntimeError(f"ASC API {method} {url} -> HTTP {e.code}:\n{err_body}") from e


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
            print("    [OK] 构建 1.0.0 (1) 先前已上传至 App Store Connect，跳过重复上传。")
            return
        raise RuntimeError(f"xcrun altool 上传失败 (exit {res.returncode}):\n{out}")
    print("    [OK] IPA 二进制包上传成功！Apple 后台正在异步处理符号与静态扫描。")


def configure_categories_and_age_rating(client: AscClient, app_id: str) -> str:
    print("==> [2/6] 配置 App 分类 (Developer Tools / Productivity) 与 4+ 年龄分级...")
    infos = client.request("GET", f"/apps/{app_id}/appInfos")["data"]
    editable_states = {
        "PREPARE_FOR_SUBMISSION",
        "READY_FOR_REVIEW",
        "WAITING_FOR_REVIEW",
        "DEVELOPER_REJECTED",
        "REJECTED",
        "METADATA_REJECTED",
    }
    app_info = next(
        (i for i in infos if i.get("attributes", {}).get("appStoreState") in editable_states),
        infos[0],
    )
    app_info_id = app_info["id"]

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

    # 动态获取当前 ageRatingDeclaration schema 支持的字段并设为全部无/否 (4+)
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
        print("    [OK] 年龄分级问卷已全部更新为 4+ 标准答案。")
    return app_info_id


def configure_app_info_localizations(client: AscClient, app_info_id: str) -> None:
    print("==> [3/6] 配置四语副标题与正式版隐私政策 URL...")
    locs = client.request("GET", f"/appInfos/{app_info_id}/appInfoLocalizations")["data"]
    by_locale = {item["attributes"]["locale"]: item for item in locs}

    for locale, meta in LOCALIZED_METADATA.items():
        attrs = {
            "subtitle": meta["subtitle"],
            "privacyPolicyUrl": PRIVACY_URL,
        }
        if locale in by_locale:
            loc_id = by_locale[locale]["id"]
            client.request(
                "PATCH",
                f"/appInfoLocalizations/{loc_id}",
                {"data": {"type": "appInfoLocalizations", "id": loc_id, "attributes": attrs}},
            )
        else:
            # 新语言需同时带 name，复用主语言应用名
            primary_name = locs[0]["attributes"]["name"]
            client.request(
                "POST",
                "/appInfoLocalizations",
                {
                    "data": {
                        "type": "appInfoLocalizations",
                        "attributes": {"locale": locale, "name": primary_name, **attrs},
                        "relationships": {
                            "appInfo": {"data": {"type": "appInfos", "id": app_info_id}}
                        },
                    }
                },
            )
        print(f"    [OK] appInfoLocalization [{locale}] 已保存。")


def configure_version_and_localizations(
    client: AscClient, app_id: str, version_str: str
) -> tuple[str, dict[str, str]]:
    print(f"==> [4/6] 配置版本 {version_str} 版权与四语商店描述/关键词/宣传文本/支持网址...")
    versions = client.request("GET", f"/apps/{app_id}/appStoreVersions?filter[platform]=IOS")[
        "data"
    ]
    if not versions:
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
    else:
        version_id = versions[0]["id"]
        client.request(
            "PATCH",
            f"/appStoreVersions/{version_id}",
            {
                "data": {
                    "type": "appStoreVersions",
                    "id": version_id,
                    "attributes": {
                        "versionString": version_str,
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

    for locale, meta in LOCALIZED_METADATA.items():
        attrs = {
            "description": meta["description"],
            "keywords": meta["keywords"],
            "promotionalText": meta["promotionalText"],
            "supportUrl": SUPPORT_URL,
        }
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


def _upload_single_screenshot(client: AscClient, set_id: str, file_path: Path) -> None:
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


def upload_screenshots_for_locales(
    client: AscClient,
    version_loc_ids: dict[str, str],
    screenshots_root: Path,
) -> None:
    print("==> [5/6] 上传真实模拟器高清无 Alpha 商店截图 (iPhone 6.9\" + iPad 13\")...")
    iphone_files = sorted((screenshots_root / "iphone_69").glob("*.png"))
    ipad_files = sorted((screenshots_root / "ipad_13").glob("*.png"))
    if not iphone_files and not ipad_files:
        print(f"    [SKIP] 未在 {screenshots_root} 找到截图文件。")
        return

    display_groups = [
        (["APP_IPHONE_67", "APP_IPHONE_65"], iphone_files, "iPhone"),
        (["APP_IPAD_PRO_3GEN_129"], ipad_files, "iPad 13\""),
    ]

    for locale, vloc_id in version_loc_ids.items():
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
            if len(existing_shots) >= len(files):
                print(
                    f"    [OK] [{locale}] {label} ({chosen_type}) 已有 {len(existing_shots)} 张截图，跳过重复上传。"
                )
                continue

            for f in files:
                _upload_single_screenshot(client, set_id, f)
            print(f"    [OK] [{locale}] {label} ({chosen_type}) 已上传 {len(files)} 张截图。")


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
        print(f"    [WARN] 保存审核详情时提示 (若缺少联系电话可补充 --contact-phone): {exc}")


def bind_build_and_submit(
    client: AscClient, app_id: str, version_id: str, submit: bool
) -> None:
    print("==> 正在查询 App Store Connect 上的可用构建包 (1.0.0)...")
    deadline = time.time() + (900 if submit else 15)
    valid_build_id: str | None = None

    while time.time() < deadline:
        builds = client.request(
            "GET", f"/builds?filter[app]={app_id}&sort=-uploadedDate&limit=5"
        ).get("data", [])
        for b in builds:
            state = b.get("attributes", {}).get("processingState")
            ver = b.get("attributes", {}).get("version")
            print(f"    检测到构建 Build {ver}: processingState={state}")
            if state == "VALID":
                valid_build_id = b["id"]
                break
        if valid_build_id or not submit:
            break
        print("    等待 Apple 完成二进制符号解析 (每 25 秒轮询一次)...")
        time.sleep(25)

    if not valid_build_id:
        print(
            "    [INFO] 构建包仍在 Apple 云端处理中（通常需 5~10 分钟）。处理完成后重跑本脚本加 --wait-and-submit 即可自动绑定提交！"
        )
        return

    client.request(
        "PATCH",
        f"/appStoreVersions/{version_id}/relationships/build",
        {"data": {"type": "builds", "id": valid_build_id}},
    )
    print(f"    [OK] 已成功将构建 ({valid_build_id}) 绑定至版本 1.0.0！")

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
        print("    🎉 [SUBMITTED] 新 App 已正式提交至 Apple App Review 审核队列！")


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
        print("[SELF-TEST OK] Pure-stdlib + OpenSSL ES256 JWT signer verified (64-byte r||s).")


def main() -> None:
    parser = argparse.ArgumentParser(description="Atermius App Store Connect 全自动一键发布工具")
    parser.add_argument("--self-test", action="store_true", help="运行本地 ES256 JWT 签名自检并退出")
    parser.add_argument("--issuer-id", help="App Store Connect API Issuer ID (UUID)")
    parser.add_argument("--key-id", help="App Store Connect API Key ID (如 2X9R4HXF34)")
    parser.add_argument("--key-path", help="可选：AuthKey_<KEY_ID>.p8 路径（默认自动扫描 ~/Downloads）")
    parser.add_argument("--bundle-id", default="com.atermius.ios", help="App Bundle ID")
    parser.add_argument("--version", default="1.0.0", help="上架版本号")
    parser.add_argument(
        "--ipa",
        default="/Users/yang/Downloads/aterm-project/ios/dist/appstore/Atermius-1.0.0-build1.ipa",
        help="待上传的正式 IPA 路径",
    )
    parser.add_argument(
        "--screenshots-dir",
        default="/Users/yang/Downloads/aterm-project/ios/dist/appstore/screenshots",
        help="截图根目录（含 iphone_69/ 与 ipad_13/ 子目录）",
    )
    parser.add_argument("--skip-ipa-upload", action="store_true", help="跳过 IPA 二进制上传")
    parser.add_argument("--contact-first", default="Yifei")
    parser.add_argument("--contact-last", default="Yang")
    parser.add_argument("--contact-email", default="yangyifeifly@gmail.com")
    parser.add_argument("--contact-phone", help="App Review 审核联系人电话（含国际区号，如 +81... 或 +1...）")
    parser.add_argument("--wait-and-submit", action="store_true", help="等待构建处理完成并直接提交审核")
    args = parser.parse_args()

    if args.self_test:
        _self_test_jwt()
        return

    if not args.issuer_id or not args.key_id:
        parser.error("必须提供 --issuer-id 与 --key-id")

    p8_path = resolve_and_install_p8(args.key_id, args.key_path)
    client = AscClient(args.issuer_id, args.key_id, p8_path)

    # 先验证该 Bundle ID 的新 App 记录是否已在 App Store Connect 创建
    apps = client.request("GET", f"/apps?filter[bundleId]={urllib.parse.quote(args.bundle_id)}").get(
        "data", []
    )
    if not apps:
        raise SystemExit(
            f"[BLOCKED] App Store Connect 中尚未找到 Bundle ID '{args.bundle_id}' 的 App 记录！\n"
            f"请先在浏览器打开 https://appstoreconnect.apple.com/apps 点击「+ 新建 App」，"
            f"套装 ID 选择 '{args.bundle_id}' 点击创建后再运行本脚本。"
        )
    app_id = apps[0]["id"]
    app_name = apps[0]["attributes"].get("name", args.bundle_id)
    print(f"==> 已连接 App Store Connect 应用: {app_name} (ID: {app_id}, Bundle: {args.bundle_id})")

    ipa_path = Path(args.ipa)
    if not args.skip_ipa_upload and ipa_path.is_file():
        upload_ipa_via_altool(ipa_path, args.issuer_id, args.key_id)

    app_info_id = configure_categories_and_age_rating(client, app_id)
    configure_app_info_localizations(client, app_info_id)
    version_id, vloc_ids = configure_version_and_localizations(client, app_id, args.version)
    upload_screenshots_for_locales(client, vloc_ids, Path(args.screenshots_dir))
    configure_review_details(
        client,
        version_id,
        args.contact_first,
        args.contact_last,
        args.contact_email,
        args.contact_phone,
    )
    bind_build_and_submit(client, app_id, version_id, args.wait_and_submit)
    print("\n==> 全部自动化配置已完成！")


if __name__ == "__main__":
    main()
