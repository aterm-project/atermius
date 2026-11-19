# Atermius 本机三版本迭代报告（`1.0.2` → `1.0.3` → `1.0.4`）

基于 `1.0.1 (Build 2)` (`0241a75`)，面向商业服务器运维、长时间跨网连接、高吞吐日志压测与高频操作习惯，本机连续完成三轮独立版本迭代与回归验证（均仅保留于本机提交与标签，未向 GitHub 推送、未向 App Store Connect 上传）。

---

## 版本一：`1.0.2 (Build 3)` — 商业长连接韧性与链路健康引擎 (`v1.0.2-build3`)

- **OpenSSH 语义保活看门狗（`packages/dartssh2/lib/src/ssh_keepalive.dart` / `ssh_client.dart`）**：
  - 彻底修复 `dartssh2` 原版 `SSHKeepAlive` 在半开 TCP（NAT/CGNAT 超时、企业防火墙静默丢包、Wi-Fi/5G 切换、休眠唤醒）下无限挂起导致“假在线僵尸连接”的缺陷；
  - 引入单次响应超时（`keepAliveTimeout`）、连续失联阈值（`keepAliveMaxMissed`，对齐 `ServerAliveCountMax`）、实时 RTT 采集（`onKeepAliveLatency`）、单次丢包告警（`onKeepAliveMissed`）与僵死自动断流（`onKeepAliveDead` 触发传输层关闭，即时交由 `SessionRecovery` 自动恢复）；
  - 新增并发去重的主动探活方法 `SSHClient.probeKeepAlive()`。
- **底层低延迟传输（`packages/dartssh2/lib/src/socket/ssh_socket_io.dart`）**：
  - 为原生 SSH TCP 套接字开启 `SocketOption.tcpNoDelay = true`，消除 Nagle + Delayed-ACK 带来的 40~200ms 按键回显卡顿。
- **多跳保活、周期密钥轮换与前后台秒级探活（`lib/ssh/ssh_service.dart`, `ssh_connection_health.dart`, `ssh_keepalive_policy.dart`, `storage/ssh_keepalive_store*.dart`, `ui/ssh_keepalive_setting.dart`）**：
  - 设备级持久化策略支持保活间隔（关闭 / 10s / 15s / 30s / 60s）、僵死阈值（2 / 3 / 5 次）、自动密钥轮换（RFC 4253 §9，关闭 / 1h / 3h）与前后台切回即时探活；
  - 跳板链（Jump Hosts）与目标连接统一受看门狗保护，新增零凭据 `SshConnectionHealth` 遥测（状态、EWMA 延迟、运行/空闲时长、收发字节、rekey 计数）；
  - 云模式 `AppController.onForegroundResumed()` 与本地模式 `LocalProfileFlow` (`WidgetsBindingObserver`) 在回到前台时均并行探活在线 SSH 连接；
  - `SessionRecovery` 新增 `recoveryCount`（累计自动恢复次数）与 `lastDisconnectReason`（断线原因码）。

---

## 版本二：`1.0.3 (Build 4)` — 高吞吐渲染管线、零分配热路径与商业级压测体系 (`v1.0.3-build4`)

- **两级自适应终端输出合批器（`lib/terminal/terminal_output_coalescer.dart`）**：
  - **Stage 1（交互零延迟）**：空闲窗口首包立即同步直通；单帧窗口内短突发经微任务聚批（0ms 定时器延迟）；
  - **Stage 2（洪流帧级节流）**：高吞吐洪流（如 `kubectl logs -f`、`dmesg`、`cat` 大日志）自动切换至 8ms（120Hz ProMotion 节奏）/ 64 KiB 封顶合批，并保护 UTF-16 代理对不被批次边界腰斩；已接入云端与本地双路径。
- **热路径零分配与算法复杂度修复**：
  - `lib/terminal/mirrored_terminal.dart`：零堆分配 `utf8EncodedLength` 替代每 4KB 切片的 `utf8.encode().length`，且每批仅触发单次 `super.write(data)` 消除多次同步 `notifyListeners()` 重绘风暴；
  - `lib/terminal/session_log.dart`：`_TranscriptBuffer` 由 `List.removeAt(0)`（O(N)）+ 双重 `utf8.encode` 升级为 `Queue` O(1) 淘汰 + 零分配 UTF-8 计数 + 代理对安全截断；
  - `lib/terminal/terminal_search.dart`：ASCII 零分配大小写折叠快路径，消除百万单元格检索时的百万级临时 `String` 分配；
  - `lib/terminal/keyword_highlighter.dart`：复用 `_unitsScratch` / `_columnsScratch` 缓冲区并开放缓存命中计数。
- **商业级压测套组（`apps/client/test/stress/`）实测结果**：
  - **72 小时 × 12 路长连接浸泡压测（`long_connection_soak_stress_test.dart`）**：穿越 5 次半开 NAT 黑洞、52,071 次保活探活、864 次小时级 rekey、50 次前台唤醒探活，恢复率 **100%**，30 路惊群断流竞态与 500 会话日志冲刷均零泄漏；
  - **14.1 MB ANSI/CJK 日志洪流压测（`terminal_throughput_stress_test.dart`）**：11,000 个高频输出包收敛为 276 次终端通知（**通知/重绘风暴削减 97.5%**），端到端解析吞吐 **6.83 MB/s**，10,000 行双语检索耗时 **160ms**，1,200 行关键字高亮耗时 **8ms**（缓存命中率 **99.58%**），24 并发终端压测耗时 **73ms** 且销毁后 RSS 回落；
  - **工作区分屏与折叠屏压测（`session_workspace_stress_test.dart`）**：32 会话 500 次随机分屏树变更 + 40 次极端视口尺寸（含 iPhone Duo 折叠/展开与 320px 极窄分屏）切换零溢出、历史零丢失。

---

## 版本三：`1.0.4 (Build 5)` — 商业运维 UI 质感与高频使用习惯打磨 (`v1.0.4-build5`)

- **生产级粘贴安全护栏（`lib/terminal/paste_safety.dart` + `lib/ui/paste_safety_dialog.dart`）**：
  - 智能区分 `bracketedPasteMode`（`\x1b[?2004h`）：在未开启括号粘贴的传统 Shell / 网络设备中拦截含换行符的自动执行多行粘贴，且在**任何模式下均拦截高危生产命令**（`rm -rf`、`mkfs`、`dd if=`、`shutdown/reboot`、`chmod -R 777`、`iptables -F`、`DROP DATABASE/TABLE`、`FLUSHALL`、`kubectl delete namespace`、`curl|sh`、Fork 炸弹）；
  - 提供「去除回车粘贴（先检查再执行）」「原样粘贴」「取消」三项原生交互，支持四语（中/英/日/俄）并在设置页可一键开关。
- **实时链路健康微标与断线诊断（`workspace_status_bar.dart`, `ios_session_bar.dart`, `session_recovery_overlay.dart`）**：
  - 桌面与平板状态栏呈现等宽数字健康胶囊（`24ms · 2h 14m` / `探活丢包 1/3`），支持点击立即探活；
  - iOS 顶部会话栏状态点按链路健康动态切换翡翠绿 / 琥珀橙 / 告警红，显示紧凑 RTT 微标并在 `…` 菜单提供「立即探活链路」；
  - 断线恢复蒙层清晰展示断线原因（如心跳保活超时）与本会话累计自动恢复次数。
- **主机快速搜索全键盘极速流（`lib/ui/host_search_palette.dart`）**：
  - 新增 `↑` / `↓` / `Ctrl+N` / `Ctrl+P` 切换高亮、`Enter` 直连当前高亮主机、`Esc` 秒关及底部快捷键提示；
  - 新增 `rankHostSearchMatches` 智能排序：名称精确/前缀匹配 > 最近连接时间 > 收藏星标 > 名称序。
- **移动端快捷键栏长按连发（`lib/ui/terminal_keybar.dart`）**：
  - 为 `← ↑ ↓ →`、`⌫` 与 `Del` 接入被动长按连发（380ms 初始延迟 + 55ms 步进连发，横向拖动 > 12px 或松手立即撤除定时器防误触防卡键），同时接入生产粘贴安全护栏。
