#!/usr/bin/env python3
"""
Atermius — App Store Connect 高转化四语精装宣发海报合成工具

输入结构：
  <raw_dir>/<locale>/{iphone_69,ipad_13}/*.png
输出结构（严格 24-bit RGB 无 Alpha 通道 PNG）：
  <out_dir>/<locale>/iphone_69/*.png  -> 1320 x 2868
  <out_dir>/<locale>/ipad_13/*.png    -> 2064 x 2752
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps

TARGET_SIZES: dict[str, tuple[int, int]] = {
    "iphone_69": (1320, 2868),
    "ipad_13": (2064, 2752),
}

AI_BACKDROP_FILES: dict[tuple[str, str], str] = {
    ("iphone_69", "01_hosts_live.png"): "bg_iphone_dark_hero.png",
    ("iphone_69", "02_terminal_pro.png"): "bg_iphone_dark_hero.png",
    ("iphone_69", "03_forwarding.png"): "bg_iphone_dark_tech.png",
    ("iphone_69", "04_keychain.png"): "bg_iphone_dark_tech.png",
    ("iphone_69", "05_settings_light.png"): "bg_iphone_light_glass.png",
    ("ipad_13", "01_ipad_workspace_dark.png"): "bg_ipad_dark_studio.png",
    ("ipad_13", "02_ipad_terminal.png"): "bg_ipad_dark_studio.png",
    ("ipad_13", "03_ipad_workspace_light.png"): "bg_ipad_light_studio.png",
}

FONT_FAMILIES: dict[str, tuple[tuple[str, int], tuple[str, int]]] = {
    "zh-Hans": (
        ("/System/Library/Fonts/Hiragino Sans GB.ttc", 2),
        ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0),
    ),
    "ja": (
        ("/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc", 0),
        ("/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc", 0),
    ),
    "en-US": (
        ("/System/Library/Fonts/HelveticaNeue.ttc", 1),
        ("/System/Library/Fonts/HelveticaNeue.ttc", 0),
    ),
    "ru": (
        ("/System/Library/Fonts/HelveticaNeue.ttc", 1),
        ("/System/Library/Fonts/HelveticaNeue.ttc", 0),
    ),
}

FALLBACK_FONT_BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
FALLBACK_FONT_REG = "/System/Library/Fonts/Supplemental/Arial.ttf"


@dataclass(frozen=True)
class PosterCopy:
    badge: str
    headline: str
    subtitle: str
    light_mode: bool = False


POSTER_COPY: dict[str, dict[str, dict[str, PosterCopy]]] = {
    "iphone_69": {
        "zh-Hans": {
            "01_hosts_live.png": PosterCopy(
                badge="LIQUID GLASS · 实时会话胶囊",
                headline="多台服务器\n一屏掌控全局",
                subtitle="分组目录与 48+ 系统图标，底部翡翠胶囊一触即回终端",
            ),
            "02_terminal_pro.png": PosterCopy(
                badge="LOW-LATENCY SSH · 快捷指令栏",
                headline="掌上专业终端\n真彩顺滑渲染",
                subtitle="断线自动恢复 PTY 尺寸 · 快捷键栏与边缘手势切换",
            ),
            "03_forwarding.png": PosterCopy(
                badge="TUNNELS & BASTION · 端口转发",
                headline="一键构建\n安全加密隧道",
                subtitle="完整支持 Local、Remote 与 SOCKS5 动态转发及多级跳板主机",
            ),
            "04_keychain.png": PosterCopy(
                badge="ZERO-TRUST KEYCHAIN · 本机加密",
                headline="免注册开箱即用\n私钥仅存本机",
                subtitle="离线生成 Ed25519 / RSA 密钥对，受 iOS 钥匙串与面容 ID 守护",
            ),
            "05_settings_light.png": PosterCopy(
                badge="DAY & NIGHT · 深浅自适应",
                headline="纯正原生质感\n随光而变",
                subtitle="全系适配折叠屏、灵动岛与横竖屏安全区，亦支持自托管零知识同步",
                light_mode=True,
            ),
        },
        "en-US": {
            "01_hosts_live.png": PosterCopy(
                badge="LIVE SESSION PILL · LIQUID GLASS",
                headline="Every Server\nOne Glance Away",
                subtitle="48+ OS marks, folders, and a live emerald pill to jump back into any shell",
            ),
            "02_terminal_pro.png": PosterCopy(
                badge="FULL ANSI SHELL · TACTILE KEYBAR",
                headline="Desktop-Grade SSH\nRight in Your Pocket",
                subtitle="Auto-restored PTY sizing, hardware shortcuts & edge-swipe navigation",
            ),
            "03_forwarding.png": PosterCopy(
                badge="PORT FORWARDING · JUMP HOSTS",
                headline="Instant Tunnels\nZero Exposed Ports",
                subtitle="Manage Local, Remote, SOCKS5 & bastion tunnels with real-time state",
            ),
            "04_keychain.png": PosterCopy(
                badge="ON-DEVICE KEYCHAIN · NO SIGN-UP",
                headline="Keys Never Leave\nYour iPhone Vault",
                subtitle="Generate Ed25519 & RSA keys offline behind Keychain & Face ID lock",
            ),
            "05_settings_light.png": PosterCopy(
                badge="LIGHT & DARK · FOLDABLE READY",
                headline="Crafted for iOS\nBuilt to Adapt",
                subtitle="Crisp daytime legibility, dynamic multitasking & optional zero-knowledge sync",
                light_mode=True,
            ),
        },
        "ja": {
            "01_hosts_live.png": PosterCopy(
                badge="LIVE SESSION PILL · LIQUID GLASS",
                headline="複数サーバーを\nスマートに一括管理",
                subtitle="48種類以上のOSアイコンとライブカプセルで、進行中の端末へ即復帰",
            ),
            "02_terminal_pro.png": PosterCopy(
                badge="LOW-LATENCY SSH · 専用キーバー",
                headline="ポケットに収まる\n本格カラーターミナル",
                subtitle="再接続後の画面サイズ復元、修飾キーバー＆左端スワイプ戻るに対応",
            ),
            "03_forwarding.png": PosterCopy(
                badge="PORT FORWARDING · 踏み台接続",
                headline="安全なSSHトンネルを\nワンタップで開通",
                subtitle="Local・Remote・SOCKS5転送と多段バストリオン構成を直感管理",
            ),
            "04_keychain.png": PosterCopy(
                badge="KEYCHAIN VAULT · アカウント登録不要",
                headline="秘密鍵はすべて\n端末内で暗号化保護",
                subtitle="Ed25519 / RSA 鍵をオフライン生成し Keychain と Face ID で堅牢に保管",
            ),
            "05_settings_light.png": PosterCopy(
                badge="LIGHT & DARK · マルチウィンドウ対応",
                headline="純正 iOS 体験を\nあらゆる画面で",
                subtitle="昼夜に映える適応テーマ、可変ウィンドウ＆ゼロ知識同期をオプション搭載",
                light_mode=True,
            ),
        },
        "ru": {
            "01_hosts_live.png": PosterCopy(
                badge="LIVE SESSION PILL · LIQUID GLASS",
                headline="Все серверы\nпод вашим контролем",
                subtitle="Папки, иконки ОС и живая капсула для мгновенного возврата в сессию",
            ),
            "02_terminal_pro.png": PosterCopy(
                badge="FULL ANSI SSH · ПАНЕЛЬ КЛАВИШ",
                headline="Мощный терминал\nвсегда с собой",
                subtitle="Восстановление размера PTY, цвета xterm-256 и жест возврата с края",
            ),
            "03_forwarding.png": PosterCopy(
                badge="ТУННЕЛИ И BASTION · ПРОБРОС ПОРТОВ",
                headline="Защищённые туннели\nв одно касание",
                subtitle="Локальный, удалённый и SOCKS5-форвардинг с наглядным статусом",
            ),
            "04_keychain.png": PosterCopy(
                badge="БЕЗ РЕГИСТРАЦИИ · LOCAL KEYCHAIN",
                headline="Ключи хранятся\nтолько на устройстве",
                subtitle="Офлайн-генерация Ed25519 / RSA под защитой Keychain и Face ID",
            ),
            "05_settings_light.png": PosterCopy(
                badge="СВЕТЛАЯ И ТЁМНАЯ · ГИБКИЙ ЭКРАН",
                headline="Нативный дизайн\nбез компромиссов",
                subtitle="Адаптивная вёрстка для любых экранов и опциональная E2E-синхронизация",
                light_mode=True,
            ),
        },
    },
    "ipad_13": {
        "zh-Hans": {
            "01_ipad_workspace_dark.png": PosterCopy(
                badge="IPAD PRO MULTITASKING · 分栏工作区",
                headline="为大屏与分屏而生的基础设施指挥台",
                subtitle="自适应导航栏、分组树形筛选与多协议主机卡片，兼顾桌面效率与触控直觉",
            ),
            "02_ipad_terminal.png": PosterCopy(
                badge="MULTI-TAB & SPLIT PANE · 硬件键盘捕获",
                headline="多标签真彩终端，接上键盘即刻进入战斗",
                subtitle="完整保留 Command / Tab / 方向键捕获、SFTP 文件抽屉与快捷工具侧边栏",
            ),
            "03_ipad_workspace_light.png": PosterCopy(
                badge="ZERO-KNOWLEDGE & LIGHT UI · 全场景适配",
                headline="清晰透亮的浅色外观，日间运维同样赏心悦目",
                subtitle="无账号壁垒开箱即用，亦支持私有化自托管加密同步与多窗口协同",
                light_mode=True,
            ),
        },
        "en-US": {
            "01_ipad_workspace_dark.png": PosterCopy(
                badge="IPAD PRO & SPLIT VIEW · COMMAND CENTER",
                headline="A Desktop-Class Workspace Scaled for Big Displays",
                subtitle="Adaptive sidebar, grouped infrastructure views & instant one-tap SSH, SFTP and RDP",
            ),
            "02_ipad_terminal.png": PosterCopy(
                badge="MULTI-TAB TERMINAL · KEYBOARD CAPTURE",
                headline="Full-Speed Terminal Tabs with External Keyboard Flow",
                subtitle="Split panes, live reconnect recovery & hardware shortcut capture built for pros",
            ),
            "03_ipad_workspace_light.png": PosterCopy(
                badge="LIGHT APPEARANCE · ZERO-KNOWLEDGE READY",
                headline="Effortless Daytime Clarity with Private Keychain Sync",
                subtitle="Zero sign-up required out of the box—add self-hosted E2E sync whenever you need it",
                light_mode=True,
            ),
        },
        "ja": {
            "01_ipad_workspace_dark.png": PosterCopy(
                badge="IPAD PRO マルチタスク · コマンドセンター",
                headline="大画面に最適化された統合インフラワークスペース",
                subtitle="適応サイドバーとフォルダ整理で、SSH・SFTP・リモートデスクトップを快適操作",
            ),
            "02_ipad_terminal.png": PosterCopy(
                badge="マルチタブ端末 · ハードウェアキーボード対応",
                headline="複数タブと画面分割で作業を止めない高速ターミナル",
                subtitle="外付けキーボードのショートカット捕捉や SFTP ファイル連携を標準搭載",
            ),
            "03_ipad_workspace_light.png": PosterCopy(
                badge="ライトモード · ゼロ知識エンドツーエンド暗号化",
                headline="日中も見やすい洗練されたライトUIと強固な暗号化",
                subtitle="アカウント登録不要ですぐ起動。セルフホスト同期にも対応",
                light_mode=True,
            ),
        },
        "ru": {
            "01_ipad_workspace_dark.png": PosterCopy(
                badge="IPAD PRO · РАБОЧАЯ СТАНЦИЯ",
                headline="Командный центр уровня десктопа на большом экране",
                subtitle="Адаптивная панель, группы серверов и мгновенный запуск SSH, SFTP и RDP",
            ),
            "02_ipad_terminal.png": PosterCopy(
                badge="ВКЛАДКИ И СПЛИТ-ЭКРАН · ВНЕШНЯЯ КЛАВИАТУРА",
                headline="Многовкладочный терминал с захватом горячих клавиш",
                subtitle="Разделение панелей, быстрый доступ к SFTP и умное переподключение",
            ),
            "03_ipad_workspace_light.png": PosterCopy(
                badge="СВЕТЛАЯ ТЕМА · SELF-HOSTED E2E",
                headline="Безупречная читаемость днём и полная приватность",
                subtitle="Запуск без регистрации, локальный Keychain и сквозная синхронизация",
                light_mode=True,
            ),
        },
    },
}


def _load_font(
    locale: str, size: int, *, bold: bool
) -> ImageFont.FreeTypeFont:
    pair = FONT_FAMILIES.get(locale, FONT_FAMILIES["en-US"])
    path, index = pair[0] if bold else pair[1]
    try:
        return ImageFont.truetype(path, size, index=index)
    except OSError:
        fallback = FALLBACK_FONT_BOLD if bold else FALLBACK_FONT_REG
        return ImageFont.truetype(fallback, size)


def _fit_multiline_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    locale: str,
    max_width: int,
    initial_size: int,
    min_size: int,
    *,
    bold: bool,
    auto_wrap: bool,
) -> tuple[ImageFont.FreeTypeFont, list[str]]:
    """Shrinks font size slightly if needed and optionally wraps paragraphs."""
    for size in range(initial_size, min_size - 1, -2):
        font = _load_font(locale, size, bold=bold)
        raw_lines = text.splitlines()
        if not auto_wrap:
            widest = max(
                (draw.textbbox((0, 0), line, font=font)[2] for line in raw_lines),
                default=0,
            )
            if widest <= max_width:
                return font, raw_lines
        else:
            wrapped: list[str] = []
            for para in raw_lines:
                if draw.textbbox((0, 0), para, font=font)[2] <= max_width:
                    wrapped.append(para)
                    continue
                if " " in para and locale in {"en-US", "ru"}:
                    words = para.split(" ")
                    cur = ""
                    for w in words:
                        cand = f"{cur} {w}".strip()
                        if draw.textbbox((0, 0), cand, font=font)[2] <= max_width:
                            cur = cand
                        else:
                            if cur:
                                wrapped.append(cur)
                            cur = w
                    if cur:
                        wrapped.append(cur)
                else:
                    cur = ""
                    for ch in para:
                        cand = cur + ch
                        if draw.textbbox((0, 0), cand, font=font)[2] <= max_width:
                            cur = cand
                        else:
                            if cur:
                                wrapped.append(cur)
                            cur = ch
                    if cur:
                        wrapped.append(cur)
            if len(wrapped) <= 3:
                return font, wrapped
    font = _load_font(locale, min_size, bold=bold)
    return font, text.splitlines()


def _create_backdrop(
    width: int, height: int, *, light_mode: bool
) -> Image.Image:
    """Renders an Obsidian-Emerald aurora background fast via downsampled blend."""
    sw, sh = 220, max(220, int(220 * height / width))
    small = Image.new("RGB", (sw, sh))
    px = small.load()
    assert px is not None

    for y in range(sh):
        ty = y / max(1, sh - 1)
        for x in range(sw):
            tx = x / max(1, sw - 1)
            # Base vertical obsidian / porcelain gradient
            if light_mode:
                r = 242 - 14 * ty
                g = 249 - 10 * ty
                b = 247 - 9 * ty
                # Emerald aurora blooms
                d1 = ((tx - 0.18) ** 2) / 0.28 + ((ty - 0.14) ** 2) / 0.14
                d2 = ((tx - 0.85) ** 2) / 0.30 + ((ty - 0.82) ** 2) / 0.22
                g1 = max(0.0, 1.0 - d1) ** 1.7
                g2 = max(0.0, 1.0 - d2) ** 1.8
                r -= 24 * g1 + 16 * g2
                g += 4 * g1 + 1 * g2
                b -= 4 * g1 - 5 * g2
            else:
                r = 5 + 4 * ty
                g = 11 + 8 * ty
                b = 13 + 9 * ty
                # Luminous emerald aurora at top-right and cyan-teal glow behind device
                d1 = ((tx - 0.80) ** 2) / 0.34 + ((ty - 0.12) ** 2) / 0.16
                d2 = ((tx - 0.50) ** 2) / 0.40 + ((ty - 0.62) ** 2) / 0.28
                d3 = ((tx - 0.16) ** 2) / 0.28 + ((ty - 0.86) ** 2) / 0.20
                g1 = max(0.0, 1.0 - d1) ** 1.8
                g2 = max(0.0, 1.0 - d2) ** 1.6
                g3 = max(0.0, 1.0 - d3) ** 1.8
                r += 8 * g1 + 6 * g2 + 4 * g3
                g += 68 * g1 + 52 * g2 + 34 * g3
                b += 58 * g1 + 48 * g2 + 44 * g3

            px[x, y] = (
                max(0, min(255, int(r))),
                max(0, min(255, int(g))),
                max(0, min(255, int(b))),
            )

    bg = small.resize((width, height), Image.Resampling.BICUBIC).convert("RGBA")

    # Subtle architectural grid pattern in upper marketing canvas
    grid = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(grid)
    step = 88
    line_rgba = (15, 123, 108, 16) if light_mode else (79, 216, 196, 14)
    fade_limit = int(height * 0.42)
    for gx in range(step, width, step):
        gdraw.line([(gx, 0), (gx, fade_limit)], fill=line_rgba, width=2)
    for gy in range(step, fade_limit, step):
        gdraw.line([(0, gy), (width, gy)], fill=line_rgba, width=2)

    return Image.alpha_composite(bg, grid)


def _load_ai_backdrop(
    bg_dir: Path | None,
    device_kind: str,
    filename: str,
    width: int,
    height: int,
    *,
    light_mode: bool,
) -> Image.Image | None:
    if bg_dir is None:
        return None
    mapped = AI_BACKDROP_FILES.get((device_kind, filename))
    if not mapped:
        return None
    candidate = bg_dir / mapped
    if not candidate.is_file():
        return None

    with Image.open(candidate) as raw_bg:
        fitted = ImageOps.fit(
            raw_bg.convert("RGB"),
            (width, height),
            method=Image.Resampling.LANCZOS,
            centering=(0.5, 0.5),
        ).convert("RGBA")

    # 顶部文字区柔光渐隐遮罩：确保四语大标题与副标题在 AI 立体背景上拥有极佳对比度与通透阅读感
    scrim = Image.new("RGBA", (1, height), (0, 0, 0, 0))
    px = scrim.load()
    assert px is not None
    fade_end = int(height * 0.42)
    base_rgb = (244, 250, 247) if light_mode else (5, 11, 13)
    max_alpha = 188 if light_mode else 196
    for y in range(height):
        if y < fade_end:
            t = y / max(1, fade_end)
            alpha = int(max_alpha * ((1.0 - t) ** 1.35))
            px[0, y] = (*base_rgb, alpha)
    scrim_full = scrim.resize((width, height), Image.Resampling.BILINEAR)
    return Image.alpha_composite(fitted, scrim_full)


def _rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    """2x supersampled smooth rounded-rectangle mask."""
    w, h = size
    mask_2x = Image.new("L", (w * 2, h * 2), 0)
    mdraw = ImageDraw.Draw(mask_2x)
    mdraw.rounded_rectangle(
        [0, 0, w * 2 - 1, h * 2 - 1], radius=radius * 2, fill=255
    )
    return mask_2x.resize((w, h), Image.Resampling.LANCZOS)


def compose_poster(
    raw_path: Path,
    out_path: Path,
    *,
    device_kind: str,
    locale: str,
    copy: PosterCopy,
    bg_dir: Path | None = None,
) -> None:
    target_w, target_h = TARGET_SIZES[device_kind]
    is_ipad = device_kind == "ipad_13"
    canvas = _load_ai_backdrop(
        bg_dir,
        device_kind,
        raw_path.name,
        target_w,
        target_h,
        light_mode=copy.light_mode,
    ) or _create_backdrop(target_w, target_h, light_mode=copy.light_mode)
    draw = ImageDraw.Draw(canvas)

    margin_x = 96 if not is_ipad else 136
    max_text_w = target_w - 2 * margin_x

    # 1. Top feature pill badge
    badge_font = _load_font(locale, 32 if not is_ipad else 34, bold=True)
    bbox = draw.textbbox((0, 0), copy.badge, font=badge_font)
    bw = bbox[2] - bbox[0]
    bh = bbox[3] - bbox[1]
    pill_pad_x, pill_pad_y = 38, 18
    pill_w = bw + pill_pad_x * 2
    pill_h = bh + pill_pad_y * 2
    pill_x = (target_w - pill_w) // 2
    pill_y = 110 if not is_ipad else 92

    if copy.light_mode:
        pill_fill = (15, 123, 108, 28)
        pill_border = (15, 123, 108, 92)
        pill_text_color = (10, 86, 75, 255)
        headline_color = (12, 30, 28, 255)
        subtitle_color = (64, 92, 87, 255)
        bezel_outer = (224, 232, 230, 255)
        bezel_inner = (255, 255, 255, 255)
        rim_highlight = (255, 255, 255, 220)
        shadow_alpha = 52
    else:
        pill_fill = (79, 216, 196, 36)
        pill_border = (79, 216, 196, 115)
        pill_text_color = (139, 232, 217, 255)
        headline_color = (242, 248, 247, 255)
        subtitle_color = (165, 190, 185, 255)
        bezel_outer = (34, 46, 48, 255)
        bezel_inner = (12, 16, 18, 255)
        rim_highlight = (160, 235, 222, 72)
        shadow_alpha = 148

    pill_overlay = Image.new("RGBA", (target_w, target_h), (0, 0, 0, 0))
    pdraw = ImageDraw.Draw(pill_overlay)
    pdraw.rounded_rectangle(
        [pill_x, pill_y, pill_x + pill_w, pill_y + pill_h],
        radius=pill_h // 2,
        fill=pill_fill,
        outline=pill_border,
        width=2,
    )
    canvas = Image.alpha_composite(canvas, pill_overlay)
    draw = ImageDraw.Draw(canvas)
    draw.text(
        (pill_x + pill_pad_x - bbox[0], pill_y + pill_pad_y - bbox[1]),
        copy.badge,
        font=badge_font,
        fill=pill_text_color,
    )

    # 2. Headline
    hl_initial = 96 if not is_ipad else (84 if locale in {"en-US", "ru"} else 92)
    hl_font, hl_lines = _fit_multiline_text(
        draw,
        copy.headline,
        locale,
        max_text_w,
        hl_initial,
        62,
        bold=True,
        auto_wrap=False,
    )
    y_cursor = pill_y + pill_h + (42 if not is_ipad else 34)
    hl_line_gap = 18 if not is_ipad else 14
    for line in hl_lines:
        lb = draw.textbbox((0, 0), line, font=hl_font)
        lw, lh = lb[2] - lb[0], lb[3] - lb[1]
        lx = (target_w - lw) // 2 - lb[0]
        draw.text((lx, y_cursor - lb[1]), line, font=hl_font, fill=headline_color)
        y_cursor += lh + hl_line_gap

    # 3. Subtitle
    y_cursor += 16 if not is_ipad else 12
    sub_font, sub_lines = _fit_multiline_text(
        draw,
        copy.subtitle,
        locale,
        max_text_w - 20,
        40 if not is_ipad else 42,
        30,
        bold=False,
        auto_wrap=True,
    )
    sub_gap = 12
    for line in sub_lines:
        sb = draw.textbbox((0, 0), line, font=sub_font)
        sw, sh = sb[2] - sb[0], sb[3] - sb[1]
        sx = (target_w - sw) // 2 - sb[0]
        draw.text((sx, y_cursor - sb[1]), line, font=sub_font, fill=subtitle_color)
        y_cursor += sh + sub_gap

    # 4. Framed simulator screenshot anchored neatly below marketing copy
    raw_img = Image.open(raw_path).convert("RGB")
    top_space = y_cursor + (56 if not is_ipad else 48)
    bottom_margin = 76 if not is_ipad else 68
    avail_h = target_h - top_space - bottom_margin
    avail_w = target_w - (176 if not is_ipad else 200)

    bezel_pad = 18 if not is_ipad else 22
    scale = min(
        (avail_w - 2 * bezel_pad) / raw_img.width,
        (avail_h - 2 * bezel_pad) / raw_img.height,
    )
    screen_w = int(round(raw_img.width * scale))
    screen_h = int(round(raw_img.height * scale))
    screen_img = raw_img.resize((screen_w, screen_h), Image.Resampling.LANCZOS)

    frame_w = screen_w + 2 * bezel_pad
    frame_h = screen_h + 2 * bezel_pad
    frame_x = (target_w - frame_w) // 2
    frame_y = top_space + max(0, (avail_h - frame_h) // 2)

    screen_radius = int(screen_w * (0.115 if not is_ipad else 0.030))
    frame_radius = screen_radius + bezel_pad

    # Ambient dual-stage drop shadow behind device frame
    shadow_pad = 104
    shadow_box = Image.new(
        "RGBA", (frame_w + shadow_pad * 2, frame_h + shadow_pad * 2), (0, 0, 0, 0)
    )
    sdraw = ImageDraw.Draw(shadow_box)
    sdraw.rounded_rectangle(
        [shadow_pad, shadow_pad + 30, shadow_pad + frame_w, shadow_pad + frame_h + 30],
        radius=frame_radius,
        fill=(0, 0, 0, shadow_alpha),
    )
    shadow_box = shadow_box.filter(ImageFilter.GaussianBlur(radius=42))
    canvas.alpha_composite(shadow_box, (frame_x - shadow_pad, frame_y - shadow_pad))

    # Titanium chassis outer rim + specular inner bevel + dark bezel
    chassis_draw = ImageDraw.Draw(canvas)
    chassis_draw.rounded_rectangle(
        [frame_x, frame_y, frame_x + frame_w, frame_y + frame_h],
        radius=frame_radius,
        fill=bezel_inner,
        outline=bezel_outer,
        width=6,
    )
    chassis_draw.rounded_rectangle(
        [frame_x + 3, frame_y + 3, frame_x + frame_w - 3, frame_y + frame_h - 3],
        radius=max(4, frame_radius - 3),
        outline=rim_highlight,
        width=2,
    )

    # Paste supersampled rounded simulator screenshot cleanly inside chassis
    mask = _rounded_mask((screen_w, screen_h), screen_radius)
    canvas.paste(screen_img, (frame_x + bezel_pad, frame_y + bezel_pad), mask)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    # 关键合规：App Store Connect 严禁截图含 Alpha 通道，必须保存为纯 24-bit RGB
    canvas.convert("RGB").save(out_path, format="PNG", optimize=True)


def build_all(
    raw_dir: Path,
    out_dir: Path,
    locales: Iterable[str],
    *,
    bg_dir: Path | None = None,
) -> int:
    count = 0
    for locale in locales:
        for device_kind in ("iphone_69", "ipad_13"):
            copies = POSTER_COPY[device_kind][locale]
            for filename, copy in copies.items():
                raw_path = raw_dir / locale / device_kind / filename
                if not raw_path.is_file():
                    raise FileNotFoundError(f"缺少原始模拟器截图: {raw_path}")
                out_path = out_dir / locale / device_kind / filename
                compose_poster(
                    raw_path,
                    out_path,
                    device_kind=device_kind,
                    locale=locale,
                    copy=copy,
                    bg_dir=bg_dir,
                )
                with Image.open(out_path) as check:
                    assert check.mode == "RGB", f"Alpha channel present in {out_path}"
                    assert check.size == TARGET_SIZES[device_kind], (
                        f"Wrong size {check.size} in {out_path}"
                    )
                count += 1
                print(f"[OK] {locale}/{device_kind}/{filename} -> {out_path.stat().st_size // 1024} KB (RGB)")
    return count


def main() -> None:
    parser = argparse.ArgumentParser(description="Atermius App Store 精装海报合成器")
    parser.add_argument(
        "--raw-dir",
        default="/Users/yang/Downloads/aterm-project/ios/build/appstore_raw_shots",
    )
    parser.add_argument(
        "--out-dir",
        default="/Users/yang/Downloads/aterm-project/ios/build/appstore_posters",
    )
    parser.add_argument(
        "--bg-dir",
        default=None,
        help="可选 AI 工作室背景图目录（含 bg_iphone_*.png / bg_ipad_*.png）",
    )
    parser.add_argument(
        "--locales",
        nargs="+",
        default=["zh-Hans", "en-US", "ja", "ru"],
    )
    args = parser.parse_args()
    bg_path = Path(args.bg_dir) if args.bg_dir else None
    total = build_all(Path(args.raw_dir), Path(args.out_dir), args.locales, bg_dir=bg_path)
    print(f"==> 全部完成：共合成 {total} 张 24-bit RGB 无 Alpha 精装营销海报。")


if __name__ == "__main__":
    main()
