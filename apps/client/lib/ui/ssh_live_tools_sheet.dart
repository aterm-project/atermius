import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../ssh/ssh_live_tools.dart';
import '../ssh/ssh_service.dart';
import 'app_density.dart';
import 'app_theme.dart';
import 'ios_native/ios_native.dart';
import 'surfaces.dart';

/// 四语在线 SSH 诊断小工具菜单文案。
String sshLiveToolsMenuLabel(BuildContext context) => switch (
  Localizations.localeOf(context).languageCode
) {
  'zh' => 'SSH 诊断小工具',
  'ja' => 'SSH 診断ツール',
  'ru' => 'Диагностика SSH',
  _ => 'SSH Live Tools',
};

/// 弹出只读「在线 SSH 诊断小工具」工作台，在不干扰交互终端的情况下快速巡检远端主机。
Future<void> showSshLiveToolsSheet(
  BuildContext context, {
  required HostRecord host,
  required SshConnection connection,
}) {
  if (isIosPhone(context)) {
    return showIosDetentSheet<void>(
      context,
      detents: const [0.78, 0.94],
      initial: 0.78,
      builder: (sheetContext, scrollController) => _SshLiveToolsView(
        host: host,
        connection: connection,
        scrollController: scrollController,
        iosCompact: true,
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final size = MediaQuery.sizeOf(dialogContext);
      final p = dialogContext.palette;
      // The sheet is the canvas its blocks sit on: no outline, the dialog
      // radius, never glass (it floats over the terminal).
      final radius = BorderRadius.circular(
        AppDensity.of(dialogContext).radiusDialog,
      );
      return Dialog(
        backgroundColor: p.background,
        shape: RoundedRectangleBorder(borderRadius: radius),
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: math.min(720, size.width - 48),
          height: math.min(640, size.height - 48),
          child: ClipRRect(
            borderRadius: radius,
            child: _SshLiveToolsView(
              host: host,
              connection: connection,
              iosCompact: false,
            ),
          ),
        ),
      );
    },
  );
}

enum _LiveToolTab { overview, network, processes, logs }

class _SshLiveToolsView extends StatefulWidget {
  const _SshLiveToolsView({
    required this.host,
    required this.connection,
    required this.iosCompact,
    this.scrollController,
  });

  final HostRecord host;
  final SshConnection connection;
  final bool iosCompact;
  final ScrollController? scrollController;

  @override
  State<_SshLiveToolsView> createState() => _SshLiveToolsViewState();
}

class _SshLiveToolsViewState extends State<_SshLiveToolsView> {
  _LiveToolTab _tab = _LiveToolTab.overview;
  bool _loading = false;
  bool _copied = false;
  String? _error;
  SshExecCancellation? _activeCancel;

  Map<String, Object?>? _overview;
  Map<String, Object?>? _network;
  Map<String, Object?>? _processes;
  Map<String, Object?>? _logs;

  String _netMode = 'listening_ports';
  String _procSort = 'cpu';
  String _logSource = 'journal';

  final _tcpHostCtrl = TextEditingController(text: '127.0.0.1');
  final _tcpPortCtrl = TextEditingController(text: '5432');
  final _unitCtrl = TextEditingController(text: 'sshd');
  final _pathCtrl = TextEditingController(text: '/var/log/syslog');
  final _filterCtrl = TextEditingController();

  String _t({
    required String zh,
    required String en,
    required String ja,
    required String ru,
  }) => switch (Localizations.localeOf(context).languageCode) {
    'zh' => zh,
    'ja' => ja,
    'ru' => ru,
    _ => en,
  };

  @override
  void initState() {
    super.initState();
    unawaited(_runCurrentTab());
  }

  @override
  void dispose() {
    _activeCancel?.cancel();
    _tcpHostCtrl.dispose();
    _tcpPortCtrl.dispose();
    _unitCtrl.dispose();
    _pathCtrl.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  Future<void> _runCurrentTab() async {
    _activeCancel?.cancel();
    final cancel = SshExecCancellation();
    _activeCancel = cancel;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _copied = false;
      });
    }
    try {
      switch (_tab) {
        case _LiveToolTab.overview:
          final data = await SshLiveTools.systemOverview(
            widget.connection,
            cancellation: cancel,
          );
          if (mounted && identical(_activeCancel, cancel)) {
            setState(() => _overview = data);
          }
        case _LiveToolTab.network:
          final port = int.tryParse(_tcpPortCtrl.text.trim());
          final data = await SshLiveTools.networkProbe(
            widget.connection,
            mode: _netMode,
            host: _netMode == 'tcp_check' ? _tcpHostCtrl.text : null,
            port: _netMode == 'tcp_check' ? port : null,
            cancellation: cancel,
          );
          if (mounted && identical(_activeCancel, cancel)) {
            setState(() => _network = data);
          }
        case _LiveToolTab.processes:
          final data = await SshLiveTools.processSnapshot(
            widget.connection,
            sortBy: _procSort,
            limit: 15,
            cancellation: cancel,
          );
          if (mounted && identical(_activeCancel, cancel)) {
            setState(() => _processes = data);
          }
        case _LiveToolTab.logs:
          final data = await SshLiveTools.serviceLogs(
            widget.connection,
            source: _logSource,
            unit: _logSource == 'journal' ? _unitCtrl.text : null,
            path: _logSource == 'file' ? _pathCtrl.text : null,
            lines: 80,
            contains: _filterCtrl.text,
            cancellation: cancel,
          );
          if (mounted && identical(_activeCancel, cancel)) {
            setState(() => _logs = data);
          }
      }
    } on SshLiveToolAbortedException catch (e) {
      if (mounted && identical(_activeCancel, cancel) && !e.cancelled) {
        setState(
          () => _error = _t(
            zh: '远端诊断超时，请重试。',
            en: 'Remote diagnostic probe timed out.',
            ja: '診断プローブがタイムアウトしました。',
            ru: 'Превышено время ожидания диагностики.',
          ),
        );
      }
    } on FormatException catch (e) {
      if (mounted && identical(_activeCancel, cancel)) {
        setState(() => _error = e.message);
      }
    } on Object catch (e) {
      if (mounted && identical(_activeCancel, cancel)) {
        setState(() => _error = '$e');
      }
    } finally {
      if (mounted && identical(_activeCancel, cancel)) {
        setState(() => _loading = false);
      }
    }
  }

  Map<String, Object?>? get _currentPayload => switch (_tab) {
    _LiveToolTab.overview => _overview,
    _LiveToolTab.network => _network,
    _LiveToolTab.processes => _processes,
    _LiveToolTab.logs => _logs,
  };

  Future<void> _copyPayload() async {
    final payload = _currentPayload;
    if (payload == null) return;
    final text = const JsonEncoder.withIndent('  ').convert(payload);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bodyList = ListView(
      controller: widget.scrollController,
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        MediaQuery.paddingOf(context).bottom + 20,
      ),
      children: [
        if (_tab == _LiveToolTab.network) _buildNetworkControls(p),
        if (_tab == _LiveToolTab.processes) _buildProcessControls(p),
        if (_tab == _LiveToolTab.logs) _buildLogControls(p),
        if (_loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Column(
                children: [
                  const CupertinoActivityIndicator(),
                  const SizedBox(height: 10),
                  Text(
                    _t(
                      zh: '正在通过独立 SSH 只读通道探测…',
                      en: 'Running read-only SSH probe…',
                      ja: '読み取り専用 SSH プローブを実行中…',
                      ru: 'Выполняется read-only опрос SSH…',
                    ),
                    style: TextStyle(color: p.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          )
        else if (_error != null)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.errorContainer,
              borderRadius: _blockRadius,
            ),
            child: Text(
              _error!,
              style: TextStyle(color: p.onErrorContainer, fontSize: 13),
            ),
          )
        else
          _buildResultBody(p),
      ],
    );

    return Column(
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            widget.iosCompact ? 4 : 16,
            12,
            8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _t(
                        zh: '在线 SSH 诊断小工具',
                        en: 'Live SSH Diagnostics',
                        ja: 'ライブ SSH 診断',
                        ru: 'Живая диагностика SSH',
                      ),
                      style: TextStyle(
                        color: p.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${widget.host.name} · ${widget.host.endpoint} · read-only',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: _t(zh: '复制 JSON', en: 'Copy JSON', ja: 'JSON をコピー', ru: 'Копировать JSON'),
                onPressed: _currentPayload == null ? null : _copyPayload,
                icon: Icon(
                  _copied ? IosIcons.check : IosIcons.copy,
                  size: 18,
                  color: _copied ? p.accent : p.text,
                ),
              ),
              IconButton(
                tooltip: _t(zh: '刷新', en: 'Refresh', ja: '更新', ru: 'Обновить'),
                onPressed: _loading ? null : _runCurrentTab,
                icon: Icon(Icons.refresh_rounded, size: 18, color: p.text),
              ),
              IconButton(
                tooltip: _t(zh: '关闭', en: 'Close', ja: '閉じる', ru: 'Закрыть'),
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(IosIcons.clear, size: 20, color: p.muted),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<_LiveToolTab>(
              groupValue: _tab,
              children: {
                _LiveToolTab.overview: Text(
                  _t(zh: '概览', en: 'System', ja: '概要', ru: 'Система'),
                  style: const TextStyle(fontSize: 12.5),
                ),
                _LiveToolTab.network: Text(
                  _t(zh: '网络', en: 'Network', ja: '通信', ru: 'Сеть'),
                  style: const TextStyle(fontSize: 12.5),
                ),
                _LiveToolTab.processes: Text(
                  _t(zh: '进程', en: 'Processes', ja: 'プロセス', ru: 'Процессы'),
                  style: const TextStyle(fontSize: 12.5),
                ),
                _LiveToolTab.logs: Text(
                  _t(zh: '日志', en: 'Logs', ja: 'ログ', ru: 'Логи'),
                  style: const TextStyle(fontSize: 12.5),
                ),
              },
              onValueChanged: (next) {
                if (next == null || next == _tab) return;
                setState(() => _tab = next);
                final existing = _currentPayload;
                if (existing == null) {
                  unawaited(_runCurrentTab());
                } else {
                  setState(() => _error = null);
                }
              },
            ),
          ),
        ),
        Expanded(child: bodyList),
      ],
    );
  }

  /// Blocks sit 16 px inside the sheet's edge: the concentric radius.
  BorderRadius get _blockRadius {
    final density = AppDensity.of(context);
    return BorderRadius.circular(
      concentricRadius(density.radiusDialog, 16, floor: density.radiusMd),
    );
  }

  Widget _buildNetworkControls(AppPalette p) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: _blockRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text(_t(zh: '本机监听端口', en: 'Listening Ports', ja: '待受ポート', ru: 'Порты')),
                selected: _netMode == 'listening_ports',
                onSelected: (_) {
                  setState(() => _netMode = 'listening_ports');
                  unawaited(_runCurrentTab());
                },
              ),
              ChoiceChip(
                label: Text(_t(zh: 'TCP 连通探测', en: 'TCP Check', ja: 'TCP 疎通', ru: 'TCP проверка')),
                selected: _netMode == 'tcp_check',
                onSelected: (_) => setState(() => _netMode = 'tcp_check'),
              ),
            ],
          ),
          if (_netMode == 'tcp_check') ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _tcpHostCtrl,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: _t(zh: '目标主机/IP', en: 'Host', ja: 'ホスト', ru: 'Хост'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 1,
                  child: TextField(
                    controller: _tcpPortCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: _t(zh: '端口', en: 'Port', ja: 'ポート', ru: 'Порт'),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _loading ? null : _runCurrentTab,
                  child: Text(_t(zh: '探测', en: 'Run', ja: '実行', ru: 'Пуск')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProcessControls(AppPalette p) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            label: Text(_t(zh: '按 CPU 排序', en: 'Sort by CPU', ja: 'CPU 順', ru: 'По CPU')),
            selected: _procSort == 'cpu',
            onSelected: (_) {
              setState(() => _procSort = 'cpu');
              unawaited(_runCurrentTab());
            },
          ),
          ChoiceChip(
            label: Text(_t(zh: '按内存排序', en: 'Sort by Memory', ja: 'メモリ順', ru: 'По RAM')),
            selected: _procSort == 'memory',
            onSelected: (_) {
              setState(() => _procSort = 'memory');
              unawaited(_runCurrentTab());
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLogControls(AppPalette p) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: _blockRadius,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('journalctl'),
                selected: _logSource == 'journal',
                onSelected: (_) => setState(() => _logSource = 'journal'),
              ),
              ChoiceChip(
                label: Text(_t(zh: '日志文件', en: 'Log File', ja: 'ログファイル', ru: 'Файл лога')),
                selected: _logSource == 'file',
                onSelected: (_) => setState(() => _logSource = 'file'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _logSource == 'journal' ? _unitCtrl : _pathCtrl,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: _logSource == 'journal'
                        ? 'Systemd Unit'
                        : _t(zh: '绝对路径', en: 'Absolute Path', ja: '絶対パス', ru: 'Путь'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _filterCtrl,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: _t(zh: '过滤词', en: 'Filter', ja: '絞り込み', ru: 'Фильтр'),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _loading ? null : _runCurrentTab,
                child: Text(_t(zh: '读取', en: 'Fetch', ja: '取得', ru: 'Читать')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResultBody(AppPalette p) {
    switch (_tab) {
      case _LiveToolTab.overview:
        final data = _overview;
        if (data == null) return const SizedBox.shrink();
        final mem = data['memory'] as Map<String, Object?>?;
        final disk = data['disk_root'] as Map<String, Object?>?;
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: _blockRadius,
          ),
          child: Column(
            children: [
              _kvRow(p, _t(zh: '主机名', en: 'Hostname', ja: 'ホスト名', ru: 'Имя хоста'), '${data['hostname'] ?? '-'}'),
              _kvRow(p, _t(zh: '操作系统', en: 'OS', ja: 'OS', ru: 'ОС'), '${data['os'] ?? '-'}'),
              _kvRow(p, _t(zh: '内核 / 架构', en: 'Kernel / Arch', ja: 'カーネル / アーキ', ru: 'Ядро / Арх'), '${data['kernel'] ?? '-'} · ${data['arch'] ?? '-'}'),
              _kvRow(p, _t(zh: 'CPU 核心', en: 'CPU Cores', ja: 'CPU コア数', ru: 'Ядра CPU'), '${data['cpu_cores'] ?? '-'}'),
              _kvRow(p, _t(zh: '系统负载', en: 'Load Average', ja: 'ロードアベレージ', ru: 'Нагрузка'), '${data['load_average'] ?? '-'}'),
              if (mem != null)
                _kvRow(
                  p,
                  _t(zh: '内存', en: 'Memory', ja: 'メモリ', ru: 'Память'),
                  mem['used_mb'] != null
                      ? '${mem['used_mb']} / ${mem['total_mb']} MB'
                      : '${mem['available_mb'] ?? '-'} free / ${mem['total_mb'] ?? '-'} MB',
                ),
              if (disk != null)
                _kvRow(
                  p,
                  _t(zh: '根分区磁盘', en: 'Root Disk', ja: 'ルートディスク', ru: 'Диск /'),
                  '${disk['capacity'] ?? '-'} (${disk['mount'] ?? '/'})',
                ),
              _kvRow(p, _t(zh: '运行时间', en: 'Uptime', ja: '稼働時間', ru: 'Аптайм'), '${data['uptime'] ?? '-'}', last: true),
            ],
          ),
        );
      case _LiveToolTab.network:
        final data = _network;
        if (data == null) return const SizedBox.shrink();
        if (data['mode'] == 'tcp_check') {
          final reachable = data['reachable'] == true;
          // Reachable tints the block toward the accent (no outline).
          return Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: reachable ? p.tinted(p.accent) : p.surface,
              borderRadius: _blockRadius,
            ),
            child: Row(
              children: [
                Icon(
                  reachable ? IosIcons.success : IosIcons.warning,
                  color: reachable ? p.accent : p.red,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${data['host']}:${data['port']} → ${'${data['status']}'.toUpperCase()}',
                    style: TextStyle(
                      color: p.text,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'Menlo',
                    ),
                  ),
                ),
              ],
            ),
          );
        }
        final listeners = (data['listeners'] as List? ?? const [])
            .cast<Map<String, String>>();
        return _monoBlock(
          p,
          listeners.isEmpty
              ? (data['raw'] as String? ?? '-')
              : [
                  for (final row in listeners)
                    '${(row['proto'] ?? '').padRight(6)} ${(row['local'] ?? '').padRight(26)} ${row['state'] ?? ''}',
                ].join('\n'),
        );
      case _LiveToolTab.processes:
        final data = _processes;
        if (data == null) return const SizedBox.shrink();
        final items = (data['items'] as List? ?? const [])
            .cast<Map<String, Object?>>();
        return _monoBlock(
          p,
          items.isEmpty
              ? '-'
              : [
                  'PID     USER         %CPU   %MEM  COMMAND',
                  for (final item in items)
                    '${'${item['pid']}'.padRight(7)} '
                        '${'${item['user']}'.padRight(12)} '
                        '${'${item['cpu_percent']}'.padLeft(5)} '
                        '${'${item['mem_percent']}'.padLeft(6)}  '
                        '${item['command']}',
                ].join('\n'),
        );
      case _LiveToolTab.logs:
        final data = _logs;
        if (data == null) return const SizedBox.shrink();
        final text = data['journalctl_available'] == false
            ? _t(
                zh: '目标主机未安装 journalctl，请切换为「日志文件」读取绝对路径。',
                en: 'journalctl is unavailable on this host; switch to Log File.',
                ja: 'このホストでは journalctl が利用できません。ログファイルをお試しください。',
                ru: 'journalctl недоступен на сервере; переключитесь на «Файл лога».',
              )
            : ((data['text'] as String?)?.trim().isNotEmpty == true
                  ? data['text'] as String
                  : _t(zh: '（无匹配日志行）', en: '(no matching log lines)', ja: '（一致するログなし）', ru: '(нет совпадений)'));
        return _monoBlock(p, text);
    }
  }

  Widget _kvRow(AppPalette p, String label, String value, {bool last = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      // A soft rule between rows inside the one block.
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: p.separator)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: Text(label, style: TextStyle(color: p.muted, fontSize: 12.5)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                color: p.text,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _monoBlock(AppPalette p, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.codeBackground,
        borderRadius: _blockRadius,
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          color: p.codeText,
          fontSize: 11.5,
          height: 1.4,
          fontFamily: 'Menlo',
        ),
      ),
    );
  }
}
