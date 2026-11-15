import 'package:xterm/src/core/buffer/scrollback/block_store.dart';
import 'package:xterm/src/core/buffer/scrollback/codec.dart';

/// How a terminal keeps the lines that have scrolled out of view.
///
/// The scrollback has up to three tiers:
///
/// 1. the *hot window*: the viewport and the [hotLines] lines above it, held
///    as plain [BufferLine]s exactly like before;
/// 2. the *memory archive*: older lines, serialized compactly in blocks of
///    [blockLines] lines and compressed, at most [maxMemoryBytes];
/// 3. optionally the *store*: when the memory archive is over its budget, its
///    oldest blocks move to [store] (for example an encrypted temporary
///    file), at most [maxStoreBytes].
///
/// Lines are restored transparently, and bit for bit, whenever something
/// reads them. Lines are dropped for good, oldest first, only when the
/// terminal's `maxLines` or the budget of the last tier is exceeded.
class ScrollbackOptions {
  const ScrollbackOptions({
    this.hotLines = 2048,
    this.blockLines = 256,
    this.maxMemoryBytes,
    this.maxStoreBytes = defaultMaxStoreBytes,
    this.maxPendingBytes = defaultMaxPendingBytes,
    this.cachedBlocks = 4,
    this.codec,
    this.store,
  })  : archive = true,
        assert(hotLines >= 0),
        assert(blockLines > 0),
        assert(cachedBlocks > 0);

  /// Keeps every line as a plain [BufferLine], like xterm.dart always did.
  const ScrollbackOptions.plain()
      : archive = false,
        hotLines = 0,
        blockLines = 256,
        maxMemoryBytes = null,
        maxStoreBytes = 0,
        maxPendingBytes = 0,
        cachedBlocks = 1,
        codec = null,
        store = null;

  /// Memory budget of the archive when there is no [store] behind it.
  static const defaultMaxMemoryBytes = 32 * 1024 * 1024;

  /// Memory budget of the archive when older blocks can move to a [store].
  static const defaultMaxMemoryBytesWithStore = 16 * 1024 * 1024;

  /// Budget of the [store] per terminal.
  static const defaultMaxStoreBytes = 512 * 1024 * 1024;

  /// How much may wait in memory for the [store] to finish writing.
  static const defaultMaxPendingBytes = 32 * 1024 * 1024;

  /// Whether lines above the hot window are archived at all.
  final bool archive;

  /// Number of scrollback lines above the viewport that stay plain. A block
  /// is archived once [blockLines] more lines than that have accumulated.
  final int hotLines;

  /// Number of lines per archived block.
  final int blockLines;

  /// Budget for the compressed blocks held in memory. Defaults to
  /// [defaultMaxMemoryBytesWithStore] with a [store] and to
  /// [defaultMaxMemoryBytes] without one.
  final int? maxMemoryBytes;

  /// Budget for the blocks handed to [store].
  final int maxStoreBytes;

  /// Budget for blocks that have been handed to [store] but are not written
  /// yet. They stay in memory, on top of [maxMemoryBytes], until the store
  /// reports them written. A store that falls further behind than this (a
  /// very slow disk under a very long burst of output) makes the buffer drop
  /// its oldest blocks, so memory stays bounded whatever the store does.
  final int maxPendingBytes;

  /// Number of restored blocks kept ready, so that scrolling through history
  /// does not decompress the same block again and again.
  final int cachedBlocks;

  /// Compression of the blocks. Defaults to [ScrollbackCodec.platform].
  final ScrollbackCodec? codec;

  /// Where blocks go when the memory archive is over its budget. Without one
  /// the oldest blocks are dropped instead.
  final ScrollbackBlockStore? store;

  /// The effective memory budget of the archive.
  int get effectiveMaxMemoryBytes =>
      maxMemoryBytes ??
      (store == null ? defaultMaxMemoryBytes : defaultMaxMemoryBytesWithStore);
}

/// A snapshot of where the lines of a buffer currently live.
class ScrollbackStats {
  const ScrollbackStats({
    required this.lines,
    required this.hotLines,
    required this.archivedLines,
    required this.memoryBlocks,
    required this.memoryBytes,
    required this.storedBlocks,
    required this.storedBytes,
    required this.cachedBlocks,
    required this.pinnedLines,
    required this.storeFailed,
  });

  /// Total number of lines, including the viewport.
  final int lines;

  /// Plain lines: the viewport and the hot window above it.
  final int hotLines;

  /// Lines held in archived blocks, in memory or in the store.
  final int archivedLines;

  /// Archived blocks whose bytes are held in memory, including those that
  /// are still being written to the store.
  final int memoryBlocks;

  /// Bytes of the archived blocks held in memory.
  final int memoryBytes;

  /// Archived blocks that live only in the store.
  final int storedBlocks;

  /// Bytes of the archived blocks that live only in the store.
  final int storedBytes;

  /// Archived blocks that are currently restored for reading.
  final int cachedBlocks;

  /// Archived lines kept alive individually because they carry anchors.
  final int pinnedLines;

  /// Whether the store failed and is no longer used for new blocks.
  final bool storeFailed;

  @override
  String toString() => 'ScrollbackStats(lines: $lines, hot: $hotLines, '
      'archived: $archivedLines, memory: $memoryBlocks blocks/$memoryBytes B, '
      'stored: $storedBlocks blocks/$storedBytes B, cached: $cachedBlocks, '
      'pinned: $pinnedLines, storeFailed: $storeFailed)';
}
