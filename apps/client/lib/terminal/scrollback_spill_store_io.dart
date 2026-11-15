import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/core.dart' show ScrollbackBlockStore;

/// Folder below the application cache directory that holds every process's
/// spilled scrollback.
const String scrollbackSpillRootName = 'atermius-scrollback';

/// Name of the lock file a process holds inside its own folder.
const String scrollbackSpillLockName = 'lock';

/// Nominal size of one append-only segment file. A segment is closed by the
/// first write that reaches this size, so it can exceed it by at most one
/// write batch.
const int scrollbackSpillSegmentBytes = 16 * 1024 * 1024;

/// Upper bound for the ciphertext handed to the OS in one write.
const int scrollbackSpillBatchBytes = 1024 * 1024;

/// How long the writer loop may spend encrypting before it writes what it
/// has and gives the event loop a turn. Encryption runs on the UI isolate
/// and libsodium's guarded allocations cost a fixed 0.1 ms or so per block,
/// so a long queue is worked off in slices of about this length.
const Duration scrollbackSpillBatchTime = Duration(milliseconds: 4);

/// How long a process folder must have been left unmodified before the
/// startup sweep considers it. Covers the moment between a new process
/// creating its folder and locking it.
const Duration scrollbackSpillSweepGrace = Duration(seconds: 60);

/// Bytes added to every block on disk: the nonce in front of the ciphertext
/// and the Poly1305 tag behind it.
const int scrollbackSpillFrameOverhead = _nonceBytes + _tagBytes;

const int _nonceBytes = 24;
const int _tagBytes = 16;
const int _keyBytes = 32;
const String _associatedDataLabel = 'atermius-scrollback-spill-v1';
const int _maxOpenReaders = 4;
const int _scratchBytes = 64 * 1024;
final RegExp _processFolderPattern = RegExp(r'^[0-9a-f]{32}$');

/// Per-terminal store on native platforms.
ScrollbackBlockStore? createScrollbackSpillStore() =>
    EncryptedFileScrollbackStore();

/// Removes the folders that dead processes left behind. Folders that are
/// still inside the grace period are looked at once more after it has
/// passed, so a quick restart does not leave them until the next launch.
Future<void> cleanStaleScrollbackSpill() async {
  try {
    final environment = ScrollbackSpillEnvironment.shared;
    final result = await environment.sweep();
    if (result.young > 0) {
      Timer(
        scrollbackSpillSweepGrace + const Duration(seconds: 5),
        () => unawaited(environment.sweep()),
      );
    }
  } on Object {
    // Leftovers cannot be decrypted; reclaiming their space is best effort.
  }
}

/// The file operations of the spill store, overridable so tests can make
/// them fail or stall. Every method may throw; the callers contain it.
class ScrollbackSpillIo {
  const ScrollbackSpillIo();

  Future<void> createDirectory(Directory directory) =>
      directory.create(recursive: true);

  /// Creates [file] empty and opens it for appending.
  Future<RandomAccessFile> openSegment(File file) =>
      file.open(mode: FileMode.write);

  Future<void> write(RandomAccessFile file, Uint8List bytes) =>
      file.writeFrom(bytes);

  /// A second, read-only handle used for the synchronous reads. A handle
  /// with an asynchronous operation in flight cannot serve them.
  RandomAccessFile openReader(File file) => file.openSync();

  Future<void> delete(File file) => file.delete();
}

/// What a store needs from its [ScrollbackSpillEnvironment].
final class ScrollbackSpillSession {
  const ScrollbackSpillSession({required this.sodium, required this.folder});

  final Sodium sodium;

  /// This process's own, locked folder.
  final Directory folder;
}

/// Outcome of one [ScrollbackSpillEnvironment.sweep].
final class ScrollbackSpillSweepResult {
  const ScrollbackSpillSweepResult({
    this.removed = 0,
    this.young = 0,
    this.live = 0,
    this.ignored = 0,
  });

  /// Folders of dead processes that were deleted.
  final int removed;

  /// Folders left alone because they were modified within the grace period.
  final int young;

  /// Folders left alone because their owner still holds the lock.
  final int live;

  /// Everything else: this process's own folder, entries the store did not
  /// create, and folders that could not be examined or deleted.
  final int ignored;
}

/// The process-wide part of the spill store: where the files live, the
/// folder and lock of this process, and libsodium.
///
/// Location: `getApplicationCacheDirectory()`, not `getTemporaryDirectory()`.
/// Both are app-private storage that the OS keeps out of backups and may
/// purge, but the temporary directory is `/tmp` on Linux, which is shared
/// between users and often a RAM-backed tmpfs that would defeat a disk tier.
///
/// * Android: `Context.getCacheDir()`, app-private, never backed up, purged
///   by the OS when storage runs low.
/// * iOS and macOS: `Library/Caches`, excluded from iCloud and iTunes
///   backups and purgeable.
/// * Linux: `$XDG_CACHE_HOME/<application id>` (`~/.cache/...`), on the
///   user's disk and owned by the user.
/// * Windows: the application folder below `%LOCALAPPDATA%`, per user and
///   not roaming.
///
/// Layout: `<cache>/atermius-scrollback/<process>/<terminal>-<n>.seg`, where
/// `<process>` is a random name chosen by each process. The process holds an
/// exclusive OS lock on `<process>/lock` until it exits; the OS drops the
/// lock when the process dies, which is how [sweep] tells leftovers from the
/// folders of live processes (detached terminal windows are separate
/// processes sharing the same root).
final class ScrollbackSpillEnvironment {
  /// [cacheDirectory] replaces the application cache directory and [sodium]
  /// the process-wide libsodium instance; both are for tests, as are [io]
  /// and [processFolderName].
  ScrollbackSpillEnvironment({
    Future<Directory> Function()? cacheDirectory,
    FutureOr<Sodium> Function()? sodium,
    this.io = const ScrollbackSpillIo(),
    String? processFolderName,
  }) : _cacheDirectory = cacheDirectory ?? getApplicationCacheDirectory,
       _sodium = sodium ?? _processSodium,
       processFolderName = processFolderName ?? _randomFolderName() {
    _ownFolderNames.add(this.processFolderName);
  }

  /// The environment of the running application.
  static final ScrollbackSpillEnvironment shared = ScrollbackSpillEnvironment();

  /// Every folder name this process has claimed. POSIX record locks do not
  /// conflict inside one process, and probing one would even release it, so
  /// the sweep recognises its own folders by name instead.
  static final Set<String> _ownFolderNames = {};

  static Future<Sodium>? _sharedSodium;

  final Future<Directory> Function() _cacheDirectory;
  final FutureOr<Sodium> Function() _sodium;
  final ScrollbackSpillIo io;

  /// Name of this process's folder below [root].
  final String processFolderName;

  Future<ScrollbackSpillSession>? _session;
  RandomAccessFile? _lock;
  int _terminals = 0;

  /// The folder shared by all processes.
  Future<Directory> root() async => Directory(
    p.join((await _cacheDirectory()).path, scrollbackSpillRootName),
  );

  /// Initialises libsodium and creates and locks this process's folder, once
  /// for all stores. Throws when any of that is impossible; a later call
  /// tries again.
  Future<ScrollbackSpillSession> prepare() {
    final existing = _session;
    if (existing != null) return existing;
    final created = _prepare();
    _session = created;
    created.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_session, created)) _session = null;
      },
    );
    return created;
  }

  Future<ScrollbackSpillSession> _prepare() async {
    final sodium = await _sodium();
    final folder = Directory(p.join((await root()).path, processFolderName));
    await io.createDirectory(folder);
    _restrictToOwner(folder.path);
    // Never closed while the process lives: the lock is the proof of life.
    final lock = await File(p.join(folder.path, scrollbackSpillLockName))
        .open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } on Object {
      await lock.close();
      rethrow;
    }
    _lock = lock;
    return ScrollbackSpillSession(sodium: sodium, folder: folder);
  }

  /// File name prefix for the next terminal of this process.
  String _nextTerminalId() => '${++_terminals}';

  /// Deletes the folders of processes that no longer exist. A folder goes
  /// only when all of this holds:
  ///
  /// * it is not a folder of this process (compared by name),
  /// * its name has the shape this store generates and it is a real
  ///   directory, not a link,
  /// * it was last modified at least [grace] before [now], and
  /// * [ownerAlive] reports that nobody holds its lock.
  ///
  /// Whatever cannot be examined is left alone. Never throws.
  Future<ScrollbackSpillSweepResult> sweep({
    Duration grace = scrollbackSpillSweepGrace,
    DateTime Function() now = DateTime.now,
    Future<bool> Function(Directory folder)? ownerAlive,
  }) async {
    var removed = 0;
    var young = 0;
    var live = 0;
    var ignored = 0;
    try {
      final root = await this.root();
      if (await root.exists()) {
        final alive = ownerAlive ?? scrollbackSpillOwnerAlive;
        await for (final entity in root.list(followLinks: false)) {
          try {
            final name = p.basename(entity.path);
            if (entity is! Directory ||
                !_processFolderPattern.hasMatch(name) ||
                _ownFolderNames.contains(name)) {
              ignored++;
              continue;
            }
            final stat = await entity.stat();
            if (stat.type != FileSystemEntityType.directory) {
              ignored++;
            } else if (now().difference(stat.modified) < grace) {
              young++;
            } else if (await alive(entity)) {
              live++;
            } else {
              await entity.delete(recursive: true);
              removed++;
            }
          } on Object {
            ignored++;
          }
        }
      }
    } on Object {
      // No cache directory, unreadable root: nothing to reclaim.
    }
    return ScrollbackSpillSweepResult(
      removed: removed,
      young: young,
      live: live,
      ignored: ignored,
    );
  }

  /// Gives up this process's lock. Only tests need this, to hand a folder
  /// over to a sweep or to remove it; the application keeps the lock until
  /// the process exits.
  Future<void> release() async {
    final session = _session;
    _session = null;
    try {
      await session;
    } on Object {
      // Nothing was locked.
    }
    final lock = _lock;
    _lock = null;
    try {
      await lock?.close();
    } on Object {
      // Already closed.
    }
  }

  static Future<Sodium> _processSodium() {
    final existing = _sharedSodium;
    if (existing != null) return existing;
    final created = Future<Sodium>.sync(SodiumSumoInit.init);
    _sharedSodium = created;
    created.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_sharedSodium, created)) _sharedSodium = null;
      },
    );
    return created;
  }

  static String _randomFolderName() {
    final random = Random.secure();
    final name = StringBuffer();
    for (var i = 0; i < 16; i++) {
      name.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return name.toString();
  }
}

/// Whether a live process holds the lock of the process folder [folder].
///
/// The lock is probed without blocking. A missing lock file means the owner
/// died before it got that far. Throws when the lock file cannot be opened,
/// which the sweep treats as "leave the folder alone".
///
/// Must not be called for a folder of the calling process: on POSIX systems
/// the probe would succeed and closing the probe's handle would drop the
/// process's own lock.
Future<bool> scrollbackSpillOwnerAlive(Directory folder) async {
  final file = File(p.join(folder.path, scrollbackSpillLockName));
  if (!await file.exists()) return false;
  final handle = await file.open(mode: FileMode.append);
  try {
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      return true;
    }
    await handle.unlock();
    return false;
  } finally {
    await handle.close();
  }
}

/// A [ScrollbackBlockStore] that keeps one terminal's oldest scrollback
/// blocks in encrypted, append-only segment files.
///
/// Confidentiality: every block is sealed with XChaCha20-Poly1305-IETF under
/// a random 256-bit key that exists only in libsodium's guarded memory for
/// the lifetime of this store. The key is never written anywhere, so the
/// files are unreadable once the store is disposed or the process is gone.
///
/// On-disk format: a segment is a plain concatenation of frames without any
/// header, `nonce (24 bytes) || ciphertext || tag (16 bytes)`, with a fresh
/// random nonce per block. The associated data is the ASCII label
/// `atermius-scrollback-spill-v1` followed by the block id as an unsigned
/// 64-bit big-endian integer, so a frame moved to another id fails
/// authentication exactly like a modified one. Where a block lives (segment,
/// offset, length) is known only to the in-memory index.
///
/// Writing: [put] only queues. One writer loop per store, started in a
/// microtask, encrypts what has been queued so far and appends it with a
/// single write per batch, a batch being bounded in bytes and in encryption
/// time so the UI isolate is never held for long; it is also the only code
/// that creates, closes or deletes segment files. Nothing is flushed to stable storage, the data
/// only has to be readable through the OS cache. A segment file is deleted
/// as soon as it holds no live block and is not being written, so disk use
/// follows the live blocks.
///
/// Removal during a write: when [remove], [clear] or [dispose] reaches a
/// block whose [put] has not completed, that future completes with `false`
/// right away and the block never becomes readable, whether it was still
/// queued or already being written.
///
/// Failure: the first error while preparing or writing marks the store as
/// failed. That [put] and every later one complete with `false` and nothing
/// is written any more, while the blocks stored before stay readable as long
/// as their files do. No method throws.
final class EncryptedFileScrollbackStore implements ScrollbackBlockStore {
  /// [environment] defaults to the application's; [segmentBytes],
  /// [batchBytes] and [batchTime] are tuning values that tests change.
  EncryptedFileScrollbackStore({
    ScrollbackSpillEnvironment? environment,
    this.segmentBytes = scrollbackSpillSegmentBytes,
    this.batchBytes = scrollbackSpillBatchBytes,
    this.batchTime = scrollbackSpillBatchTime,
  }) : environment = environment ?? ScrollbackSpillEnvironment.shared;

  final ScrollbackSpillEnvironment environment;
  final int segmentBytes;
  final int batchBytes;
  final Duration batchTime;

  /// Ciphertext read buffer shared by all stores; reads are synchronous and
  /// never overlap. Larger blocks get a buffer of their own.
  static final Uint8List _scratch = Uint8List(_scratchBytes);

  final HashMap<int, _Block> _index = HashMap();

  /// Blocks whose [put] has not completed: queued or being written.
  final HashMap<int, _PendingPut> _pending = HashMap();
  final ListQueue<_PendingPut> _queue = ListQueue();
  final Set<_Segment> _segments = {};
  final List<_Segment> _retired = [];
  final List<_Segment> _readers = [];
  final Uint8List _associatedData = _newAssociatedData();

  Sodium? _sodium;
  SecureKey? _key;
  String _prefix = '';
  int _nextSegment = 0;
  _Segment? _active;
  bool _pumping = false;
  bool _failed = false;
  bool _disposed = false;
  Completer<void>? _idle;

  /// Whether an error has stopped this store from accepting blocks.
  bool get hasFailed => _failed;

  /// Number of blocks that can currently be read back from disk.
  int get storedBlocks => _index.length;

  /// Completes when the writer loop has nothing left to do: every queued
  /// block is written or refused and every released file is deleted.
  Future<void> whenIdle() =>
      _pumping ? (_idle ??= Completer<void>()).future : Future<void>.value();

  @override
  Future<bool> put(int id, Uint8List bytes) {
    if (_disposed || _failed) return Future<bool>.value(false);
    // Ids are never reused; a repeated one replaces the earlier block.
    remove(id);
    final put = _PendingPut(id, bytes);
    _pending[id] = put;
    _queue.add(put);
    _kick();
    return put.completer.future;
  }

  @override
  Uint8List? get(int id) {
    if (_disposed) return null;
    final pending = _pending[id];
    if (pending != null) return pending.bytes;
    final block = _index[id];
    if (block == null) return null;
    final key = _key;
    final sodium = _sodium;
    if (key == null || sodium == null) return null;
    try {
      final length = block.length;
      if (length < scrollbackSpillFrameOverhead) return null;
      final reader = _readerFor(block.segment);
      final frame = length <= _scratchBytes ? _scratch : Uint8List(length);
      reader.setPositionSync(block.offset);
      var read = 0;
      while (read < length) {
        final count = reader.readIntoSync(frame, read, length);
        if (count <= 0) return null;
        read += count;
      }
      return sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: Uint8List.sublistView(frame, _nonceBytes, length),
        nonce: Uint8List.sublistView(frame, 0, _nonceBytes),
        key: key,
        additionalData: _associatedDataFor(id),
      );
    } on Object {
      // Missing, short, corrupt or forged: fail closed.
      return null;
    }
  }

  @override
  void remove(int id) {
    final pending = _pending.remove(id);
    if (pending != null) {
      pending.finish(false);
      return;
    }
    final block = _index.remove(id);
    if (block == null) return;
    block.segment.live--;
    _retireIfDead(block.segment);
  }

  @override
  void clear() {
    if (_disposed) return;
    _forgetEverything();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _forgetEverything();
    try {
      _key?.dispose();
    } on Object {
      // The key memory is released with the process at the latest.
    }
    _key = null;
    _sodium = null;
  }

  void _forgetEverything() {
    for (final put in _pending.values) {
      put.finish(false);
    }
    _pending.clear();
    _queue.clear();
    _index.clear();
    for (final segment in _segments.toList()) {
      _retire(segment);
    }
  }

  void _retireIfDead(_Segment segment) {
    if (segment.retired || segment.busy || segment.live > 0) return;
    _retire(segment);
  }

  /// Takes [segment] out of use. Its file is deleted by the writer loop,
  /// which is the only place where no write to it can be in flight.
  void _retire(_Segment segment) {
    if (segment.retired) return;
    segment.retired = true;
    _closeReader(segment);
    _segments.remove(segment);
    if (identical(_active, segment)) _active = null;
    _retired.add(segment);
    _kick();
  }

  RandomAccessFile _readerFor(_Segment segment) {
    final open = segment.reader;
    if (open != null) {
      if (!identical(_readers.last, segment)) {
        _readers
          ..remove(segment)
          ..add(segment);
      }
      return open;
    }
    if (_readers.length >= _maxOpenReaders) _closeReader(_readers.first);
    final reader = environment.io.openReader(File(segment.path));
    segment.reader = reader;
    _readers.add(segment);
    return reader;
  }

  void _closeReader(_Segment segment) {
    final reader = segment.reader;
    if (reader == null) return;
    segment.reader = null;
    _readers.remove(segment);
    try {
      reader.closeSync();
    } on Object {
      // Nothing to release.
    }
  }

  Uint8List _associatedDataFor(int id) {
    final data = _associatedData;
    ByteData.sublistView(data).setUint64(data.length - 8, id);
    return data;
  }

  static Uint8List _newAssociatedData() {
    final label = _associatedDataLabel.codeUnits;
    return Uint8List(label.length + 8)..setRange(0, label.length, label);
  }

  void _kick() {
    if (_pumping) return;
    _pumping = true;
    scheduleMicrotask(() => unawaited(_pump()));
  }

  /// The writer loop. Runs until there is nothing to delete and nothing to
  /// write; everything that touches a segment file for writing happens here,
  /// one operation after the other.
  Future<void> _pump() async {
    try {
      while (true) {
        // Blocks removed while they were queued need no file at all.
        while (_queue.isNotEmpty && _queue.first.settled) {
          _queue.removeFirst();
        }
        if (_retired.isNotEmpty) {
          await _deleteRetired();
        } else if (_disposed || _failed || _queue.isEmpty) {
          break;
        } else {
          try {
            await _writeBatch();
          } on Object {
            await _fail();
          }
        }
      }
    } on Object {
      // Unreachable by construction; a store must never throw.
    } finally {
      _pumping = false;
      final idle = _idle;
      _idle = null;
      idle?.complete();
    }
  }

  Future<void> _deleteRetired() async {
    while (_retired.isNotEmpty) {
      final segment = _retired.removeLast();
      await _closeWriter(segment);
      try {
        await environment.io.delete(File(segment.path));
      } on Object {
        // Never created, already purged, or left for the startup sweep.
      }
    }
  }

  Future<void> _closeWriter(_Segment segment) async {
    final writer = segment.writer;
    if (writer == null) return;
    segment.writer = null;
    try {
      await writer.close();
    } on Object {
      // The descriptor is gone either way.
    }
  }

  /// Stops accepting blocks. What is on disk stays readable.
  Future<void> _fail() async {
    _failed = true;
    for (final put in _pending.values) {
      put.finish(false);
    }
    _pending.clear();
    _queue.clear();
    final active = _active;
    _active = null;
    if (active != null) {
      await _closeWriter(active);
      _retireIfDead(active);
    }
  }

  /// Encrypts queued blocks until [batchBytes] or [batchTime] is reached
  /// and appends them to the current segment with one write. Throws on any
  /// failure.
  Future<void> _writeBatch() async {
    if (_key == null) {
      final session = await environment.prepare();
      if (_disposed) return;
      final sodium = session.sodium;
      final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
      if (aead.nonceBytes != _nonceBytes ||
          aead.aBytes != _tagBytes ||
          aead.keyBytes != _keyBytes) {
        throw StateError('Unexpected XChaCha20-Poly1305 parameters.');
      }
      _prefix = p.join(session.folder.path, environment._nextTerminalId());
      _sodium = sodium;
      _key = aead.keygen();
    }

    var segment = _active;
    if (segment == null) {
      segment = _Segment('$_prefix-${_nextSegment++}.seg');
      _segments.add(segment);
      _active = segment;
    }
    segment.busy = true;
    try {
      var writer = segment.writer;
      if (writer == null) {
        writer = await environment.io.openSegment(File(segment.path));
        segment.writer = writer;
        // Cleared or disposed while the file was being created.
        if (segment.retired || _disposed) return;
      }

      final sodium = _sodium!;
      final key = _key!;
      final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
      final frames = BytesBuilder(copy: false);
      final written = <_PendingPut>[];
      final elapsed = Stopwatch()..start();
      while (_queue.isNotEmpty) {
        final put = _queue.first;
        final bytes = put.bytes;
        if (put.settled || bytes == null) {
          _queue.removeFirst();
          continue;
        }
        if (written.isNotEmpty &&
            (segment.size + frames.length >= segmentBytes ||
                frames.length + bytes.length + scrollbackSpillFrameOverhead >
                    batchBytes ||
                elapsed.elapsed >= batchTime)) {
          break;
        }
        _queue.removeFirst();
        final nonce = sodium.randombytes.buf(_nonceBytes);
        final sealed = aead.encrypt(
          message: bytes,
          nonce: nonce,
          key: key,
          additionalData: _associatedDataFor(put.id),
        );
        put
          ..offset = segment.size + frames.length
          ..length = nonce.length + sealed.length;
        frames
          ..add(nonce)
          ..add(sealed);
        written.add(put);
      }
      if (written.isEmpty) return;

      final batch = frames.takeBytes();
      await environment.io.write(writer, batch);
      segment.size += batch.length;
      for (final put in written) {
        // Removed, cleared or disposed during the write: the frame stays
        // behind as dead bytes of a segment that is deleted when it empties.
        if (put.settled) continue;
        _pending.remove(put.id);
        _index[put.id] = _Block(segment, put.offset, put.length);
        segment.live++;
        put.finish(true);
      }
      if (!segment.retired && segment.size >= segmentBytes) {
        if (identical(_active, segment)) _active = null;
        await _closeWriter(segment);
      }
    } finally {
      segment.busy = false;
      _retireIfDead(segment);
    }
  }
}

/// Where a stored block lives.
final class _Block {
  const _Block(this.segment, this.offset, this.length);

  final _Segment segment;
  final int offset;

  /// Length of the whole frame: nonce, ciphertext and tag.
  final int length;
}

final class _Segment {
  _Segment(this.path);

  final String path;
  RandomAccessFile? writer;
  RandomAccessFile? reader;

  /// Bytes appended so far.
  int size = 0;

  /// Indexed blocks inside this segment.
  int live = 0;

  /// The writer loop is creating or appending to the file.
  bool busy = false;

  /// Out of use and waiting for, or past, deletion.
  bool retired = false;
}

final class _PendingPut {
  _PendingPut(this.id, this.bytes);

  final int id;
  Uint8List? bytes;
  final Completer<bool> completer = Completer<bool>();
  int offset = 0;
  int length = 0;

  bool get settled => completer.isCompleted;

  void finish(bool stored) {
    bytes = null;
    if (!completer.isCompleted) completer.complete(stored);
  }
}

typedef _ChmodNative32 = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ChmodNative16 = Int32 Function(Pointer<Utf8>, Uint16);
typedef _Chmod = int Function(Pointer<Utf8>, int);

/// Best effort `chmod 0700` through libc, so other local users cannot even
/// list a process folder. The cache directory is already private on mobile
/// platforms and protected by the profile ACL on Windows.
void _restrictToOwner(String directory) {
  if (Platform.isWindows) return;
  try {
    final libc = DynamicLibrary.process();
    final chmod = Platform.isIOS || Platform.isMacOS
        ? libc.lookupFunction<_ChmodNative16, _Chmod>('chmod')
        : libc.lookupFunction<_ChmodNative32, _Chmod>('chmod');
    final path = directory.toNativeUtf8();
    try {
      chmod(path, 0x1c0);
    } finally {
      calloc.free(path);
    }
  } on Object {
    // The ciphertext does not depend on file permissions.
  }
}
