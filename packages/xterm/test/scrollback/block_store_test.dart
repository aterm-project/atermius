import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';

import 'helpers.dart';

const budget = 16 * 1024;

ScrollbackOptions tiers(
  ScrollbackBlockStore? store, {
  int maxMemoryBytes = budget,
  int maxStoreBytes = 512 * 1024 * 1024,
  int maxPendingBytes = 32 * 1024 * 1024,
}) {
  return ScrollbackOptions(
    hotLines: 40,
    blockLines: 16,
    maxMemoryBytes: maxMemoryBytes,
    maxStoreBytes: maxStoreBytes,
    maxPendingBytes: maxPendingBytes,
    store: store,
  );
}

Terminal terminalWith(ScrollbackOptions scrollback, {int maxLines = 1000000}) {
  return Terminal(maxLines: maxLines, scrollback: scrollback)..resize(80, 24);
}

void writeLogs(List<Terminal> terminals, int count, {int seed = 1}) {
  final random = Random(seed);
  for (var i = 0; i < count; i++) {
    final line = 'n$i ${logLine(random, i, width: 70)}\r\n';
    for (final terminal in terminals) {
      terminal.write(line);
    }
  }
}

void main() {
  group('store tier', () {
    test('the oldest blocks move to the store and read back exactly', () async {
      final store = FakeBlockStore();
      final terminal = terminalWith(tiers(store));
      final plain = terminalWith(const ScrollbackOptions.plain());
      writeLogs([terminal, plain], 4000);
      final lines = terminal.buffer.lines;

      // Handed over, oldest first, but still in memory until written.
      expect(store.putIds, isNotEmpty);
      expect(store.putIds, List.generate(store.putIds.length, (i) => i));
      expect(lines.stats.storedBlocks, 0);
      expect(lines.stats.memoryBytes, greaterThan(budget));
      expectSameLines(terminal.buffer, plain.buffer);
      expect(store.gets, 0, reason: 'blocks in flight are read from memory');

      await store.flush();
      final stats = lines.stats;
      expect(stats.storedBlocks, store.putIds.length);
      expect(stats.storedBytes, greaterThan(0));
      expect(stats.memoryBytes, lessThanOrEqualTo(budget));
      expect(stats.storeFailed, isFalse);
      expect(lines.length, plain.buffer.lines.length, reason: 'nothing lost');

      // All three tiers read back the same.
      expectSameLines(terminal.buffer, plain.buffer);
      expect(store.gets, greaterThan(0));

      // More output keeps spilling in the background.
      for (var round = 0; round < 5; round++) {
        writeLogs([terminal, plain], 1000, seed: 10 + round);
        await store.flush();
        expect(lines.stats.memoryBytes, lessThanOrEqualTo(budget));
      }
      expect(lines.length, plain.buffer.lines.length);
      expectSameLines(terminal.buffer, plain.buffer);
      expect(store.removedIds, isEmpty);
    });

    test('ids only ever increase, also after a clear', () async {
      final store = FakeBlockStore();
      final terminal = terminalWith(tiers(store));
      writeLogs([terminal], 3000);
      await store.flush();
      final highest = store.putIds.last;

      terminal.write('\x1b[3J');
      expect(store.clears, 1);
      expect(store.blocks, isEmpty);
      expect(terminal.buffer.lines.length, 24);
      expect(terminal.buffer.lines.stats.storedBytes, 0);
      expect(terminal.buffer.lines.stats.memoryBytes, 0);

      writeLogs([terminal], 3000, seed: 2);
      await store.flush();
      expect(store.putIds.sublist(store.putIds.indexOf(highest) + 1),
          everyElement(greaterThan(highest)));
      expect(store.putIds.toSet().length, store.putIds.length);
      expect(terminal.buffer.lines.stats.storedBlocks, greaterThan(0));
    });

    test('a clear while writes are in flight leaves nothing behind', () async {
      final store = FakeBlockStore();
      final terminal = terminalWith(tiers(store));
      writeLogs([terminal], 3000);
      expect(store.pending, isNotEmpty);

      terminal.write('\x1b[3J');
      await store.flush();
      final stats = terminal.buffer.lines.stats;
      expect(store.blocks, isEmpty);
      expect(stats.storedBytes, 0);
      expect(stats.memoryBytes, 0);
      expect(stats.storeFailed, isFalse);
      expect(terminal.buffer.lines.length, 24);
    });

    test('the store budget and the line limit drop the oldest blocks',
        () async {
      final store = FakeBlockStore(synchronous: true);
      final terminal = terminalWith(tiers(store, maxStoreBytes: 48 * 1024));
      final plain = terminalWith(const ScrollbackOptions.plain());
      for (var round = 0; round < 12; round++) {
        writeLogs([terminal, plain], 500, seed: round);
        await store.flush();
      }
      final lines = terminal.buffer.lines;
      final stats = lines.stats;
      expect(stats.storedBytes, lessThanOrEqualTo(48 * 1024));
      expect(stats.memoryBytes, lessThanOrEqualTo(budget + 2048));
      expect(store.removedIds, isNotEmpty);
      // Oldest first, without gaps.
      expect(
        store.removedIds,
        List.generate(store.removedIds.length, (i) => i),
      );
      expect(store.blocks.keys.reduce(min), store.removedIds.last + 1);

      // What remains is the newest part, still exact.
      final offset = plain.buffer.lines.length - lines.length;
      expect(offset, greaterThan(0));
      for (var y = 0; y < lines.length; y += 3) {
        expect(lines[y].getText(), plain.buffer.lines[y + offset].getText());
      }

      // The line limit: one line out per line in, blocks leave the store as
      // their last line goes.
      final limited = FakeBlockStore(synchronous: true);
      final capped = terminalWith(tiers(limited), maxLines: 2000);
      for (var round = 0; round < 10; round++) {
        writeLogs([capped], 500, seed: round);
        await limited.flush();
        expect(capped.buffer.lines.length, lessThanOrEqualTo(2000));
      }
      expect(capped.buffer.lines.length, 2000);
      expect(limited.removedIds, isNotEmpty);
      expect(
        limited.removedIds,
        List.generate(limited.removedIds.length, (i) => i),
      );
      expect(capped.buffer.lines[0].getText(), startsWith('n'));
    });

    test('a failing store drops nothing that is still in memory', () async {
      final store = FakeBlockStore();
      var notified = 0;
      final terminal = terminalWith(tiers(store));
      terminal.addListener(() => notified++);
      final plain = terminalWith(const ScrollbackOptions.plain());
      writeLogs([terminal, plain], 2000);
      await store.flush();
      final lines = terminal.buffer.lines;
      final storedBefore = lines.stats.storedBlocks;
      expect(storedBefore, greaterThan(0));

      // The disk fills up.
      store.failWrites = true;
      writeLogs([terminal, plain], 300, seed: 2);
      expect(store.pending, isNotEmpty);
      final lengthBefore = lines.length;
      expect(lengthBefore, plain.buffer.lines.length);
      notified = 0;
      await store.flush();

      // Nothing threw; the store is no longer used.
      expect(lines.stats.storeFailed, isTrue);
      final puts = store.putIds.length;
      writeLogs([terminal, plain], 3000, seed: 3);
      await store.flush();
      expect(store.putIds.length, puts);

      // Memory only now: the oldest blocks are dropped, as without a store.
      expect(lines.stats.memoryBytes, lessThanOrEqualTo(budget));
      expect(lines.stats.storedBlocks, 0);
      expect(lines.length, lessThan(plain.buffer.lines.length));
      final offset = plain.buffer.lines.length - lines.length;
      for (var y = 0; y < lines.length; y++) {
        expect(lines[y].getText(), plain.buffer.lines[y + offset].getText());
        expect(lines[y].index, y);
      }
    });

    test('lines dropped after a late write failure notify listeners', () async {
      final store = FakeBlockStore();
      var notified = 0;
      final terminal = terminalWith(tiers(store));
      final plain = terminalWith(const ScrollbackOptions.plain());
      // Enough for several blocks to be in flight at once.
      writeLogs([terminal, plain], 3000);
      final lines = terminal.buffer.lines;
      expect(lines.length, plain.buffer.lines.length);
      expect(lines.stats.memoryBytes, greaterThan(budget));

      terminal.addListener(() => notified++);
      store.failWrites = true;
      await store.flush();

      expect(lines.stats.storeFailed, isTrue);
      expect(lines.stats.memoryBytes, lessThanOrEqualTo(budget));
      expect(lines.length, lessThan(plain.buffer.lines.length));
      expect(notified, greaterThan(0), reason: 'the view must lay out again');
      final offset = plain.buffer.lines.length - lines.length;
      for (var y = 0; y < lines.length; y += 5) {
        expect(lines[y].getText(), plain.buffer.lines[y + offset].getText());
      }
    });

    test('a store that throws is treated as failed', () async {
      final terminal = terminalWith(tiers(_ThrowingStore()));
      final plain = terminalWith(const ScrollbackOptions.plain());
      writeLogs([terminal, plain], 3000);
      await Future<void>.delayed(Duration.zero);
      final lines = terminal.buffer.lines;
      expect(lines.stats.storeFailed, isTrue);
      expect(lines.stats.memoryBytes, lessThanOrEqualTo(budget));
      writeLogs([terminal, plain], 500, seed: 2);
      terminal.write('\x1b[3J');
      expect(lines.length, 24);

      final failing = terminalWith(tiers(_ErrorFutureStore()));
      writeLogs([failing], 3000);
      await Future<void>.delayed(Duration.zero);
      expect(failing.buffer.lines.stats.storeFailed, isTrue);
    });

    test('a missing, corrupt or unreadable block reads as blank lines',
        () async {
      final store = FakeBlockStore();
      final terminal = terminalWith(tiers(store));
      final plain = terminalWith(const ScrollbackOptions.plain());
      writeLogs([terminal, plain], 4000);
      await store.flush();
      final lines = terminal.buffer.lines;
      final length = lines.length;
      expect(store.blocks.length, greaterThan(5));

      // Block 0 is gone, block 1 is garbage, block 2 is truncated, block 3
      // is a valid block of the wrong shape.
      store.blocks.remove(0);
      store.blocks[1] = Uint8List.fromList(List.generate(500, (i) => i * 7));
      store.blocks[2] = Uint8List.sublistView(store.blocks[2]!, 0, 20);
      store.blocks[3] = Uint8List.fromList([0, 3, 1, 0, 0]);

      for (var y = 0; y < 64; y++) {
        final line = lines[y];
        expect(line.getText(), '', reason: 'line $y');
        expect(line.length, 80);
        expect(line.isWrapped, isFalse);
        expect(line.index, y);
      }
      // The neighbours are untouched, and the count is the same.
      expect(lines[64].getText(), plain.buffer.lines[64].getText());
      expect(lines.length, length);
      expect(terminal.buffer.getText(), isNotEmpty);

      // A read that throws.
      store.throwOnGet = true;
      for (var y = length ~/ 4; y < length ~/ 4 + 100; y++) {
        expect(lines[y].index, y);
      }
      store.throwOnGet = false;

      // The store went away entirely (the tab was closed).
      store.dispose();
      for (var y = 0; y < length; y++) {
        expect(lines[y].index, y);
      }
      expect(lines.length, length);
      writeLogs([terminal], 2000, seed: 2);
      await store.flush();
      expect(lines.stats.storeFailed, isTrue);
      expect(lines.stats.memoryBytes, lessThanOrEqualTo(budget));
    });

    test('a store that cannot keep up does not let memory grow unbounded', () {
      final store = FakeBlockStore();
      final terminal = terminalWith(tiers(store, maxPendingBytes: 48 * 1024));
      final plain = terminalWith(const ScrollbackOptions.plain());
      // Never flushed: every write stays in flight.
      writeLogs([terminal, plain], 20000);
      final lines = terminal.buffer.lines;
      expect(lines.stats.storedBlocks, 0);
      expect(lines.stats.memoryBytes, lessThanOrEqualTo(budget + 50 * 1024));
      expect(lines.length, lessThan(plain.buffer.lines.length));
      // Dropped blocks were taken back from the store.
      expect(store.removedIds, isNotEmpty);
      expect(
          store.pending.keys, everyElement(greaterThan(store.removedIds.last)));
      final offset = plain.buffer.lines.length - lines.length;
      for (var y = 0; y < lines.length; y += 11) {
        expect(lines[y].getText(), plain.buffer.lines[y + offset].getText());
      }
    });

    test('stored blocks come back when the viewport needs them', () async {
      final store = FakeBlockStore(synchronous: true);
      final terminal = terminalWith(
        ScrollbackOptions(
          hotLines: 0,
          blockLines: 8,
          maxMemoryBytes: 0,
          store: store,
        ),
      );
      final plain = terminalWith(const ScrollbackOptions.plain());
      writeLogs([terminal, plain], 300);
      await store.flush();
      final lines = terminal.buffer.lines;
      expect(lines.stats.memoryBlocks, 0);
      expect(lines.stats.storedBlocks, greaterThan(30));

      terminal.resize(80, 120);
      plain.resize(80, 120);
      expect(lines.hotLength, greaterThanOrEqualTo(120));
      expect(store.removedIds, isNotEmpty);
      expectSameLines(terminal.buffer, plain.buffer);

      terminal.resize(80, 24);
      plain.resize(80, 24);
      writeLogs([terminal, plain], 300, seed: 2);
      await store.flush();
      expectSameLines(terminal.buffer, plain.buffer);
      expect(store.putIds.toSet().length, store.putIds.length);
    });

    test('without a store the memory budget is the larger default', () {
      expect(const ScrollbackOptions().effectiveMaxMemoryBytes, 32 << 20);
      expect(
        ScrollbackOptions(store: FakeBlockStore()).effectiveMaxMemoryBytes,
        16 << 20,
      );
      expect(const ScrollbackOptions().maxStoreBytes, 512 << 20);
    });
  });

  group('BufferLines', () {
    BufferLine line(String text) {
      final line = BufferLine(20);
      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }
      return line;
    }

    BufferLines filled(int count, {int maxLength = 100000}) {
      final lines = BufferLines(
        maxLength,
        options: const ScrollbackOptions(hotLines: 10, blockLines: 4),
        viewWidth: 20,
        viewportLines: 5,
      );
      for (var i = 0; i < count; i++) {
        lines.push(line('l$i'));
      }
      return lines;
    }

    List<String> texts(BufferLines lines) =>
        [for (var i = 0; i < lines.length; i++) lines[i].getText()];

    test('mutations inside the archive bring the lines back first', () {
      final lines = filled(100);
      expect(lines.archivedLength, greaterThan(80));
      final expected = [for (var i = 0; i < 100; i++) 'l$i'];

      lines[50] = line('replaced');
      expected[50] = 'replaced';
      expect(lines.hotLength, greaterThanOrEqualTo(50));
      expect(texts(lines), expected);

      // More lines push the excess back into the archive.
      for (var i = 100; i < 130; i++) {
        lines.push(line('l$i'));
        expected.add('l$i');
      }
      expect(lines.archivedLength, greaterThan(100));
      expect(texts(lines), expected);

      final old = lines.swap(20, line('swapped'));
      expect(old.getText(), 'l20');
      expected[20] = 'swapped';
      expect(texts(lines), expected);

      lines.insert(30, line('inserted'));
      expected.insert(30, 'inserted');
      expect(texts(lines), expected);

      lines.remove(10, 5);
      expected.removeRange(10, 15);
      expect(texts(lines), expected);

      for (var i = 0; i < lines.length; i++) {
        expect(lines[i].index, i);
        expect(lines[i].attached, isTrue);
      }
    });

    test('pop, clear, replaceWith and trimStart', () {
      final lines = filled(60);
      final expected = [for (var i = 0; i < 60; i++) 'l$i'];

      // Popping past the hot window continues into the archive.
      while (lines.length > 20) {
        expect(lines.pop().getText(), expected.removeLast());
      }
      expect(texts(lines), expected);

      lines.trimStart(7);
      expect(texts(lines), expected.sublist(7));
      expect(lines[0].index, 0);

      lines.replaceWith([line('a'), line('b'), line('c')]);
      expect(texts(lines), ['a', 'b', 'c']);
      expect(lines.archivedLength, 0);

      lines.clear();
      expect(lines.length, 0);
      expect(() => lines.pop(), throwsStateError);
      lines.push(line('again'));
      expect(lines[0].index, 0);
      expect(texts(lines), ['again']);
    });

    test('a line that is assigned to a new index stays attached', () {
      // What Buffer.scrollUp does: lines[i] = lines[i + 1].
      final lines = filled(8);
      final moved = lines[5];
      lines[4] = lines[5];
      lines[5] = line('new');
      expect(moved.attached, isTrue);
      expect(moved.index, 4);
      expect(lines[5].index, 5);
    });

    test('the limit applies while inserting', () {
      final lines = filled(40, maxLength: 40);
      lines.insert(38, line('inserted'));
      expect(lines.length, 40);
      expect(lines[0].getText(), 'l1');
      expect(lines[37].getText(), 'inserted');
      expect(lines[39].getText(), 'l39');
      expect(lines.isFull, isTrue);
    });
  });
}

class _ThrowingStore implements ScrollbackBlockStore {
  @override
  Future<bool> put(int id, Uint8List bytes) => throw StateError('put');

  @override
  Uint8List? get(int id) => throw StateError('get');

  @override
  void remove(int id) => throw StateError('remove');

  @override
  void clear() => throw StateError('clear');

  @override
  void dispose() {}
}

class _ErrorFutureStore implements ScrollbackBlockStore {
  @override
  Future<bool> put(int id, Uint8List bytes) =>
      Future<bool>.error(StateError('disk full'));

  @override
  Uint8List? get(int id) => null;

  @override
  void remove(int id) {}

  @override
  void clear() {}

  @override
  void dispose() {}
}
