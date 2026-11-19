import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'ssh_service.dart';

/// 在线 SSH 诊断小工具单次输出最大字节数（与 MCP 工具输出上限保持一致）。
const int sshLiveToolsMaxOutputBytes = 64 * 1024;

final RegExp _safeHostPattern = RegExp(r'^[A-Za-z0-9._:-]{1,253}$');
final RegExp _safeUnitPattern = RegExp(r'^[A-Za-z0-9@._:-]{1,128}$');
final RegExp _controlCharsPattern = RegExp(r'[\x00-\x1f\x7f]');

/// 严格转义单引号 POSIX Shell 参数。
String _posixSingleQuote(String value) {
  return "'${value.replaceAll("'", "'\\''")}'";
}

/// 在线 SSH 只读诊断小工具引擎。
///
/// 所有操作均通过独立 [SshConnection.executeRemoteCommand] Exec 通道执行：
/// - 绝不向交互式 PTY 终端写入按键；
/// - 绝不拼接未校验用户输入至 Shell 命令；
/// - 严格只读，支持 [SshExecCancellation] 随时取消。
abstract final class SshLiveTools {
  static const Duration defaultTimeout = Duration(seconds: 15);

  /// 1. 采集远端主机系统概览（主机名、OS、内核、架构、运行时间、负载、CPU、内存与根分区磁盘）。
  static Future<Map<String, Object?>> systemOverview(
    SshConnection connection, {
    SshExecCancellation? cancellation,
    Duration timeout = defaultTimeout,
  }) async {
    final token = cancellation ?? SshExecCancellation();
    final res = await connection.executeRemoteCommand(
      buildSystemOverviewCommand(),
      cancellation: token,
      timeout: timeout,
      maxOutputBytes: sshLiveToolsMaxOutputBytes,
    );
    _throwIfAborted(res);
    return parseSystemOverviewOutput(
      res.stdout,
      truncated: res.outputTruncated,
      stderr: res.stderr,
    );
  }

  /// 2. 执行网络监听端口检查或目标主机 TCP 连通性探测。
  static Future<Map<String, Object?>> networkProbe(
    SshConnection connection, {
    required String mode,
    String? host,
    int? port,
    SshExecCancellation? cancellation,
    Duration timeout = defaultTimeout,
  }) async {
    final cmd = buildNetworkProbeCommand(mode: mode, host: host, port: port);
    final token = cancellation ?? SshExecCancellation();
    final res = await connection.executeRemoteCommand(
      cmd,
      cancellation: token,
      timeout: timeout,
      maxOutputBytes: sshLiveToolsMaxOutputBytes,
    );
    _throwIfAborted(res);
    return parseNetworkProbeOutput(
      mode: mode,
      stdout: res.stdout,
      stderr: res.stderr,
      exitCode: res.exitCode,
      host: host,
      port: port,
      truncated: res.outputTruncated,
    );
  }

  /// 3. 采集远端当前资源占用 Top 进程快照。
  static Future<Map<String, Object?>> processSnapshot(
    SshConnection connection, {
    String sortBy = 'cpu',
    int limit = 15,
    SshExecCancellation? cancellation,
    Duration timeout = defaultTimeout,
  }) async {
    final cmd = buildProcessSnapshotCommand(sortBy: sortBy, limit: limit);
    final token = cancellation ?? SshExecCancellation();
    final res = await connection.executeRemoteCommand(
      cmd,
      cancellation: token,
      timeout: timeout,
      maxOutputBytes: sshLiveToolsMaxOutputBytes,
    );
    _throwIfAborted(res);
    return parseProcessSnapshotOutput(
      res.stdout,
      sortBy: sortBy,
      limit: limit,
      truncated: res.outputTruncated,
      stderr: res.stderr,
    );
  }

  /// 4. 读取只读服务日志（systemd journal 或绝对路径文本日志尾行，可选关键字在本地过滤）。
  static Future<Map<String, Object?>> serviceLogs(
    SshConnection connection, {
    required String source,
    String? unit,
    String? path,
    int lines = 80,
    String? contains,
    SshExecCancellation? cancellation,
    Duration timeout = defaultTimeout,
  }) async {
    if (contains != null &&
        (contains.length > 256 || _controlCharsPattern.hasMatch(contains))) {
      throw const FormatException('Invalid log filter string.');
    }
    final cmd = buildServiceLogsCommand(
      source: source,
      unit: unit,
      path: path,
      lines: lines,
    );
    final token = cancellation ?? SshExecCancellation();
    final res = await connection.executeRemoteCommand(
      cmd,
      cancellation: token,
      timeout: timeout,
      maxOutputBytes: sshLiveToolsMaxOutputBytes,
    );
    _throwIfAborted(res);
    return parseServiceLogsOutput(
      res.stdout,
      source: source,
      unit: unit,
      path: path,
      contains: contains,
      stderr: res.stderr,
      exitCode: res.exitCode,
      truncated: res.outputTruncated,
    );
  }

  static void _throwIfAborted(SshExecResult res) {
    if (res.cancelled) {
      throw const SshLiveToolAbortedException(
        cancelled: true,
        timedOut: false,
      );
    }
    if (res.timedOut) {
      throw const SshLiveToolAbortedException(
        cancelled: false,
        timedOut: true,
      );
    }
  }

  @visibleForTesting
  static String buildSystemOverviewCommand() {
    return '''
printf '__AT_HOST__='; hostname 2>/dev/null || uname -n
printf '__AT_KERNEL__='; uname -r
printf '__AT_ARCH__='; uname -m
printf '__AT_OS__='; if [ -r /etc/os-release ]; then . /etc/os-release 2>/dev/null; printf '%s\\n' "\${PRETTY_NAME:-\${NAME:-Linux}}"; else uname -s; fi
printf '__AT_UPTIME__='; uptime 2>/dev/null | tr '\\n' ' '; echo ''
printf '__AT_LOAD__='; if [ -r /proc/loadavg ]; then cut -d' ' -f1-3 /proc/loadavg; else sysctl -n vm.loadavg 2>/dev/null || echo ''; fi
printf '__AT_CORES__='; nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo ''
printf '__AT_MEM_START__\\n'
if command -v free >/dev/null 2>&1; then free -m 2>/dev/null; elif [ -r /proc/meminfo ]; then head -n 5 /proc/meminfo; fi
printf '__AT_MEM_END__\\n'
printf '__AT_DISK_START__\\n'
df -Pk / 2>/dev/null || df -k / 2>/dev/null
printf '__AT_DISK_END__\\n'
'''
        .trim();
  }

  @visibleForTesting
  static String validateTcpHost(String? host) {
    final trimmed = host?.trim() ?? '';
    if (trimmed.isEmpty ||
        trimmed.startsWith('-') ||
        !_safeHostPattern.hasMatch(trimmed)) {
      throw const FormatException(
        'Invalid target host: only [A-Za-z0-9._:-] up to 253 chars is allowed.',
      );
    }
    return trimmed;
  }

  @visibleForTesting
  static int validateTcpPort(int? port) {
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('Port must be between 1 and 65535.');
    }
    return port;
  }

  @visibleForTesting
  static String validateJournalUnit(String? unit) {
    final trimmed = unit?.trim() ?? '';
    if (trimmed.isEmpty ||
        trimmed.startsWith('-') ||
        !_safeUnitPattern.hasMatch(trimmed)) {
      throw const FormatException(
        'Invalid systemd unit name: only [A-Za-z0-9@._:-] is allowed.',
      );
    }
    return trimmed;
  }

  @visibleForTesting
  static String validateLogFilePath(String? path) {
    final value = path ?? '';
    if (!value.startsWith('/') ||
        value.length > 4096 ||
        _controlCharsPattern.hasMatch(value)) {
      throw const FormatException(
        'Log file path must be an absolute path without control characters.',
      );
    }
    return value;
  }

  static String buildNetworkProbeCommand({
    required String mode,
    String? host,
    int? port,
  }) {
    switch (mode) {
      case 'listening_ports':
        return '''
if command -v ss >/dev/null 2>&1; then
  printf '__AT_TOOL__=ss\\n'
  ss -tuln 2>/dev/null | head -n 120
elif command -v netstat >/dev/null 2>&1; then
  printf '__AT_TOOL__=netstat\\n'
  netstat -tuln 2>/dev/null | head -n 120 || netstat -an 2>/dev/null | grep LISTEN | head -n 120
elif command -v sockstat >/dev/null 2>&1; then
  printf '__AT_TOOL__=sockstat\\n'
  sockstat -l 2>/dev/null | head -n 120
else
  printf '__AT_TOOL__=none\\n'
fi
'''
            .trim();
      case 'tcp_check':
        final safeHost = validateTcpHost(host);
        final safePort = validateTcpPort(port);
        final qHost = _posixSingleQuote(safeHost);
        return '''
if command -v nc >/dev/null 2>&1; then
  if nc -z -w 4 $qHost $safePort >/dev/null 2>&1; then
    printf '__AT_TCP__=OPEN\\n'
  else
    printf '__AT_TCP__=CLOSED\\n'
  fi
elif command -v python3 >/dev/null 2>&1; then
  python3 -c 'import socket,sys; s=socket.create_connection((sys.argv[1],int(sys.argv[2])),4); s.close()' $qHost $safePort >/dev/null 2>&1 && printf '__AT_TCP__=OPEN\\n' || printf '__AT_TCP__=CLOSED\\n'
elif command -v timeout >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
  if timeout 4 bash -c 'exec 3<>"/dev/tcp/\$1/\$2"' _ $qHost $safePort >/dev/null 2>&1; then
    printf '__AT_TCP__=OPEN\\n'
  else
    printf '__AT_TCP__=CLOSED\\n'
  fi
else
  printf '__AT_TCP__=UNSUPPORTED\\n'
fi
'''
            .trim();
      default:
        throw FormatException('Unsupported network probe mode: $mode');
    }
  }

  static String buildProcessSnapshotCommand({
    String sortBy = 'cpu',
    int limit = 15,
  }) {
    if (sortBy != 'cpu' && sortBy != 'memory') {
      throw FormatException('sortBy must be "cpu" or "memory": $sortBy');
    }
    if (limit < 1 || limit > 50) {
      throw RangeError.range(limit, 1, 50, 'limit');
    }
    final sortFlag = sortBy == 'memory' ? '-pmem' : '-pcpu';
    final fetchRows = math.max(limit * 3, 60);
    return '''
if ps -eo pid=,user=,%cpu=,%mem=,args= --sort=$sortFlag >/dev/null 2>&1; then
  ps -eo pid=,user=,%cpu=,%mem=,args= --sort=$sortFlag 2>/dev/null | head -n $fetchRows
else
  ps -axo pid=,user=,%cpu=,%mem=,comm= 2>/dev/null | head -n $fetchRows
fi
'''
        .trim();
  }

  static String buildServiceLogsCommand({
    required String source,
    String? unit,
    String? path,
    int lines = 80,
  }) {
    if (lines < 1 || lines > 500) {
      throw RangeError.range(lines, 1, 500, 'lines');
    }
    switch (source) {
      case 'journal':
        final safeUnit = validateJournalUnit(unit);
        final qUnit = _posixSingleQuote(safeUnit);
        return 'if command -v journalctl >/dev/null 2>&1; then '
            'journalctl -u $qUnit -n $lines --no-pager -o short-iso 2>&1; '
            "else printf '__AT_NO_JOURNAL__\\n'; fi";
      case 'file':
        final safePath = validateLogFilePath(path);
        final qPath = _posixSingleQuote(safePath);
        return 'tail -n $lines -- $qPath 2>&1';
      default:
        throw FormatException('Unsupported log source: $source');
    }
  }

  @visibleForTesting
  static Map<String, Object?> parseSystemOverviewOutput(
    String stdout, {
    bool truncated = false,
    String stderr = '',
  }) {
    String? single(String prefix) {
      for (final line in LineSplitter.split(stdout)) {
        if (line.startsWith(prefix)) {
          final v = line.substring(prefix.length).trim();
          return v.isEmpty ? null : v;
        }
      }
      return null;
    }

    String block(String startMarker, String endMarker) {
      final start = stdout.indexOf(startMarker);
      final end = stdout.indexOf(endMarker);
      if (start < 0 || end <= start) return '';
      return stdout.substring(start + startMarker.length, end).trim();
    }

    final memText = block('__AT_MEM_START__', '__AT_MEM_END__');
    final diskText = block('__AT_DISK_START__', '__AT_DISK_END__');

    Map<String, Object?>? memory;
    for (final line in LineSplitter.split(memText)) {
      if (line.startsWith('Mem:')) {
        final cols = line.trim().split(RegExp(r'\s+'));
        if (cols.length >= 4) {
          memory = {
            'total_mb': int.tryParse(cols[1]),
            'used_mb': int.tryParse(cols[2]),
            'free_mb': int.tryParse(cols[3]),
            if (cols.length >= 7) 'available_mb': int.tryParse(cols[6]),
          };
        }
        break;
      }
    }
    if (memory == null && memText.contains('MemTotal:')) {
      int? kbOf(String label) {
        for (final line in LineSplitter.split(memText)) {
          if (line.startsWith(label)) {
            final match = RegExp(r'(\d+)').firstMatch(line);
            return match == null ? null : int.tryParse(match.group(1)!);
          }
        }
        return null;
      }

      final totalKb = kbOf('MemTotal:');
      final availKb = kbOf('MemAvailable:') ?? kbOf('MemFree:');
      if (totalKb != null) {
        memory = {
          'total_mb': totalKb ~/ 1024,
          if (availKb != null) 'available_mb': availKb ~/ 1024,
        };
      }
    }

    Map<String, Object?>? diskRoot;
    final diskLines = LineSplitter.split(diskText)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (diskLines.length >= 2) {
      final cols = diskLines.last.split(RegExp(r'\s+'));
      if (cols.length >= 5) {
        diskRoot = {
          'filesystem': cols[0],
          'blocks_kb': int.tryParse(cols[1]),
          'used_kb': int.tryParse(cols[2]),
          'available_kb': int.tryParse(cols[3]),
          'capacity': cols[4],
          if (cols.length >= 6) 'mount': cols.sublist(5).join(' '),
        };
      }
    }

    final coresRaw = single('__AT_CORES__=');
    return {
      'hostname': single('__AT_HOST__='),
      'os': single('__AT_OS__='),
      'kernel': single('__AT_KERNEL__='),
      'arch': single('__AT_ARCH__='),
      'uptime': single('__AT_UPTIME__='),
      'load_average': single('__AT_LOAD__='),
      'cpu_cores': coresRaw == null ? null : int.tryParse(coresRaw),
      'memory': ?memory,
      'disk_root': ?diskRoot,
      'raw_truncated': truncated,
      if (stderr.trim().isNotEmpty) 'stderr': stderr.trim(),
    };
  }

  @visibleForTesting
  static Map<String, Object?> parseNetworkProbeOutput({
    required String mode,
    required String stdout,
    String stderr = '',
    int? exitCode,
    String? host,
    int? port,
    bool truncated = false,
  }) {
    if (mode == 'tcp_check') {
      final reachable = stdout.contains('__AT_TCP__=OPEN');
      final unsupported = stdout.contains('__AT_TCP__=UNSUPPORTED');
      return {
        'mode': mode,
        'host': host?.trim(),
        'port': port,
        'reachable': unsupported ? null : reachable,
        'status': unsupported
            ? 'unsupported'
            : reachable
            ? 'open'
            : 'closed',
        if (stderr.trim().isNotEmpty) 'stderr': stderr.trim(),
      };
    }

    String tool = 'unknown';
    final lines = <String>[];
    for (final line in LineSplitter.split(stdout)) {
      if (line.startsWith('__AT_TOOL__=')) {
        tool = line.substring('__AT_TOOL__='.length).trim();
        continue;
      }
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) lines.add(trimmed);
    }

    final listeners = <Map<String, String>>[];
    for (final line in lines) {
      if (line.startsWith('Netid') ||
          line.startsWith('Proto') ||
          line.startsWith('Active') ||
          line.startsWith('USER')) {
        continue;
      }
      final cols = line.split(RegExp(r'\s+'));
      if (tool == 'ss' && cols.length >= 5) {
        listeners.add({
          'proto': cols[0],
          'state': cols[1],
          'local': cols[4],
        });
      } else if (cols.length >= 4) {
        listeners.add({
          'proto': cols[0],
          'local': cols[3],
          if (cols.length >= 6) 'state': cols[5],
        });
      }
    }

    return {
      'mode': mode,
      'tool': tool,
      'count': listeners.length,
      'listeners': listeners,
      'raw': lines.join('\n'),
      'raw_truncated': truncated,
      if (stderr.trim().isNotEmpty) 'stderr': stderr.trim(),
    };
  }

  @visibleForTesting
  static Map<String, Object?> parseProcessSnapshotOutput(
    String stdout, {
    String sortBy = 'cpu',
    int limit = 15,
    bool truncated = false,
    String stderr = '',
  }) {
    final items = <Map<String, Object?>>[];
    for (final rawLine in LineSplitter.split(stdout)) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final match = RegExp(
        r'^(\d+)\s+(\S+)\s+([0-9]+(?:\.[0-9]+)?)\s+([0-9]+(?:\.[0-9]+)?)\s+(.+)$',
      ).firstMatch(line);
      if (match == null) continue;
      items.add({
        'pid': int.parse(match.group(1)!),
        'user': match.group(2)!,
        'cpu_percent': double.parse(match.group(3)!),
        'mem_percent': double.parse(match.group(4)!),
        'command': match.group(5)!.trim(),
      });
    }
    items.sort((a, b) {
      final key = sortBy == 'memory' ? 'mem_percent' : 'cpu_percent';
      final cmp = (b[key]! as num).compareTo(a[key]! as num);
      if (cmp != 0) return cmp;
      return (a['pid']! as int).compareTo(b['pid']! as int);
    });
    final capped = items.take(limit).toList(growable: false);
    return {
      'sort_by': sortBy,
      'count': capped.length,
      'items': capped,
      'raw_truncated': truncated,
      if (stderr.trim().isNotEmpty) 'stderr': stderr.trim(),
    };
  }

  @visibleForTesting
  static Map<String, Object?> parseServiceLogsOutput(
    String stdout, {
    required String source,
    String? unit,
    String? path,
    String? contains,
    String stderr = '',
    int? exitCode,
    bool truncated = false,
  }) {
    final missingJournal = stdout.contains('__AT_NO_JOURNAL__');
    var lines = LineSplitter.split(stdout)
        .where((l) => l.trim() != '__AT_NO_JOURNAL__')
        .toList(growable: false);
    final filter = contains?.trim();
    if (filter != null && filter.isNotEmpty) {
      final lower = filter.toLowerCase();
      lines = lines
          .where((line) => line.toLowerCase().contains(lower))
          .toList(growable: false);
    }
    return {
      'source': source,
      if (unit != null) 'unit': unit.trim(),
      'path': ?path,
      if (filter != null && filter.isNotEmpty) 'filter': filter,
      'journalctl_available': !missingJournal,
      'exit_code': exitCode,
      'line_count': lines.length,
      'lines': lines,
      'text': lines.join('\n'),
      'raw_truncated': truncated,
      if (stderr.trim().isNotEmpty) 'stderr': stderr.trim(),
    };
  }
}

/// 在线诊断小工具被用户取消或超时中断时抛出的异常。
class SshLiveToolAbortedException implements Exception {
  const SshLiveToolAbortedException({
    required this.cancelled,
    required this.timedOut,
  });

  final bool cancelled;
  final bool timedOut;

  @override
  String toString() =>
      timedOut ? 'SshLiveToolAbortedException(timedOut)' : 'SshLiveToolAbortedException(cancelled)';
}
