export const REPO = 'https://github.com/aterm-project/atermius';
export const RELEASES = `${REPO}/releases`;
export const DOCS = `${REPO}/tree/main/docs`;

export type Lang = 'en' | 'zh';

export interface Feature {
  key: string;
  shot: string;
  tag: string;
  title: string;
  body: string;
  points: string[];
}

export interface Copy {
  lang: Lang;
  htmlLang: string;
  title: string;
  description: string;
  nav: { features: string; security: string; selfHost: string; download: string; other: string; otherHref: string };
  hero: { eyebrow: string; lines: string[]; sub: string; primary: string; secondary: string; hint: string; caption: string };
  platforms: string[];
  showcase: { eyebrow: string; title: string; features: Feature[] };
  stats: { value: number; suffix: string; label: string }[];
  security: {
    eyebrow: string;
    title: string;
    body: string;
    plain: string[];
    nodes: { device: string; server: string; other: string; cipher: string };
    points: { title: string; body: string }[];
  };
  bento: { eyebrow: string; title: string; cards: { title: string; body: string; glyph: string }[] };
  gallery: { eyebrow: string; title: string; captions: Record<string, string> };
  mobile: { eyebrow: string; title: string; body: string };
  selfHost: { eyebrow: string; title: string; body: string; note: string; link: string };
  download: {
    title: string[];
    body: string;
    primary: string;
    secondary: string;
    rows: { name: string; detail: string }[];
    note: string;
  };
  footer: { tagline: string; docs: string; releases: string; source: string; privacy: string };
}

export const en: Copy = {
  lang: 'en',
  htmlLang: 'en',
  title: 'Atermius — encrypted SSH, SFTP, RDP and VNC workspace',
  description:
    'Atermius is one encrypted workspace for SSH, SFTP, RDP and VNC on Android, iOS, Windows, macOS, Linux and the browser, with an optional sync server you host yourself.',
  nav: { features: 'Features', security: 'Security', selfHost: 'Self-host', download: 'Download', other: '中文', otherHref: 'zh/' },
  hero: {
    eyebrow: 'SSH · SFTP · RDP · VNC',
    lines: ['Every server.', 'One encrypted', 'workspace.'],
    sub: 'Terminals, files and remote desktops in a single app for Android, iOS, Windows, macOS, Linux and the browser. Keep everything on the device, or sync through a server you host yourself.',
    primary: 'Download',
    secondary: 'View on GitHub',
    hint: 'Scroll',
    caption: 'Home in the browser build',
  },
  platforms: ['Android', 'iOS', 'Windows', 'macOS', 'Linux', 'Browser', 'Self-hosted server'],
  showcase: {
    eyebrow: 'The workspace',
    title: 'Built for people who live in remote machines',
    features: [
      {
        key: 'home',
        shot: 'home',
        tag: '01 — Hosts',
        title: 'Your whole fleet, one keystroke away',
        body: 'Compact host lists, groups and reusable commands. Type an ssh command into the search field to connect at once.',
        points: ['Groups and sorting shared by every client', 'Quick connect from the search field', 'Jump hosts, saved or temporary for one tab'],
      },
      {
        key: 'terminal',
        shot: 'terminal',
        tag: '02 — Terminal',
        title: 'A terminal that reads the log with you',
        body: 'Errors, warnings, successes, IP addresses and links are colored in plain output, even when the remote program prints no color at all.',
        points: ['Keyword groups, colors and word lists are editable', 'Up to 5,000,000 lines of scrollback', 'SSH and Telnet; local shell and serial console on desktop'],
      },
      {
        key: 'files',
        shot: 'files',
        tag: '03 — Files',
        title: 'Files without leaving the session',
        body: 'SFTP and SCP file workspaces sit next to your terminals. Copy between two hosts directly over SSH, or relay through your device.',
        points: ['Copy and move between hosts', 'Open remote files in system apps on Windows and macOS', 'Upload prompt after a local save'],
      },
      {
        key: 'split',
        shot: 'split',
        tag: '04 — Layout',
        title: 'Split it the way you think',
        body: 'Put terminals and file views side by side in panes, then save the arrangement as a window set to bring it back later.',
        points: ['Split panes in every client', 'Saved window sets', 'Separate OS windows on desktop'],
      },
    ],
  },
  stats: [
    { value: 6, suffix: '', label: 'client platforms from one codebase' },
    { value: 5000000, suffix: '', label: 'lines of scrollback at the top setting' },
    { value: 26, suffix: ' B', label: 'per archived line of ordinary log output' },
    { value: 4, suffix: '', label: 'interface languages: English, 中文, 日本語, Русский' },
  ],
  security: {
    eyebrow: 'Security model',
    title: 'The server syncs ciphertext',
    body: 'Hosts, keys and passwords are encrypted on the device before they are synced. The sync server stores ciphertext records and checks signed device identities.',
    plain: ['host  db-primary', 'user  deploy', 'key   ed25519 ••••', 'port  22'],
    nodes: { device: 'Your device', server: 'Your server', other: 'Your other devices', cipher: 'ciphertext' },
    points: [
      { title: 'Local profiles', body: 'Native clients can keep an encrypted profile on the device and never talk to a server.' },
      { title: 'Private by default', body: 'Each account is either private (zero knowledge) or explicitly admin-visible, with a notice to the user and a recorded view log.' },
      { title: 'Encrypted at rest', body: 'The server database is SQLCipher-encrypted, snapshots included, with the key kept outside the data volume.' },
      { title: 'Scrollback stays yours', body: 'Scrollback spilled to disk is sealed with XChaCha20-Poly1305 under a key that only exists in memory.' },
    ],
  },
  bento: {
    eyebrow: 'And the rest',
    title: 'Everything a remote workday needs',
    cards: [
      { glyph: '▣', title: 'Remote desktop', body: 'RDP and VNC through native engines where the platform has one, or through the gateway of your server. Route them through an SSH jump host.' },
      { glyph: '◈', title: 'MCP for AI tools', body: 'An opt-in MCP listener on desktop, Android and iOS lets external AI tools read and drive sessions you allow.' },
      { glyph: '⇄', title: 'Teams and Vaults', body: 'Organizations, roles and team Vaults. Copy or move a host to any Vault you can write to.' },
      { glyph: '◷', title: 'Temporary links', body: 'Hand out browser access to one host with a start time, an expiry, limits and revocation.' },
      { glyph: '⌁', title: 'Keyword highlighting', body: 'Display only: copied text, search, logs and MCP output stay exactly as the remote wrote them.' },
      { glyph: '◐', title: 'Themes', body: 'Application accents and terminal palettes are separate settings, so the terminal looks the way you want.' },
    ],
  },
  gallery: {
    eyebrow: 'Screenshots',
    title: 'Real screens, captured from the running app',
    captions: {},
  },
  mobile: {
    eyebrow: 'On the phone',
    title: 'The same workspace in your pocket',
    body: 'The Android and iOS apps are the same Flutter client as the desktop one: the same hosts, the same Vault, the same terminal.',
  },
  selfHost: {
    eyebrow: 'Self-hosted',
    title: 'Your sync server, on your hardware',
    body: 'The server is a single Rust service with Docker Compose files. It runs the encrypted sync API, organizations and the temporary access gateway.',
    note: 'Docker with Compose 2.24 or later.',
    link: 'Server guide',
  },
  download: {
    title: ['Open a terminal.', 'Anywhere.'],
    body: 'Builds are published on the GitHub Releases page with checksums and build evidence.',
    primary: 'Get the latest release',
    secondary: 'Read the docs',
    rows: [
      { name: 'Android', detail: 'APK · arm64, x86_64' },
      { name: 'Windows', detail: 'Installer and portable ZIP · x64' },
      { name: 'macOS', detail: 'ZIP · ad-hoc signed' },
      { name: 'Linux', detail: 'tar.gz bundle · x64' },
      { name: 'iOS', detail: 'Unsigned IPA · daily builds' },
      { name: 'Browser', detail: 'Static bundle for your server' },
    ],
    note: 'Pre-release software: Windows packages are not code-signed, macOS builds are not notarized and the iOS IPA is unsigned.',
  },
  footer: {
    tagline: 'Encrypted SSH workspace for every platform.',
    docs: 'Documentation',
    releases: 'Releases',
    source: 'Source',
    privacy: 'Privacy policy',
  },
};

export const zh: Copy = {
  lang: 'zh',
  htmlLang: 'zh-CN',
  title: 'Atermius — 加密的 SSH、SFTP、RDP、VNC 工作区',
  description:
    'Atermius 把 SSH、SFTP、RDP 和 VNC 放进一个加密工作区，支持 Android、iOS、Windows、macOS、Linux 和浏览器，同步服务端可以自己部署。',
  nav: { features: '功能', security: '安全', selfHost: '自托管', download: '下载', other: 'English', otherHref: '' },
  hero: {
    eyebrow: 'SSH · SFTP · RDP · VNC',
    lines: ['所有服务器，', '一个加密的', '工作区。'],
    sub: '终端、文件和远程桌面都在同一个应用里，支持 Android、iOS、Windows、macOS、Linux 和浏览器。数据可以只留在本机，也可以通过自己部署的服务端同步。',
    primary: '下载',
    secondary: '在 GitHub 查看',
    hint: '向下滚动',
    caption: '浏览器版的主页',
  },
  platforms: ['Android', 'iOS', 'Windows', 'macOS', 'Linux', '浏览器', '自托管服务端'],
  showcase: {
    eyebrow: '工作区',
    title: '为每天泡在远程机器里的人而做',
    features: [
      {
        key: 'home',
        shot: 'home',
        tag: '01 — 主机',
        title: '整个机群，随手可达',
        body: '紧凑的主机列表、分组和可复用命令。在搜索框里输入一条 ssh 命令就能直接连接。',
        points: ['分组和排序在各端保持一致', '搜索框快速连接', '跳板主机可保存，也可只给当前标签临时使用'],
      },
      {
        key: 'terminal',
        shot: 'terminal',
        tag: '02 — 终端',
        title: '帮你一起看日志的终端',
        body: '错误、警告、成功、IP 地址和链接会在普通输出里自动着色，即使远端程序完全不输出颜色。',
        points: ['关键词分组、颜色和词表都可以编辑', '回滚缓冲区最多 5,000,000 行', 'SSH 和 Telnet；桌面端还有本机 Shell 和串口'],
      },
      {
        key: 'files',
        shot: 'files',
        tag: '03 — 文件',
        title: '不离开会话就能管文件',
        body: 'SFTP 和 SCP 文件工作区与终端并排。两台主机之间可以通过 SSH 直传，也可以经本机中转。',
        points: ['跨主机复制和移动', 'Windows 和 macOS 可用系统应用打开远程文件', '本地保存后提示上传'],
      },
      {
        key: 'split',
        shot: 'split',
        tag: '04 — 布局',
        title: '按自己的思路分屏',
        body: '把终端和文件视图放进并排的面板，再把这套布局存成窗口组合，下次直接恢复。',
        points: ['各端都支持分屏', '可保存的窗口组合', '桌面端支持独立系统窗口'],
      },
    ],
  },
  stats: [
    { value: 6, suffix: '', label: '个客户端平台，同一套代码' },
    { value: 5000000, suffix: '', label: '行回滚缓冲（最高档）' },
    { value: 26, suffix: ' B', label: '普通日志每行归档后的大小' },
    { value: 4, suffix: '', label: '种界面语言：中文、English、日本語、Русский' },
  ],
  security: {
    eyebrow: '安全模型',
    title: '服务端同步的是密文',
    body: '主机、密钥和密码在设备上加密之后才会同步。同步服务端保存密文记录，并校验带签名的设备身份。',
    plain: ['host  db-primary', 'user  deploy', 'key   ed25519 ••••', 'port  22'],
    nodes: { device: '你的设备', server: '你的服务端', other: '你的其他设备', cipher: '密文' },
    points: [
      { title: '本地资料', body: '原生客户端可以只在设备上保存加密资料，完全不连接任何服务端。' },
      { title: '默认私密', body: '每个账户要么是私密模式（零知识），要么明确设为管理员可见，用户会收到提示，查看行为会被记录。' },
      { title: '静态加密', body: '服务端数据库使用 SQLCipher 加密，快照也一样，密钥保存在数据卷之外。' },
      { title: '回滚内容只属于你', body: '写入磁盘的回滚内容用 XChaCha20-Poly1305 加密，密钥只存在于内存中。' },
    ],
  },
  bento: {
    eyebrow: '还有这些',
    title: '远程工作的一天所需要的一切',
    cards: [
      { glyph: '▣', title: '远程桌面', body: '平台有原生引擎时直接使用 RDP 和 VNC，否则走服务端网关。还可以经 SSH 跳板主机连接。' },
      { glyph: '◈', title: '面向 AI 工具的 MCP', body: '桌面、Android 和 iOS 可以主动开启 MCP 监听，让外部 AI 工具读取和操作你允许的会话。' },
      { glyph: '⇄', title: '团队与 Vault', body: '组织、角色和团队 Vault。主机可以复制或移动到任何有写权限的 Vault。' },
      { glyph: '◷', title: '临时链接', body: '把某台主机的浏览器访问权限临时交给别人，可设置开始时间、过期时间、次数限制，并可随时撤销。' },
      { glyph: '⌁', title: '关键词高亮', body: '只影响显示：复制的文本、搜索、日志和 MCP 输出都与远端写出的内容完全一致。' },
      { glyph: '◐', title: '主题', body: '应用强调色和终端配色分开设置，终端可以是你想要的样子。' },
    ],
  },
  gallery: {
    eyebrow: '截图',
    title: '全部来自运行中的应用',
    captions: {},
  },
  mobile: {
    eyebrow: '在手机上',
    title: '同一个工作区，装进口袋',
    body: 'Android 和 iOS 应用与桌面端是同一个 Flutter 客户端：同样的主机、同样的 Vault、同样的终端。',
  },
  selfHost: {
    eyebrow: '自托管',
    title: '同步服务端，跑在你自己的机器上',
    body: '服务端是一个 Rust 服务，附带 Docker Compose 文件，提供加密同步 API、组织管理和临时访问网关。',
    note: '需要 Docker 和 Compose 2.24 或更高版本。',
    link: '服务端指南',
  },
  download: {
    title: ['打开终端，', '在任何地方。'],
    body: '构建发布在 GitHub Releases 页面，附带校验和与构建凭证。',
    primary: '获取最新版本',
    secondary: '阅读文档',
    rows: [
      { name: 'Android', detail: 'APK · arm64、x86_64' },
      { name: 'Windows', detail: '安装程序和便携 ZIP · x64' },
      { name: 'macOS', detail: 'ZIP · ad-hoc 签名' },
      { name: 'Linux', detail: 'tar.gz 包 · x64' },
      { name: 'iOS', detail: '未签名 IPA · 每日构建' },
      { name: '浏览器', detail: '部署到自己服务端的静态包' },
    ],
    note: '目前是预发布软件：Windows 包没有代码签名，macOS 构建未经公证，iOS IPA 未签名。',
  },
  footer: {
    tagline: '全平台的加密 SSH 工作区。',
    docs: '文档',
    releases: '版本发布',
    source: '源代码',
    privacy: '隐私政策',
  },
};

/** Captions per screenshot file name (without extension). */
export const shotCaptions: Record<Lang, Record<string, string>> = {
  en: {
    terminal: 'An SSH terminal with highlighted service logs',
    home: 'Saved hosts organized by group in the workspace',
    split: 'Several terminal sessions in a split workspace',
    files: 'Remote files open beside a terminal session',
    'quick-connect': 'Search for a saved host and connect from the keyboard',
    'jump-host': 'Choose an SSH jump host to retry a connection',
    snippets: 'Command snippets stored in the same Vault as your hosts',
    'settings-theme': 'Terminal color schemes and a live preview',
    admin: 'Instance administration and account management',
    signin: 'Initial setup of a self-hosted instance',
  },
  zh: {
    terminal: 'SSH 终端中的服务日志和关键词高亮',
    home: '工作区中按分组整理的已保存主机',
    split: '同一工作区中的多个分屏终端会话',
    files: '在终端会话旁浏览远程文件',
    'quick-connect': '用键盘搜索已保存的主机并连接',
    'jump-host': '选择 SSH 跳板主机后重试连接',
    snippets: '与主机保存在同一 Vault 的命令片段',
    'settings-theme': '终端配色方案与实时预览',
    admin: '实例管理与用户账户列表',
    signin: '自托管实例的初次配置',
  },
};
