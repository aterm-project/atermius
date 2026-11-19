import 'dart:async';

/// 基于定时探测的 SSH 链路保活看门狗（对齐 OpenSSH `ServerAliveInterval` /
/// `ServerAliveCountMax` 语义）。
///
/// - 周期性调用 [ping] 发送 `keepalive@openssh.com`；
/// - 当配置了 [timeout] 时，单次探测超时即计为一次丢包并触发 [onMissed]；
/// - 连续丢包达到 [maxMissed] 后判定对端为半开僵尸链路，停止定时器并回调 [onDead]；
/// - 支持通过 [probeNow] 在前后台切换 / 设备休眠唤醒时立即发起一次探活，秒级识别断流。
class SSHKeepAlive {
  Timer? _timer;
  Timer? _activeProbeTimer;

  final Duration interval;

  /// 单次保活响应超时；为 null 时退化为无超时限制的旧版周期探活。
  final Duration? timeout;

  /// 判定对端失联前的最大连续超时次数（默认 3，对齐 OpenSSH ServerAliveCountMax）。
  final int maxMissed;

  final Future<void> Function() ping;

  /// 探测成功回调，返回本次保活往返延迟（RTT）。
  final void Function(Duration latency)? onLatency;

  /// 单次探测超时回调，参数为当前连续超时次数。
  final void Function(int missedCount)? onMissed;

  /// 连续超时达到 [maxMissed] 时的僵尸链路判定回调。
  final void Function()? onDead;

  final DateTime Function() _now;

  bool _running = false;
  bool _dead = false;
  bool _awaitingActiveProbe = false;
  int _inFlightCount = 0;
  int _missedCount = 0;
  Duration? _lastLatency;
  Completer<Duration?>? _activeProbeCompleter;
  DateTime? _activeProbeDeadline;
  void Function()? _activeProbeOnTimeout;

  SSHKeepAlive({
    required this.ping,
    this.interval = const Duration(seconds: 10),
    this.timeout,
    this.maxMissed = 3,
    this.onLatency,
    this.onMissed,
    this.onDead,
    DateTime Function()? now,
  })  : assert(maxMissed >= 1, 'maxMissed must be at least 1'),
        _now = now ?? DateTime.now;

  /// 当前连续未响应的探测次数。
  int get missedCount => _missedCount;

  /// 尚未收到响应（含已超时但仍在 FIFO 队列中的）在途探测数。
  int get inFlightCount => _inFlightCount;

  /// 周期看门狗是否正在运行。
  bool get isRunning => _running;

  /// 是否已因连续超时被判定为僵死链路。
  bool get isDead => _dead;

  /// 最近一次成功探活测得的往返延迟。
  Duration? get lastLatency => _lastLatency;

  void start() {
    if (_running || _dead) return;
    _running = true;
    _timer = Timer.periodic(interval, (_) {
      unawaited(_runProbe(timeoutOverride: null));
    });
  }

  /// 立即发起一次带超时的探活（常用于休眠唤醒或 iOS/桌面端切回前台）。
  ///
  /// - 若当前已有周期探活或手动探活在途，则复用同一在途 Future 避免重复叠包；
  /// - 若本次调用的 [timeout] 比在途探活的剩余超时窗口更短，则立即收紧超时定时器，
  ///   确保前台切回能够在期望窗口内快速识别僵尸链路。
  Future<Duration?> probeNow({Duration? timeout}) {
    if (_dead) return Future<Duration?>.value(null);
    final effectiveTimeout = timeout ?? this.timeout ?? const Duration(seconds: 5);
    final activeCompleter = _activeProbeCompleter;
    if (_awaitingActiveProbe &&
        activeCompleter != null &&
        !activeCompleter.isCompleted) {
      _tightenActiveProbeTimeout(effectiveTimeout);
      return activeCompleter.future;
    }
    return _runProbe(timeoutOverride: effectiveTimeout, force: true);
  }

  void _tightenActiveProbeTimeout(Duration timeout) {
    final onTimeout = _activeProbeOnTimeout;
    if (onTimeout == null) return;
    final desiredDeadline = _now().add(timeout);
    final currentDeadline = _activeProbeDeadline;
    if (currentDeadline == null || desiredDeadline.isBefore(currentDeadline)) {
      _activeProbeTimer?.cancel();
      _activeProbeDeadline = desiredDeadline;
      _activeProbeTimer = Timer(timeout, onTimeout);
    }
  }

  Future<Duration?> _runProbe({
    required Duration? timeoutOverride,
    bool force = false,
  }) {
    if (_dead) return Future<Duration?>.value(null);
    if (!force && !_running) return Future<Duration?>.value(null);
    // 已有正在等待超时窗口的在途探测，或未配置超时且已有在途请求时，不重复叠包。
    if (_awaitingActiveProbe) {
      final active = _activeProbeCompleter;
      return active != null ? active.future : Future<Duration?>.value(null);
    }
    final effectiveTimeout = timeoutOverride ?? timeout;
    if (effectiveTimeout == null && _inFlightCount > 0) {
      return Future<Duration?>.value(null);
    }
    if (effectiveTimeout != null && _inFlightCount >= maxMissed) {
      // 在途未回包数已达上限，直接记一次超时以避免无限堆积全局请求队列。
      _recordMissed();
      return Future<Duration?>.value(null);
    }

    final completer = Completer<Duration?>();
    final startedAt = _now();
    var settled = false;
    _inFlightCount++;
    _awaitingActiveProbe = true;
    _activeProbeCompleter = completer;

    void clearActiveTracking() {
      if (identical(_activeProbeCompleter, completer)) {
        _activeProbeCompleter = null;
        _activeProbeDeadline = null;
        _activeProbeOnTimeout = null;
        _activeProbeTimer?.cancel();
        _activeProbeTimer = null;
      }
    }

    void handleTimeout() {
      if (settled) return;
      settled = true;
      _awaitingActiveProbe = false;
      clearActiveTracking();
      _recordMissed();
      if (!completer.isCompleted) completer.complete(null);
    }

    _activeProbeOnTimeout = handleTimeout;
    if (effectiveTimeout != null) {
      _activeProbeDeadline = startedAt.add(effectiveTimeout);
      _activeProbeTimer = Timer(effectiveTimeout, handleTimeout);
    }

    Future<void>.sync(ping).then(
      (_) {
        _inFlightCount = _inFlightCount > 0 ? _inFlightCount - 1 : 0;
        clearActiveTracking();
        if (!settled) {
          settled = true;
          _awaitingActiveProbe = false;
        }
        if (_dead) {
          if (!completer.isCompleted) completer.complete(null);
          return;
        }
        final rawRtt = _now().difference(startedAt);
        final rtt = rawRtt.isNegative ? Duration.zero : rawRtt;
        _missedCount = 0;
        _lastLatency = rtt;
        onLatency?.call(rtt);
        if (!completer.isCompleted) completer.complete(rtt);
      },
      onError: (Object error, StackTrace stackTrace) {
        _inFlightCount = _inFlightCount > 0 ? _inFlightCount - 1 : 0;
        clearActiveTracking();
        if (!settled) {
          settled = true;
          _awaitingActiveProbe = false;
        }
        // 底层传输断开时由 SSHTransport 接管关闭流程，此处仅静默结束探测。
        if (!completer.isCompleted) completer.complete(null);
      },
    );

    return completer.future;
  }

  void _recordMissed() {
    if (_dead) return;
    _missedCount++;
    onMissed?.call(_missedCount);
    if (_missedCount >= maxMissed) {
      _dead = true;
      stop();
      onDead?.call();
    }
  }

  void stop() {
    _running = false;
    _awaitingActiveProbe = false;
    _timer?.cancel();
    _timer = null;
    _activeProbeTimer?.cancel();
    _activeProbeTimer = null;
    _activeProbeDeadline = null;
    _activeProbeOnTimeout = null;
    final pending = _activeProbeCompleter;
    _activeProbeCompleter = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(null);
    }
  }
}
