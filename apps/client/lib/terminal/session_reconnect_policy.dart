import 'dart:async';

import 'package:flutter/foundation.dart';

import '../storage/session_reconnect_store.dart';

/// Seconds between automatic reconnect attempts the user can choose from.
const sessionReconnectIntervalChoices = [2, 5, 10, 15, 30, 60];

/// Interval used until the user chooses, and whenever the stored value is
/// missing or not one of [sessionReconnectIntervalChoices].
const sessionReconnectIntervalDefault = 5;

/// "No limit" in [sessionReconnectLimitChoices] and in the stored value.
const sessionReconnectNoLimit = 0;

/// Seconds one interruption keeps reconnecting automatically; the last entry
/// ([sessionReconnectNoLimit]) never gives up.
const sessionReconnectLimitChoices = [
  30,
  60,
  120,
  300,
  600,
  sessionReconnectNoLimit,
];

/// Time limit used until the user chooses, and whenever the stored value is
/// missing or not one of [sessionReconnectLimitChoices].
const sessionReconnectLimitDefault = 60;

/// How a dropped session is reconnected on this device.
@immutable
class SessionReconnectPolicy {
  const SessionReconnectPolicy({
    this.automatic = true,
    this.intervalSeconds = sessionReconnectIntervalDefault,
    this.limitSeconds = sessionReconnectLimitDefault,
  });

  /// Whether a session that was connected and then dropped reconnects by
  /// itself. Off leaves only the manual "Restore connection".
  final bool automatic;

  /// One of [sessionReconnectIntervalChoices].
  final int intervalSeconds;

  /// One of [sessionReconnectLimitChoices].
  final int limitSeconds;

  Duration get interval => Duration(seconds: intervalSeconds);

  /// How long one interruption keeps retrying; null never gives up.
  Duration? get limit => limitSeconds == sessionReconnectNoLimit
      ? null
      : Duration(seconds: limitSeconds);

  SessionReconnectPolicy copyWith({
    bool? automatic,
    int? intervalSeconds,
    int? limitSeconds,
  }) => SessionReconnectPolicy(
    automatic: automatic ?? this.automatic,
    intervalSeconds: intervalSeconds ?? this.intervalSeconds,
    limitSeconds: limitSeconds ?? this.limitSeconds,
  );

  /// Stored form: `automatic,interval,limit` as `0|1` and two second counts.
  String encode() => '${automatic ? 1 : 0},$intervalSeconds,$limitSeconds';

  @override
  bool operator ==(Object other) =>
      other is SessionReconnectPolicy &&
      other.automatic == automatic &&
      other.intervalSeconds == intervalSeconds &&
      other.limitSeconds == limitSeconds;

  @override
  int get hashCode => Object.hash(automatic, intervalSeconds, limitSeconds);

  @override
  String toString() => 'SessionReconnectPolicy(${encode()})';
}

/// Sanitizes a stored reconnect preference.
///
/// Each part is accepted only in its exact offered form; a missing, garbled or
/// unknown part (for example written by a newer version) yields that part's
/// default, so a session can never retry in a tight loop or at a nonsensical
/// interval.
SessionReconnectPolicy parseSessionReconnectPolicy(String? stored) {
  const fallback = SessionReconnectPolicy();
  if (stored == null || stored.length > 64) return fallback;
  final parts = stored.trim().split(',');
  String? part(int index) => index < parts.length ? parts[index].trim() : null;
  int choice(String? value, List<int> choices, int otherwise) {
    for (final candidate in choices) {
      if (value == '$candidate') return candidate;
    }
    return otherwise;
  }

  return SessionReconnectPolicy(
    automatic: switch (part(0)) {
      '0' => false,
      '1' => true,
      _ => fallback.automatic,
    },
    intervalSeconds: choice(
      part(1),
      sessionReconnectIntervalChoices,
      sessionReconnectIntervalDefault,
    ),
    limitSeconds: choice(
      part(2),
      sessionReconnectLimitChoices,
      sessionReconnectLimitDefault,
    ),
  );
}

/// Device-local policy for reconnecting dropped sessions.
///
/// Every session recovery on this device (local profile and cloud workspace)
/// reads [policy]; a change applies to interruptions that are still retrying
/// and to every later one. The value is never synced or stored in a Vault.
class SessionReconnectController extends ChangeNotifier {
  SessionReconnectController();

  static SessionReconnectController? _instance;

  /// Process-wide controller used by the app roots and session recoveries.
  static SessionReconnectController get instance =>
      _instance ??= SessionReconnectController();

  @visibleForTesting
  static set debugInstance(SessionReconnectController? controller) =>
      _instance = controller;

  SessionReconnectStore? _store;
  SessionReconnectPolicy _policy = const SessionReconnectPolicy();
  int _selectionRevision = 0;
  bool _writeFailed = false;
  int _writeRevision = 0;
  Future<void>? _writeChain;
  bool _disposed = false;

  SessionReconnectPolicy get policy => _policy;

  /// Whether persisting the latest selection failed; it still applies now.
  bool get writeFailed => _writeFailed;

  /// Reads the stored choice. Unknown values and read failures fall back to
  /// the defaults without rewriting the stored value. Never throws.
  Future<void> load(SessionReconnectStore store) async {
    _store = store;
    final revision = _selectionRevision;
    String? stored;
    try {
      stored = await store.read().timeout(const Duration(seconds: 2));
    } on Object {
      stored = null;
    }
    // A choice made while the read was in flight wins over the stored value.
    if (_disposed || revision != _selectionRevision) return;
    final next = parseSessionReconnectPolicy(stored);
    if (next != _policy) {
      _policy = next;
      notifyListeners();
    }
  }

  Future<void> setAutomatic(bool automatic) =>
      select(_policy.copyWith(automatic: automatic));

  Future<void> setIntervalSeconds(int seconds) =>
      select(_policy.copyWith(intervalSeconds: seconds));

  Future<void> setLimitSeconds(int seconds) =>
      select(_policy.copyWith(limitSeconds: seconds));

  /// Applies [policy] immediately and persists it. Writes are serialized and
  /// coalesced like the scrollback preference, so the last selection always
  /// wins on disk.
  Future<void> select(SessionReconnectPolicy policy) {
    if (!sessionReconnectIntervalChoices.contains(policy.intervalSeconds)) {
      throw ArgumentError.value(
        policy.intervalSeconds,
        'intervalSeconds',
        'Unsupported reconnect interval',
      );
    }
    if (!sessionReconnectLimitChoices.contains(policy.limitSeconds)) {
      throw ArgumentError.value(
        policy.limitSeconds,
        'limitSeconds',
        'Unsupported reconnect time limit',
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
    // Created per call so the chain runs in the caller's zone.
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
