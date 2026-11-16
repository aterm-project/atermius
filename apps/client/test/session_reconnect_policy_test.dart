import 'dart:async';
import 'dart:io';

import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/session_reconnect_store.dart';
import 'package:aterm_client/storage/session_reconnect_store_native.dart';
import 'package:aterm_client/terminal/session_reconnect_policy.dart';
import 'package:aterm_client/terminal/session_recovery.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/session_reconnect_setting.dart';
import 'package:aterm_client/ui/session_recovery_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Reconnect policy: a dropped session is retried every N seconds for a
// limited time, both device-local settings. All timing uses fake time.

SessionReconnectController _policy({
  bool automatic = true,
  int interval = sessionReconnectIntervalDefault,
  int limit = sessionReconnectLimitDefault,
}) {
  final controller = SessionReconnectController();
  unawaited(
    controller.select(
      SessionReconnectPolicy(
        automatic: automatic,
        intervalSeconds: interval,
        limitSeconds: limit,
      ),
    ),
  );
  return controller;
}

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  theme: buildAppTheme(),
  locale: locale,
  localizationsDelegates: AppLocalizationSetup.delegates,
  supportedLocales: AppLocalizationSetup.locales,
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

Widget _overlay(
  SessionRecovery recovery, {
  VoidCallback? onClose,
  Locale locale = const Locale('en'),
}) => MaterialApp(
  theme: buildAppTheme(),
  locale: locale,
  localizationsDelegates: AppLocalizationSetup.delegates,
  supportedLocales: AppLocalizationSetup.locales,
  home: Scaffold(
    body: SessionRecoveryOverlay(
      recovery: recovery,
      onClose: onClose,
      child: const ColoredBox(
        key: ValueKey('terminal'),
        color: Color(0xff000000),
      ),
    ),
  ),
);

/// Recoveries of the running test. They are disposed when its body ends, so
/// no retry timer outlives the test (tear-downs run after that check).
final _live = <SessionRecovery>[];

void _testWidgets(
  String description,
  Future<void> Function(WidgetTester tester) body,
) => testWidgets(description, (tester) async {
  try {
    await body(tester);
  } finally {
    for (final recovery in _live) {
      recovery.dispose();
    }
    _live.clear();
  }
});

const _restore = ValueKey('session_restore_connection');
const _automatic = ValueKey('session_recovery_automatic');
const _countdown = ValueKey('session_recovery_countdown');
const _gaveUp = ValueKey('session_recovery_gave_up');
const _close = ValueKey('session_recovery_close');

String? _text(WidgetTester tester, Key key) {
  final found = find.byKey(key);
  return found.evaluate().isEmpty ? null : tester.widget<Text>(found).data;
}

/// A store whose writes complete only when the test releases them.
class _GatedWriteStore implements SessionReconnectStore {
  final List<String> started = [];
  final List<Completer<void>> gates = [];

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) {
    started.add(value);
    final gate = Completer<void>();
    gates.add(gate);
    return gate.future;
  }
}

class _BrokenReadStore implements SessionReconnectStore {
  _BrokenReadStore({this.error});
  final Object? error;
  final List<String> written = [];

  @override
  Future<String?> read() {
    if (error case final error?) return Future<String?>.error(error);
    return Completer<String?>().future;
  }

  @override
  Future<void> write(String value) async => written.add(value);
}

void main() {
  group('policy value', () {
    test('defaults: automatic, every 5 seconds, for 1 minute', () {
      const policy = SessionReconnectPolicy();
      expect(policy.automatic, isTrue);
      expect(policy.interval, const Duration(seconds: 5));
      expect(policy.limit, const Duration(minutes: 1));
      expect(sessionReconnectIntervalChoices, [2, 5, 10, 15, 30, 60]);
      expect(sessionReconnectLimitChoices, [30, 60, 120, 300, 600, 0]);
      expect(
        sessionReconnectIntervalChoices,
        contains(sessionReconnectIntervalDefault),
      );
      expect(
        sessionReconnectLimitChoices,
        contains(sessionReconnectLimitDefault),
      );
      expect(
        const SessionReconnectPolicy(limitSeconds: 0).limit,
        isNull,
        reason: 'no limit',
      );
    });

    test('every offered combination round-trips through its stored form', () {
      for (final automatic in [true, false]) {
        for (final interval in sessionReconnectIntervalChoices) {
          for (final limit in sessionReconnectLimitChoices) {
            final policy = SessionReconnectPolicy(
              automatic: automatic,
              intervalSeconds: interval,
              limitSeconds: limit,
            );
            expect(parseSessionReconnectPolicy(policy.encode()), policy);
            expect(
              parseSessionReconnectPolicy('  ${policy.encode()}\n'),
              policy,
            );
          }
        }
      }
      expect(const SessionReconnectPolicy().encode(), '1,5,60');
    });

    test('anything else falls back to the default, part by part', () {
      const fallback = SessionReconnectPolicy();
      for (final stored in <String?>[
        null,
        '',
        '   ',
        'garbage',
        ',,',
        '2,1,7',
        'true,5s,1m',
        '1,-5,-60',
        '1,0,60000',
        '1,5.0,60.0',
        '1,5,60${' ' * 80}',
      ]) {
        expect(parseSessionReconnectPolicy(stored), fallback, reason: '$stored');
      }
      // A valid part survives next to an invalid one.
      expect(
        parseSessionReconnectPolicy('0,3,600'),
        const SessionReconnectPolicy(automatic: false, limitSeconds: 600),
      );
      expect(
        parseSessionReconnectPolicy('1,30'),
        const SessionReconnectPolicy(intervalSeconds: 30),
      );
      expect(
        parseSessionReconnectPolicy('1,5,0,future-field'),
        const SessionReconnectPolicy(limitSeconds: 0),
      );
    });
  });

  group('stores', () {
    test('memory store round-trips and can fail writes', () async {
      final store = MemorySessionReconnectStore();
      expect(await store.read(), isNull);
      await store.write('0,10,300');
      expect(await store.read(), '0,10,300');
      store.failWith = const FileSystemException('read-only');
      await expectLater(store.write('1,5,60'), throwsA(isA<FileSystemException>()));
      expect(await store.read(), '0,10,300');
    });

    test('file store round-trips atomically and survives a restart', () async {
      final directory = await Directory.systemTemp.createTemp('reconnect-');
      addTearDown(() => directory.delete(recursive: true));
      final nested = Directory('${directory.path}/support/app');
      final store = FileSessionReconnectStore(directory: () async => nested);
      expect(await store.read(), isNull);
      await store.write('0,30,600');
      expect(
        File('${nested.path}/session-reconnect-v1').readAsStringSync(),
        '0,30,600',
      );
      expect(
        nested.listSync().map((entry) => entry.uri.pathSegments.last),
        ['session-reconnect-v1'],
        reason: 'no temporary files are left behind',
      );

      // A new process reads the same file at startup.
      final relaunched = SessionReconnectController();
      await relaunched.load(
        FileSessionReconnectStore(directory: () async => nested),
      );
      expect(
        relaunched.policy,
        const SessionReconnectPolicy(
          automatic: false,
          intervalSeconds: 30,
          limitSeconds: 600,
        ),
      );
    });

    test('corrupt, empty and oversized files load as the default', () async {
      final directory = await Directory.systemTemp.createTemp('reconnect-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/session-reconnect-v1');
      final store = FileSessionReconnectStore(directory: () async => directory);
      for (final content in ['', '\n', 'x' * 500, '\u0000\u0001', '9,9,9']) {
        file.writeAsStringSync(content);
        final controller = SessionReconnectController();
        await controller.load(store);
        expect(controller.policy, const SessionReconnectPolicy());
      }
    });
  });

  group('controller', () {
    test('loads a stored policy and keeps unknown values untouched', () async {
      final store = MemorySessionReconnectStore('0,10,0');
      final controller = SessionReconnectController();
      expect(controller.policy, const SessionReconnectPolicy());
      await controller.load(store);
      expect(
        controller.policy,
        const SessionReconnectPolicy(
          automatic: false,
          intervalSeconds: 10,
          limitSeconds: 0,
        ),
      );

      final newer = MemorySessionReconnectStore('1,7,90');
      final fallback = SessionReconnectController();
      await fallback.load(newer);
      expect(fallback.policy, const SessionReconnectPolicy());
      expect(newer.writes, 0, reason: 'not rewritten');
      expect(newer.value, '1,7,90');
    });

    test('each change applies at once, notifies and persists', () async {
      final store = MemorySessionReconnectStore();
      final controller = SessionReconnectController();
      await controller.load(store);
      var notified = 0;
      controller.addListener(() => notified++);

      await controller.setIntervalSeconds(10);
      expect(controller.policy.intervalSeconds, 10);
      expect(store.value, '1,10,60');
      await controller.setLimitSeconds(sessionReconnectNoLimit);
      expect(controller.policy.limit, isNull);
      expect(store.value, '1,10,0');
      await controller.setAutomatic(false);
      expect(controller.policy.automatic, isFalse);
      expect(store.value, '0,10,0');
      expect(notified, 3);
      await controller.setAutomatic(false);
      expect(notified, 3, reason: 'unchanged');

      final relaunched = SessionReconnectController();
      await relaunched.load(store);
      expect(relaunched.policy, controller.policy);
    });

    test('values that are not offered are rejected', () async {
      final store = MemorySessionReconnectStore('1,10,300');
      final controller = SessionReconnectController();
      await controller.load(store);
      for (final seconds in [-1, 0, 1, 3, 61, 3600]) {
        expect(
          () => controller.setIntervalSeconds(seconds),
          throwsArgumentError,
        );
      }
      for (final seconds in [-1, 1, 45, 601, 86400]) {
        expect(() => controller.setLimitSeconds(seconds), throwsArgumentError);
      }
      expect(controller.policy.encode(), '1,10,300');
      expect(store.writes, 0);
    });

    test('a failed write still applies and is reported', () async {
      final store = MemorySessionReconnectStore()
        ..failWith = const FileSystemException('read-only');
      final controller = SessionReconnectController();
      await controller.load(store);
      await controller.setIntervalSeconds(30);
      expect(controller.policy.intervalSeconds, 30);
      expect(controller.writeFailed, isTrue);
      expect(store.value, isNull);
      store.failWith = null;
      await controller.setIntervalSeconds(30);
      expect(controller.writeFailed, isFalse);
      expect(store.value, '1,30,60');
    });

    test('load never throws; a choice made while loading wins', () async {
      final failing = SessionReconnectController();
      await failing.load(_BrokenReadStore(error: StateError('broken')));
      expect(failing.policy, const SessionReconnectPolicy());

      final store = MemorySessionReconnectStore('0,2,30');
      final controller = SessionReconnectController();
      final loading = controller.load(store);
      final saving = controller.setLimitSeconds(600);
      await Future.wait([loading, saving]);
      expect(controller.policy.encode(), '1,5,600');
      expect(store.value, '1,5,600');
    });

    test('writes are serialized and coalesced; the last choice wins', () async {
      final store = _GatedWriteStore();
      final controller = SessionReconnectController();
      await controller.load(store);
      final first = controller.setIntervalSeconds(2);
      await pumpEventQueue();
      final second = controller.setIntervalSeconds(10);
      final third = controller.setIntervalSeconds(30);
      await pumpEventQueue();
      expect(store.started, ['1,2,60'], reason: 'one write at a time');
      store.gates[0].complete();
      await pumpEventQueue();
      expect(store.started, ['1,2,60', '1,30,60'], reason: '10 is skipped');
      store.gates[1].complete();
      await Future.wait([first, second, third]);
      expect(controller.policy.intervalSeconds, 30);
    });

    test('the process-wide instance can be replaced for tests', () {
      addTearDown(() => SessionReconnectController.debugInstance = null);
      final controller = _policy(interval: 30);
      SessionReconnectController.debugInstance = controller;
      expect(SessionReconnectController.instance, same(controller));
      SessionReconnectController.debugInstance = null;
      expect(
        SessionReconnectController.instance.policy,
        const SessionReconnectPolicy(),
      );
    });
  });

  group('recovery', () {
    _testWidgets('attempts follow the configured interval', (tester) async {
      var attempts = 0;
      final recovery = SessionRecovery(
        automatic: true,
        policy: _policy(interval: 10, limit: sessionReconnectNoLimit),
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      expect(recovery.nextAttemptIn, const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 9999));
      expect(attempts, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(attempts, 1);
      await tester.pump(const Duration(milliseconds: 9999));
      expect(attempts, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(attempts, 2);
      await tester.pump(const Duration(seconds: 30));
      expect(attempts, 5);
    });

    _testWidgets('the process-wide policy is used when none is given', (
      tester,
    ) async {
      addTearDown(() => SessionReconnectController.debugInstance = null);
      SessionReconnectController.debugInstance = _policy(interval: 2, limit: 30);
      var attempts = 0;
      final recovery = SessionRecovery(
        automatic: true,
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      expect(recovery.remaining, const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 2));
      expect(attempts, 1);
    });

    _testWidgets('the time left counts down and the attempts stop at the limit', (
      tester,
    ) async {
      var attempts = 0, notified = 0;
      final recovery = SessionRecovery(
        automatic: true,
        policy: _policy(),
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.addListener(() => notified++);
      recovery.update(connected: true);
      expect(recovery.remaining, isNull, reason: 'connected');
      recovery.update(connected: false);
      expect(recovery.interrupted, isTrue);
      expect(recovery.automaticEnabled, isTrue);
      expect(recovery.expired, isFalse);
      expect(recovery.remaining, const Duration(minutes: 1));
      expect(recovery.nextAttemptIn, const Duration(seconds: 5));

      await tester.pump(const Duration(seconds: 17));
      expect(attempts, 3);
      expect(recovery.remaining, const Duration(seconds: 43));
      expect(recovery.nextAttemptIn, const Duration(seconds: 3));

      // Repeated state reports of the same interruption change nothing.
      recovery.update(connected: false);
      expect(recovery.remaining, const Duration(seconds: 43));

      await tester.pump(const Duration(milliseconds: 42999));
      expect(recovery.expired, isFalse);
      expect(recovery.remaining, const Duration(milliseconds: 1));
      final before = notified;
      await tester.pump(const Duration(milliseconds: 1));
      expect(notified, greaterThan(before), reason: 'the overlay is told');
      expect(recovery.expired, isTrue);
      expect(recovery.automaticEnabled, isFalse);
      expect(recovery.interrupted, isTrue);
      expect(recovery.remaining, isNull);
      expect(recovery.nextAttemptIn, isNull);
      expect(attempts, 11, reason: 'one every 5 s from 0:05 to 0:55');

      await tester.pump(const Duration(hours: 1));
      expect(attempts, 11, reason: 'given up');
      expect(recovery.expired, isTrue);
    });

    _testWidgets('"no limit" keeps retrying', (tester) async {
      var attempts = 0;
      final recovery = SessionRecovery(
        automatic: true,
        policy: _policy(limit: sessionReconnectNoLimit),
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      expect(recovery.remaining, isNull);
      expect(recovery.nextAttemptIn, const Duration(seconds: 5));
      await tester.pump(const Duration(hours: 1));
      expect(attempts, 720);
      expect(recovery.expired, isFalse);
      expect(recovery.automaticEnabled, isTrue);
    });

    _testWidgets('a successful reconnect resets the time limit', (tester) async {
      var attempts = 0, succeed = false;
      late SessionRecovery recovery;
      recovery = SessionRecovery(
        automatic: true,
        policy: _policy(),
        isCurrent: () => true,
        reconnect: () async {
          attempts++;
          if (succeed) recovery.update(connected: true);
        },
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      await tester.pump(const Duration(seconds: 52));
      expect(attempts, 10);
      expect(recovery.remaining, const Duration(seconds: 8));
      succeed = true;
      await tester.pump(const Duration(seconds: 3));
      expect(attempts, 11);
      expect(recovery.interrupted, isFalse);
      expect(recovery.remaining, isNull);
      await tester.pump(const Duration(minutes: 5));
      expect(attempts, 11, reason: 'connected: nothing to retry');

      // The next drop gets the full minute again.
      succeed = false;
      recovery.update(connected: false);
      expect(recovery.remaining, const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      expect(recovery.expired, isTrue);
      expect(attempts, 22);

      // So does a drop after the limit had been reached.
      recovery.update(connected: true);
      expect(recovery.expired, isFalse);
      recovery.update(connected: false);
      expect(recovery.automaticEnabled, isTrue);
      expect(recovery.remaining, const Duration(minutes: 1));
    });

    _testWidgets('manual restore works after the limit; a failed one starts a '
        'fresh automatic period', (tester) async {
      var attempts = 0, succeed = false;
      late SessionRecovery recovery;
      recovery = SessionRecovery(
        automatic: true,
        policy: _policy(),
        isCurrent: () => true,
        reconnect: () async {
          attempts++;
          if (succeed) recovery.update(connected: true);
        },
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      await tester.pump(const Duration(minutes: 2));
      expect(recovery.expired, isTrue);
      expect(attempts, 11);

      await recovery.retry();
      expect(attempts, 12);
      expect(recovery.interrupted, isTrue);
      expect(recovery.expired, isFalse);
      expect(recovery.automaticEnabled, isTrue);
      expect(recovery.remaining, const Duration(minutes: 1));
      await tester.pump(const Duration(seconds: 5));
      expect(attempts, 13);
      await tester.pump(const Duration(seconds: 55));
      expect(recovery.expired, isTrue);
      expect(attempts, 23);

      // And a manual restore that succeeds ends the interruption.
      succeed = true;
      await recovery.retry();
      expect(attempts, 24);
      expect(recovery.interrupted, isFalse);
      expect(recovery.expired, isFalse);
      await tester.pump(const Duration(minutes: 2));
      expect(attempts, 24);
    });

    _testWidgets('a manual restore during the countdown restarts it', (
      tester,
    ) async {
      var attempts = 0;
      final recovery = SessionRecovery(
        automatic: true,
        policy: _policy(),
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      await tester.pump(const Duration(seconds: 48));
      expect(recovery.remaining, const Duration(seconds: 12));
      await recovery.retry();
      expect(attempts, 10);
      expect(recovery.remaining, const Duration(minutes: 1));
      expect(recovery.nextAttemptIn, const Duration(seconds: 5));
    });

    _testWidgets('blocked cases stay blocked and are not "given up"', (
      tester,
    ) async {
      var attempts = 0, rejectHostKey = false;
      late SessionRecovery recovery;
      recovery = SessionRecovery(
        automatic: true,
        policy: _policy(),
        isCurrent: () => true,
        reconnect: () async {
          attempts++;
          if (rejectHostKey) {
            // What the owners do when the host key changed or was rejected.
            recovery.blockAutomatic();
            throw StateError('host key');
          }
        },
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      await tester.pump(const Duration(seconds: 7));
      expect(attempts, 1);

      // A user disconnect (or stop, or "Disconnect all") blocks the retries.
      recovery.blockAutomatic();
      recovery.update(connected: false);
      expect(recovery.automaticEnabled, isFalse);
      expect(recovery.expired, isFalse);
      expect(recovery.remaining, isNull);
      expect(recovery.nextAttemptIn, isNull);
      await tester.pump(const Duration(minutes: 10));
      expect(attempts, 1);
      expect(recovery.expired, isFalse, reason: 'no limit was running');

      // A manual restore that hits a rejected host key stays blocked.
      rejectHostKey = true;
      await recovery.retry();
      expect(attempts, 2);
      expect(recovery.automaticEnabled, isFalse);
      expect(recovery.remaining, isNull);
      await tester.pump(const Duration(minutes: 10));
      expect(attempts, 2);

      // An automatic attempt that hits it stops the remaining ones too.
      rejectHostKey = false;
      recovery.update(connected: true);
      recovery.update(connected: false);
      rejectHostKey = true;
      await tester.pump(const Duration(seconds: 5));
      expect(attempts, 3);
      expect(recovery.automaticEnabled, isFalse);
      await tester.pump(const Duration(minutes: 10));
      expect(attempts, 3);
    });

    _testWidgets('a session that never connected is not retried', (
      tester,
    ) async {
      var attempts = 0;
      final recovery = SessionRecovery(
        automatic: true,
        policy: _policy(),
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.update(connected: false);
      expect(recovery.everConnected, isFalse);
      expect(recovery.automaticEnabled, isFalse);
      expect(recovery.remaining, isNull);
      await tester.pump(const Duration(minutes: 2));
      expect(attempts, 0);
      expect(recovery.expired, isFalse);
    });

    _testWidgets('session kinds without automatic retries ignore the policy', (
      tester,
    ) async {
      var attempts = 0;
      final policy = _policy();
      final recovery = SessionRecovery(
        policy: policy,
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      await policy.setIntervalSeconds(2);
      await tester.pump(const Duration(minutes: 2));
      expect(attempts, 0);
      expect(recovery.automaticEnabled, isFalse);
      expect(recovery.expired, isFalse);
      await recovery.retry();
      expect(attempts, 1, reason: 'manual restore only');
    });

    _testWidgets('automatic reconnect switched off leaves manual restore', (
      tester,
    ) async {
      var attempts = 0;
      final policy = _policy(automatic: false);
      final recovery = SessionRecovery(
        automatic: true,
        policy: policy,
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      expect(recovery.automaticEnabled, isFalse);
      expect(recovery.remaining, isNull);
      await tester.pump(const Duration(minutes: 2));
      expect(attempts, 0);
      expect(recovery.expired, isFalse);
      await recovery.retry();
      expect(attempts, 1);
      await tester.pump(const Duration(minutes: 2));
      expect(attempts, 1);

      // Switching it on applies to the interruption that is still open...
      await policy.setAutomatic(true);
      expect(recovery.automaticEnabled, isTrue);
      expect(recovery.remaining, const Duration(minutes: 1));
      await tester.pump(const Duration(seconds: 5));
      expect(attempts, 2);
      // ...and switching it off stops the pending attempts at once.
      await policy.setAutomatic(false);
      expect(recovery.automaticEnabled, isFalse);
      expect(recovery.remaining, isNull);
      await tester.pump(const Duration(minutes: 2));
      expect(attempts, 2);
      expect(recovery.expired, isFalse);
    });

    _testWidgets('a changed interval or limit applies to a running countdown', (
      tester,
    ) async {
      var attempts = 0;
      final policy = _policy();
      final recovery = SessionRecovery(
        automatic: true,
        policy: policy,
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      await tester.pump(const Duration(seconds: 21));
      expect(attempts, 4);
      expect(recovery.remaining, const Duration(seconds: 39));

      await policy.setIntervalSeconds(2);
      expect(recovery.nextAttemptIn, const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(attempts, 5);

      // The limit is measured from the start of the interruption.
      await policy.setLimitSeconds(120);
      expect(recovery.remaining, const Duration(seconds: 97));
      await policy.setLimitSeconds(sessionReconnectNoLimit);
      expect(recovery.remaining, isNull);
      expect(recovery.automaticEnabled, isTrue);
      await policy.setLimitSeconds(30);
      expect(recovery.remaining, const Duration(seconds: 7));
      await tester.pump(const Duration(seconds: 7));
      expect(recovery.expired, isTrue);
      final given = attempts;

      // Once given up, a longer limit does not silently start it again.
      await policy.setLimitSeconds(600);
      await tester.pump(const Duration(minutes: 1));
      expect(recovery.expired, isTrue);
      expect(attempts, given);

      // A limit that is already used up ends the countdown immediately.
      recovery.update(connected: true);
      recovery.update(connected: false);
      await tester.pump(const Duration(seconds: 45));
      expect(recovery.expired, isFalse);
      await policy.setLimitSeconds(30);
      expect(recovery.expired, isTrue);
    });

    _testWidgets('an interval longer than the limit still tries once', (
      tester,
    ) async {
      var attempts = 0;
      final recovery = SessionRecovery(
        automatic: true,
        policy: _policy(interval: 60, limit: 30),
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      await tester.pump(const Duration(milliseconds: 29999));
      expect(attempts, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(attempts, 1);
      expect(recovery.expired, isTrue);
      await tester.pump(const Duration(minutes: 10));
      expect(attempts, 1);
    });

    _testWidgets('an attempt running at the limit finishes; none follows', (
      tester,
    ) async {
      var attempts = 0;
      final flight = Completer<void>();
      late SessionRecovery recovery;
      recovery = SessionRecovery(
        automatic: true,
        policy: _policy(limit: 30),
        isCurrent: () => true,
        reconnect: () {
          attempts++;
          return flight.future;
        },
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      await tester.pump(const Duration(seconds: 5));
      expect(attempts, 1);
      expect(recovery.busy, isTrue);
      expect(recovery.remaining, const Duration(seconds: 25));
      await tester.pump(const Duration(seconds: 25));
      expect(recovery.expired, isTrue);
      expect(recovery.busy, isTrue, reason: 'the attempt is not cut off');
      flight.complete();
      await tester.pump();
      expect(recovery.busy, isFalse);
      expect(recovery.expired, isTrue);
      await tester.pump(const Duration(minutes: 5));
      expect(attempts, 1);

      // Had it connected, the interruption would simply be over.
      recovery.update(connected: true);
      expect(recovery.interrupted, isFalse);
      expect(recovery.expired, isFalse);
    });

    _testWidgets('closing the owner stops the countdown and its timers', (
      tester,
    ) async {
      var attempts = 0, current = true;
      final policy = _policy();
      final recovery = SessionRecovery(
        automatic: true,
        policy: policy,
        isCurrent: () => current,
        reconnect: () async => attempts++,
      );
      recovery.update(connected: true);
      recovery.update(connected: false);
      await tester.pump(const Duration(seconds: 5));
      expect(attempts, 1);
      // Locked, signed out or switched: the pending attempt does nothing.
      current = false;
      await tester.pump(const Duration(seconds: 5));
      expect(attempts, 1);
      recovery.dispose();
      await policy.setIntervalSeconds(2);
      await tester.pump(const Duration(minutes: 5));
      expect(attempts, 1);
    });
  });

  group('overlay', () {
    _testWidgets('shows that it reconnects, the next attempt and a countdown '
        'that decreases; says so when the limit is reached', (tester) async {
      var attempts = 0, closed = 0;
      final recovery = SessionRecovery(
        automatic: true,
        policy: _policy(),
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.update(connected: true);
      await tester.pumpWidget(_overlay(recovery, onClose: () => closed++));
      expect(find.byKey(const ValueKey('terminal')), findsOneWidget);
      expect(find.text('Connection lost'), findsNothing);
      expect(find.byKey(_restore), findsNothing);

      recovery.update(connected: false);
      await tester.pump();
      expect(find.byKey(const ValueKey('terminal')), findsOneWidget);
      expect(find.text('Connection lost'), findsOneWidget);
      expect(
        _text(tester, _automatic),
        'Reconnecting automatically, next attempt in 5 s',
      );
      expect(_text(tester, _countdown), 'Stops trying in 1:00');
      expect(find.byKey(_gaveUp), findsNothing);
      expect(find.text('Restore connection'), findsOneWidget);
      expect(find.byKey(_close), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      expect(
        _text(tester, _automatic),
        'Reconnecting automatically, next attempt in 4 s',
      );
      expect(_text(tester, _countdown), 'Stops trying in 0:59');
      await tester.pump(const Duration(seconds: 3));
      expect(
        _text(tester, _automatic),
        'Reconnecting automatically, next attempt in 1 s',
      );
      expect(_text(tester, _countdown), 'Stops trying in 0:56');
      await tester.pump(const Duration(seconds: 13));
      expect(attempts, 3);
      expect(_text(tester, _countdown), 'Stops trying in 0:43');
      expect(
        _text(tester, _automatic),
        'Reconnecting automatically, next attempt in 3 s',
      );
      await tester.pump(const Duration(seconds: 42));
      expect(_text(tester, _countdown), 'Stops trying in 0:01');
      expect(find.byKey(_gaveUp), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      expect(attempts, 11);
      expect(find.text('Connection lost'), findsOneWidget);
      expect(
        _text(tester, _gaveUp),
        "Couldn't restore the connection automatically.",
      );
      expect(find.byKey(_automatic), findsNothing);
      expect(find.byKey(_countdown), findsNothing);
      expect(
        tester.widget<ButtonStyleButton>(find.byKey(_restore)).onPressed,
        isNotNull,
      );
      expect(find.text('Restore connection'), findsOneWidget);
      await tester.pump(const Duration(minutes: 3));
      expect(attempts, 11);
      expect(find.byKey(_gaveUp), findsOneWidget);

      // Manual restore still works; failing again restarts the countdown.
      await tester.tap(find.byKey(_restore));
      await tester.pump();
      expect(attempts, 12);
      expect(find.byKey(_gaveUp), findsNothing);
      expect(_text(tester, _countdown), 'Stops trying in 1:00');
      await tester.pump(const Duration(seconds: 2));
      expect(_text(tester, _countdown), 'Stops trying in 0:58');

      await tester.tap(find.byKey(_close));
      expect(closed, 1);

      // Reconnected: the card is gone and nothing keeps ticking.
      recovery.update(connected: true);
      await tester.pump();
      expect(find.text('Connection lost'), findsNothing);
      expect(find.byKey(_countdown), findsNothing);
      await tester.pump(const Duration(minutes: 2));
      expect(attempts, 12);
    });

    _testWidgets('an attempt in progress shows reconnecting; the countdown '
        'keeps running', (tester) async {
      final flight = Completer<void>();
      final recovery = SessionRecovery(
        automatic: true,
        policy: _policy(),
        isCurrent: () => true,
        reconnect: () => flight.future,
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      await tester.pumpWidget(_overlay(recovery));
      await tester.pump(const Duration(seconds: 5));
      expect(recovery.busy, isTrue);
      expect(_text(tester, _automatic), 'Reconnecting automatically');
      expect(_text(tester, _countdown), 'Stops trying in 0:55');
      expect(find.text('reconnecting'), findsOneWidget);
      expect(
        tester.widget<ButtonStyleButton>(find.byKey(_restore)).onPressed,
        isNull,
      );
      expect(find.byKey(_close), findsNothing, reason: 'no close callback');
      await tester.pump(const Duration(seconds: 10));
      expect(_text(tester, _countdown), 'Stops trying in 0:45');
      flight.complete();
      await tester.pump();
      expect(
        _text(tester, _automatic),
        'Reconnecting automatically, next attempt in 5 s',
      );
    });

    _testWidgets('"no limit" shows no countdown; blocked, switched off and '
        'manual-only sessions show neither line', (tester) async {
      final unlimited = SessionRecovery(
        automatic: true,
        policy: _policy(interval: 30, limit: sessionReconnectNoLimit),
        isCurrent: () => true,
        reconnect: () async {},
      );
      _live.add(unlimited);
      unlimited.update(connected: true);
      unlimited.update(connected: false);
      await tester.pumpWidget(_overlay(unlimited));
      expect(
        _text(tester, _automatic),
        'Reconnecting automatically, next attempt in 30 s',
      );
      expect(find.byKey(_countdown), findsNothing);
      await tester.pump(const Duration(seconds: 12));
      expect(
        _text(tester, _automatic),
        'Reconnecting automatically, next attempt in 18 s',
      );
      await tester.pump(const Duration(hours: 2));
      expect(find.byKey(_gaveUp), findsNothing);
      expect(find.byKey(_automatic), findsOneWidget);

      unlimited.blockAutomatic();
      await tester.pump();
      expect(find.text('Connection lost'), findsOneWidget);
      expect(find.byKey(_automatic), findsNothing);
      expect(find.byKey(_countdown), findsNothing);
      expect(find.byKey(_gaveUp), findsNothing);
      expect(find.byKey(_restore), findsOneWidget);

      for (final recovery in [
        SessionRecovery(
          automatic: true,
          policy: _policy(automatic: false),
          isCurrent: () => true,
          reconnect: () async {},
        ),
        SessionRecovery(
          policy: _policy(),
          isCurrent: () => true,
          reconnect: () async {},
        ),
      ]) {
        _live.add(recovery);
        recovery.update(connected: true);
        recovery.update(connected: false);
        await tester.pumpWidget(_overlay(recovery));
        await tester.pump(const Duration(minutes: 2));
        expect(find.text('Connection lost'), findsOneWidget);
        expect(find.byKey(_automatic), findsNothing);
        expect(find.byKey(_countdown), findsNothing);
        expect(find.byKey(_gaveUp), findsNothing);
        expect(find.byKey(_restore), findsOneWidget);
      }
    });

    _testWidgets('fits a narrow pane in every language', (tester) async {
      tester.view.physicalSize = const Size(260, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final locale in const ['en', 'zh', 'ja', 'ru']) {
        final l10n = appLocalizationsFor(Locale(locale));
        final recovery = SessionRecovery(
          automatic: true,
          policy: _policy(interval: 60, limit: 600),
          isCurrent: () => true,
          reconnect: () async {},
        );
        recovery.update(connected: true);
        recovery.update(connected: false);
        await tester.pumpWidget(
          _overlay(recovery, onClose: () {}, locale: Locale(locale)),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: locale);
        expect(
          _text(tester, _automatic),
          l10n.sessionReconnectNextAttempt(60),
        );
        expect(_text(tester, _countdown), l10n.sessionReconnectTimeLeft('10:00'));
        await tester.pump(const Duration(minutes: 10));
        expect(tester.takeException(), isNull, reason: locale);
        expect(_text(tester, _gaveUp), l10n.sessionReconnectGaveUp);
        if (locale != 'en') {
          final english = appLocalizationsFor(const Locale('en'));
          expect(
            l10n.sessionReconnectGaveUp,
            isNot(english.sessionReconnectGaveUp),
          );
          expect(
            l10n.sessionReconnectTimeLeft('0:43'),
            isNot(english.sessionReconnectTimeLeft('0:43')),
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        recovery.dispose();
      }
    });

    test('the countdown is minutes:seconds, rounded up', () {
      expect(sessionRecoveryCountdown(const Duration(minutes: 1)), '1:00');
      expect(sessionRecoveryCountdown(const Duration(seconds: 43)), '0:43');
      expect(
        sessionRecoveryCountdown(const Duration(milliseconds: 42001)),
        '0:43',
      );
      expect(sessionRecoveryCountdown(const Duration(minutes: 10)), '10:00');
      expect(sessionRecoveryCountdown(const Duration(seconds: 9)), '0:09');
      expect(sessionRecoveryCountdown(const Duration(milliseconds: 1)), '0:01');
      expect(sessionRecoveryCountdown(Duration.zero), '0:00');
      expect(sessionRecoveryCountdown(const Duration(seconds: -3)), '0:00');
    });
  });

  group('setting widget', () {
    test('labels read naturally in every language', () {
      String label(String locale, int seconds) => sessionReconnectDurationLabel(
        appLocalizationsFor(Locale(locale)),
        seconds,
      );
      expect(label('en', 2), '2 seconds');
      expect(label('en', 30), '30 seconds');
      expect(label('en', 60), '1 minute');
      expect(label('en', 600), '10 minutes');
      expect(label('en', 0), 'No limit');
      expect(label('zh', 5), '5 秒');
      expect(label('zh', 120), '2 分钟');
      expect(label('zh', 0), '不限时');
      expect(label('ja', 15), '15 秒');
      expect(label('ja', 300), '5 分');
      expect(label('ja', 0), '無制限');
      expect(label('ru', 2), '2 секунды');
      expect(label('ru', 5), '5 секунд');
      expect(label('ru', 60), '1 минута');
      expect(label('ru', 120), '2 минуты');
      expect(label('ru', 300), '5 минут');
      expect(label('ru', 0), 'Без ограничения');
      final zh = appLocalizationsFor(const Locale('zh'));
      expect(zh.sessionReconnectTitle, '自动重连');
      expect(zh.sessionReconnectIntervalLabel, '重连间隔');
      expect(zh.sessionReconnectLimitLabel, '重连时限');
    });

    for (final locale in const ['en', 'zh', 'ja', 'ru']) {
      _testWidgets('fits 390 px and selects every choice in $locale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final store = MemorySessionReconnectStore();
        final controller = SessionReconnectController();
        await controller.load(store);
        final l10n = appLocalizationsFor(Locale(locale));
        String label(int seconds, int standard) {
          final text = sessionReconnectDurationLabel(l10n, seconds);
          return seconds == standard
              ? l10n.sessionReconnectChoiceDefault(text)
              : text;
        }

        await tester.pumpWidget(
          _app(
            SessionReconnectSetting(controller: controller),
            locale: Locale(locale),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(l10n.sessionReconnectTitle), findsOneWidget);
        expect(find.text(l10n.sessionReconnectDescription), findsOneWidget);
        expect(find.text(l10n.sessionReconnectNote), findsOneWidget);
        expect(
          find.text(label(5, sessionReconnectIntervalDefault)),
          findsOneWidget,
          reason: 'the default interval is the current choice',
        );
        expect(
          find.text(label(60, sessionReconnectLimitDefault)),
          findsOneWidget,
          reason: 'the default limit is the current choice',
        );

        final interval = find.byKey(
          const ValueKey('session_reconnect_interval_dropdown'),
        );
        for (final seconds in [
          ...sessionReconnectIntervalChoices.reversed,
          sessionReconnectIntervalDefault,
        ]) {
          await tester.tap(interval);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'open menu');
          await tester.tap(
            find.text(label(seconds, sessionReconnectIntervalDefault)).last,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'selected $seconds');
          expect(controller.policy.intervalSeconds, seconds);
          expect(store.value, '1,$seconds,60');
        }

        final limit = find.byKey(
          const ValueKey('session_reconnect_limit_dropdown'),
        );
        for (final seconds in [
          ...sessionReconnectLimitChoices.reversed,
          sessionReconnectLimitDefault,
        ]) {
          await tester.tap(limit);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'open menu');
          expect(
            find.text(label(0, sessionReconnectLimitDefault)),
            findsWidgets,
            reason: 'the menu offers "no limit"',
          );
          await tester.tap(
            find.text(label(seconds, sessionReconnectLimitDefault)).last,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'selected $seconds');
          expect(controller.policy.limitSeconds, seconds);
          expect(store.value, '1,5,$seconds');
        }

        // Every visible text stays inside the 390 px wide window.
        for (final element in find.byType(Text).evaluate()) {
          final box = element.renderObject! as RenderBox;
          final bounds = MatrixUtils.transformRect(
            box.getTransformTo(null),
            Offset.zero & box.size,
          );
          final text = (element.widget as Text).data;
          expect(bounds.left, greaterThanOrEqualTo(0), reason: text);
          expect(bounds.right, lessThanOrEqualTo(390), reason: text);
        }
      });
    }

    _testWidgets('the switch turns automatic reconnect off and on, persists, '
        'and a stored policy is shown', (tester) async {
      final store = MemorySessionReconnectStore('1,10,300');
      final controller = SessionReconnectController();
      await tester.pumpWidget(
        _app(SessionReconnectSetting(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('5 seconds (default)'), findsOneWidget);
      expect(find.text('1 minute (default)'), findsOneWidget);

      // The stored policy arriving after the first frame is shown.
      await controller.load(store);
      await tester.pumpAndSettle();
      expect(find.text('10 seconds'), findsOneWidget);
      expect(find.text('5 minutes'), findsOneWidget);
      expect(find.text('5 seconds (default)'), findsNothing);

      final toggle = find.byKey(const ValueKey('session_reconnect_switch'));
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      expect(find.text('Reconnect dropped sessions automatically'), findsOne);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.policy.automatic, isFalse);
      expect(store.value, '0,10,300');
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      // Interval and limit keep their values but cannot be changed while off.
      for (final key in const [
        'session_reconnect_interval_dropdown',
        'session_reconnect_limit_dropdown',
      ]) {
        expect(
          tester
              .widget<DropdownButton<int>>(
                find.descendant(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(DropdownButton<int>),
                ),
              )
              .onChanged,
          isNull,
          reason: key,
        );
      }
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.policy.automatic, isTrue);
      expect(store.value, '1,10,300');

      store.failWith = const FileSystemException('read-only');
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(controller.policy.automatic, isFalse, reason: 'still applies');
      expect(
        find.byKey(const ValueKey('session_reconnect_save_failed')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    _testWidgets('uses the process-wide controller, which recoveries read', (
      tester,
    ) async {
      addTearDown(() => SessionReconnectController.debugInstance = null);
      final store = MemorySessionReconnectStore();
      final controller = SessionReconnectController();
      SessionReconnectController.debugInstance = controller;
      await controller.load(store);
      await tester.pumpWidget(_app(const SessionReconnectSetting()));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('session_reconnect_interval_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 seconds').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('session_reconnect_limit_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 seconds').last);
      await tester.pumpAndSettle();
      expect(store.value, '1,2,30');

      var attempts = 0;
      final recovery = SessionRecovery(
        automatic: true,
        isCurrent: () => true,
        reconnect: () async => attempts++,
      );
      _live.add(recovery);
      recovery.update(connected: true);
      recovery.update(connected: false);
      expect(recovery.remaining, const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 2));
      expect(attempts, 1);
      await tester.pump(const Duration(seconds: 28));
      expect(recovery.expired, isTrue);
    });
  });

  test('startup reads the stored policy before any session opens', () {
    final main = File('lib/main.dart').readAsStringSync();
    final load = main.indexOf(
      'SessionReconnectController.instance.load(createSessionReconnectStore())',
    );
    expect(load, greaterThan(0));
    expect(main.substring(0, load), contains('await'));
    expect(
      load,
      lessThan(main.indexOf('if (desktopLaunch != null)')),
      reason: 'loaded with the other device-local preferences',
    );
  });
}
