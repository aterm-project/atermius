import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/ssh/ssh_connection_health.dart';
import 'package:aterm_client/ssh/ssh_keepalive_policy.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/paste_safety_store.dart';
import 'package:aterm_client/storage/ssh_keepalive_store.dart';
import 'package:aterm_client/storage/ssh_keepalive_store_native.dart';
import 'package:aterm_client/terminal/paste_safety.dart';
import 'package:aterm_client/terminal/session_reconnect_policy.dart';
import 'package:aterm_client/terminal/session_recovery.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/ssh_keepalive_setting.dart';
import 'package:dartssh2/dartssh2.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SSHKeepAlive watchdog (OpenSSH ServerAlive 语义)', () {
    test('持续周期保活正常采集 RTT 并容忍时钟回拨', () {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 11, 19, 12, 0, 0);
        final latencies = <Duration>[];
        var pingCalls = 0;

        final watchdog = SSHKeepAlive(
          interval: const Duration(seconds: 15),
          timeout: const Duration(seconds: 10),
          maxMissed: 3,
          now: () => now,
          ping: () async {
            pingCalls++;
            if (pingCalls == 2) {
              // 模拟 NTP 时钟回拨 50ms，RTT 不得为负。
              now = now.subtract(const Duration(milliseconds: 50));
            } else {
              now = now.add(const Duration(milliseconds: 35));
            }
          },
          onLatency: latencies.add,
        );

        watchdog.start();
        async.elapse(const Duration(seconds: 45));
        watchdog.stop();

        expect(pingCalls, 3);
        expect(latencies.length, 3);
        expect(latencies[0], const Duration(milliseconds: 35));
        expect(latencies[1], Duration.zero);
        expect(latencies[2], const Duration(milliseconds: 35));
        expect(watchdog.missedCount, 0);
        expect(watchdog.isDead, isFalse);
      });
    });

    test('半开 TCP 黑洞连续丢失 3 次保活后立即判定僵死并停止定时发包', () {
      fakeAsync((async) {
        final pending = <Completer<void>>[];
        final missedHistory = <int>[];
        var deadCalls = 0;

        final watchdog = SSHKeepAlive(
          interval: const Duration(seconds: 15),
          timeout: const Duration(seconds: 10),
          maxMissed: 3,
          ping: () {
            final c = Completer<void>();
            pending.add(c);
            return c.future;
          },
          onMissed: missedHistory.add,
          onDead: () => deadCalls++,
        );

        watchdog.start();
        // t=15s 发第 1 包，t=25s 超时（missed=1）
        async.elapse(const Duration(seconds: 25));
        expect(missedHistory, [1]);
        expect(deadCalls, 0);
        expect(watchdog.isDead, isFalse);

        // t=30s 发第 2 包，t=40s 超时（missed=2）
        async.elapse(const Duration(seconds: 15));
        expect(missedHistory, [1, 2]);
        expect(deadCalls, 0);

        // t=45s 发第 3 包，t=55s 超时（missed=3 -> onDead）
        async.elapse(const Duration(seconds: 15));
        expect(missedHistory, [1, 2, 3]);
        expect(deadCalls, 1);
        expect(watchdog.isDead, isTrue);
        expect(watchdog.isRunning, isFalse);

        // 僵死后再流逝 5 分钟也不应再发起任何 ping。
        final countAtDeath = pending.length;
        async.elapse(const Duration(minutes: 5));
        expect(pending.length, countAtDeath);

        // 模拟底层关闭传输后拒绝在途请求，不应产生未捕获异常。
        for (final c in pending) {
          c.completeError(SSHSocketError('transport closed'));
        }
        async.flushMicrotasks();
        expect(deadCalls, 1);
      });
    });

    test('瞬时抖动超时后收到迟到响应可清零丢包计数而不误杀连接', () {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 11, 19, 12, 0, 0);
        Completer<void>? first;
        var call = 0;
        final missed = <int>[];
        final rtts = <Duration>[];
        var dead = 0;

        final watchdog = SSHKeepAlive(
          interval: const Duration(seconds: 15),
          timeout: const Duration(seconds: 10),
          maxMissed: 3,
          now: () => now,
          ping: () {
            call++;
            if (call == 1) {
              first = Completer<void>();
              return first!.future;
            }
            now = now.add(const Duration(milliseconds: 22));
            return Future<void>.value();
          },
          onLatency: rtts.add,
          onMissed: missed.add,
          onDead: () => dead++,
        );

        watchdog.start();
        async.elapse(const Duration(seconds: 25));
        expect(missed, [1]);
        expect(watchdog.missedCount, 1);

        // 第 1 包迟到 2 秒到达 -> 清零丢包计数。
        now = now.add(const Duration(seconds: 12));
        first!.complete();
        async.flushMicrotasks();
        expect(watchdog.missedCount, 0);
        expect(rtts.length, 1);

        // 后续 10 个周期稳定在线。
        async.elapse(const Duration(seconds: 150));
        watchdog.stop();
        expect(dead, 0);
        expect(rtts.length, 11);
      });
    });

    test('probeNow 并发调用去重并在黑洞超时时计入丢包', () {
      fakeAsync((async) {
        var pingCalls = 0;
        final completer = Completer<void>();
        final missed = <int>[];

        final watchdog = SSHKeepAlive(
          interval: const Duration(seconds: 60),
          timeout: const Duration(seconds: 10),
          maxMissed: 2,
          ping: () {
            pingCalls++;
            return completer.future;
          },
          onMissed: missed.add,
        );

        watchdog.start();
        Duration? r1;
        Duration? r2;
        var done1 = false;
        var done2 = false;
        watchdog.probeNow(timeout: const Duration(seconds: 4)).then((v) {
          r1 = v;
          done1 = true;
        });
        watchdog.probeNow(timeout: const Duration(seconds: 4)).then((v) {
          r2 = v;
          done2 = true;
        });

        expect(pingCalls, 1, reason: '并发 probeNow 必须复用同一次探活请求');
        async.elapse(const Duration(seconds: 4));
        expect(done1, isTrue);
        expect(done2, isTrue);
        expect(r1, isNull);
        expect(r2, isNull);
        expect(missed, [1]);

        watchdog.stop();
        completer.completeError(SSHSocketError('closed'));
        async.flushMicrotasks();
      });
    });

    test('周期探测在途时 probeNow 复用同一 Future 并可收紧超时窗口，不误返 null', () {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 11, 19, 12, 0, 0);
        var pingCalls = 0;
        final pending = <Completer<void>>[];
        final missed = <int>[];

        final watchdog = SSHKeepAlive(
          interval: const Duration(seconds: 15),
          timeout: const Duration(seconds: 10),
          maxMissed: 3,
          now: () => now,
          ping: () {
            pingCalls++;
            final c = Completer<void>();
            pending.add(c);
            return c.future;
          },
          onMissed: missed.add,
        );

        watchdog.start();
        // t=15s 周期探活发出，原超时窗口在 t=25s。
        now = now.add(const Duration(seconds: 15));
        async.elapse(const Duration(seconds: 15));
        expect(pingCalls, 1);

        // t=16s 切回前台调用 probeNow(timeout: 3s)：必须复用在途探测而不额外发包，
        // 若在 1s 后成功回包则应拿到真实 RTT 而非虚假 null。
        now = now.add(const Duration(seconds: 1));
        async.elapse(const Duration(seconds: 1));
        Duration? manualResult;
        var manualDone = false;
        watchdog.probeNow(timeout: const Duration(seconds: 3)).then((v) {
          manualResult = v;
          manualDone = true;
        });
        expect(pingCalls, 1, reason: '周期探测在途时 probeNow 不得叠包');
        expect(manualDone, isFalse, reason: '不得同步误返 null');

        now = now.add(const Duration(milliseconds: 500));
        pending.first.complete();
        async.flushMicrotasks();
        expect(manualDone, isTrue);
        expect(manualResult, const Duration(milliseconds: 1500));
        expect(missed, isEmpty);

        // 下一轮周期探测 t=30s 发出，t=31s 切回前台要求 2s 超时 -> 应在 t=33s（而非 t=40s）判定超时。
        now = now.add(const Duration(seconds: 14));
        async.elapse(const Duration(seconds: 14));
        expect(pingCalls, 2);

        now = now.add(const Duration(seconds: 1));
        async.elapse(const Duration(seconds: 1));
        var tightenedDone = false;
        Duration? tightenedResult = const Duration(seconds: 99);
        watchdog.probeNow(timeout: const Duration(seconds: 2)).then((v) {
          tightenedResult = v;
          tightenedDone = true;
        });
        now = now.add(const Duration(seconds: 2));
        async.elapse(const Duration(seconds: 2));
        expect(tightenedDone, isTrue, reason: 'probeNow 较短超时应立即收紧在途探测截止时间');
        expect(tightenedResult, isNull);
        expect(missed, [1]);

        watchdog.stop();
        for (final c in pending) {
          if (!c.isCompleted) c.completeError(SSHSocketError('closed'));
        }
        async.flushMicrotasks();
      });
    });

    test('stop() 立即以 null 完结在途 probeNow Future，避免调用方永久挂起', () {
      fakeAsync((async) {
        final stuck = Completer<void>();
        final watchdog = SSHKeepAlive(
          interval: const Duration(seconds: 60),
          timeout: const Duration(seconds: 10),
          maxMissed: 3,
          ping: () => stuck.future,
        );

        watchdog.start();
        var completed = false;
        Duration? result = const Duration(seconds: 1);
        watchdog.probeNow(timeout: const Duration(seconds: 5)).then((v) {
          completed = true;
          result = v;
        });
        expect(completed, isFalse);

        // 底层 ping 永不返回时调用 stop()，probeNow 必须立即释放调用方。
        watchdog.stop();
        async.flushMicrotasks();
        expect(completed, isTrue);
        expect(result, isNull);
      });
    });
  });

  group('SshKeepalivePolicy & Store & Controller', () {
    test('默认策略、编解码往返与损坏数据逐项容错回退', () {
      const defaults = SshKeepalivePolicy();
      expect(defaults.intervalSeconds, 15);
      expect(defaults.maxMissed, 3);
      expect(defaults.probeOnResume, isTrue);
      expect(defaults.rekeyMinutes, 60);
      expect(defaults.probeTimeout, const Duration(seconds: 10));

      for (final interval in sshKeepaliveIntervalChoices) {
        for (final maxMissed in sshKeepaliveMaxMissedChoices) {
          for (final resume in [false, true]) {
            for (final rekey in sshKeepaliveRekeyMinutesChoices) {
              final policy = SshKeepalivePolicy(
                intervalSeconds: interval,
                maxMissed: maxMissed,
                probeOnResume: resume,
                rekeyMinutes: rekey,
              );
              expect(parseSshKeepalivePolicy(policy.encode()), policy);
            }
          }
        }
      }

      expect(parseSshKeepalivePolicy(null), defaults);
      expect(parseSshKeepalivePolicy('garbage'), defaults);
      expect(
        parseSshKeepalivePolicy('30,99,0,180'),
        const SshKeepalivePolicy(
          intervalSeconds: 30,
          maxMissed: 3,
          probeOnResume: false,
          rekeyMinutes: 180,
        ),
      );
      expect(parseSshKeepalivePolicy('1' * 100), defaults);
    });

    test('FileSshKeepaliveStore 原子落盘并拒绝超长损坏文件', () async {
      final dir = await Directory.systemTemp.createTemp('ssh-keepalive-test-');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSshKeepaliveStore(directory: () async => dir);

      expect(await store.read(), isNull);
      await store.write('30,5,0,180');
      expect(await store.read(), '30,5,0,180');

      final rawFile = File('${dir.path}/ssh-keepalive-v1');
      await rawFile.writeAsString('x' * 200);
      expect(await store.read(), isNull);
    });

    test('Controller 串行合批写盘、拒绝非法枚举并在写失败时标记 writeFailed', () async {
      final store = MemorySshKeepaliveStore();
      final controller = SshKeepaliveController();
      addTearDown(controller.dispose);
      await controller.load(store);

      expect(
        () => controller.setIntervalSeconds(7),
        throwsArgumentError,
      );
      expect(
        () => controller.setMaxMissed(9),
        throwsArgumentError,
      );
      expect(
        () => controller.setRekeyMinutes(45),
        throwsArgumentError,
      );

      final w1 = controller.setIntervalSeconds(10);
      final w2 = controller.setIntervalSeconds(30);
      final w3 = controller.setMaxMissed(5);
      await Future.wait([w1, w2, w3]);
      expect(store.value, '30,5,1,60');
      expect(controller.writeFailed, isFalse);

      store.failWith = const FileSystemException('disk full');
      await controller.setProbeOnResume(false);
      expect(controller.policy.probeOnResume, isFalse);
      expect(controller.writeFailed, isTrue);
    });
  });

  group('SshConnectionHealth & SessionRecovery 商业长连接诊断', () {
    test('完整覆盖健康态迁移、EWMA 平滑、时长/RTT 格式化与无敏感信息快照', () {
      var now = DateTime.utc(2026, 11, 19, 10, 0, 0);
      final health = SshConnectionHealth(now: () => now, maxMissedThreshold: 3);
      addTearDown(health.dispose);

      expect(health.state, SshHealthState.healthy);
      now = now.add(const Duration(seconds: 30));
      health.recordProbeSuccess(const Duration(milliseconds: 40));
      expect(health.lastRtt, const Duration(milliseconds: 40));
      expect(health.smoothedRtt, const Duration(milliseconds: 40));
      expect(health.state, SshHealthState.healthy);

      // 高延迟样本触发 degraded
      health.recordProbeSuccess(const Duration(milliseconds: 600));
      expect(health.state, SshHealthState.degraded);
      // EWMA = 0.3 * 600 + 0.7 * 40 = 208ms
      expect(health.smoothedRtt?.inMilliseconds, closeTo(208, 1));

      // 恢复低延迟回归 healthy
      health.recordProbeSuccess(const Duration(milliseconds: 20));
      expect(health.state, SshHealthState.healthy);

      // 丢包 1 次 -> degraded；丢包 3 次 -> stale
      health.recordProbeMissed(1);
      expect(health.state, SshHealthState.degraded);
      health.recordProbeMissed(3);
      expect(health.state, SshHealthState.stale);
      health.recordKeepaliveDead();
      expect(health.keepaliveTimedOut, isTrue);

      health.recordBytesReceived(4096);
      health.recordBytesSent(128);
      health.recordRekeySuccess();

      now = now.add(const Duration(hours: 2, minutes: 14));
      final snap = health.toDiagnosticSnapshot();
      expect(snap['rekeyCount'], 1);
      expect(snap['bytesReceived'], 4096);
      expect(snap['bytesSent'], 128);
      expect(snap['keepaliveTimedOut'], isTrue);
      expect(snap.containsKey('host'), isFalse);
      expect(snap.containsKey('password'), isFalse);

      expect(SshConnectionHealth.formatUptime(const Duration(seconds: 45)), '45s');
      expect(SshConnectionHealth.formatUptime(const Duration(minutes: 12)), '12m');
      expect(
        SshConnectionHealth.formatUptime(const Duration(hours: 3, minutes: 5)),
        '3h 5m',
      );
      expect(
        SshConnectionHealth.formatUptime(const Duration(days: 2, hours: 6)),
        '2d 6h',
      );
      expect(SshConnectionHealth.formatRtt(const Duration(microseconds: 400)), '<1ms');
      expect(SshConnectionHealth.formatRtt(const Duration(milliseconds: 24)), '24ms');
      expect(SshConnectionHealth.formatRtt(const Duration(milliseconds: 1250)), '1.3s');

      health.beginProbe();
      expect(health.probing, isTrue);
      health.markClosed();
      expect(health.state, SshHealthState.closed);
      expect(health.probing, isFalse);
    });

    test('SshConnection.probeLiveness 连续刷新 RTT、上报超时并在探活结束复位 probing', () async {
      final probeResults = <Duration?>[
        const Duration(milliseconds: 20),
        const Duration(milliseconds: 180),
        null,
      ];
      var call = 0;
      final client = _FakeProbeClient(
        onProbe: (_) async => probeResults[call++],
      );
      final health = SshConnectionHealth(maxMissedThreshold: 3);
      addTearDown(health.dispose);
      final connection = SshConnection(
        client: client,
        session: _FakeProbeSession(),
        health: health,
      );

      expect(await connection.probeLiveness(), isTrue);
      expect(health.lastRtt, const Duration(milliseconds: 20));
      expect(health.probing, isFalse);

      // 第二次手动探活必须刷新 RTT 为 180ms（不得停留在第一次的 20ms）
      expect(await connection.probeLiveness(), isTrue);
      expect(health.lastRtt, const Duration(milliseconds: 180));
      expect(health.probesSucceeded, 2);

      // 第三次超时返回 null -> 即使底层未绑定 onKeepAliveMissed 也应记录丢包进入 degraded
      expect(await connection.probeLiveness(), isFalse);
      expect(health.missedProbes, 1);
      expect(health.state, SshHealthState.degraded);
      expect(health.probing, isFalse);
    });

    test('SessionRecovery 精准记录恢复次数与断线原因码', () {
      fakeAsync((async) {
        final policy = SessionReconnectController();
        var shouldSucceed = true;
        late SessionRecovery recovery;
        recovery = SessionRecovery(
          automatic: true,
          isCurrent: () => true,
          policy: policy,
          reconnect: () async {
            if (shouldSucceed) {
              recovery.update(connected: true);
            }
          },
        );

        recovery.update(connected: true);
        expect(recovery.recoveryCount, 0);
        expect(recovery.lastDisconnectReason, isNull);

        // 模拟保活超时断流
        recovery.update(connected: false, disconnectReason: 'keepalive_timeout');
        expect(recovery.interrupted, isTrue);
        expect(recovery.lastDisconnectReason, 'keepalive_timeout');

        // 自动重连成功 -> recoveryCount 递增且清除断线原因
        async.elapse(const Duration(seconds: 5));
        expect(recovery.interrupted, isFalse);
        expect(recovery.recoveryCount, 1);
        expect(recovery.lastDisconnectReason, isNull);

        // 第二次远端断开 -> 重连失败后再成功
        shouldSucceed = false;
        recovery.update(connected: false, disconnectReason: 'remote_closed');
        async.elapse(const Duration(seconds: 5));
        expect(recovery.interrupted, isTrue);
        expect(recovery.lastDisconnectReason, 'remote_closed');

        shouldSucceed = true;
        async.elapse(const Duration(seconds: 5));
        expect(recovery.interrupted, isFalse);
        expect(recovery.recoveryCount, 2);

        recovery.dispose();
        policy.dispose();
      });
    });
  });

  group('SshKeepaliveSetting UI 四语与 390px 窄屏适配', () {
    for (final locale in const [
      Locale('zh'),
      Locale('en'),
      Locale('ja'),
      Locale('ru'),
    ]) {
      testWidgets('在 ${locale.languageCode} 下 390px 无溢出且可交互持久化', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        final store = MemorySshKeepaliveStore();
        final controller = SshKeepaliveController();
        addTearDown(controller.dispose);
        await controller.load(store);

        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: buildAppTheme(brightness: Brightness.dark),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SshKeepaliveSetting(controller: controller),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('ssh_keepalive_setting')), findsOneWidget);
        expect(tester.takeException(), isNull);

        // 切换前台探活开关
        await tester.tap(
          find.byKey(const ValueKey('ssh_keepalive_probe_on_resume_switch')),
        );
        await tester.pumpAndSettle();
        expect(controller.policy.probeOnResume, isFalse);
        expect(store.value, '15,3,0,60');

        // 切换心跳间隔为 30s
        await tester.tap(
          find.byKey(const ValueKey('ssh_keepalive_interval_dropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .descendant(
                of: find.byKey(
                  const ValueKey('ssh_keepalive_interval_option_30'),
                ),
                matching: find.byType(Text),
              )
              .last,
        );
        await tester.pumpAndSettle();
        expect(controller.policy.intervalSeconds, 30);
        expect(store.value, '30,3,0,60');

        // 切换密钥轮换周期为每 3 小时（180 分钟）
        await tester.tap(
          find.byKey(const ValueKey('ssh_keepalive_rekey_dropdown')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .descendant(
                of: find.byKey(
                  const ValueKey('ssh_keepalive_rekey_option_180'),
                ),
                matching: find.byType(Text),
              )
              .last,
        );
        await tester.pumpAndSettle();
        expect(controller.policy.rekeyMinutes, 180);
        expect(store.value, '30,3,0,180');
      });
    }

    testWidgets('支持注入独立 pasteSafetyController，切换持久化与写失败提示与全局单例隔离', (
      tester,
    ) async {
      final keepaliveStore = MemorySshKeepaliveStore();
      final keepaliveCtrl = SshKeepaliveController();
      addTearDown(keepaliveCtrl.dispose);
      await keepaliveCtrl.load(keepaliveStore);

      final pasteStore = MemoryPasteSafetyStore();
      final pasteCtrl = PasteSafetyController(enabled: true);
      addTearDown(pasteCtrl.dispose);
      await pasteCtrl.load(pasteStore);

      final globalBefore = PasteSafetyController.instance.enabled;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: buildAppTheme(brightness: Brightness.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: SshKeepaliveSetting(
                controller: keepaliveCtrl,
                pasteSafetyController: pasteCtrl,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('ssh_keepalive_save_failed')),
        findsNothing,
      );

      // 切换粘贴安全开关 -> 仅影响注入控制器，不污染全局单例
      await tester.tap(find.byKey(const ValueKey('paste_safety_guard_switch')));
      await tester.pumpAndSettle();
      expect(pasteCtrl.enabled, isFalse);
      expect(pasteStore.value, '0');
      expect(PasteSafetyController.instance.enabled, globalBefore);

      // 注入存储写失败 -> 展示保存失败提示
      pasteStore.failWith = const FileSystemException('disk full');
      await tester.tap(find.byKey(const ValueKey('paste_safety_guard_switch')));
      await tester.pumpAndSettle();
      expect(pasteCtrl.enabled, isTrue);
      expect(pasteCtrl.writeFailed, isTrue);
      expect(
        find.byKey(const ValueKey('ssh_keepalive_save_failed')),
        findsOneWidget,
      );
    });
  });

  group('真实本机回环 TCP (ServerSocket + connectNativeSocket) 集成测试', () {
    test(
      'connectNativeSocket 真实建连并在服务端进入静默黑洞后于超时内判定死链、关闭真实 Socket 且无泄漏',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        var blackhole = false;
        final acceptedPeers = <Socket>[];
        final serverPeerClosed = Completer<void>();

        final serverSub = server.listen((peer) {
          acceptedPeers.add(peer);
          peer.listen(
            (chunk) {
              if (!blackhole) {
                // 回显等长确认字节模拟正常心跳响应。
                peer.add(List<int>.filled(chunk.length, 0x41));
              }
            },
            onDone: () {
              if (!serverPeerClosed.isCompleted) serverPeerClosed.complete();
            },
            onError: (_) {
              if (!serverPeerClosed.isCompleted) serverPeerClosed.complete();
            },
          );
        });

        addTearDown(() async {
          for (final peer in acceptedPeers) {
            peer.destroy();
          }
          await serverSub.cancel();
          await server.close();
        });

        final socket = await SSHSocket.connect(
          server.address.address,
          server.port,
          timeout: const Duration(seconds: 2),
        );

        final pendingReplies = <Completer<void>>[];
        final clientSub = socket.stream.listen(
          (data) {
            for (var i = 0; i < data.length; i++) {
              if (pendingReplies.isNotEmpty) {
                final next = pendingReplies.removeAt(0);
                if (!next.isCompleted) next.complete();
              }
            }
          },
          onDone: () {
            while (pendingReplies.isNotEmpty) {
              final next = pendingReplies.removeAt(0);
              if (!next.isCompleted) {
                next.completeError(SSHSocketError('socket closed'));
              }
            }
          },
          onError: (Object error) {
            while (pendingReplies.isNotEmpty) {
              final next = pendingReplies.removeAt(0);
              if (!next.isCompleted) next.completeError(error);
            }
          },
        );
        addTearDown(clientSub.cancel);

        final latencies = <Duration>[];
        final twoLatencies = Completer<void>();
        final missed = <int>[];
        var deadCalls = 0;
        final deadCompleter = Completer<void>();
        var pingCalls = 0;

        final watchdog = SSHKeepAlive(
          interval: const Duration(milliseconds: 50),
          timeout: const Duration(milliseconds: 40),
          maxMissed: 2,
          ping: () {
            pingCalls++;
            final reply = Completer<void>();
            pendingReplies.add(reply);
            socket.sink.add(utf8.encode('P'));
            return reply.future;
          },
          onLatency: (rtt) {
            latencies.add(rtt);
            if (latencies.length >= 2 && !twoLatencies.isCompleted) {
              twoLatencies.complete();
            }
          },
          onMissed: missed.add,
          onDead: () {
            deadCalls++;
            socket.destroy();
            if (!deadCompleter.isCompleted) deadCompleter.complete();
          },
        );
        addTearDown(watchdog.stop);

        watchdog.start();
        // 阶段一：正常回包期间应成功采集真实本机回环 RTT，零丢包。
        await twoLatencies.future.timeout(const Duration(seconds: 2));
        expect(missed, isEmpty);
        expect(deadCalls, 0);

        // 阶段二：服务端切入静默黑洞（保持 TCP 半开但不回包）。
        blackhole = true;
        final blackholeStarted = DateTime.now();

        await deadCompleter.future.timeout(const Duration(seconds: 2));
        await serverPeerClosed.future.timeout(const Duration(seconds: 2));
        final elapsed = DateTime.now().difference(blackholeStarted);

        expect(
          elapsed,
          lessThan(const Duration(seconds: 1)),
          reason: '看门狗应在配置的保活超时窗口内快速判定死链',
        );
        expect(missed, [1, 2]);
        expect(deadCalls, 1);
        expect(watchdog.isDead, isTrue);
        expect(watchdog.isRunning, isFalse);

        // 阶段三：判定死链后不再发起任何 ping，确认无定时器泄漏。
        final pingsAtDeath = pingCalls;
        await Future<void>.delayed(const Duration(milliseconds: 160));
        expect(pingCalls, pingsAtDeath);
      },
    );

    test(
      'SSHClient keepAliveInterval == null 模式下连续 probeKeepAlive 超时达到 keepAliveMaxMissed 触发 onKeepAliveDead 并关闭真实 Socket',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final acceptedPeers = <Socket>[];
        final bannerReceived = Completer<void>();
        final serverPeerClosed = Completer<void>();

        final serverSub = server.listen((peer) {
          acceptedPeers.add(peer);
          peer.listen(
            (chunk) {
              if (chunk.isNotEmpty && !bannerReceived.isCompleted) {
                bannerReceived.complete();
              }
              // 静默黑洞：接受连接并吸收客户端报文，永不回包。
            },
            onDone: () {
              if (!serverPeerClosed.isCompleted) serverPeerClosed.complete();
            },
            onError: (_) {
              if (!serverPeerClosed.isCompleted) serverPeerClosed.complete();
            },
          );
        });

        addTearDown(() async {
          for (final peer in acceptedPeers) {
            peer.destroy();
          }
          await serverSub.cancel();
          await server.close();
        });

        final socket = await SSHSocket.connect(
          server.address.address,
          server.port,
          timeout: const Duration(seconds: 2),
        );

        final missed = <int>[];
        var deadCalls = 0;
        final client = SSHClient(
          socket,
          username: 'ops',
          keepAliveInterval: null,
          keepAliveMaxMissed: 2,
          onKeepAliveMissed: missed.add,
          onKeepAliveDead: () => deadCalls++,
        );
        addTearDown(() async {
          if (!client.isClosed) await client.close();
        });

        Object? doneError;
        final doneCompleter = Completer<void>();
        client.done.then(
          (_) {
            if (!doneCompleter.isCompleted) doneCompleter.complete();
          },
          onError: (Object error, StackTrace _) {
            doneError = error;
            if (!doneCompleter.isCompleted) doneCompleter.complete();
          },
        );

        // 验证 connectNativeSocket 真实建立了 TCP 通道并成功发送 SSH 版本报文。
        await bannerReceived.future.timeout(const Duration(seconds: 2));

        // 第一次主动探活（并发两次调用必须去重，仅计 1 次丢包，尚未达阈值不关闭）。
        final firstResults = await Future.wait([
          client.probeKeepAlive(timeout: const Duration(milliseconds: 60)),
          client.probeKeepAlive(timeout: const Duration(milliseconds: 60)),
        ]);
        expect(firstResults, [null, null]);
        expect(missed, [1]);
        expect(deadCalls, 0);
        expect(client.isClosed, isFalse);

        // 第二次连续超时达到 keepAliveMaxMissed(2) -> 必须触发 onKeepAliveDead 并关闭底层真实 TCP Socket。
        final secondResult = await client.probeKeepAlive(
          timeout: const Duration(milliseconds: 60),
        );
        expect(secondResult, isNull);
        expect(missed, [1, 2]);
        expect(deadCalls, 1);
        expect(client.isClosed, isTrue);

        await doneCompleter.future.timeout(const Duration(seconds: 2));
        expect(doneError, isA<SSHSocketError>());
        expect(doneError.toString(), contains('2 missed probes'));

        // 服务端真实 TCP Socket 应立即感知断流关闭，无句柄泄漏。
        await serverPeerClosed.future.timeout(const Duration(seconds: 2));

        // 已关闭后再次探活应直接返回 null，不再重复触发回调。
        expect(
          await client.probeKeepAlive(timeout: const Duration(milliseconds: 30)),
          isNull,
        );
        expect(missed, [1, 2]);
        expect(deadCalls, 1);
      },
    );

    test(
      'SSHClient 周期保活模式下面对真实 TCP 黑洞主动探活连续超时同样触发 onKeepAliveDead 并关闭真实 Socket',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final acceptedPeers = <Socket>[];
        final serverPeerClosed = Completer<void>();

        final serverSub = server.listen((peer) {
          acceptedPeers.add(peer);
          peer.listen(
            (_) {},
            onDone: () {
              if (!serverPeerClosed.isCompleted) serverPeerClosed.complete();
            },
            onError: (_) {
              if (!serverPeerClosed.isCompleted) serverPeerClosed.complete();
            },
          );
        });

        addTearDown(() async {
          for (final peer in acceptedPeers) {
            peer.destroy();
          }
          await serverSub.cancel();
          await server.close();
        });

        final socket = await SSHSocket.connect(
          server.address.address,
          server.port,
          timeout: const Duration(seconds: 2),
        );

        final missed = <int>[];
        var deadCalls = 0;
        final client = SSHClient(
          socket,
          username: 'ops',
          keepAliveInterval: const Duration(milliseconds: 80),
          keepAliveTimeout: const Duration(milliseconds: 50),
          keepAliveMaxMissed: 2,
          onKeepAliveMissed: missed.add,
          onKeepAliveDead: () => deadCalls++,
        );
        addTearDown(() async {
          if (!client.isClosed) await client.close();
        });

        Object? doneError;
        final doneCompleter = Completer<void>();
        client.done.then(
          (_) {
            if (!doneCompleter.isCompleted) doneCompleter.complete();
          },
          onError: (Object error, StackTrace _) {
            doneError = error;
            if (!doneCompleter.isCompleted) doneCompleter.complete();
          },
        );

        expect(
          await client.probeKeepAlive(timeout: const Duration(milliseconds: 50)),
          isNull,
        );
        expect(missed, [1]);
        expect(deadCalls, 0);
        expect(client.isClosed, isFalse);

        expect(
          await client.probeKeepAlive(timeout: const Duration(milliseconds: 50)),
          isNull,
        );
        expect(missed, [1, 2]);
        expect(deadCalls, 1);
        expect(client.isClosed, isTrue);

        await doneCompleter.future.timeout(const Duration(seconds: 2));
        expect(doneError, isA<SSHSocketError>());
        await serverPeerClosed.future.timeout(const Duration(seconds: 2));
      },
    );

    test(
      'keepAliveInterval == null 端到端链路：SshConnection.probeLiveness 连续超时关闭真实 Socket 并驱动 SessionRecovery 以 keepalive_timeout 重连',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final acceptedPeers = <Socket>[];
        final serverPeerClosed = Completer<void>();

        final serverSub = server.listen((peer) {
          acceptedPeers.add(peer);
          peer.listen(
            (_) {},
            onDone: () {
              if (!serverPeerClosed.isCompleted) serverPeerClosed.complete();
            },
            onError: (_) {
              if (!serverPeerClosed.isCompleted) serverPeerClosed.complete();
            },
          );
        });
        addTearDown(() async {
          for (final peer in acceptedPeers) {
            peer.destroy();
          }
          await serverSub.cancel();
          await server.close();
        });

        final socket = await SSHSocket.connect(
          server.address.address,
          server.port,
          timeout: const Duration(seconds: 2),
        );
        final health = SshConnectionHealth(maxMissedThreshold: 2);
        addTearDown(health.dispose);

        final client = SSHClient(
          socket,
          username: 'ops',
          keepAliveInterval: null,
          keepAliveMaxMissed: 2,
          onKeepAliveLatency: health.recordProbeSuccess,
          onKeepAliveMissed: health.recordProbeMissed,
          onKeepAliveDead: health.recordKeepaliveDead,
        );
        addTearDown(() async {
          if (!client.isClosed) await client.close();
        });

        final connection = SshConnection(
          client: client,
          session: _FakeProbeSession(),
          health: health,
        );
        final policy = SessionReconnectController();
        addTearDown(policy.dispose);
        var reconnectTriggered = false;
        final recovery = SessionRecovery(
          automatic: true,
          isCurrent: () => true,
          policy: policy,
          reconnect: () async {
            reconnectTriggered = true;
          },
        );
        addTearDown(recovery.dispose);
        recovery.update(connected: true);

        final clientDone = Completer<void>();
        client.done.then(
          (_) {
            recovery.update(
              connected: false,
              disconnectReason: health.keepaliveTimedOut
                  ? 'keepalive_timeout'
                  : 'remote_closed',
            );
            if (!clientDone.isCompleted) clientDone.complete();
          },
          onError: (Object _, StackTrace _) {
            recovery.update(
              connected: false,
              disconnectReason: health.keepaliveTimedOut
                  ? 'keepalive_timeout'
                  : 'transport_error',
            );
            if (!clientDone.isCompleted) clientDone.complete();
          },
        );

        // 第 1 次探活超时 -> degraded，不关闭底层连接。
        expect(
          await connection.probeLiveness(
            timeout: const Duration(milliseconds: 50),
          ),
          isFalse,
        );
        expect(health.state, SshHealthState.degraded);
        expect(health.missedProbes, 1);
        expect(health.keepaliveTimedOut, isFalse);
        expect(client.isClosed, isFalse);

        // 第 2 次探活超时达到阈值 -> onKeepAliveDead 标记 keepaliveTimedOut、销毁真实 TCP Socket，
        // 并将 SessionRecovery 切入 interrupted（disconnectReason == keepalive_timeout）。
        expect(
          await connection.probeLiveness(
            timeout: const Duration(milliseconds: 50),
          ),
          isFalse,
        );
        expect(health.keepaliveTimedOut, isTrue);
        expect(health.state, SshHealthState.closed);
        expect(client.isClosed, isTrue);

        await clientDone.future.timeout(const Duration(seconds: 2));
        await serverPeerClosed.future.timeout(const Duration(seconds: 2));
        expect(recovery.interrupted, isTrue);
        expect(recovery.lastDisconnectReason, 'keepalive_timeout');
        expect(reconnectTriggered, isFalse);
      },
    );
  });
}

class _FakeProbeClient implements SSHClient {
  _FakeProbeClient({required this.onProbe});

  final Future<Duration?> Function(Duration timeout) onProbe;

  @override
  bool get isClosed => false;

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<Duration?> probeKeepAlive({
    Duration timeout = const Duration(seconds: 5),
  }) => onProbe(timeout);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProbeSession implements SSHSession {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
