import 'dart:async';

import 'package:flutter/foundation.dart';

import '../storage/ssh_keepalive_store.dart';

/// 可选的 SSH 链路保活间隔（秒）；`0` 表示关闭应用层保活探测。
const sshKeepaliveIntervalChoices = [0, 10, 15, 30, 60];
const sshKeepaliveIntervalDefault = 15;

/// 判定半开僵尸链路前允许连续丢包的次数（对应 OpenSSH `ServerAliveCountMax`）。
const sshKeepaliveMaxMissedChoices = [2, 3, 5];
const sshKeepaliveMaxMissedDefault = 3;

/// 商业长连接自动密钥轮换周期（分钟，RFC 4253 §9）；`0` 表示不主动轮换。
const sshKeepaliveRekeyMinutesChoices = [0, 60, 180];
const sshKeepaliveRekeyMinutesDefault = 60;

/// 设备级 SSH 长连接保活与链路维护策略。
@immutable
class SshKeepalivePolicy {
  const SshKeepalivePolicy({
    this.intervalSeconds = sshKeepaliveIntervalDefault,
    this.maxMissed = sshKeepaliveMaxMissedDefault,
    this.probeOnResume = true,
    this.rekeyMinutes = sshKeepaliveRekeyMinutesDefault,
  });

  /// 保活发送间隔（秒）；`0` 为关闭。
  final int intervalSeconds;

  /// 允许连续未响应次数，达到即判定为半开僵尸连接并主动断开以触发自动恢复。
  final int maxMissed;

  /// 从系统休眠或 iOS/桌面后台切回前台时是否立即向已连接会话发一次探活。
  final bool probeOnResume;

  /// 自动密钥轮换周期（分钟）；`0` 为关闭。
  final int rekeyMinutes;

  bool get enabled => intervalSeconds > 0;

  Duration? get interval =>
      intervalSeconds > 0 ? Duration(seconds: intervalSeconds) : null;

  /// 单次保活响应超时：跟随保活间隔自适应收敛（至少 8s，至多 15s），避免弱网误杀。
  Duration? get probeTimeout {
    if (intervalSeconds <= 0) return null;
    final seconds = intervalSeconds <= 10
        ? 8
        : intervalSeconds <= 15
        ? 10
        : 15;
    return Duration(seconds: seconds);
  }

  Duration? get rekeyInterval =>
      rekeyMinutes > 0 ? Duration(minutes: rekeyMinutes) : null;

  SshKeepalivePolicy copyWith({
    int? intervalSeconds,
    int? maxMissed,
    bool? probeOnResume,
    int? rekeyMinutes,
  }) => SshKeepalivePolicy(
    intervalSeconds: intervalSeconds ?? this.intervalSeconds,
    maxMissed: maxMissed ?? this.maxMissed,
    probeOnResume: probeOnResume ?? this.probeOnResume,
    rekeyMinutes: rekeyMinutes ?? this.rekeyMinutes,
  );

  /// 紧凑落盘格式：`interval,maxMissed,probeOnResume(0|1),rekeyMinutes`。
  String encode() =>
      '$intervalSeconds,$maxMissed,${probeOnResume ? 1 : 0},$rekeyMinutes';

  @override
  bool operator ==(Object other) =>
      other is SshKeepalivePolicy &&
      other.intervalSeconds == intervalSeconds &&
      other.maxMissed == maxMissed &&
      other.probeOnResume == probeOnResume &&
      other.rekeyMinutes == rekeyMinutes;

  @override
  int get hashCode =>
      Object.hash(intervalSeconds, maxMissed, probeOnResume, rekeyMinutes);

  @override
  String toString() => 'SshKeepalivePolicy(${encode()})';
}

/// 逐项宽容解析持久化的保活策略，任何损坏或未来版本字段均安全回退为默认值。
SshKeepalivePolicy parseSshKeepalivePolicy(String? stored) {
  const fallback = SshKeepalivePolicy();
  if (stored == null || stored.length > 64) return fallback;
  final parts = stored.trim().split(',');
  String? part(int index) => index < parts.length ? parts[index].trim() : null;
  int pick(String? raw, List<int> choices, int otherwise) {
    for (final candidate in choices) {
      if (raw == '$candidate') return candidate;
    }
    return otherwise;
  }

  return SshKeepalivePolicy(
    intervalSeconds: pick(
      part(0),
      sshKeepaliveIntervalChoices,
      sshKeepaliveIntervalDefault,
    ),
    maxMissed: pick(
      part(1),
      sshKeepaliveMaxMissedChoices,
      sshKeepaliveMaxMissedDefault,
    ),
    probeOnResume: switch (part(2)) {
      '0' => false,
      '1' => true,
      _ => fallback.probeOnResume,
    },
    rekeyMinutes: pick(
      part(3),
      sshKeepaliveRekeyMinutesChoices,
      sshKeepaliveRekeyMinutesDefault,
    ),
  );
}

/// 进程级 SSH 长连接保活策略控制器（写盘串行防竞争，行为对齐 [SessionReconnectController]）。
class SshKeepaliveController extends ChangeNotifier {
  SshKeepaliveController();

  static SshKeepaliveController? _instance;

  static SshKeepaliveController get instance =>
      _instance ??= SshKeepaliveController();

  @visibleForTesting
  static set debugInstance(SshKeepaliveController? controller) =>
      _instance = controller;

  SshKeepaliveStore? _store;
  SshKeepalivePolicy _policy = const SshKeepalivePolicy();
  int _selectionRevision = 0;
  bool _writeFailed = false;
  int _writeRevision = 0;
  Future<void>? _writeChain;
  bool _disposed = false;

  SshKeepalivePolicy get policy => _policy;
  bool get writeFailed => _writeFailed;

  Future<void> load(SshKeepaliveStore store) async {
    _store = store;
    final revision = _selectionRevision;
    String? stored;
    try {
      stored = await store.read().timeout(const Duration(seconds: 2));
    } on Object {
      stored = null;
    }
    if (_disposed || revision != _selectionRevision) return;
    final next = parseSshKeepalivePolicy(stored);
    if (next != _policy) {
      _policy = next;
      notifyListeners();
    }
  }

  Future<void> setIntervalSeconds(int seconds) =>
      select(_policy.copyWith(intervalSeconds: seconds));

  Future<void> setMaxMissed(int maxMissed) =>
      select(_policy.copyWith(maxMissed: maxMissed));

  Future<void> setProbeOnResume(bool enabled) =>
      select(_policy.copyWith(probeOnResume: enabled));

  Future<void> setRekeyMinutes(int minutes) =>
      select(_policy.copyWith(rekeyMinutes: minutes));

  Future<void> select(SshKeepalivePolicy policy) {
    if (!sshKeepaliveIntervalChoices.contains(policy.intervalSeconds)) {
      throw ArgumentError.value(
        policy.intervalSeconds,
        'intervalSeconds',
        'Unsupported SSH keepalive interval',
      );
    }
    if (!sshKeepaliveMaxMissedChoices.contains(policy.maxMissed)) {
      throw ArgumentError.value(
        policy.maxMissed,
        'maxMissed',
        'Unsupported SSH keepalive maxMissed count',
      );
    }
    if (!sshKeepaliveRekeyMinutesChoices.contains(policy.rekeyMinutes)) {
      throw ArgumentError.value(
        policy.rekeyMinutes,
        'rekeyMinutes',
        'Unsupported SSH auto-rekey interval',
      );
    }
    _selectionRevision++;
    if (policy != _policy) {
      _policy = policy;
      notifyListeners();
    }
    final store = _store;
    if (store == null) return Future<void>.value();
    final revision = ++_writeRevision;
    final previous = _writeChain ?? Future<void>.value();
    final next = previous.then((_) async {
      if (revision != _writeRevision || _disposed) return;
      var failed = false;
      try {
        await store.write(policy.encode());
      } on Object {
        failed = true;
      }
      if (revision != _writeRevision || _disposed) return;
      if (failed != _writeFailed) {
        _writeFailed = failed;
        notifyListeners();
      }
    });
    _writeChain = next;
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
