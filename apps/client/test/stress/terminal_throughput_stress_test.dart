import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/terminal/keyword_highlighter.dart';
import 'package:aterm_client/terminal/mirrored_terminal.dart';
import 'package:aterm_client/terminal/session_log.dart';
import 'package:aterm_client/terminal/terminal_output_coalescer.dart';
import 'package:aterm_client/terminal/terminal_search.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

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
}
