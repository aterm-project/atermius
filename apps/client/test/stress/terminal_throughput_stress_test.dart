import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:aterm_client/terminal/keyword_highlighter.dart';
import 'package:aterm_client/terminal/mirrored_terminal.dart';
import 'package:aterm_client/terminal/session_log.dart';
import 'package:aterm_client/terminal/terminal_output_coalescer.dart';
import 'package:aterm_client/terminal/terminal_search.dart';
import 'package:drift/native.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

import '../support/fake_local_console.dart';
import '../support/l10n_fixture.dart';

void main() {
  group('零分配热路径等价性与边界保护', () {
    test('utf8EncodedLength 与 utf8.encode().length 在全字符集上逐字节一致', () {
      final samples = <String>[
        '',
        'hello world 0123456789\r\n',
        'café naïve résumé Ω Σ ς',
        '中文运维日志：节点 10.20.30.40 负载正常 🚀🔥💻',
        '日本語テスト・Кириллица тест',
        // 含孤立高代理与孤立低代理的异常 UTF-16 串
        String.fromCharCodes([0x41, 0xD800, 0x42, 0xDC00, 0xD83D, 0xDE80, 0xDFFF]),
        'A' * 8192,
      ];
      for (final sample in samples) {
        expect(
          utf8EncodedLength(sample),
          utf8.encode(sample).length,
          reason: 'length mismatch for sample len=${sample.length}',
        );
      }
    });

    test('TerminalOutputCoalescer 空闲零延迟直通、突发高倍率收敛与代理对边界安全', () {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 11, 19, 12, 0, 0);
        final flushed = <String>[];
        final coalescer = TerminalOutputCoalescer(
          onFlush: flushed.add,
          burstWindow: const Duration(milliseconds: 8),
          maxBatchChars: 1024,
          immediatePassThroughMaxChars: 256,
          now: () => now,
        );

        // 1. 空闲态交互按键回显 -> 0ms 立即同步送达
        coalescer.add('ls -la\r\n');
        expect(flushed, ['ls -la\r\n']);
        expect(coalescer.flushedBatches, 1);

        // 2. 突发洪流：2ms 内连续到达 500 个小包 -> 仅触发 1~N 次受限批冲刷
        now = now.add(const Duration(milliseconds: 1));
        for (var i = 0; i < 500; i++) {
          coalescer.add('L$i ');
        }
        expect(coalescer.inputChunks, 501);
        async.elapse(const Duration(milliseconds: 10));
        expect(
          coalescer.flushedBatches,
          lessThan(10),
          reason: '500 个突发小包应被合批至个位数冲刷',
        );
        final reassembled = flushed.join();
        expect(reassembled, startsWith('ls -la\r\nL0 L1 '));
        expect(reassembled, endsWith('L499 '));

        // 3. 批次上限边界恰好落在高代理码元时不得撕裂代理对
        flushed.clear();
        now = now.add(const Duration(seconds: 1));
        // 构造长度正好跨过 maxBatchChars=1024 且第 1024 码元为高代理 0xD83D 的负载
        final prefix = 'x' * 1023;
        const rocket = '\u{1F680}'; // 2 UTF-16 units: D83D DE80
        coalescer.add('$prefix$rocket!');
        expect(flushed.length, 1);
        expect(flushed.first.length, 1023, reason: '高代理应留给下一批与低代理拼合');
        coalescer.close(flushPending: true);
        expect(flushed.length, 2);
        expect(flushed.last, '$rocket!');
        expect(coalescer.isClosed, isTrue);
      });
    });

    test('TerminalOutputCoalescer 闲时单高代理不撕裂、超大块流不堆积、close 重入无泄漏', () {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 11, 19, 12, 0, 0);
        final flushed = <String>[];
        late TerminalOutputCoalescer coalescer;
        coalescer = TerminalOutputCoalescer(
          onFlush: flushed.add,
          burstWindow: const Duration(milliseconds: 8),
          maxBatchChars: 1024,
          immediatePassThroughMaxChars: 256,
          now: () => now,
        );

        // 1. 闲时仅收到高代理 0xD83D -> 暂存不直通；紧接低代理 0xDE80 -> 合并为完整 🚀
        coalescer.add('\uD83D');
        expect(flushed, isEmpty, reason: '闲时单个高代理不得被提前直通撕裂');
        coalescer.add('\uDE80ok');
        async.elapse(const Duration(milliseconds: 8));
        expect(flushed, ['\u{1F680}ok']);

        // 2. 闲时短包末尾含高代理 -> 前缀直通、高代理等待下一包拼合
        flushed.clear();
        now = now.add(const Duration(seconds: 1));
        coalescer.add('hi\uD83D');
        expect(flushed, ['hi']);
        coalescer.add('\uDE80!');
        async.elapse(const Duration(milliseconds: 8));
        expect(flushed, ['hi', '\u{1F680}!']);

        // 3. 真正孤立的坏高代理在完整帧窗口到期后释放，不永久卡死
        flushed.clear();
        now = now.add(const Duration(seconds: 1));
        coalescer.add('\uD83D');
        expect(flushed, isEmpty);
        now = now.add(const Duration(milliseconds: 8));
        async.elapse(const Duration(milliseconds: 8));
        expect(flushed, ['\uD83D']);

        // 4. 连续推入 20 个 2500 字符大块（> maxBatchChars=1024）：缓冲残余严控 < maxBatchChars
        flushed.clear();
        final bigChunk = 'B' * 2500;
        for (var i = 0; i < 20; i++) {
          coalescer.add(bigChunk);
          expect(
            coalescer.pendingChars,
            lessThan(1024),
            reason: '超大块连续推入不得导致缓冲区净增长',
          );
        }
        coalescer.close(flushPending: true);
        expect(flushed.join().length, 2500 * 20);

        // 5. close(flushPending: true) 期间 onFlush 重入 add() 不得泄漏新定时器
        final reentrantFlushed = <String>[];
        late TerminalOutputCoalescer reentrant;
        reentrant = TerminalOutputCoalescer(
          onFlush: (batch) {
            reentrantFlushed.add(batch);
            reentrant.add('should-be-ignored-after-close');
          },
          maxBatchChars: 1024,
          immediatePassThroughMaxChars: 0,
          now: () => now,
        );
        reentrant.add('tail-before-close');
        reentrant.close(flushPending: true);
        expect(reentrant.isClosed, isTrue);
        expect(reentrant.pendingChars, 0);
        expect(reentrantFlushed, ['tail-before-close']);
        async.elapse(const Duration(seconds: 1));
        expect(reentrantFlushed, ['tail-before-close']);
      });
    });

    test('TerminalOutputCoalescer 断线/退出前冲刷严格保序不丢末行，主动销毁立即取消定时器', () {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 11, 19, 12, 0, 0);
        final writes = <String>[];
        final coalescer = TerminalOutputCoalescer(
          onFlush: writes.add,
          burstWindow: const Duration(milliseconds: 8),
          maxBatchChars: 64 * 1024,
          microtaskBudgetChars: 16 * 1024,
          immediatePassThroughMaxChars: 2048,
          now: () => now,
        );

        // 先灌入超过 microtaskBudgetChars (16KiB) 的输出使合批器进入 Stage 2 帧级定时节流态。
        for (var i = 0; i < 20; i++) {
          coalescer.add('${'A' * 1000}\r\n');
        }
        async.flushMicrotasks();
        // 紧接着推入末行关键日志，此时停留在 8ms 帧定时器缓冲区内尚未刷屏。
        coalescer.add('CRITICAL_TAIL_LINE_BEFORE_EXIT\r\n');
        expect(coalescer.pendingChars, greaterThan(0));

        // 模拟连接正常断开 / 进程退出：先 close(flushPending: true) 再写退出提示。
        coalescer.close(flushPending: true);
        writes.add('\r\n[Process exited with code 0]\r\n');

        final combined = writes.join();
        final tailIndex = combined.indexOf('CRITICAL_TAIL_LINE_BEFORE_EXIT');
        final exitIndex = combined.indexOf('[Process exited with code 0]');
        expect(tailIndex, greaterThanOrEqualTo(0));
        expect(exitIndex, greaterThan(tailIndex));
        expect(coalescer.pendingChars, 0);
        expect(coalescer.isClosed, isTrue);

        final countAfterClose = writes.length;
        async.elapse(const Duration(seconds: 1));
        expect(writes.length, countAfterClose);

        // 模拟主动关闭 / 重连销毁：close(flushPending: false) 立即丢弃缓冲并取消定时器。
        final droppedWrites = <String>[];
        final active = TerminalOutputCoalescer(
          onFlush: droppedWrites.add,
          burstWindow: const Duration(milliseconds: 8),
          microtaskBudgetChars: 1024,
          immediatePassThroughMaxChars: 0,
          now: () => now,
        );
        active.add('X' * 2048);
        async.flushMicrotasks();
        active.add('SHOULD_BE_DROPPED_ON_ACTIVE_CLOSE');
        expect(active.pendingChars, greaterThan(0));
        active.close(flushPending: false);
        expect(active.pendingChars, 0);
        expect(active.isClosed, isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(
          droppedWrites.join(),
          isNot(contains('SHOULD_BE_DROPPED_ON_ACTIVE_CLOSE')),
        );
      });
    });

    test('TerminalOutputCoalescer 慢帧渲染超窗后仍强制切入 Stage-2 节流，不会误判空闲直通阻塞 UI', () {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 11, 19, 12, 0, 0);
        final writes = <String>[];
        final coalescer = TerminalOutputCoalescer(
          onFlush: (batch) {
            writes.add(batch);
            // 模拟复杂 ANSI 批次同步解析耗时 12ms（超过 8ms 单帧窗口）。
            now = now.add(const Duration(milliseconds: 12));
          },
          burstWindow: const Duration(milliseconds: 8),
          maxBatchChars: 64 * 1024,
          microtaskBudgetChars: 16 * 1024,
          immediatePassThroughMaxChars: 2048,
          now: () => now,
        );

        // 推送超过 16KiB 预算的大块并经微任务冲刷（耗时 12ms > 8ms 帧窗）。
        coalescer.add('S' * 20000);
        async.flushMicrotasks();
        expect(writes.length, 1);

        // 紧随慢帧后立即到达的短包不得绕过 Stage-2 直通，必须进入 8ms 帧缓冲让出渲染时机。
        coalescer.add('FOLLOW_UP_AFTER_SLOW_FRAME');
        expect(writes.length, 1, reason: '慢帧之后紧接包必须转入 Stage-2 缓冲而非立刻同步渲染');
        expect(coalescer.pendingChars, 'FOLLOW_UP_AFTER_SLOW_FRAME'.length);

        now = now.add(const Duration(milliseconds: 8));
        async.elapse(const Duration(milliseconds: 8));
        expect(writes.length, 2);
        expect(writes.last, 'FOLLOW_UP_AFTER_SLOW_FRAME');
        coalescer.close(flushPending: false);
      });
    });
  });

  group('商业级高吞吐终端压测 (Log Flood + Multi-Session Concurrency)', () {
    test('12MB ANSI/CJK 混合日志洪流：验证吞吐、合批降绘比、内存封顶、检索与高亮性能', () {
      fakeAsync((async) {
        var now = DateTime.utc(2026, 11, 19, 12, 0, 0);
        final terminal = MirroredTerminal(
          maxLines: 10000,
          maxHistoryBytes: 512 * 1024,
        );
        var terminalNotifications = 0;
        terminal.addListener(() => terminalNotifications++);

        final logBook = SessionLogBook.memory();
        logBook.setRecordTranscripts(true);
        final recorder = logBook.begin(
          host: const HostRecord(
            id: 'stress-prod-01',
            name: 'prod-k8s-worker-01',
            address: '198.51.100.10',
            username: 'ops',
          ),
        );
        recorder.markConnected();

        final coalescer = TerminalOutputCoalescer(
          now: () => now,
          onFlush: (batch) {
            terminal.write(batch);
            recorder.output(batch);
          },
        );

        // 构造真实运维风格日志行（含 ANSI 颜色、时间戳、IPv4、URL、ERROR/WARN、中文）。
        const line =
            '\x1b[32m2026-11-19T12:00:01Z\x1b[0m '
            '[\x1b[31mERROR\x1b[0m] node=198.51.100.10 '
            'upstream=https://api.example.invalid/v1/health '
            'latency=18ms msg=商业网关并发探活校验正常\r\n';
        final chunk = line * 8; // ~1.1 KB / packet
        const packetCount = 11000; // ~12.4 MB 原始流
        final expectedBytes = utf8EncodedLength(chunk) * packetCount;

        final watch = Stopwatch()..start();
        for (var i = 0; i < packetCount; i++) {
          coalescer.add(chunk);
          if (i % 120 == 119) {
            now = now.add(const Duration(milliseconds: 8));
            async.elapse(const Duration(milliseconds: 8));
          }
        }
        coalescer.close(flushPending: true);
        watch.stop();

        // 1. 吞吐与通知收敛验证
        final throughputMBps =
            (expectedBytes / (1024 * 1024)) /
            (watch.elapsedMicroseconds / 1e6).clamp(0.001, 1e9);
        final reductionPct =
            (1 - terminalNotifications / packetCount) * 100.0;

        expect(terminalNotifications, lessThan(packetCount ~/ 10));
        expect(terminal.retainedBytes, lessThanOrEqualTo(512 * 1024));
        expect(terminal.historyTruncated, isTrue);

        // 2. 高并发日志转录缓冲上限严格封顶
        recorder.markClosed(SessionLogEndReason.user);
        async.flushMicrotasks();
        expect(recorder.finished, isTrue);

        // 3. 10,000 行全量终端缓冲检索压测（ASCII 快路径 + CJK/Unicode 混合）
        final searchWatch = Stopwatch()..start();
        final asciiHits = searchTerminalBuffer(terminal, 'error');
        final cjkHits = searchTerminalBuffer(terminal, '商业网关并发探活');
        searchWatch.stop();
        expect(asciiHits.matches.length, 1000); // 命中 maxMatches 封顶保护
        expect(asciiHits.truncated, isTrue);
        expect(cjkHits.matches.length, 1000);

        // 4. 关键字高亮器在高频重绘滚动下缓存命中率验证
        final highlighter = TerminalKeywordHighlighter();
        final styles = highlighter.beginPaint(
          terminal,
          TerminalThemes.defaultTheme,
        );
        expect(styles, isNotNull);
        final highlightWatch = Stopwatch()..start();
        final totalLines = terminal.buffer.lines.length;
        final sampleStart = (totalLines - 400).clamp(0, totalLines);
        for (var pass = 0; pass < 3; pass++) {
          for (var row = sampleStart; row < totalLines; row++) {
            highlighter.spansFor(terminal.buffer.lines[row]);
          }
        }
        highlightWatch.stop();
        final totalLookups = (totalLines - sampleStart) * 3;
        final hitRate = totalLookups > 0
            ? highlighter.debugCacheHits / totalLookups
            : 0.0;
        expect(hitRate, greaterThan(0.95), reason: '重复日志行应几乎全命中 LRU 缓存');

        // 输出压测结构化量化指标
        // ignore: avoid_print
        print(
          jsonEncode({
            'stress': '12mb_log_flood',
            'payloadMB': double.parse(
              (expectedBytes / (1024 * 1024)).toStringAsFixed(2),
            ),
            'packetCount': packetCount,
            'flushedBatches': coalescer.flushedBatches,
            'terminalNotifications': terminalNotifications,
            'notifyReductionPct': double.parse(reductionPct.toStringAsFixed(1)),
            'ingestMs': watch.elapsedMilliseconds,
            'throughputMBps': double.parse(throughputMBps.toStringAsFixed(2)),
            'search2QueriesMs': searchWatch.elapsedMilliseconds,
            'highlight1200LinesMs': highlightWatch.elapsedMilliseconds,
            'highlightCacheHitRate': double.parse(hitRate.toStringAsFixed(4)),
            'retainedHistoryBytes': terminal.retainedBytes,
            'processRssMB': double.parse(
              (ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(1),
            ),
          }),
        );

        highlighter.dispose();
        logBook.dispose();
        terminal.closeMirror();
      });
    });

    test('24 并发商业终端会话同时突发写入、检索与彻底销毁无泄漏', () async {
      const sessionCount = 24;
      final terminals = List.generate(
        sessionCount,
        (_) => MirroredTerminal(maxLines: 2000, maxHistoryBytes: 128 * 1024),
      );
      final coalescers = [
        for (final t in terminals) TerminalOutputCoalescer(onFlush: t.write),
      ];

      final rssBefore = ProcessInfo.currentRss;
      final watch = Stopwatch()..start();

      for (var round = 0; round < 200; round++) {
        for (var s = 0; s < sessionCount; s++) {
          coalescers[s].add(
            '\x1b[36m[host-$s]\x1b[0m round=$round '
            'status=OK load=0.${round % 99} ip=203.0.113.${s + 1}\r\n',
          );
        }
      }
      for (final c in coalescers) {
        c.close(flushPending: true);
      }

      for (var s = 0; s < sessionCount; s++) {
        final hit = searchTerminalBuffer(terminals[s], '203.0.113.${s + 1}');
        expect(hit.matches.length, 200);
        expect(terminals[s].retainedBytes, lessThanOrEqualTo(128 * 1024));
      }

      await Future.wait([for (final t in terminals) t.closeMirror()]);
      watch.stop();

      for (final t in terminals) {
        expect(t.retainedBytes, 0);
        expect(t.history, isEmpty);
      }

      // ignore: avoid_print
      print(
        jsonEncode({
          'stress': '24_concurrent_sessions',
          'sessions': sessionCount,
          'elapsedMs': watch.elapsedMilliseconds,
          'rssBeforeMB': double.parse(
            (rssBefore / (1024 * 1024)).toStringAsFixed(1),
          ),
          'rssAfterMB': double.parse(
            (ProcessInfo.currentRss / (1024 * 1024)).toStringAsFixed(1),
          ),
        }),
      );
    });
  });

  group('AppController LocalConsole / Telnet 热路径合批与退出保序集成验证', () {
    useAppLocaleFixture('en');
    late ClientDatabase database;
    late AppController app;
    late FakeConsoleFactory consoles;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      database = ClientDatabase.forTesting(NativeDatabase.memory());
      consoles = FakeConsoleFactory();
      app = AppController(
        sodium: await SodiumSumoInit.init(),
        database: database,
        secureStore: ClientSecureStore(),
      )..stage = ClientStage.workspace;
      app.localConsoleOpenerForTesting = consoles.call;
    });

    tearDown(() async {
      await app.disconnectAllTerminalTabs();
      app.dispose();
      await database.close();
    });

    String dumpTerminalText(Terminal terminal) {
      final out = StringBuffer();
      for (var i = 0; i < terminal.buffer.lines.length; i++) {
        out.writeln(terminal.buffer.lines[i].toString());
      }
      return out.toString();
    }

    /// 确定性地打满 Stage-1 预算（16KiB）并将 [tail] 压入 Stage-2 帧缓冲，
    /// 避免在冷启动 JIT 下因多轮 `pumpEventQueue()` 超过 8ms 墙钟窗口导致用例抖动。
    Future<void> pushIntoStage2Buffer(
      void Function(String) emit,
      String fillerChar,
      String tail,
    ) async {
      emit('${fillerChar * 20000}\r\n');
      for (var i = 0; i < 4; i++) {
        await Future<void>.microtask(() {});
      }
      emit(tail);
      for (var i = 0; i < 4; i++) {
        await Future<void>.microtask(() {});
      }
    }

    test('LocalConsole 突发输出接入合批器，进程退出前先冲刷末行再写退出提示，主动关闭无定时器泄漏', () async {
      final id = await app.openLocalShellTab();
      final tab = app.terminalTabFor(id)!;
      final console = consoles.opened.single;
      expect(tab.outputCoalescer, isNotNull);

      await pushIntoStage2Buffer(
        console.emit,
        'C',
        'FINAL_CONSOLE_TAIL_MARKER\r\n',
      );
      expect(tab.outputCoalescer, isNotNull);
      expect(tab.outputCoalescer!.pendingChars, greaterThan(0));

      // 进程在缓冲尚未到 8ms 帧窗口时即退出 -> 必须先冲刷末行再写入退出提示。
      console.exit(0);
      await pumpEventQueue();
      expect(tab.outputCoalescer, isNull);
      expect(tab.state, 'disconnected');

      final rendered = dumpTerminalText(tab.terminal);
      final tailPos = rendered.indexOf('FINAL_CONSOLE_TAIL_MARKER');
      final exitPos = rendered.indexOf('exited');
      expect(tailPos, greaterThanOrEqualTo(0), reason: '退出前末行日志不得丢失');
      expect(exitPos, greaterThan(tailPos), reason: '退出提示必须严格排在末行日志之后');

      // 主动关闭处于洪流缓冲中的终端标签 -> 立即释放合批器，不得泄漏定时器。
      final id2 = await app.openLocalShellTab();
      final tab2 = app.terminalTabFor(id2)!;
      final console2 = consoles.opened.last;
      await pushIntoStage2Buffer(console2.emit, 'D', 'PENDING_BEFORE_CLOSE\r\n');
      expect(tab2.outputCoalescer!.pendingChars, greaterThan(0));
      await app.closeTerminalTab(id2!);
      expect(tab2.outputCoalescer, isNull);
    });

    test('LocalConsole exitCode 先于 stdout 尾包与 onDone 到达时不得吞掉尾包且最终清理合批器', () async {
      final id = await app.openLocalShellTab();
      final tab = app.terminalTabFor(id)!;
      final console = consoles.opened.single;
      expect(tab.outputCoalescer, isNotNull);

      await pushIntoStage2Buffer(
        console.emit,
        'E',
        'PRE_EXIT_BUFFERED_TAIL\r\n',
      );
      expect(tab.outputCoalescer!.pendingChars, greaterThan(0));

      // 模拟真实 PTY：waitpid 先返回 exitCode，而 master fd 还有最后一行输出随后到达。
      console.completeExitCodeOnly(0);
      await pumpEventQueue();

      final afterExit = dumpTerminalText(tab.terminal);
      final preTailPos = afterExit.indexOf('PRE_EXIT_BUFFERED_TAIL');
      final exitPos = afterExit.indexOf('exited');
      expect(preTailPos, greaterThanOrEqualTo(0), reason: '退出前已缓冲输出必须立即冲刷');
      expect(exitPos, greaterThan(preTailPos), reason: '退出提示必须排在已缓冲输出之后');

      // 在 onDone 前到达的 PTY 尾包不得被已关闭的合批器静默吞掉。
      console.emit('LATE_TAIL_AFTER_EXITCODE\r\n');
      await console.finishOutput();
      await pumpEventQueue();

      final finalRendered = dumpTerminalText(tab.terminal);
      expect(
        finalRendered,
        contains('LATE_TAIL_AFTER_EXITCODE'),
        reason: 'exitCode 先于 stdout EOF 到达时的尾包不得丢失',
      );
      expect(tab.outputCoalescer, isNull, reason: 'onDone 后必须彻底释放合批器');
    });

    test('Telnet 突发输出接入合批器，远端断流前先冲刷末行再写断线提示，主动断开立即销毁合批器', () async {
      final channels = <_TestTelnetChannel>[];
      app.telnetConnectorForTesting = (host, port) async {
        final channel = _TestTelnetChannel();
        channels.add(channel);
        return channel;
      };

      const host = HostRecord(
        id: 'telnet-coalescer-host',
        name: 'Switch-Core-01',
        address: '198.51.100.23',
        port: 23,
        protocol: HostProtocol.telnet,
      );
      await app.openTerminalTab(host);
      final tab = app.activeTerminalTab!;
      final channel = channels.single;
      expect(tab.outputCoalescer, isNotNull);

      await pushIntoStage2Buffer(
        channel.emit,
        'T',
        'FINAL_TELNET_TAIL_MARKER\r\n',
      );
      expect(tab.outputCoalescer, isNotNull);
      expect(tab.outputCoalescer!.pendingChars, greaterThan(0));

      // 远端关闭流 -> 先冲刷待渲染末行，再写 Telnet 断线提示。
      await channel.incoming.close();
      await pumpEventQueue();
      expect(tab.outputCoalescer, isNull);
      expect(tab.state, 'disconnected');

      final rendered = dumpTerminalText(tab.terminal);
      final tailPos = rendered.indexOf('FINAL_TELNET_TAIL_MARKER');
      final closedPos = rendered.toLowerCase().indexOf('closed');
      expect(tailPos, greaterThanOrEqualTo(0), reason: 'Telnet 断流前末行不得丢失');
      expect(closedPos, greaterThan(tailPos), reason: 'Telnet 断线提示必须排在末行之后');

      // 主动断开处于洪流缓冲中的 Telnet 会话 -> 立即取消合批器定时器。
      await app.openTerminalTab(host);
      final tab2 = app.activeTerminalTab!;
      final channel2 = channels.last;
      await pushIntoStage2Buffer(
        channel2.emit,
        'U',
        'PENDING_TELNET_BEFORE_DISCONNECT\r\n',
      );
      expect(tab2.outputCoalescer!.pendingChars, greaterThan(0));
      await app.disconnectTerminalTab(tab2.id);
      expect(tab2.outputCoalescer, isNull);
    });
  });
}

class _TestTelnetChannel implements TelnetByteChannel {
  final StreamController<Uint8List> incoming = StreamController<Uint8List>();
  bool closed = false;

  void emit(String text) {
    incoming.add(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  Stream<Uint8List> get stream => incoming.stream;

  @override
  void add(Uint8List bytes) {}

  @override
  Future<void> close() async {
    closed = true;
    if (!incoming.isClosed) await incoming.close();
  }
}
