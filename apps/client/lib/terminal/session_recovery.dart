import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../platform/ssh_background_keepalive.dart';
import 'session_reconnect_policy.dart';

/// One retry flight per live owner. A retry never replays terminal input.
///
/// A session that was connected and then dropped is retried automatically
/// according to the device's [SessionReconnectPolicy]: one attempt per
/// interval, for at most the policy's time limit per interruption. When the
/// limit is reached the automatic attempts stop ([expired]) and only the
/// manual [retry] remains; a manual retry that fails starts a fresh automatic
/// period.
class SessionRecovery extends ChangeNotifier {
  SessionRecovery({
    required this.reconnect,
    required this.isCurrent,
    this.automatic = false,
    bool keepSshAlive = false,
    @visibleForTesting SshBackgroundKeepalive? sshKeepalive,
    this.keepaliveLimit = const Duration(minutes: 5),
    SessionReconnectController? policy,
  }) : _policy = policy ?? SessionReconnectController.instance,
       _keepalive = keepSshAlive
           ? _enabledOrNull(sshKeepalive ?? SshBackgroundKeepalive.instance)
           : null {
    // Notification "Disconnect all" must not be undone by an automatic retry
    // of the transport it closed.
    _removeDisconnectListener = _keepalive?.addUserDisconnectListener(
      blockAutomatic,
    );
    // Session kinds without automatic retries have nothing to re-plan.
    if (automatic) _policy.addListener(_policyChanged);
  }
  // Off Android there is nothing to keep alive: no hold, limit timer or
  // Disconnect all listener.
  static SshBackgroundKeepalive? _enabledOrNull(SshBackgroundKeepalive value) =>
      value.enabled ? value : null;

  final Future<void> Function() reconnect;
  final bool Function() isCurrent;

  /// Whether this kind of session may be retried without the user (SSH and
  /// Telnet). The device's policy can still switch automatic retries off.
  final bool automatic;
  final SessionReconnectController _policy;

  /// Longest time one interruption keeps the SSH background keepalive while
  /// automatic retries continue. The hold also ends as soon as the automatic
  /// retries do, so it never outlives the reconnect time limit.
  final Duration keepaliveLimit;
  final SshBackgroundKeepalive? _keepalive;
  void Function()? _removeDisconnectListener;
  SshKeepaliveHold? _hold;
  Timer? _holdLimit;
  bool _holdExpired = false;

  /// Next automatic attempt.
  Timer? _timer;

  /// End of the current automatic period.
  Timer? _deadline;

  /// Runs from the start of the current automatic period; null outside one.
  Stopwatch? _elapsed;
  Duration? _limit, _attemptDue;
  bool _expired = false, _attempted = false;
  bool _disposed = false, _everConnected = false, _automaticBlocked = false;
  int _recoveryCount = 0;
  String? _lastDisconnectReason;
  bool interrupted = false, busy = false;
  bool get available => !_disposed && isCurrent();

  /// 本会话在首次建连后成功恢复连接的累计次数（用于长连接稳定性观测）。
  int get recoveryCount => _recoveryCount;

  /// 最近一次断线的非敏感原因码（如 `keepalive_timeout` / `remote_closed` / `transport_error`）。
  String? get lastDisconnectReason => _lastDisconnectReason;

  /// Whether the session has been connected at least once. Its terminal then
  /// holds output worth keeping on screen while it is interrupted.
  bool get everConnected => _everConnected;

  /// Whether automatic attempts are (still) made for this session: its kind
  /// and the device's policy allow them, it had been connected, nothing
  /// blocked them and the time limit of this interruption is not used up.
  bool get automaticEnabled =>
      automatic &&
      _policy.policy.automatic &&
      _everConnected &&
      !_automaticBlocked &&
      !_expired;

  /// The automatic attempts of this interruption used up their time limit.
  /// Cleared by a successful connection and by a manual [retry].
  bool get expired => interrupted && _expired;

  /// Time left until the automatic attempts are given up; null without a
  /// limit or while no automatic period is running.
  Duration? get remaining {
    final limit = _limit, elapsed = _elapsed;
    if (limit == null || elapsed == null || !interrupted || !automaticEnabled) {
      return null;
    }
    final left = limit - elapsed.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// Time until the next automatic attempt starts; null while one is running
  /// or none is planned.
  Duration? get nextAttemptIn {
    final due = _attemptDue, elapsed = _elapsed;
    if (due == null || elapsed == null || _timer == null) return null;
    final left = due - elapsed.elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  void update({
    required bool connected,
    bool connecting = false,
    String? disconnectReason,
  }) {
    if (_disposed) return;
    if (connected) {
      if (_everConnected && interrupted) {
        _recoveryCount++;
      }
      _everConnected = true;
      _automaticBlocked = false;
      interrupted = false;
      _lastDisconnectReason = null;
      _endPeriod();
      _holdExpired = false;
    } else if (!connecting) {
      interrupted = true;
      if (disconnectReason != null && disconnectReason.isNotEmpty) {
        _lastDisconnectReason = disconnectReason;
      }
      _schedule();
    }
    _syncKeepalive();
    notifyListeners();
  }

  void blockAutomatic() {
    _automaticBlocked = true;
    _endPeriod();
    _syncKeepalive();
    if (!_disposed) notifyListeners();
  }

  /// Holds the SSH keepalive only while an automatic retry is genuinely
  /// pending or running for a still-current owner, and at most
  /// [keepaliveLimit] per interruption.
  void _syncKeepalive() {
    final keepalive = _keepalive;
    final wanted =
        keepalive != null &&
        !_disposed &&
        !_holdExpired &&
        interrupted &&
        automaticEnabled &&
        (_timer != null || busy) &&
        isCurrent();
    if (wanted) {
      _hold ??= keepalive.hold(SshKeepaliveKind.reconnecting);
      _holdLimit ??= Timer(keepaliveLimit, () {
        _holdLimit = null;
        _holdExpired = true;
        _syncKeepalive();
      });
      return;
    }
    _hold?.release();
    _hold = null;
    _holdLimit?.cancel();
    _holdLimit = null;
  }

  /// Forgets the automatic period of this interruption (timers, elapsed time
  /// and the expired mark), so the next one starts with the full time limit.
  void _endPeriod() {
    _timer?.cancel();
    _timer = null;
    _deadline?.cancel();
    _deadline = null;
    _elapsed = null;
    _limit = null;
    _attemptDue = null;
    _expired = false;
    _attempted = false;
  }

  /// Plans the next automatic attempt with the policy that applies now. The
  /// first call of an interruption starts its automatic period.
  void _schedule() {
    if (_disposed ||
        busy ||
        !automaticEnabled ||
        _timer != null ||
        !available) {
      return;
    }
    final policy = _policy.policy;
    final elapsed = _elapsed ??= clock.stopwatch()..start();
    final limit = _limit = policy.limit;
    _deadline?.cancel();
    _deadline = null;
    if (limit != null) {
      final left = limit - elapsed.elapsed;
      if (left <= Duration.zero) {
        _expire();
        return;
      }
      _deadline = Timer(left, _expire);
    }
    _attemptDue = elapsed.elapsed + policy.interval;
    _timer = Timer(policy.interval, () {
      _timer = null;
      _attemptDue = null;
      unawaited(retry(manual: false));
    });
  }

  /// The time limit of this interruption is used up: no further automatic
  /// attempt starts. One that is running finishes and still counts.
  void _expire() {
    _deadline = null;
    if (_disposed || !interrupted) return;
    final attempted = _attempted;
    _expired = true;
    _timer?.cancel();
    _timer = null;
    _attemptDue = null;
    _elapsed?.stop();
    _syncKeepalive();
    notifyListeners();
    // An interval longer than the limit would otherwise never try at all.
    if (!attempted && !busy) unawaited(retry(manual: false));
  }

  /// The device's policy changed: an interruption that is still retrying
  /// continues with the new interval and time limit (measured from its
  /// start), or stops when automatic reconnect was switched off.
  void _policyChanged() {
    if (_disposed) return;
    if (!_policy.policy.automatic) {
      _endPeriod();
    } else if (interrupted && !busy && !_expired) {
      _timer?.cancel();
      _timer = null;
      _attemptDue = null;
      _schedule();
    }
    _syncKeepalive();
    notifyListeners();
  }

  Future<void> retry({bool manual = true}) async {
    if (!available || busy || !interrupted) return;
    _timer?.cancel();
    _timer = null;
    _attemptDue = null;
    if (manual) {
      // The user wants this session back: if this attempt fails too, the
      // automatic attempts start over with the full time limit.
      _automaticBlocked = false;
      _endPeriod();
    } else {
      _attempted = true;
    }
    busy = true;
    _syncKeepalive();
    notifyListeners();
    try {
      final keepalive = _keepalive;
      await (keepalive == null
          ? reconnect()
          : keepalive.runRecoveryFlight(reconnect));
    } on Object {
      // Owners publish a sanitized connection state; never surface secrets.
    } finally {
      busy = false;
      if (!_disposed) {
        if (interrupted) _schedule();
        _syncKeepalive();
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _endPeriod();
    _syncKeepalive();
    _removeDisconnectListener?.call();
    _removeDisconnectListener = null;
    if (automatic) _policy.removeListener(_policyChanged);
    super.dispose();
  }
}
