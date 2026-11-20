import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/web_update/web_app_update_monitor.dart';

void main() {
  test('a matching bundle stays current and never reloads', () async {
    var reloads = 0;
    final monitor = WebAppUpdateMonitor(
      currentBuildId: 'build-a',
      probeBuildId: () async => 'build-a',
      reload: () async => reloads++,
      checkInterval: const Duration(days: 1),
    );
    addTearDown(monitor.dispose);

    await monitor.checkNow();

    expect(monitor.lastCheckSucceeded, isTrue);
    expect(monitor.hasUpdate, isFalse);
    await monitor.applyUpdate();
    expect(reloads, 0);
  });

  test(
    'a different bundle is reported and only explicit apply reloads',
    () async {
      var reloads = 0;
      final monitor = WebAppUpdateMonitor(
        currentBuildId: 'build-a',
        probeBuildId: () async => 'build-b',
        reload: () async => reloads++,
        checkInterval: const Duration(days: 1),
      );
      addTearDown(monitor.dispose);

      await monitor.checkNow();

      expect(monitor.hasUpdate, isTrue);
      expect(monitor.availableBuildId, 'build-b');
      expect(reloads, 0);
      await monitor.applyUpdate();
      expect(reloads, 1);
    },
  );

  test(
    'failed probes expose no error and clear stale update availability',
    () async {
      var fail = false;
      final monitor = WebAppUpdateMonitor(
        currentBuildId: 'build-a',
        probeBuildId: () async {
          if (fail) throw StateError('private network detail');
          return 'build-b';
        },
        reload: () async {},
        checkInterval: const Duration(days: 1),
      );
      addTearDown(monitor.dispose);

      await monitor.checkNow();
      expect(monitor.hasUpdate, isTrue);
      fail = true;
      await monitor.checkNow();

      expect(monitor.lastCheckSucceeded, isFalse);
      expect(monitor.hasUpdate, isFalse);
      expect(monitor.toString(), isNot(contains('private network detail')));
    },
  );

  group('with a bundle cache', () {
    test('an update is offered only after its download finished', () async {
      final download = Completer<void>();
      final prepared = <String>[];
      final order = <String>[];
      final monitor = WebAppUpdateMonitor(
        currentBuildId: 'build-a',
        probeBuildId: () async => 'build-b',
        reload: () async => order.add('reload'),
        prepareBuild: (id) {
          prepared.add(id);
          return download.future;
        },
        activateBuild: (id) async => order.add('activate $id'),
        checkInterval: const Duration(days: 1),
      );
      addTearDown(monitor.dispose);
      var notified = 0;
      monitor.addListener(() => notified++);

      await monitor.checkNow();
      expect(prepared, ['build-b']);
      expect(monitor.hasUpdate, isFalse, reason: 'still downloading');
      expect(monitor.downloadingUpdate, isTrue);
      await monitor.applyUpdate();
      expect(order, isEmpty, reason: 'nothing to reload into yet');

      // Another check while the download runs does not start a second one.
      await monitor.checkNow();
      expect(prepared, ['build-b']);

      final before = notified;
      download.complete();
      await pumpEventQueue();
      expect(monitor.hasUpdate, isTrue);
      expect(monitor.downloadingUpdate, isFalse);
      expect(notified, greaterThan(before), reason: 'the UI is told');

      await monitor.applyUpdate();
      expect(order, ['activate build-b', 'reload']);
    });

    test('a failed download offers nothing and is retried at the next check, '
        'and a failed probe does not forget a finished download', () async {
      var attempts = 0;
      var probeFails = false;
      final monitor = WebAppUpdateMonitor(
        currentBuildId: 'build-a',
        probeBuildId: () async {
          if (probeFails) throw StateError('offline');
          return 'build-b';
        },
        reload: () async {},
        prepareBuild: (id) async {
          if (++attempts == 1) throw StateError('connection lost');
        },
        checkInterval: const Duration(days: 1),
      );
      addTearDown(monitor.dispose);

      await monitor.checkNow();
      await pumpEventQueue();
      expect(monitor.hasUpdate, isFalse);
      expect(monitor.downloadingUpdate, isTrue);

      await monitor.checkNow();
      await pumpEventQueue();
      expect(attempts, 2);
      expect(monitor.hasUpdate, isTrue);

      probeFails = true;
      await monitor.checkNow();
      expect(monitor.hasUpdate, isFalse);
      probeFails = false;
      await monitor.checkNow();
      await pumpEventQueue();
      expect(monitor.hasUpdate, isTrue);
      expect(attempts, 2, reason: 'the stored build is not downloaded again');
    });

    test('a newer build found during a download is prepared too and the '
        'older one is never offered', () async {
      var server = 'build-b';
      final downloads = <String, Completer<void>>{};
      final monitor = WebAppUpdateMonitor(
        currentBuildId: 'build-a',
        probeBuildId: () async => server,
        reload: () async {},
        prepareBuild: (id) => (downloads[id] = Completer<void>()).future,
        checkInterval: const Duration(days: 1),
      );
      addTearDown(monitor.dispose);

      await monitor.checkNow();
      server = 'build-c';
      await monitor.checkNow();
      expect(downloads.keys, ['build-b', 'build-c']);
      downloads['build-b']!.complete();
      await pumpEventQueue();
      expect(monitor.hasUpdate, isFalse, reason: 'build-b is no longer served');
      downloads['build-c']!.complete();
      await pumpEventQueue();
      expect(monitor.hasUpdate, isTrue);
      expect(monitor.availableBuildId, 'build-c');
    });

    test('reloads even when the cache cannot switch builds', () async {
      var reloads = 0;
      final monitor = WebAppUpdateMonitor(
        currentBuildId: 'build-a',
        probeBuildId: () async => 'build-b',
        reload: () async => reloads++,
        prepareBuild: (id) async {},
        activateBuild: (id) async => throw StateError('worker gone'),
        checkInterval: const Duration(days: 1),
      );
      addTearDown(monitor.dispose);
      await monitor.checkNow();
      await pumpEventQueue();
      await monitor.applyUpdate();
      expect(reloads, 1);
    });
  });
}
