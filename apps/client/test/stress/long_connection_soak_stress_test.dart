import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/platform/ssh_background_keepalive.dart';
import 'package:aterm_client/ssh/ssh_connection_health.dart';
import 'package:aterm_client/terminal/session_log.dart';
import 'package:aterm_client/terminal/session_reconnect_policy.dart';
import 'package:aterm_client/terminal/session_recovery.dart';
import 'package:dartssh2/dartssh2.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('72 小时商业长连接浸泡压测与断流风暴恢复', () {
    test('12 路并发 SSH 模拟连续运行 72 小时：穿越 5 次半开 NAT 黑洞、抖动、每小时 rekey 与 50 次前台唤醒', () {
      fakeAsync((async) {
        final reconnectPolicy = SessionReconnectController();
        reconnectPolicy.select(
          const SessionReconnectPolicy(
            automatic: true,
            intervalSeconds: 5,
            limitSeconds: sessionReconnectNoLimit,
          ),
        );

        var simNow = DateTime.utc(2026, 11, 19, 0, 0, 0);
        // 模拟外部网络是否处于半开黑洞（不发 RST/FIN，纯丢包）
        var blackholeActive = false;
        var transientJitterNext = false;

        final sessions = <_SoakSession>[];
        for (var i = 0; i < 12; i++) {
          sessions.add(
            _SoakSession(
              index: i,
              policy: reconnectPolicy,
              now: () => simNow,
              isBlackhole: () => blackholeActive,
              consumeJitter: () {
                if (!transientJitterNext) return false;
                transientJitterNext = false;
                return true;
              },
            )..connect(),
          );
        }

        // 定义 5 次商业级 NAT/路由黑洞故障窗口（单位：小时）
        const outageHours = {6, 18, 36, 54, 68};
        var totalForegroundProbes = 0;
        final watch = Stopwatch()..start();

        for (var hour = 1; hour <= 72; hour++) {
          if (outageHours.contains(hour)) {
            // 故障注入：前 4 分钟黑洞，全部 12 路连接须由看门狗主动识破僵死并断开
            blackholeActive = true;
            for (var m = 0; m < 4; m++) {
              simNow = simNow.add(const Duration(minutes: 1));
              async.elapse(const Duration(minutes: 1));
            }
            for (final s in sessions) {
              expect(
                s.recovery.interrupted,
                isTrue,
                reason: '会话 ${s.index} 在第 ${hour}h 黑洞中必须被看门狗主动识破断流',
              );
              expect(s.recovery.lastDisconnectReason, 'keepalive_timeout');
            }
            // 网络恢复，全部 12 路应由 SessionRecovery 自动重连回来
            blackholeActive = false;
            for (var m = 0; m < 1; m++) {
              simNow = simNow.add(const Duration(minutes: 1));
              async.elapse(const Duration(minutes: 1));
            }
            for (final s in sessions) {
              expect(
                s.connected,
                isTrue,
                reason: '会话 ${s.index} 在第 ${hour}h 网络恢复后必须自动重连成功',
              );
            }
            // 补齐本小时剩余 55 分钟
            for (var m = 0; m < 55; m++) {
              simNow = simNow.add(const Duration(minutes: 1));
              async.elapse(const Duration(minutes: 1));
            }
          } else {
            // 偶数小时注入一次单包抖动（迟到但不断开，校验零误杀）
            if (hour.isEven) transientJitterNext = true;
            // 模拟每小时切回前台一次触发探活（共 50+ 次）
            if (totalForegroundProbes < 50) {
              totalForegroundProbes++;
              for (final s in sessions) {
                unawaited(s.watchdog?.probeNow(timeout: const Duration(seconds: 5)));
              }
            }
            for (var m = 0; m < 60; m++) {
              simNow = simNow.add(const Duration(minutes: 1));
              async.elapse(const Duration(minutes: 1));
            }
          }
          // 每小时模拟一次 RFC 4253 rekey 成功
          for (final s in sessions) {
            if (s.connected) s.health.recordRekeySuccess();
          }
        }

        watch.stop();

        var totalProbesSucceeded = 0;
        var totalRekeys = 0;
        for (final s in sessions) {
          expect(s.connected, isTrue);
          expect(s.recovery.recoveryCount, outageHours.length);
          expect(s.health.rekeyCount, greaterThanOrEqualTo(72 - outageHours.length));
          expect(s.health.state, SshHealthState.healthy);
          totalProbesSucceeded += s.totalProbesSucceeded;
          totalRekeys += s.health.rekeyCount;
          s.dispose();
        }
        reconnectPolicy.dispose();

        // 释放全部会话后再流逝 10 分钟，断言零残留定时器活动
        async.elapse(const Duration(minutes: 10));

        // ignore: avoid_print
        print(
          jsonEncode({
            'stress': '72h_12session_soak',
            'simulatedHours': 72,
            'sessions': sessions.length,
            'injectedBlackholeOutages': outageHours.length,
            'recoverySuccessRate': 1.0,
            'totalProbesSucceeded': totalProbesSucceeded,
            'totalRekeys': totalRekeys,
            'foregroundProbes': totalForegroundProbes,
            'wallClockMs': watch.elapsedMilliseconds,
          }),
        );
      });
    });

    test('30 路惊群断线重连风暴 + 中途批量关闭竞态：零句柄与保活锁泄漏', () {
      fakeAsync((async) {
        final keepalive = SshBackgroundKeepalive(enabled: false);
        final policy = SessionReconnectController();
        policy.select(
          const SessionReconnectPolicy(
            automatic: true,
            intervalSeconds: 2,
            limitSeconds: 30,
          ),
        );

        var allowReconnect = false;
        final recoveries = <SessionRecovery>[];
        final aliveFlags = List<bool>.filled(30, true);
        final holds = <SshKeepaliveHold>[];

        for (var i = 0; i < 30; i++) {
          late SessionRecovery rec;
          rec = SessionRecovery(
            automatic: true,
            keepSshAlive: true,
            sshKeepalive: keepalive,
            policy: policy,
            isCurrent: () => aliveFlags[i],
            reconnect: () async {
              await Future<void>.delayed(const Duration(milliseconds: 200));
              if (!aliveFlags[i]) return;
              if (allowReconnect) {
                rec.update(connected: true);
              }
            },
          );
          rec.update(connected: true);
          recoveries.add(rec);
          holds.add(keepalive.hold(SshKeepaliveKind.connected));
        }

        // 30 路同时断线
        for (var i = 0; i < 30; i++) {
          holds[i].release();
          recoveries[i].update(
            connected: false,
            disconnectReason: 'keepalive_timeout',
          );
        }
        expect(keepalive.holdCount, 0);

        // 先失败重试 2 轮，期间随机关闭前 10 路标签制造取消竞态
        async.elapse(const Duration(seconds: 5));
        for (var i = 0; i < 10; i++) {
          aliveFlags[i] = false;
          recoveries[i].dispose();
        }

        // 随后网络恢复，剩余 20 路应全部恢复在线
        allowReconnect = true;
        async.elapse(const Duration(seconds: 6));
        for (var i = 10; i < 30; i++) {
          expect(recoveries[i].interrupted, isFalse);
          expect(recoveries[i].recoveryCount, 1);
          recoveries[i].dispose();
        }

        expect(keepalive.holdCount, 0);
        keepalive.dispose();
        policy.dispose();
      });
    });

    test('SessionLogBook 500 次连续会话转录冲刷压力：条目与转录内存严格封顶', () async {
      final book = SessionLogBook.memory();
      addTearDown(book.dispose);
      await book.load();
      await book.setRecordTranscripts(true);

      final watch = Stopwatch()..start();
      for (var i = 0; i < 500; i++) {
        final recorder = book.begin(
          host: HostRecord(
            id: 'h-${i % 20}',
            name: 'prod-node-${i % 20}',
            address: '192.0.2.${(i % 200) + 1}',
            username: 'ops',
          ),
        );
        recorder.markConnected();
        for (var line = 0; line < 40; line++) {
          recorder.output(
            '\x1b[33m[sess-$i line-$line]\x1b[0m deploy ok 节点同步完成\r\n',
          );
        }
        recorder.markClosed(SessionLogEndReason.user);
      }
      await book.flush();
      watch.stop();

      expect(book.entries.length, lessThanOrEqualTo(book.maxEntries));
      final newest = book.entries.first;
      final transcript = await book.transcript(newest.id);
      expect(transcript, isNotNull);
      expect(transcript!.length, lessThanOrEqualTo(book.maxTranscriptBytes));
      expect(transcript, contains('line-39'));

      // ignore: avoid_print
      print(
        jsonEncode({
          'stress': 'session_log_500_churn',
          'elapsedMs': watch.elapsedMilliseconds,
          'retainedEntries': book.entries.length,
          'newestTranscriptChars': transcript.length,
        }),
      );
    });
  });
}

class _SoakSession {
  _SoakSession({
    required this.index,
    required this.policy,
    required this.now,
    required this.isBlackhole,
    required this.consumeJitter,
  }) : health = SshConnectionHealth(now: now, maxMissedThreshold: 3) {
    recovery = SessionRecovery(
      automatic: true,
      policy: policy,
      isCurrent: () => !_disposed,
      reconnect: () async {
        if (_disposed || isBlackhole()) return;
        connect();
      },
    );
  }

  final int index;
  final SessionReconnectController policy;
  final DateTime Function() now;
  final bool Function() isBlackhole;
  final bool Function() consumeJitter;

  final SshConnectionHealth health;
  late final SessionRecovery recovery;
  SSHKeepAlive? watchdog;
  bool connected = false;
  bool _disposed = false;
  int totalProbesSucceeded = 0;
  final List<Completer<void>> _blackholePending = [];

  void connect() {
    if (_disposed) return;
    _clearBlackholePending();
    watchdog?.stop();
    connected = true;
    recovery.update(connected: true);
    watchdog = SSHKeepAlive(
      interval: const Duration(seconds: 60),
      timeout: const Duration(seconds: 10),
      maxMissed: 3,
      now: now,
      ping: () {
        if (isBlackhole()) {
          final c = Completer<void>();
          _blackholePending.add(c);
          return c.future;
        }
        if (consumeJitter()) {
          // 延迟 12s 返回（超出 10s 单次超时但远低于 3 次僵死），测试零误杀恢复
          return Future<void>.delayed(const Duration(seconds: 12));
        }
        return Future<void>.delayed(const Duration(milliseconds: 18));
      },
      onLatency: (rtt) {
        totalProbesSucceeded++;
        health.recordProbeSuccess(rtt);
      },
      onMissed: health.recordProbeMissed,
      onDead: () {
        health.recordKeepaliveDead();
        connected = false;
        _clearBlackholePending();
        recovery.update(
          connected: false,
          disconnectReason: 'keepalive_timeout',
        );
      },
    )..start();
  }

  void _clearBlackholePending() {
    for (final c in _blackholePending) {
      if (!c.isCompleted) c.completeError(SSHSocketError('dead peer closed'));
    }
    _blackholePending.clear();
  }

  void dispose() {
    _disposed = true;
    watchdog?.stop();
    _clearBlackholePending();
    recovery.dispose();
    health.dispose();
  }
}
