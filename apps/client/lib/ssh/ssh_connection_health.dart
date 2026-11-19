import 'package:flutter/foundation.dart';

/// SSH 长连接当前健康等级。
enum SshHealthState {
  /// 正在建连或尚未完成首次探活。
  healthy,

  /// 出现高延迟（>= 500ms）或已有保活探针丢失，链路出现抖动。
  degraded,

  /// 连续丢失保活响应，已判定为半开僵尸链路并触发断开恢复。
  stale,

  /// 连接已关闭。
  closed,
}

/// 单条 SSH 连接的实时健康遥测与运行时长状态（零凭据、零地址泄漏）。
///
/// 供桌面状态栏、iOS 顶部会话栏、断线恢复蒙层及压力/长连诊断测试共同订阅。
class SshConnectionHealth extends ChangeNotifier {
  SshConnectionHealth({
    DateTime Function()? now,
    this.highLatencyThreshold = const Duration(milliseconds: 500),
    this.maxMissedThreshold = 3,
  }) : _now = now ?? _utcNow,
       connectedAt = (now ?? _utcNow)(),
       _lastActivityAt = (now ?? _utcNow)();

  static DateTime _utcNow() => DateTime.now().toUtc();

  final DateTime Function() _now;

  /// 触发「链路抖动 (degraded)」告警的单次 RTT 阈值。
  final Duration highLatencyThreshold;

  /// 连续丢失探针判定僵死的阈值（用于对外汇报诊断状态）。
  final int maxMissedThreshold;

  /// 建连完成时间（UTC）。
  final DateTime connectedAt;

  SshHealthState _state = SshHealthState.healthy;
  Duration? _lastRtt;
  Duration? _smoothedRtt;
  int _probesSucceeded = 0;
  int _missedProbes = 0;
  int _totalMissedProbes = 0;
  int _rekeyCount = 0;
  DateTime? _lastRekeyAt;
  int _bytesReceived = 0;
  int _bytesSent = 0;
  DateTime _lastActivityAt;
  bool _keepaliveTimedOut = false;
  bool _disposed = false;

  SshHealthState get state => _state;
  Duration? get lastRtt => _lastRtt;
  Duration? get smoothedRtt => _smoothedRtt;
  int get probesSucceeded => _probesSucceeded;
  int get missedProbes => _missedProbes;
  int get totalMissedProbes => _totalMissedProbes;
  int get rekeyCount => _rekeyCount;
  DateTime? get lastRekeyAt => _lastRekeyAt;
  int get bytesReceived => _bytesReceived;
  int get bytesSent => _bytesSent;
  DateTime get lastActivityAt => _lastActivityAt;
  bool get keepaliveTimedOut => _keepaliveTimedOut;

  /// 当前连接持续在线时长（时钟回拨时自动钳制为非负）。
  Duration get uptime {
    final delta = _now().difference(connectedAt);
    return delta.isNegative ? Duration.zero : delta;
  }

  /// 距最近一次流量或保活响应的空闲时长。
  Duration get idleDuration {
    final delta = _now().difference(_lastActivityAt);
    return delta.isNegative ? Duration.zero : delta;
  }

  void recordProbeSuccess(Duration rtt) {
    if (_disposed || _state == SshHealthState.closed) return;
    final safeRtt = rtt.isNegative ? Duration.zero : rtt;
    _lastRtt = safeRtt;
    _smoothedRtt = _smoothedRtt == null
        ? safeRtt
        : Duration(
            microseconds:
                ((safeRtt.inMicroseconds * 3 +
                            _smoothedRtt!.inMicroseconds * 7) /
                        10)
                    .round(),
          );
    _probesSucceeded++;
    _missedProbes = 0;
    _lastActivityAt = _now();
    _state = safeRtt >= highLatencyThreshold
        ? SshHealthState.degraded
        : SshHealthState.healthy;
    notifyListeners();
  }

  void recordProbeMissed(int consecutiveMissed) {
    if (_disposed || _state == SshHealthState.closed) return;
    _missedProbes = consecutiveMissed;
    _totalMissedProbes++;
    _state = consecutiveMissed >= maxMissedThreshold
        ? SshHealthState.stale
        : SshHealthState.degraded;
    notifyListeners();
  }

  void recordKeepaliveDead() {
    if (_disposed) return;
    _keepaliveTimedOut = true;
    if (_state != SshHealthState.closed) {
      _state = SshHealthState.stale;
    }
    notifyListeners();
  }

  void recordRekeySuccess() {
    if (_disposed || _state == SshHealthState.closed) return;
    _rekeyCount++;
    _lastRekeyAt = _now();
    notifyListeners();
  }

  /// 高频流量路径仅更新计数器，避免每包触发 UI 重绘风暴。
  void recordBytesReceived(int bytes) {
    if (bytes <= 0 || _disposed) return;
    _bytesReceived += bytes;
    _lastActivityAt = _now();
  }

  /// 高频按键发送路径仅更新计数器，不触发同步 UI 通知。
  void recordBytesSent(int bytes) {
    if (bytes <= 0 || _disposed) return;
    _bytesSent += bytes;
    _lastActivityAt = _now();
  }

  void markClosed() {
    if (_disposed || _state == SshHealthState.closed) return;
    _state = SshHealthState.closed;
    notifyListeners();
  }

  /// 输出无敏感信息的纯数值诊断快照，可用于日志排查或自动化压测断言。
  Map<String, Object?> toDiagnosticSnapshot() => <String, Object?>{
    'state': _state.name,
    'uptimeSeconds': uptime.inSeconds,
    'idleSeconds': idleDuration.inSeconds,
    'lastRttMs': _lastRtt?.inMilliseconds,
    'smoothedRttMs': _smoothedRtt?.inMilliseconds,
    'probesSucceeded': _probesSucceeded,
    'missedProbes': _missedProbes,
    'totalMissedProbes': _totalMissedProbes,
    'rekeyCount': _rekeyCount,
    'bytesReceived': _bytesReceived,
    'bytesSent': _bytesSent,
    'keepaliveTimedOut': _keepaliveTimedOut,
  };

  /// 紧凑格式化运行时长（例如 `42s`、`12m`、`3h 18m`、`2d 4h`），供状态栏展示。
  static String formatUptime(Duration duration) {
    final totalSeconds = duration.inSeconds < 0 ? 0 : duration.inSeconds;
    if (totalSeconds < 60) return '${totalSeconds}s';
    final totalMinutes = totalSeconds ~/ 60;
    if (totalMinutes < 60) return '${totalMinutes}m';
    final totalHours = totalMinutes ~/ 60;
    final remMinutes = totalMinutes % 60;
    if (totalHours < 24) {
      return remMinutes == 0 ? '${totalHours}h' : '${totalHours}h ${remMinutes}m';
    }
    final days = totalHours ~/ 24;
    final remHours = totalHours % 24;
    return remHours == 0 ? '${days}d' : '${days}d ${remHours}h';
  }

  /// 紧凑格式化往返延迟（例如 `<1ms`、`24ms`、`1.2s`）。
  static String formatRtt(Duration rtt) {
    final ms = rtt.inMilliseconds;
    if (ms < 1) return '<1ms';
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
