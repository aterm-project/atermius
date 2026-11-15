import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/mcp_access_policy.dart';
import 'package:aterm_client/mcp/mcp_protocol.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:aterm_client/terminal/mirrored_terminal.dart';
import 'package:aterm_client/terminal/scrollback_spill_store_io.dart';
import 'package:aterm_client/terminal/terminal_scrollback_tiers.dart';
import 'package:aterm_client/terminal/terminal_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

const _words = [
  'accepted',
  'connection',
  'from',
  'worker',
  'request',
  'finished',
  'cache',
  'miss',
  'retrying',
  'upstream',
  'timeout',
  'scheduled',
  'job',
  'started',
  'completed',
  'status',
  'session',
  'opened',
  'closed',
  'bytes',
  'written',
  'queue',
  'depth',
  'threshold',
  'reloading',
  'configuration',
  'health',
  'check',
  'passed',
  'failed',
  'node',
  'joined',
  'cluster',
  'compaction',
  'segment',
  'replica',
  'lag',
  'handshake',
  'peer',
  'renewed',
  'lease',
];

/// Realistic log text; random enough that it does not compress to nothing.
String _logLine(Random random, int i) {
  final buffer = StringBuffer('row $i ')
    ..write(const ['INFO ', 'WARN ', 'DEBUG', 'ERROR'][random.nextInt(4)])
    ..write(' ');
  for (var k = 0; k < 4 + random.nextInt(4); k++) {
    buffer
      ..write(_words[random.nextInt(_words.length)])
      ..write(' ');
  }
  buffer.write('id=${random.nextInt(1 << 30).toRadixString(16)}');
  final line = buffer.toString();
  return line.length > 78 ? line.substring(0, 78) : line;
}

void _expectSameLines(Terminal actual, Terminal expected) {
  final a = actual.buffer.lines;
  final e = expected.buffer.lines;
  expect(a.length, e.length);
  for (var y = 0; y < e.length; y++) {
    if (a[y].isWrapped != e[y].isWrapped) fail('wrap flag of line $y');
    for (var x = 0; x < expected.viewWidth; x++) {
      if (a[y].getContent(x) != e[y].getContent(x) ||
          a[y].getForeground(x) != e[y].getForeground(x) ||
          a[y].getBackground(x) != e[y].getBackground(x) ||
          a[y].getAttributes(x) != e[y].getAttributes(x)) {
        fail('line $y differs at column $x: "${a[y]}" != "${e[y]}"');
      }
    }
  }
}

List<int> _allBytes(Directory directory) => [
  for (final entity in directory.listSync(recursive: true))
    if (entity is File) ...entity.readAsBytesSync(),
];

List<File> _segments(Directory directory) => [
  for (final entity in directory.listSync(recursive: true))
    if (entity is File && entity.path.endsWith('.seg')) entity,
];

bool _contains(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

class _FailingIo extends ScrollbackSpillIo {
  bool failWrites = false;

  @override
  Future<void> write(RandomAccessFile file, Uint8List bytes) async {
    if (failWrites) throw const FileSystemException('No space left on device');
    await super.write(file, bytes);
  }
}

class _RecordingStore implements ScrollbackBlockStore {
  int disposals = 0;
  int clears = 0;

  @override
  Future<bool> put(int id, Uint8List bytes) => Future.value(false);

  @override
  Uint8List? get(int id) => null;

  @override
  void remove(int id) {}

  @override
  void clear() => clears++;

  @override
  void dispose() => disposals++;
}

void main() {
  group('search and highlights in a long scrollback', () {
    late Terminal terminal;

    setUp(() {
      terminal = Terminal(maxLines: 100000)..resize(80, 24);
      final random = Random(1);
      for (var i = 0; i < 9000; i++) {
        if (i == 1500) {
          terminal.write('the NEEDLE is deep in the archive\r\n');
        } else if (i == 6700) {
          terminal.write('a wrapped ${'x' * 67}nee');
          terminal.write('dle across two rows\r\n');
        } else {
          terminal.write('${_logLine(random, i)}\r\n');
        }
      }
      terminal.write('needle on the live screen');
    });

    test('finds matches on both sides of the hot window', () {
      final lines = terminal.buffer.lines;
      final archived = lines.archivedLength;
      expect(archived, greaterThan(6000));
      expect(lines.length - archived, lessThan(2400));

      // The default search window (10,000 rows) reaches far into the archive.
      final result = searchTerminalBuffer(terminal, 'needle');
      expect(result.truncated, isFalse);
      expect(result.matches, hasLength(3));

      final deep = result.matches[0];
      expect(deep.start.y, lessThan(archived));
      expect(
        lines[deep.start.y].getText(),
        'the NEEDLE is deep in the archive',
      );
      expect(deep.start.x, 4);
      expect(deep.end, CellOffset(10, deep.start.y));

      // A match that continues on the next (wrapped) row.
      final wrapped = result.matches[1];
      expect(wrapped.end.y, wrapped.start.y + 1);
      expect(lines[wrapped.end.y].isWrapped, isTrue);
      expect(
        terminal.buffer.getText(BufferRangeLine(wrapped.start, wrapped.end)),
        'needle',
      );

      final live = result.matches[2];
      expect(live.start.y, lines.length - 1);
      expect(live.start.y, greaterThan(archived));
    });

    test('a match that straddles the archive boundary is found', () {
      final small = Terminal(
        maxLines: 100000,
        scrollback: const ScrollbackOptions(hotLines: 0, blockLines: 8),
      )..resize(20, 6);
      // One logical line much longer than the hot window: most of its rows
      // are archived, and the query is split by every row boundary once.
      for (var i = 0; i < 40; i++) {
        small.write('part${i.toString().padLeft(3, '0')}|');
      }
      final lines = small.buffer.lines;
      final boundary = lines.archivedLength;
      expect(boundary, greaterThan(0));
      expect(lines[boundary].isWrapped, isTrue);

      final all = searchTerminalBuffer(small, 'part');
      expect(all.matches, hasLength(40));
      for (var i = 0; i < 40; i++) {
        final found = searchTerminalBuffer(
          small,
          '${i.toString().padLeft(3, '0')}|part',
        );
        expect(found.matches, hasLength(i == 39 ? 0 : 1), reason: 'part $i');
      }
      // The row right above the boundary plus the first hot row.
      final above = lines[boundary - 1].getText();
      final below = lines[boundary].getText();
      final across = searchTerminalBuffer(
        small,
        above.substring(above.length - 5) + below.substring(0, 5),
      );
      expect(across.matches, hasLength(1));
      expect(across.matches.single.start.y, boundary - 1);
      expect(across.matches.single.end.y, boundary);
    });

    test('highlights stay on their text while output continues', () {
      final controller = TerminalController();
      final buffer = terminal.buffer;
      final matches = searchTerminalBuffer(terminal, 'needle').matches;
      // What the app does for every match (see _paintSearchMatches).
      final highlights = [
        for (final match in matches)
          controller.highlight(
            p1: buffer.createAnchorFromOffset(match.start),
            p2: buffer.createAnchorFromOffset(match.end),
            color: const Color(0xff00ff00),
          ),
      ];
      String textOf(TerminalHighlight highlight) =>
          buffer.getText(highlight.range).toLowerCase();
      expect(highlights.map(textOf), everyElement('needle'));
      final rows = [for (final h in highlights) h.range!.begin.y];

      // The live-screen match moves into the archive; nothing is dropped,
      // so every highlight keeps its absolute row.
      final random = Random(2);
      for (var i = 0; i < 6000; i++) {
        terminal.write('\r\n${_logLine(random, i)}');
      }
      expect(rows.last, lessThan(buffer.lines.archivedLength));
      expect([for (final h in highlights) h.range!.begin.y], rows);
      expect(highlights.map(textOf), everyElement('needle'));

      // Searching again gives the same positions as the anchors.
      final again = searchTerminalBuffer(
        terminal,
        'needle',
        maxRows: 100000,
        maxScannedCells: 10000000,
      ).matches;
      expect([for (final m in again) m.start.y], rows);

      for (final highlight in highlights) {
        highlight.dispose();
      }
      expect(controller.highlights, isEmpty);
    });
  });

  group('terminal_read', () {
    test('reads rendered text out of the archive', () async {
      // The tool reads at most 2,000 lines, which normally all sit in the
      // hot window; a small hot window makes the same call cross into the
      // archive.
      final terminal = Terminal(
        maxLines: 100000,
        scrollback: const ScrollbackOptions(hotLines: 100, blockLines: 64),
      )..resize(80, 24);
      final expected = <String>[];
      final random = Random(3);
      for (var i = 0; i < 5000; i++) {
        final line = _logLine(random, i);
        expected.add(line);
        terminal.write('$line\r\n');
      }
      expect(terminal.buffer.lines.archivedLength, greaterThan(4500));

      final protocol = McpProtocol(
        workspace: McpWorkspace(
          scope: () => 'fixture:one',
          describe: () => {'mode': 'fixture'},
          hosts: () => const [
            HostRecord(
              id: 'h1',
              name: 'test',
              address: 'fixture.example',
              username: 'test',
            ),
          ],
          sessions: () => [
            McpSession(
              id: 's1',
              name: 'test',
              kind: 'ssh',
              hostId: 'h1',
              state: 'connected',
              isAlive: () => true,
              focus: () {},
              close: () async {},
              input: (_) {},
              terminal: terminal,
            ),
          ],
          connect: (_) async {},
          openConsole: () async {},
        ),
        validateAccess: () {},
        access: (_) => McpAccessMode.readOnly,
      );
      final reply = await protocol.handle({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'terminal_read',
          'arguments': {'session_id': 's1', 'lines': 600},
        },
      });
      final content =
          (reply.body!['result'] as Map)['structuredContent'] as Map;
      expect(content['total_retained_lines'], 5001);
      expect(content['truncated'], isTrue);
      final text = (content['text'] as String).split('\n');
      // 600 rows: the last 599 written lines and the empty cursor row.
      expect(text, hasLength(600));
      expect(text.sublist(0, 599), expected.sublist(5000 - 599));
    });
  });

  group('terminal wiring', () {
    test('every terminal gets its own scrollback options and disk tier', () {
      final first = newTerminalScrollback();
      final second = newTerminalScrollback();
      expect(first.archive, isTrue);
      expect(first.store, isNotNull, reason: 'native platforms have a tier');
      expect(identical(first.store, second.store), isFalse);
      // With a disk tier behind it the memory archive is the smaller one.
      expect(first.effectiveMaxMemoryBytes, 16 * 1024 * 1024);
      expect(first.maxStoreBytes, 512 * 1024 * 1024);

      final terminal = Terminal(maxLines: 1000, scrollback: first);
      disposeTerminalScrollback(terminal);
      disposeTerminalScrollback(terminal);
      disposeTerminalScrollback(null);
      disposeTerminalScrollback(Terminal(maxLines: 1000));
      second.store!.dispose();
    });

    test('closing a mirrored terminal disposes its disk tier', () async {
      final store = _RecordingStore();
      final terminal = MirroredTerminal(
        maxLines: 5000,
        scrollback: ScrollbackOptions(store: store),
      );
      expect(terminal.scrollback.store, same(store));
      terminal.write('some output\r\n');
      await terminal.closeMirror();
      expect(store.disposals, 1);
      await terminal.closeMirror();
      expect(store.disposals, 1);
    });
  });

  group('encrypted disk tier behind a terminal', () {
    late Directory cache;
    late Sodium sodium;
    late _FailingIo io;
    late ScrollbackSpillEnvironment environment;

    setUpAll(() async {
      sodium = await SodiumSumoInit.init();
    });

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('long-scrollback-test-');
      io = _FailingIo();
      environment = ScrollbackSpillEnvironment(
        cacheDirectory: () async => cache,
        sodium: () => sodium,
        io: io,
      );
    });

    tearDown(() async {
      await environment.release();
      if (cache.existsSync()) await cache.delete(recursive: true);
    });

    ({Terminal terminal, EncryptedFileScrollbackStore store}) open({
      int maxLines = 1000000,
      int maxStoreBytes = 512 * 1024 * 1024,
    }) {
      final store = EncryptedFileScrollbackStore(
        environment: environment,
        segmentBytes: 64 * 1024,
      );
      final terminal = Terminal(
        maxLines: maxLines,
        scrollback: ScrollbackOptions(
          hotLines: 100,
          blockLines: 64,
          maxMemoryBytes: 32 * 1024,
          maxStoreBytes: maxStoreBytes,
          store: store,
        ),
      )..resize(80, 24);
      return (terminal: terminal, store: store);
    }

    /// Writes [count] lines in bursts with an event-loop turn in between,
    /// the way output arrives from a connection.
    Future<void> feed(
      List<Terminal> terminals,
      EncryptedFileScrollbackStore store,
      int count, {
      int seed = 1,
      String prefix = '',
    }) async {
      final random = Random(seed);
      for (var i = 0; i < count; i++) {
        final line = '$prefix${_logLine(random, i)}\r\n';
        for (final terminal in terminals) {
          terminal.write(line);
        }
        if (i % 500 == 499) await store.whenIdle();
      }
      await store.whenIdle();
      await Future<void>.delayed(Duration.zero);
    }

    test('history spills to disk and reads back exactly', () async {
      final (:terminal, :store) = open();
      final plain = Terminal(
        maxLines: 1000000,
        scrollback: const ScrollbackOptions.plain(),
      )..resize(80, 24);
      await feed([terminal, plain], store, 12000);

      final stats = terminal.buffer.lines.stats;
      expect(stats.storeFailed, isFalse);
      expect(stats.storedBlocks, greaterThan(100));
      expect(stats.memoryBytes, lessThanOrEqualTo(32 * 1024));
      expect(store.storedBlocks, stats.storedBlocks);
      expect(terminal.buffer.lines.length, 12001, reason: 'nothing dropped');
      expect(_segments(cache).length, greaterThan(1));

      _expectSameLines(terminal, plain);

      // Search and copy work on lines that live on disk.
      final found = searchTerminalBuffer(
        terminal,
        'row 37 ',
        maxRows: 100000,
        maxScannedCells: 10000000,
      );
      expect(found.matches, hasLength(1));
      expect(found.matches.single.start.y, 37);
      expect(
        terminal.buffer.getText(
          BufferRangeLine(const CellOffset(0, 40), const CellOffset(6, 42)),
        ),
        plain.buffer.getText(
          BufferRangeLine(const CellOffset(0, 40), const CellOffset(6, 42)),
        ),
      );
    });

    test('nothing readable reaches the disk', () async {
      final (:terminal, :store) = open();
      const secret = 'hunter2-TOP-SECRET-PASSWORD';
      final random = Random(4);
      for (var i = 0; i < 6000; i++) {
        terminal.write(
          i % 3 == 0
              ? 'export TOKEN=$secret # $i\r\n'
              : '${_logLine(random, i)}\r\n',
        );
        if (i % 500 == 499) await store.whenIdle();
      }
      await store.whenIdle();
      expect(terminal.buffer.lines.stats.storedBlocks, greaterThan(20));

      final bytes = _allBytes(cache);
      expect(bytes.length, greaterThan(20000));
      for (final needle in [secret, 'TOKEN', 'export', 'row 3 ', 'INFO']) {
        expect(
          _contains(bytes, utf8.encode(needle)),
          isFalse,
          reason: '"$needle" must not be on disk in the clear',
        );
      }
      // Ciphertext does not compress: no plaintext structure is left.
      expect(
        ZLibCodec(level: 9).encode(bytes).length,
        greaterThan(bytes.length * 0.97),
      );
      // The text is still there for the terminal itself.
      expect(terminal.buffer.lines[0].getText(), 'export TOKEN=$secret # 0');
    });

    test('a tampered or swapped block reads as blank lines', () async {
      final (:terminal, :store) = open();
      await feed([terminal], store, 6000);
      final lines = terminal.buffer.lines;
      final length = lines.length;
      expect(lines[0].getText(), startsWith('row 0 '));
      expect(lines.stats.storedBlocks, greaterThan(20));

      // Evict what was just read, then flip one byte in every segment.
      for (var y = length - 1; y > length - 400; y--) {
        lines[y];
      }
      for (final segment in _segments(cache)) {
        final bytes = segment.readAsBytesSync();
        // Swap the first two blocks' worth of bytes and corrupt the rest.
        for (var i = 100; i < bytes.length; i += 997) {
          bytes[i] ^= 0x01;
        }
        segment.writeAsBytesSync(bytes, flush: true);
      }

      var blank = 0;
      for (var y = 0; y < length; y++) {
        final line = lines[y];
        expect(line.index, y);
        if (line.getText().isEmpty) blank++;
      }
      // Whole blocks fail closed; the count of lines is unchanged and the
      // lines still in memory are intact.
      expect(blank, greaterThanOrEqualTo(lines.stats.storedBlocks * 64));
      expect(lines.length, length);
      expect(lines[length - 2].getText(), startsWith('row 5999 '));
      expect(lines[0].getText(), '');
    });

    test(
      'clearing the scrollback and closing the terminal delete the files',
      () async {
        final (:terminal, :store) = open();
        await feed([terminal], store, 6000);
        expect(_segments(cache), isNotEmpty);

        terminal.write('\x1b[3J');
        await store.whenIdle();
        expect(_segments(cache), isEmpty, reason: 'ED 3 clears the disk tier');
        expect(terminal.buffer.lines.length, 24);
        expect(terminal.buffer.lines.stats.storedBlocks, 0);

        // The tier keeps working afterwards.
        await feed([terminal], store, 6000, seed: 2);
        expect(terminal.buffer.lines.stats.storeFailed, isFalse);
        expect(_segments(cache), isNotEmpty);
        expect(terminal.buffer.lines[0].getText(), isNotEmpty);

        disposeTerminalScrollback(terminal);
        await store.whenIdle();
        expect(_segments(cache), isEmpty, reason: 'closing removes the file');

        // A closed terminal that is still referenced does not throw: lines
        // that lived only on disk are blank, the memory tiers are intact.
        final lines = terminal.buffer.lines;
        for (var y = 0; y < lines.length; y++) {
          expect(lines[y].index, y);
        }
        expect(lines[0].getText(), '');
        expect(lines[lines.length - 2].getText(), startsWith('row 5999 '));
        terminal.write('still accepts output\r\n');
        await Future<void>.delayed(Duration.zero);
      },
    );

    test('budgets drop the oldest history first', () async {
      // Line limit.
      final limited = open(maxLines: 4000);
      await feed([limited.terminal], limited.store, 12000);
      var lines = limited.terminal.buffer.lines;
      expect(lines.length, 4000);
      expect(lines[0].getText(), startsWith('row 8001 '));
      expect(lines.stats.storeFailed, isFalse);
      final blocksOnDisk = limited.store.storedBlocks;
      expect(blocksOnDisk, lessThan(4000 ~/ 64 + 1));

      // Disk budget.
      final small = open(maxStoreBytes: 96 * 1024);
      await feed([small.terminal], small.store, 12000);
      lines = small.terminal.buffer.lines;
      final stats = lines.stats;
      expect(stats.storedBytes, lessThanOrEqualTo(96 * 1024));
      expect(stats.memoryBytes, lessThanOrEqualTo(32 * 1024));
      expect(lines.length, lessThan(12000));
      expect(lines.length, greaterThan(1000));
      // The newest part, contiguous.
      final first = int.parse(lines[0].getText().split(' ')[1]);
      for (var y = 0; y < lines.length - 1; y += 17) {
        expect(lines[y].getText(), startsWith('row ${first + y} '));
      }
      // Disk use follows the budget (whole segments are freed).
      final onDisk = _segments(cache)
          .where((file) => file.path.contains('${Platform.pathSeparator}2-'))
          .fold<int>(0, (sum, file) => sum + file.lengthSync());
      expect(onDisk, lessThan(96 * 1024 + 2 * 64 * 1024 + 64 * 1024));
    });

    test(
      'a full disk falls back to memory without losing recent lines',
      () async {
        final (:terminal, :store) = open();
        final plain = Terminal(
          maxLines: 1000000,
          scrollback: const ScrollbackOptions.plain(),
        )..resize(80, 24);
        await feed([terminal, plain], store, 3000);
        expect(terminal.buffer.lines.stats.storedBlocks, greaterThan(0));

        io.failWrites = true;
        await feed([terminal, plain], store, 6000, seed: 2);

        final lines = terminal.buffer.lines;
        expect(store.hasFailed, isTrue);
        expect(lines.stats.storeFailed, isTrue);
        // Memory only from here on: the oldest lines went, the rest is exact.
        expect(lines.stats.memoryBytes, lessThanOrEqualTo(32 * 1024));
        expect(lines.length, lessThan(plain.buffer.lines.length));
        final offset = plain.buffer.lines.length - lines.length;
        for (var y = 0; y < lines.length; y++) {
          expect(lines[y].getText(), plain.buffer.lines[y + offset].getText());
        }
      },
    );

    test('bytes per line on disk and in memory', () async {
      final store = EncryptedFileScrollbackStore(environment: environment);
      final terminal = Terminal(
        maxLines: 5000000,
        scrollback: ScrollbackOptions(
          // A sixteenth of the real budgets, for a sixteenth of the lines.
          maxMemoryBytes: 1024 * 1024,
          store: store,
        ),
      )..resize(80, 24);
      await feed([terminal], store, 150000);
      final stats = terminal.buffer.lines.stats;
      final onDisk = _segments(cache)
          .fold<int>(0, (sum, file) => sum + file.lengthSync());
      final storedLines = stats.storedBlocks * 256;
      // ignore: avoid_print
      print(
        '150,000 log lines, 1 MiB memory budget: $stats; '
        '$onDisk bytes on disk = '
        '${(onDisk / storedLines).toStringAsFixed(1)} bytes/line',
      );
      expect(stats.storeFailed, isFalse);
      expect(terminal.buffer.lines.length, 150001);
      expect(stats.memoryBytes, lessThanOrEqualTo(1024 * 1024));
      expect(onDisk / storedLines, lessThan(64));
      // The encryption framing is 40 bytes per 256-line block.
      expect(onDisk, lessThan(stats.storedBytes + stats.storedBlocks * 8));
    });
  });
}
