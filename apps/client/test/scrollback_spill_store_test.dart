import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:aterm_client/terminal/scrollback_spill_store.dart' as facade;
import 'package:aterm_client/terminal/scrollback_spill_store_io.dart';
import 'package:aterm_client/terminal/scrollback_spill_store_web.dart' as web;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sodium/sodium_sumo.dart';

/// File operations that can be made to stall or fail on demand.
class _ScriptedIo extends ScrollbackSpillIo {
  bool failWrites = false;
  bool failOpen = false;
  Completer<void>? writeGate;
  Completer<void> writeStarted = Completer<void>();
  final List<int> writeSizes = [];
  int segmentsOpened = 0;

  @override
  Future<RandomAccessFile> openSegment(File file) {
    segmentsOpened++;
    if (failOpen) throw FileSystemException('Cannot create', file.path);
    return super.openSegment(file);
  }

  @override
  Future<void> write(RandomAccessFile file, Uint8List bytes) async {
    writeSizes.add(bytes.length);
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate?.future;
    if (failWrites) throw const FileSystemException('No space left on device');
    await super.write(file, bytes);
  }
}

Uint8List _block(int seed, int length) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

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

String _hexName(int seed) => seed.toRadixString(16).padLeft(32, '0');

void main() {
  late Sodium sodium;
  late Directory cache;
  final environments = <ScrollbackSpillEnvironment>[];

  setUpAll(() async => sodium = await SodiumSumoInit.init());
  setUp(
    () async =>
        cache = await Directory.systemTemp.createTemp('scrollback-spill-'),
  );
  tearDown(() async {
    for (final environment in environments) {
      await environment.release();
    }
    environments.clear();
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  ScrollbackSpillEnvironment environment({
    ScrollbackSpillIo io = const ScrollbackSpillIo(),
    Future<Directory> Function()? cacheDirectory,
    FutureOr<Sodium> Function()? sodiumProvider,
  }) {
    final created = ScrollbackSpillEnvironment(
      cacheDirectory: cacheDirectory ?? () async => cache,
      sodium: sodiumProvider ?? () => sodium,
      io: io,
    );
    environments.add(created);
    return created;
  }

  Directory root() => Directory(p.join(cache.path, scrollbackSpillRootName));

  Directory folderOf(ScrollbackSpillEnvironment environment) =>
      Directory(p.join(root().path, environment.processFolderName));

  List<File> segmentsOf(ScrollbackSpillEnvironment environment) {
    final folder = folderOf(environment);
    if (!folder.existsSync()) return [];
    return folder
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.seg'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  group('storing and reading', () {
    test('round-trips many blocks including empty and 1 MiB ones', () async {
      final env = environment();
      final store = EncryptedFileScrollbackStore(environment: env);
      final blocks = <int, Uint8List>{
        0: Uint8List(0),
        1: _block(1, 1),
        2: _block(2, 1024 * 1024),
        3: Uint8List(0),
        for (var id = 4; id < 300; id++) id: _block(id, (id * 97) % 9000),
      };
      final results = await Future.wait([
        for (final entry in blocks.entries) store.put(entry.key, entry.value),
      ]);
      expect(results, everyElement(isTrue));
      expect(store.storedBlocks, blocks.length);
      for (final entry in blocks.entries) {
        expect(store.get(entry.key), entry.value, reason: 'id ${entry.key}');
      }
      // Random access in any order, repeatedly.
      for (final id in [299, 2, 0, 150, 2, 4]) {
        expect(store.get(id), blocks[id]);
      }
      expect(store.get(300), isNull);
      expect(store.hasFailed, isFalse);
      store.dispose();
      await store.whenIdle();
    });

    test('put returns before anything is written and a burst of puts '
        'becomes one write', () async {
      final io = _ScriptedIo();
      final env = environment(io: io);
      final store = EncryptedFileScrollbackStore(
        environment: env,
        batchTime: const Duration(days: 1),
      );
      final puts = [
        for (var id = 0; id < 50; id++) store.put(id, _block(id, 2000)),
      ];
      expect(root().existsSync(), isFalse, reason: 'put must not do IO');
      expect(await Future.wait(puts), everyElement(isTrue));
      expect(io.writeSizes, [50 * (2000 + scrollbackSpillFrameOverhead)]);
      expect(io.segmentsOpened, 1);

      final later = [
        for (var id = 50; id < 60; id++) store.put(id, _block(id, 10)),
      ];
      expect(await Future.wait(later), everyElement(isTrue));
      expect(io.writeSizes, hasLength(2));
      expect(segmentsOf(env), hasLength(1));
      expect(store.get(55), _block(55, 10));
    });

    test('a long queue is written in bounded slices', () async {
      final io = _ScriptedIo();
      final env = environment(io: io);
      final store = EncryptedFileScrollbackStore(
        environment: env,
        batchBytes: 4096,
      );
      final puts = [
        for (var id = 0; id < 10; id++) store.put(id, _block(id, 1000)),
      ];
      expect(await Future.wait(puts), everyElement(isTrue));
      expect(io.writeSizes, hasLength(greaterThan(2)));
      expect(io.writeSizes, everyElement(lessThanOrEqualTo(4096)));
      for (var id = 0; id < 10; id++) {
        expect(store.get(id), _block(id, 1000));
      }

      // An exhausted time budget still makes progress, one block per write.
      final slow = EncryptedFileScrollbackStore(
        environment: env,
        batchTime: Duration.zero,
      );
      final before = io.writeSizes.length;
      expect(
        await Future.wait([
          for (var id = 0; id < 5; id++) slow.put(id, _block(id, 100)),
        ]),
        everyElement(isTrue),
      );
      expect(io.writeSizes.sublist(before), List.filled(5, 140));
      for (var id = 0; id < 5; id++) {
        expect(slow.get(id), _block(id, 100));
      }
    });

    test('a block larger than a segment is stored on its own', () async {
      final env = environment();
      final store = EncryptedFileScrollbackStore(
        environment: env,
        segmentBytes: 4096,
      );
      final results = await Future.wait([
        store.put(0, _block(0, 100)),
        store.put(1, _block(1, 20000)),
        store.put(2, _block(2, 100)),
      ]);
      expect(results, everyElement(isTrue));
      expect(store.get(1), _block(1, 20000));
      expect(store.get(0), _block(0, 100));
      expect(store.get(2), _block(2, 100));
    });

    test('get serves a block from memory before its put completes and from '
        'disk afterwards', () async {
      final io = _ScriptedIo()..writeGate = Completer<void>();
      final env = environment(io: io);
      final store = EncryptedFileScrollbackStore(environment: env);
      final bytes = _block(7, 3000);
      var completed = false;
      final put = store.put(7, bytes)..then((_) => completed = true);

      // Still queued.
      expect(store.get(7), same(bytes));
      await io.writeStarted.future;
      // Being written.
      expect(completed, isFalse);
      expect(store.get(7), same(bytes));
      expect(store.storedBlocks, 0);

      io.writeGate!.complete();
      expect(await put, isTrue);
      final read = store.get(7);
      expect(read, bytes);
      expect(read, isNot(same(bytes)));
      expect(store.storedBlocks, 1);
      expect(segmentsOf(env).single.lengthSync(), 3000 + 40);
    });
  });

  group('confidentiality and integrity', () {
    test('segment files contain no plaintext and differ between stores '
        'holding the same plaintext', () async {
      final marker = utf8.encode('hunter2-DISTINCTIVE-PLAINTEXT-MARKER');
      final plaintext = Uint8List.fromList([
        for (var i = 0; i < 200; i++) ...marker,
      ]);
      final env = environment();
      final first = EncryptedFileScrollbackStore(environment: env);
      final second = EncryptedFileScrollbackStore(environment: env);
      expect(await first.put(0, plaintext), isTrue);
      expect(await second.put(0, plaintext), isTrue);

      final files = segmentsOf(env);
      expect(files, hasLength(2));
      final a = files[0].readAsBytesSync();
      final b = files[1].readAsBytesSync();
      expect(a, hasLength(plaintext.length + scrollbackSpillFrameOverhead));
      expect(b, hasLength(a.length));
      expect(_contains(a, marker), isFalse);
      expect(_contains(b, marker), isFalse);
      expect(a, isNot(b));
      // Not even the keystream is shared: no common 16-byte run.
      expect(_contains(a, b.sublist(100, 116)), isFalse);
      // Only the lock and the segments, with nothing descriptive in names.
      expect(folderOf(env).listSync().map((e) => p.basename(e.path)).toSet(), {
        scrollbackSpillLockName,
        '1-0.seg',
        '2-0.seg',
      });
      expect(first.get(0), plaintext);
      expect(second.get(0), plaintext);
      if (!Platform.isWindows) {
        // Other local users cannot even list the process folder.
        expect(folderOf(env).statSync().mode & 0x1ff, 0x1c0);
      }
    });

    test(
      'the same plaintext under two ids of one store is sealed differently',
      () async {
        final env = environment();
        final store = EncryptedFileScrollbackStore(environment: env);
        final plaintext = _block(1, 500);
        expect(
          await Future.wait([store.put(0, plaintext), store.put(1, plaintext)]),
          [true, true],
        );
        final raw = segmentsOf(env).single.readAsBytesSync();
        expect(raw.sublist(0, 540), isNot(raw.sublist(540, 1080)));
        expect(raw.sublist(0, 24), isNot(raw.sublist(540, 564)));
      },
    );

    test('a block copied to another id, modified or truncated reads as null '
        'and nothing throws', () async {
      final env = environment();
      final store = EncryptedFileScrollbackStore(environment: env);
      const frame = 500 + scrollbackSpillFrameOverhead;
      expect(
        await Future.wait([
          for (var id = 0; id < 3; id++) store.put(id, _block(id, 500)),
        ]),
        everyElement(isTrue),
      );
      final file = segmentsOf(env).single;
      final original = file.readAsBytesSync();
      expect(original, hasLength(3 * frame));
      for (var id = 0; id < 3; id++) {
        expect(store.get(id), _block(id, 500));
      }

      // Block 0's bytes, nonce and tag included, moved to where 1 lives.
      final moved = Uint8List.fromList(original)
        ..setRange(frame, 2 * frame, original);
      file.writeAsBytesSync(moved);
      expect(store.get(1), isNull);
      expect(store.get(0), _block(0, 500));
      expect(store.get(2), _block(2, 500));

      // One flipped bit in the nonce, the ciphertext or the tag of block 2.
      for (final offset in [0, 5, 23, 24, 300, frame - 16, frame - 1]) {
        final flipped = Uint8List.fromList(original);
        flipped[2 * frame + offset] ^= 0x01;
        file.writeAsBytesSync(flipped);
        expect(store.get(2), isNull, reason: 'offset $offset');
        expect(store.get(0), _block(0, 500));
      }

      // Truncated inside the last block, then down to nothing.
      file.writeAsBytesSync(original.sublist(0, original.length - 10));
      expect(store.get(2), isNull);
      expect(store.get(1), _block(1, 500));
      file.writeAsBytesSync(const []);
      for (var id = 0; id < 3; id++) {
        expect(store.get(id), isNull);
      }

      // Intact bytes authenticate again; the failures changed no state.
      file.writeAsBytesSync(original);
      for (var id = 0; id < 3; id++) {
        expect(store.get(id), _block(id, 500));
      }
    });

    test('a block whose file is gone reads as null', () async {
      final env = environment();
      final store = EncryptedFileScrollbackStore(environment: env);
      expect(await store.put(0, _block(0, 100)), isTrue);
      segmentsOf(env).single.deleteSync();
      expect(store.get(0), isNull);
      expect(store.get(0), isNull);
    });

    test(
      'blocks of one store cannot be read with the key of another',
      () async {
        final env = environment();
        final first = EncryptedFileScrollbackStore(environment: env);
        final second = EncryptedFileScrollbackStore(environment: env);
        expect(await first.put(0, _block(0, 500)), isTrue);
        expect(await second.put(0, _block(1, 500)), isTrue);
        final files = segmentsOf(env);
        files[1].writeAsBytesSync(files[0].readAsBytesSync());
        expect(second.get(0), isNull);
        expect(first.get(0), _block(0, 500));
      },
    );
  });

  group('removal and space reclamation', () {
    test('segment files are deleted as their blocks are removed', () async {
      final env = environment();
      // Four 1040-byte frames reach the 4096-byte segment size.
      final store = EncryptedFileScrollbackStore(
        environment: env,
        segmentBytes: 4096,
      );
      expect(
        await Future.wait([
          for (var id = 0; id < 10; id++) store.put(id, _block(id, 1000)),
        ]),
        everyElement(isTrue),
      );
      List<String> names() => [
        for (final file in segmentsOf(env)) p.basename(file.path),
      ];
      expect(names(), ['1-0.seg', '1-1.seg', '1-2.seg']);

      // Oldest first, as the buffer does.
      for (var id = 0; id < 3; id++) {
        store.remove(id);
      }
      await store.whenIdle();
      expect(names(), ['1-0.seg', '1-1.seg', '1-2.seg']);
      expect(store.get(0), isNull);
      expect(store.get(3), _block(3, 1000));
      store.remove(3);
      await store.whenIdle();
      expect(names(), ['1-1.seg', '1-2.seg']);
      expect(store.get(4), _block(4, 1000));

      // Unknown and already removed ids are ignored.
      store
        ..remove(3)
        ..remove(12345)
        ..remove(-1);

      // The newest blocks sit in the segment still being appended to; it
      // goes as well once it is empty.
      store.remove(9);
      await store.whenIdle();
      expect(names(), ['1-1.seg', '1-2.seg']);
      store.remove(8);
      await store.whenIdle();
      expect(names(), ['1-1.seg']);

      // A segment read before stays deletable and later puts start a new
      // file without reusing a name.
      expect(await store.put(10, _block(10, 1000)), isTrue);
      expect(names(), ['1-1.seg', '1-3.seg']);
      for (var id = 4; id < 8; id++) {
        store.remove(id);
      }
      await store.whenIdle();
      expect(names(), ['1-3.seg']);
      expect(store.get(10), _block(10, 1000));
      expect(store.storedBlocks, 1);
      store.remove(10);
      await store.whenIdle();
      expect(names(), isEmpty);
      expect(store.hasFailed, isFalse);
    });

    test(
      'many segments stay readable with a bounded number of open files',
      () async {
        final env = environment();
        final store = EncryptedFileScrollbackStore(
          environment: env,
          segmentBytes: 1024,
        );
        expect(
          await Future.wait([
            for (var id = 0; id < 40; id++) store.put(id, _block(id, 1000)),
          ]),
          everyElement(isTrue),
        );
        expect(segmentsOf(env), hasLength(40));
        for (var round = 0; round < 3; round++) {
          for (var id = 39; id >= 0; id--) {
            expect(store.get(id), _block(id, 1000));
          }
        }
        store.dispose();
        await store.whenIdle();
        expect(segmentsOf(env), isEmpty);
      },
    );

    test('a block removed while still queued is never written', () async {
      final io = _ScriptedIo();
      final env = environment(io: io);
      final store = EncryptedFileScrollbackStore(environment: env);
      final put = store.put(1, _block(1, 100));
      store.remove(1);
      expect(await put, isFalse);
      await store.whenIdle();
      expect(io.segmentsOpened, 0);
      expect(root().existsSync(), isFalse);
      expect(store.get(1), isNull);
      expect(store.hasFailed, isFalse);
      expect(await store.put(2, _block(2, 100)), isTrue);
    });

    test(
      'a block removed while its write is in flight is not resurrected',
      () async {
        final io = _ScriptedIo()..writeGate = Completer<void>();
        final env = environment(io: io);
        final store = EncryptedFileScrollbackStore(environment: env);
        final first = store.put(1, _block(1, 100));
        final second = store.put(2, _block(2, 100));
        await io.writeStarted.future;
        store.remove(1);
        expect(store.get(1), isNull);
        // The result is false at once, without waiting for the write.
        expect(await first, isFalse);
        io.writeGate!.complete();
        expect(await second, isTrue);
        await store.whenIdle();
        expect(store.get(1), isNull);
        expect(store.get(2), _block(2, 100));
        expect(store.storedBlocks, 1);
        expect(store.hasFailed, isFalse);

        // The dead bytes of block 1 go with the segment.
        store.remove(2);
        await store.whenIdle();
        expect(segmentsOf(env), isEmpty);
      },
    );

    test('removing every block of an in-flight write leaves no file', () async {
      final io = _ScriptedIo()..writeGate = Completer<void>();
      final env = environment(io: io);
      final store = EncryptedFileScrollbackStore(environment: env);
      final puts = [store.put(1, _block(1, 100)), store.put(2, _block(2, 100))];
      await io.writeStarted.future;
      store
        ..remove(2)
        ..remove(1);
      expect(await Future.wait(puts), [false, false]);
      io.writeGate!.complete();
      await store.whenIdle();
      expect(segmentsOf(env), isEmpty);
      expect(store.storedBlocks, 0);
      expect(store.hasFailed, isFalse);
      io.writeGate = null;
      expect(await store.put(3, _block(3, 100)), isTrue);
      expect(store.get(3), _block(3, 100));
    });

    test(
      'clear racing an in-flight put drops it and the store stays usable',
      () async {
        final io = _ScriptedIo()..writeGate = Completer<void>();
        final env = environment(io: io);
        final store = EncryptedFileScrollbackStore(environment: env);
        final puts = [
          store.put(1, _block(1, 100)),
          store.put(2, _block(2, 100)),
        ];
        await io.writeStarted.future;
        store.clear();
        // Queued behind the cleared write.
        final after = store.put(3, _block(3, 100));
        expect(await Future.wait(puts), [false, false]);
        io.writeGate!.complete();
        expect(await after, isTrue);
        await store.whenIdle();
        expect(store.get(1), isNull);
        expect(store.get(2), isNull);
        expect(store.get(3), _block(3, 100));
        expect(segmentsOf(env).map((f) => p.basename(f.path)), ['1-1.seg']);
        expect(store.hasFailed, isFalse);
      },
    );

    test('dispose racing an in-flight put leaves nothing behind', () async {
      final io = _ScriptedIo()..writeGate = Completer<void>();
      final env = environment(io: io);
      final store = EncryptedFileScrollbackStore(environment: env);
      final puts = [store.put(1, _block(1, 100)), store.put(2, _block(2, 100))];
      await io.writeStarted.future;
      store.dispose();
      expect(await Future.wait(puts), [false, false]);
      expect(store.get(1), isNull);
      io.writeGate!.complete();
      await store.whenIdle();
      expect(segmentsOf(env), isEmpty);
      expect(await store.put(3, _block(3, 100)), isFalse);
      expect(store.get(3), isNull);
    });

    test(
      'dispose while libsodium is still loading leaves nothing behind',
      () async {
        final loading = Completer<Sodium>();
        final env = environment(sodiumProvider: () => loading.future);
        final store = EncryptedFileScrollbackStore(environment: env);
        final put = store.put(1, _block(1, 100));
        await Future<void>.delayed(Duration.zero);
        store.dispose();
        expect(await put, isFalse);
        loading.complete(sodium);
        await store.whenIdle();
        expect(segmentsOf(env), isEmpty);
        expect(store.get(1), isNull);
      },
    );

    test('clear deletes the files and keeps the store usable', () async {
      final env = environment();
      final store = EncryptedFileScrollbackStore(
        environment: env,
        segmentBytes: 2048,
      );
      expect(
        await Future.wait([
          for (var id = 0; id < 6; id++) store.put(id, _block(id, 1000)),
        ]),
        everyElement(isTrue),
      );
      expect(store.get(0), _block(0, 1000));
      expect(segmentsOf(env), hasLength(3));

      store.clear();
      for (var id = 0; id < 6; id++) {
        expect(store.get(id), isNull);
      }
      await store.whenIdle();
      expect(segmentsOf(env), isEmpty);
      expect(store.storedBlocks, 0);

      // Ids keep increasing after a clear.
      expect(await store.put(6, _block(6, 1000)), isTrue);
      expect(await store.put(7, _block(7, 1000)), isTrue);
      expect(store.get(6), _block(6, 1000));
      expect(store.get(7), _block(7, 1000));
      expect(store.get(0), isNull);
      expect(segmentsOf(env).map((f) => p.basename(f.path)), ['1-3.seg']);
      store.clear();
      store.clear();
      await store.whenIdle();
      expect(segmentsOf(env), isEmpty);
      expect(store.hasFailed, isFalse);
    });

    test('dispose deletes the files and makes the store inert', () async {
      final env = environment();
      final store = EncryptedFileScrollbackStore(
        environment: env,
        segmentBytes: 2048,
      );
      final neighbour = EncryptedFileScrollbackStore(environment: env);
      expect(
        await Future.wait([
          for (var id = 0; id < 6; id++) store.put(id, _block(id, 1000)),
          neighbour.put(0, _block(99, 1000)),
        ]),
        everyElement(isTrue),
      );
      expect(store.get(5), _block(5, 1000));
      expect(segmentsOf(env), hasLength(4));

      store.dispose();
      expect(store.get(5), isNull);
      expect(await store.put(6, _block(6, 10)), isFalse);
      await store.whenIdle();
      store
        ..remove(0)
        ..clear()
        ..dispose();
      await store.whenIdle();
      expect(store.get(0), isNull);
      expect(store.storedBlocks, 0);

      // Only the other terminal's file and the process lock remain.
      expect(segmentsOf(env).map((f) => p.basename(f.path)), ['2-0.seg']);
      expect(
        File(p.join(folderOf(env).path, scrollbackSpillLockName)).existsSync(),
        isTrue,
      );
      expect(neighbour.get(0), _block(99, 1000));
    });

    test('disposing a store that never stored anything does no IO', () async {
      final env = environment();
      final store = EncryptedFileScrollbackStore(environment: env);
      expect(store.get(0), isNull);
      store
        ..remove(0)
        ..clear()
        ..dispose();
      await store.whenIdle();
      expect(root().existsSync(), isFalse);
    });
  });

  group('failures', () {
    test('a failed write refuses that put and all later ones while earlier '
        'blocks stay readable', () async {
      final io = _ScriptedIo();
      final env = environment(io: io);
      final store = EncryptedFileScrollbackStore(environment: env);
      expect(await store.put(0, _block(0, 500)), isTrue);
      expect(store.get(0), _block(0, 500));

      io.failWrites = true;
      final failing = [
        store.put(1, _block(1, 500)),
        store.put(2, _block(2, 500)),
      ];
      expect(await Future.wait(failing), [false, false]);
      expect(store.hasFailed, isTrue);
      expect(store.get(1), isNull);

      // The disk recovering does not bring the store back.
      io.failWrites = false;
      final writes = io.writeSizes.length;
      expect(await store.put(3, _block(3, 500)), isFalse);
      await store.whenIdle();
      expect(io.writeSizes, hasLength(writes));
      expect(store.get(3), isNull);

      expect(store.get(0), _block(0, 500));
      expect(store.storedBlocks, 1);

      // Space is still reclaimed.
      store.remove(0);
      await store.whenIdle();
      expect(segmentsOf(env), isEmpty);
      store.dispose();
    });

    test('a failing first write leaves no file behind', () async {
      final io = _ScriptedIo()..failWrites = true;
      final env = environment(io: io);
      final store = EncryptedFileScrollbackStore(environment: env);
      expect(
        await Future.wait([
          for (var id = 0; id < 5; id++) store.put(id, _block(id, 500)),
        ]),
        everyElement(isFalse),
      );
      await store.whenIdle();
      expect(segmentsOf(env), isEmpty);
      expect(store.hasFailed, isTrue);
    });

    test('a segment that cannot be created fails the store', () async {
      final io = _ScriptedIo()..failOpen = true;
      final env = environment(io: io);
      final store = EncryptedFileScrollbackStore(environment: env);
      expect(await store.put(0, _block(0, 500)), isFalse);
      expect(await store.put(1, _block(1, 500)), isFalse);
      expect(io.segmentsOpened, 1);
      expect(store.get(0), isNull);
      store.clear();
      await store.whenIdle();
      store.dispose();
    });

    test('a cache directory that is a regular file fails the store', () async {
      final file = File(p.join(cache.path, 'not-a-directory'))
        ..writeAsStringSync('x');
      final env = environment(cacheDirectory: () async => Directory(file.path));
      final store = EncryptedFileScrollbackStore(environment: env);
      expect(await store.put(0, _block(0, 500)), isFalse);
      expect(await store.put(1, _block(1, 500)), isFalse);
      expect(store.hasFailed, isTrue);
      expect(store.get(0), isNull);
      expect(file.readAsStringSync(), 'x');
      store.dispose();
      await store.whenIdle();
    });

    test('a missing cache directory provider fails the store', () async {
      final env = environment(
        cacheDirectory: () async => throw StateError('no path provider'),
      );
      final store = EncryptedFileScrollbackStore(environment: env);
      expect(await store.put(0, _block(0, 500)), isFalse);
      expect(store.hasFailed, isTrue);
    });

    test('unavailable libsodium fails that store only', () async {
      var available = false;
      final env = environment(
        sodiumProvider: () =>
            available ? sodium : throw StateError('libsodium missing'),
      );
      final broken = EncryptedFileScrollbackStore(environment: env);
      expect(await broken.put(0, _block(0, 500)), isFalse);
      expect(broken.hasFailed, isTrue);
      expect(root().existsSync(), isFalse);

      available = true;
      expect(await broken.put(1, _block(1, 500)), isFalse);
      final fresh = EncryptedFileScrollbackStore(environment: env);
      expect(await fresh.put(0, _block(0, 500)), isTrue);
      expect(fresh.get(0), _block(0, 500));
    });

    test(
      'the folder vanishing underneath fails later puts without throwing',
      () async {
        final env = environment();
        final store = EncryptedFileScrollbackStore(
          environment: env,
          segmentBytes: 2048,
        );
        // Two blocks fill and close the first segment.
        expect(
          await Future.wait([
            store.put(0, _block(0, 1000)),
            store.put(1, _block(1, 1000)),
          ]),
          [true, true],
        );
        folderOf(env).deleteSync(recursive: true);

        expect(await store.put(2, _block(2, 1000)), isFalse);
        expect(await store.put(3, _block(3, 1000)), isFalse);
        expect(store.hasFailed, isTrue);
        expect(store.get(0), isNull);
        expect(store.get(2), isNull);
        store
          ..remove(0)
          ..clear()
          ..dispose();
        await store.whenIdle();
      },
    );
  });

  group('stale folder sweep', () {
    Directory staleFolder(int seed, {bool lock = true}) {
      final folder = Directory(p.join(root().path, _hexName(seed)))
        ..createSync(recursive: true);
      File(p.join(folder.path, '1-0.seg')).writeAsBytesSync(_block(seed, 64));
      if (lock) {
        File(p.join(folder.path, scrollbackSpillLockName)).createSync();
      }
      return folder;
    }

    DateTime later() => DateTime.now().add(const Duration(minutes: 5));

    test('keeps the folder of this process', () async {
      final env = environment();
      final store = EncryptedFileScrollbackStore(environment: env);
      expect(await store.put(0, _block(0, 500)), isTrue);

      final result = await env.sweep(
        grace: Duration.zero,
        now: later,
        ownerAlive: (_) async => false,
      );
      expect(result.removed, 0);
      expect(result.ignored, 1);
      expect(folderOf(env).existsSync(), isTrue);
      expect(store.get(0), _block(0, 500));
      // The lock survived the sweep: the store keeps working.
      expect(await store.put(1, _block(1, 500)), isTrue);
    });

    test('keeps the folders of other environments of this process', () async {
      final mine = environment();
      final other = environment();
      final store = EncryptedFileScrollbackStore(environment: other);
      expect(await store.put(0, _block(0, 500)), isTrue);
      final result = await mine.sweep(grace: Duration.zero, now: later);
      expect(result.removed, 0);
      expect(folderOf(other).existsSync(), isTrue);
    });

    test(
      'keeps a young folder and removes it after the grace period',
      () async {
        final env = environment();
        final folder = staleFolder(1);
        final probed = <String>[];
        Future<bool> dead(Directory folder) async {
          probed.add(folder.path);
          return false;
        }

        var result = await env.sweep(ownerAlive: dead);
        expect(result.young, 1);
        expect(result.removed, 0);
        expect(folder.existsSync(), isTrue);
        expect(probed, isEmpty, reason: 'a young folder is not even probed');

        result = await env.sweep(
          now: () => DateTime.now().add(const Duration(seconds: 30)),
          ownerAlive: dead,
        );
        expect(result.young, 1);
        expect(folder.existsSync(), isTrue);

        result = await env.sweep(
          now: () => DateTime.now().add(const Duration(seconds: 61)),
          ownerAlive: dead,
        );
        expect(result.removed, 1);
        expect(result.young, 0);
        expect(folder.existsSync(), isFalse);
        expect(probed, [folder.path]);
      },
    );

    test('keeps a folder with a modification time in the future', () async {
      final env = environment();
      final folder = staleFolder(2);
      final result = await env.sweep(
        now: () => DateTime.now().subtract(const Duration(days: 1)),
        ownerAlive: (_) async => false,
      );
      expect(result.young, 1);
      expect(folder.existsSync(), isTrue);
    });

    test('keeps an old folder whose owner is alive', () async {
      final env = environment();
      final liveFolder = staleFolder(3);
      final deadFolder = staleFolder(4);
      final result = await env.sweep(
        now: later,
        ownerAlive: (folder) async => folder.path == liveFolder.path,
      );
      expect(result.live, 1);
      expect(result.removed, 1);
      expect(liveFolder.existsSync(), isTrue);
      expect(File(p.join(liveFolder.path, '1-0.seg')).existsSync(), isTrue);
      expect(deadFolder.existsSync(), isFalse);
    });

    test(
      'removes old folders that are unlocked or have no lock file',
      () async {
        final env = environment();
        final unlocked = staleFolder(5);
        final lockless = staleFolder(6, lock: false);
        // The real lock probe.
        final result = await env.sweep(now: later);
        expect(result.removed, 2);
        expect(unlocked.existsSync(), isFalse);
        expect(lockless.existsSync(), isFalse);
        expect(root().existsSync(), isTrue);
      },
    );

    test('keeps a folder whose owner cannot be determined', () async {
      final env = environment();
      final unknown = staleFolder(7);
      final dead = staleFolder(8);
      final result = await env.sweep(
        now: later,
        ownerAlive: (folder) async => folder.path == unknown.path
            ? throw const FileSystemException('Permission denied')
            : false,
      );
      expect(result.ignored, 1);
      expect(result.removed, 1);
      expect(unknown.existsSync(), isTrue);
      expect(dead.existsSync(), isFalse);
    });

    test(
      'never throws on, and never deletes, entries it did not create',
      () async {
        final env = environment();
        root().createSync(recursive: true);
        final fileWithFolderName = File(p.join(root().path, _hexName(9)))
          ..writeAsStringSync('a regular file');
        final notes = File(p.join(root().path, 'notes.txt'))
          ..writeAsStringSync('keep');
        final foreign = Directory(p.join(root().path, 'someone-elses-folder'))
          ..createSync();
        final shortName = Directory(p.join(root().path, 'abcdef'))
          ..createSync();
        final upperCase = Directory(
          p.join(root().path, _hexName(0xABCDEF).toUpperCase()),
        )..createSync();
        final target = Directory(p.join(cache.path, 'link-target'))
          ..createSync();
        File(p.join(target.path, 'precious')).writeAsStringSync('keep');
        final link = Link(p.join(root().path, _hexName(10)));
        var linked = true;
        try {
          link.createSync(target.path);
        } on FileSystemException {
          linked = false; // Needs a privilege on Windows.
        }
        final stale = staleFolder(11);

        final result = await env.sweep(
          now: later,
          ownerAlive: (_) async => false,
        );
        expect(result.removed, 1);
        expect(stale.existsSync(), isFalse);
        expect(fileWithFolderName.readAsStringSync(), 'a regular file');
        expect(notes.existsSync(), isTrue);
        expect(foreign.existsSync(), isTrue);
        expect(shortName.existsSync(), isTrue);
        expect(upperCase.existsSync(), isTrue);
        if (linked) expect(link.existsSync(), isTrue);
        expect(File(p.join(target.path, 'precious')).existsSync(), isTrue);
      },
    );

    test('never throws without a root or a cache directory', () async {
      final empty = await environment().sweep(now: later);
      expect(empty.removed + empty.young + empty.live + empty.ignored, 0);
      expect(root().existsSync(), isFalse, reason: 'a sweep creates nothing');

      final noProvider = await environment(
        cacheDirectory: () async => throw StateError('no path provider'),
      ).sweep(now: later);
      expect(noProvider.removed, 0);

      File(root().path).writeAsStringSync('the root is a file');
      final fileRoot = await environment().sweep(now: later);
      expect(fileRoot.removed, 0);
      expect(File(root().path).readAsStringSync(), 'the root is a file');
    });

    test('leaves the folder of a live second process alone and removes it once '
        'that process is gone', () async {
      final dart = [
        if (Platform.environment['FLUTTER_ROOT'] case final flutter?)
          p.join(flutter, 'bin', 'cache', 'dart-sdk', 'bin', 'dart'),
        '/root/.cache/atermius/flutter/bin/cache/dart-sdk/bin/dart',
      ].where((path) => File(path).existsSync()).firstOrNull;
      if (dart == null) {
        markTestSkipped('No Dart VM found in the Flutter SDK.');
        return;
      }
      final script = File(
        p.join('test', 'support', 'scrollback_spill_lock_holder.dart'),
      ).absolute.path;
      final env = environment();

      Future<Process> holder(Directory folder) async {
        final process = await Process.start(dart, [script, folder.path]);
        final ready = Completer<void>();
        final errors = StringBuffer();
        process.stderr.transform(utf8.decoder).listen(errors.write);
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (line) {
                if (line == 'ready' && !ready.isCompleted) ready.complete();
              },
              onDone: () {
                if (!ready.isCompleted) {
                  ready.completeError(StateError('Helper failed: $errors'));
                }
              },
            );
        await ready.future.timeout(const Duration(seconds: 60));
        return process;
      }

      final exiting = staleFolder(20, lock: false);
      final killed = staleFolder(21, lock: false);
      final first = await holder(exiting);
      final second = await holder(killed);
      addTearDown(() {
        first.kill(ProcessSignal.sigkill);
        second.kill(ProcessSignal.sigkill);
      });

      // Old enough, not ours, but locked by live processes.
      for (var i = 0; i < 2; i++) {
        final result = await env.sweep(now: later);
        expect(result.live, 2);
        expect(result.removed, 0);
        expect(File(p.join(exiting.path, '1-0.seg')).existsSync(), isTrue);
        expect(File(p.join(killed.path, '1-0.seg')).existsSync(), isTrue);
      }
      expect(await scrollbackSpillOwnerAlive(exiting), isTrue);

      // A clean exit.
      await first.stdin.close();
      expect(await first.exitCode, 0);
      var result = await env.sweep(now: later);
      expect(result.removed, 1);
      expect(result.live, 1);
      expect(exiting.existsSync(), isFalse);
      expect(killed.existsSync(), isTrue);

      // A crash: the OS drops the lock with the process.
      second.kill(ProcessSignal.sigkill);
      await second.exitCode;
      result = await env.sweep(now: later);
      expect(result.removed, 1);
      expect(killed.existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('platform facade', () {
    test('the native facade creates an independent store per terminal '
        'without touching the disk', () {
      final first = facade.createScrollbackSpillStore();
      final second = facade.createScrollbackSpillStore();
      expect(first, isA<EncryptedFileScrollbackStore>());
      expect(second, isNot(same(first)));
      first!.dispose();
      second!.dispose();
      expect(first.get(0), isNull);
    });

    test('the web stub has no disk tier', () async {
      expect(web.createScrollbackSpillStore(), isNull);
      await web.cleanStaleScrollbackSpill();

      final stub = File(
        p.join('lib', 'terminal', 'scrollback_spill_store_web.dart'),
      ).readAsStringSync();
      for (final forbidden in [
        'dart:io',
        'dart:ffi',
        'sodium',
        'path_provider',
        '_io.dart',
      ]) {
        expect(stub, isNot(contains(forbidden)), reason: forbidden);
      }

      final entry = File(
        p.join('lib', 'terminal', 'scrollback_spill_store.dart'),
      ).readAsStringSync();
      expect(
        entry,
        contains(
          "if (dart.library.js_interop) 'scrollback_spill_store_web.dart'",
        ),
      );
      for (final forbidden in ['dart:io', 'dart:ffi', 'package:sodium']) {
        expect(entry, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });
}
