import 'dart:collection';
import 'dart:math' show max, min;
import 'dart:typed_data';

import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/scrollback/block_store.dart';
import 'package:xterm/src/core/buffer/scrollback/codec.dart';
import 'package:xterm/src/core/buffer/scrollback/line_block.dart';
import 'package:xterm/src/core/buffer/scrollback/options.dart';
import 'package:xterm/src/core/reflow.dart';
import 'package:xterm/src/utils/circular_buffer.dart';

const _cellSize = 4;

/// Bookkeeping cost charged per archived block on top of its bytes.
const _blockOverhead = 96;

const _payloadStored = 0;

const _payloadDeflated = 1;

const _spillNone = 0;

const _spillPending = 1;

const _spillStored = 2;

/// A block of [ScrollbackOptions.blockLines] consecutive archived lines.
class _Block {
  _Block(this.id, this.firstAbsolute, Uint8List this.bytes)
      : size = bytes.length + _blockOverhead;

  /// Identifies the block in the [ScrollbackBlockStore]. Never reused.
  final int id;

  /// Absolute index of the first line of the block.
  final int firstAbsolute;

  /// The packed block, or null once it lives only in the store.
  Uint8List? bytes;

  /// What the block is charged against the memory or the store budget.
  final int size;

  int spill = _spillNone;

  /// Set when the block left the buffer, so that a store write that finishes
  /// later is ignored.
  bool dropped = false;

  /// The restored lines while the block is in the read cache.
  List<BufferLine>? lines;

  int lastUse = 0;
}

/// The lines of a terminal [Buffer]: the viewport and the scrollback above it.
///
/// It behaves like the list of [BufferLine]s it replaces
/// ([IndexAwareCircularBuffer]): index 0 is the oldest retained line, lines
/// know their [BufferLine.index], and when [maxLength] is exceeded the oldest
/// line is dropped. The difference is how the lines are held. Only the most
/// recent ones (the *hot window*) are plain [BufferLine]s; older ones are
/// moved, a block at a time, into a compact compressed archive and restored
/// on demand, see [ScrollbackOptions]. Reading a line through [operator []]
/// returns the same content either way.
///
/// Every line has an absolute sequence number that never changes while the
/// line exists, in whichever tier it lives. [BufferLine.index] is that number
/// minus the number of lines dropped from the front so far, so indexes held by
/// the UI (scroll offsets, selections, highlights) stay consistent while lines
/// move between the hot window and the archive, and shift together when the
/// oldest lines are dropped.
///
/// Archived lines are immutable. The terminal only ever modifies lines of the
/// viewport, which is always inside the hot window; a mutation that targets an
/// archived index first brings the affected blocks back into the hot window.
class BufferLines implements IndexedItemOwner {
  BufferLines(
    this.maxLength, {
    ScrollbackOptions options = const ScrollbackOptions(),
    int viewWidth = 80,
    int viewportLines = 0,
    this.onLinesDropped,
  })  : assert(maxLength > 0),
        _options = options,
        _codec = options.codec ?? ScrollbackCodec.platform,
        _viewWidth = viewWidth,
        _viewportLines = viewportLines;

  /// The number of lines that can be held. Older lines are dropped beyond it.
  final int maxLength;

  /// Called when lines were dropped outside of a mutating call, which only
  /// happens when a [ScrollbackBlockStore] write fails after the fact.
  final void Function()? onLinesDropped;

  final ScrollbackOptions _options;

  final ScrollbackCodec _codec;

  ScrollbackOptions get options => _options;

  /* Index space */

  /// Absolute index of the line at index 0.
  var _absoluteStart = 0;

  /// Absolute index of the first hot line. Everything between
  /// [_absoluteStart] and this is archived.
  var _hotStart = 0;

  @override
  int get absoluteStartIndex => _absoluteStart;

  /// Number of lines in the buffer.
  int get length => _hotStart - _absoluteStart + _hotLength;

  /// Number of lines held in the archive.
  int get archivedLength => _hotStart - _absoluteStart;

  /// Number of plain lines: the viewport and the hot window above it.
  int get hotLength => _hotLength;

  /// Whether adding another line drops the oldest one.
  bool get isFull => length >= maxLength;

  /* Hot window: a growable ring of plain lines */

  var _ring = List<BufferLine?>.filled(64, null);

  var _ringStart = 0;

  var _hotLength = 0;

  @pragma('vm:prefer-inline')
  BufferLine _hot(int index) {
    return _ring[(_ringStart + index) & (_ring.length - 1)]!;
  }

  void _reserveHot(int capacity) {
    if (capacity <= _ring.length) {
      return;
    }
    var size = _ring.length;
    while (size < capacity) {
      size *= 2;
    }
    final ring = List<BufferLine?>.filled(size, null);
    for (var i = 0; i < _hotLength; i++) {
      ring[i] = _hot(i);
    }
    _ring = ring;
    _ringStart = 0;
  }

  /// Puts [line] into hot slot [index], which is either empty or holds a line
  /// that is being replaced.
  @pragma('vm:prefer-inline')
  void _place(int index, BufferLine line) {
    final slot = (_ringStart + index) & (_ring.length - 1);
    final absolute = _hotStart + index;
    final previous = _ring[slot];
    if (previous != null && !identical(previous, line)) {
      _release(previous, absolute);
    }
    _ring[slot] = line..attachTo(this, absolute);
  }

  /// Detaches [line] unless it has been placed somewhere else in the
  /// meantime, as when the terminal scrolls a region by assigning lines to
  /// new indexes.
  @pragma('vm:prefer-inline')
  void _release(BufferLine line, int absolute) {
    if (line.absoluteIndex == absolute && identical(line.owner, this)) {
      line.detachFromOwner();
    }
  }

  /* Archive */

  /// Archived blocks, oldest first. They are contiguous: block `i` starts at
  /// `_blocks.first.firstAbsolute + i * blockLines`. Only the oldest block
  /// can be partly dropped (when `_absoluteStart` is inside it).
  final _blocks = ListQueue<_Block>();

  var _nextBlockId = 0;

  /// Bytes of blocks held in memory, including those being written out.
  var _memoryBytes = 0;

  /// Bytes of blocks that are being written to the store.
  var _pendingBytes = 0;

  /// Bytes of blocks that live only in the store.
  var _storedBytes = 0;

  /// Absolute index of the first block that has not been handed to the store.
  var _nextSpill = 0;

  var _storeFailed = false;

  /// Restored blocks, at most [ScrollbackOptions.cachedBlocks].
  final _cached = <_Block>[];

  var _tick = 0;

  /// Archived lines that carry anchors but whose block is not in the read
  /// cache, by absolute index. They are the objects the anchors point to, so
  /// they must be the ones returned for their index for as long as the
  /// anchors live.
  final _pinned = <int, BufferLine>{};

  var _pinnedSweepAt = 64;

  int _viewWidth;

  int _viewportLines;

  final _scratch = <BufferLine>[];

  bool get _archiving => _options.archive;

  int get _blockLines => _options.blockLines;

  /// The number of hot lines above which blocks are archived.
  int get _hotLimit => _options.hotLines + _viewportLines;

  /// The number of cells every restored line shows. Set by the [Buffer].
  int get viewWidth => _viewWidth;

  set viewWidth(int value) {
    if (value == _viewWidth) {
      return;
    }
    _viewWidth = value;
    // Restored lines are rebuilt for the new width when they are next read;
    // the ones that must survive because of their anchors are resized.
    while (_cached.isNotEmpty) {
      _evict(_cached.last);
    }
    for (final line in _pinned.values) {
      line.resize(value);
    }
  }

  /// The height of the viewport, which is kept out of the archive in addition
  /// to [ScrollbackOptions.hotLines]. Set by the [Buffer].
  int get viewportLines => _viewportLines;

  set viewportLines(int value) {
    _viewportLines = value;
  }

  /// Where the lines currently live.
  ScrollbackStats get stats {
    var memoryBlocks = 0;
    var storedBlocks = 0;
    for (final block in _blocks) {
      if (block.bytes != null) {
        memoryBlocks++;
      } else {
        storedBlocks++;
      }
    }
    return ScrollbackStats(
      lines: length,
      hotLines: _hotLength,
      archivedLines: archivedLength,
      memoryBlocks: memoryBlocks,
      memoryBytes: _memoryBytes,
      storedBlocks: storedBlocks,
      storedBytes: _storedBytes,
      cachedBlocks: _cached.length,
      pinnedLines: _pinned.length,
      storeFailed: _storeFailed,
    );
  }

  /* Reading */

  /// Gets the line at [index]. Throws if the index is out of bounds.
  ///
  /// A line of the archive is restored for the call. The returned object
  /// stays valid for reading, but it is only guaranteed to remain the line at
  /// its index (and to report [BufferLine.attached]) while it carries an
  /// anchor or until other archived blocks are read.
  BufferLine operator [](int index) {
    final hotIndex = index - (_hotStart - _absoluteStart);
    if (hotIndex >= 0) {
      if (hotIndex >= _hotLength) {
        throw RangeError.index(index, this, 'index', null, length);
      }
      return _ring[(_ringStart + hotIndex) & (_ring.length - 1)]!;
    }
    if (index < 0) {
      throw RangeError.index(index, this, 'index', null, length);
    }
    return _archived(_absoluteStart + index);
  }

  /// Calls [callback] for every line, oldest first. Restores every archived
  /// block on the way; use it for small buffers and tests.
  void forEach(void Function(BufferLine item) callback) {
    final length = this.length;
    for (var i = 0; i < length; i++) {
      callback(this[i]);
    }
  }

  /// Returns a list containing all lines. See [forEach].
  List<BufferLine> toList() {
    return List<BufferLine>.generate(length, (index) => this[index]);
  }

  _Block _blockAt(int absolute) {
    final first = _blocks.first.firstAbsolute;
    return _blocks.elementAt((absolute - first) ~/ _blockLines);
  }

  BufferLine _archived(int absolute) {
    final block = _blockAt(absolute);
    var lines = block.lines;
    if (lines == null) {
      if (_pinned.isNotEmpty) {
        final pinned = _pinned[absolute];
        if (pinned != null) {
          return pinned;
        }
      }
      lines = _restore(block);
      block.lines = lines;
      block.lastUse = ++_tick;
      _cached.add(block);
      if (_cached.length > _options.cachedBlocks) {
        var oldest = _cached.first;
        for (final candidate in _cached) {
          if (candidate.lastUse < oldest.lastUse) {
            oldest = candidate;
          }
        }
        _evict(oldest);
      }
    } else {
      block.lastUse = ++_tick;
    }
    return lines[absolute - block.firstAbsolute];
  }

  /// Rebuilds the lines of [block] and makes them the lines at their indexes.
  /// Never throws: a block that cannot be read or decoded yields blank lines.
  List<BufferLine> _restore(_Block block) {
    List<BufferLine>? lines;
    try {
      final payload = block.bytes ?? _options.store?.get(block.id);
      if (payload != null) {
        lines = _unpack(payload);
      }
    } catch (_) {
      lines = null;
    }
    lines ??= List<BufferLine>.generate(
      _blockLines,
      (_) => BufferLine.fromData(
        Uint32List(BufferLine.capacityFor(_viewWidth) * _cellSize),
        _viewWidth,
      ),
    );

    final first = block.firstAbsolute;
    for (var i = 0; i < lines.length; i++) {
      final absolute = first + i;
      if (absolute < _absoluteStart) {
        continue;
      }
      final pinned = _pinned.isEmpty ? null : _pinned.remove(absolute);
      if (pinned != null) {
        lines[i] = pinned;
      } else {
        lines[i].attachTo(this, absolute);
      }
    }
    return lines;
  }

  /// Removes [block] from the read cache. Lines that carry anchors stay
  /// reachable through [_pinned].
  void _evict(_Block block) {
    final lines = block.lines;
    if (lines == null) {
      return;
    }
    final first = block.firstAbsolute;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final absolute = first + i;
      if (absolute < _absoluteStart) {
        continue;
      }
      if (line.anchors.isNotEmpty) {
        _pinned[absolute] = line;
      } else {
        _release(line, absolute);
      }
    }
    block.lines = null;
    _cached.remove(block);
    if (_pinned.length > _pinnedSweepAt) {
      _sweepPinned();
    }
  }

  /// Lets go of pinned lines whose anchors have all been disposed.
  void _sweepPinned() {
    _pinned.removeWhere((absolute, line) {
      if (line.anchors.isNotEmpty) {
        return false;
      }
      _release(line, absolute);
      return true;
    });
    _pinnedSweepAt = max(64, _pinned.length * 2);
  }

  Uint8List _pack(Uint8List raw) {
    var body = raw;
    var kind = _payloadStored;
    if (!identical(_codec, ScrollbackCodec.none)) {
      final compressed = _codec.compress(raw);
      if (compressed.length < raw.length) {
        body = compressed;
        kind = _payloadDeflated;
      }
    }
    // kind, raw length as a varint, body.
    final payload = Uint8List(body.length + 6);
    var length = 0;
    payload[length++] = kind;
    var value = raw.length;
    while (value >= 0x80) {
      payload[length++] = (value & 0x7f) | 0x80;
      value >>= 7;
    }
    payload[length++] = value;
    payload.setRange(length, length + body.length, body);
    return Uint8List.sublistView(payload, 0, length + body.length);
  }

  List<BufferLine> _unpack(Uint8List payload) {
    if (payload.length < 2) {
      throw const FormatException('Malformed scrollback block');
    }
    final kind = payload[0];
    var position = 1;
    var rawLength = 0;
    var shift = 0;
    while (true) {
      if (position >= payload.length || shift > 28) {
        throw const FormatException('Malformed scrollback block');
      }
      final byte = payload[position++];
      rawLength |= (byte & 0x7f) << shift;
      if (byte < 0x80) {
        break;
      }
      shift += 7;
    }
    final body = Uint8List.sublistView(payload, position);
    final Uint8List raw;
    if (kind == _payloadStored) {
      raw = body;
    } else if (kind == _payloadDeflated) {
      raw = _codec.decompress(body, rawLength);
    } else {
      throw const FormatException('Unknown scrollback block encoding');
    }
    if (raw.length != rawLength) {
      throw const FormatException('Malformed scrollback block');
    }
    return decodeLineBlock(raw, _viewWidth, expectedLines: _blockLines);
  }

  /* Archiving */

  /// Called after lines were added: enforces [maxLength] and moves hot lines
  /// that are far enough from the viewport into the archive.
  @pragma('vm:prefer-inline')
  void _settle() {
    final excess = length - maxLength;
    if (excess > 0) {
      _dropFront(excess);
    }
    if (_archiving && _hotLength >= _hotLimit + _blockLines) {
      _archiveBlocks();
    }
  }

  void _archiveBlocks() {
    final limit = _hotLimit;
    final blockLines = _blockLines;
    while (_hotLength >= limit + blockLines) {
      _archiveBlock();
    }
    _enforceBudgets();
  }

  /// Moves the oldest [ScrollbackOptions.blockLines] hot lines into a new
  /// archived block.
  void _archiveBlock() {
    final count = _blockLines;
    final lines = _scratch;
    for (var i = 0; i < count; i++) {
      lines.add(_hot(i));
    }
    final block = _Block(
      _nextBlockId++,
      _hotStart,
      _pack(encodeLineBlock(lines, count)),
    );

    final mask = _ring.length - 1;
    for (var i = 0; i < count; i++) {
      final line = lines[i];
      final absolute = _hotStart + i;
      _ring[(_ringStart + i) & mask] = null;
      if (line.anchors.isNotEmpty) {
        // The anchors keep pointing at this object, which from now on is the
        // restored form of its line. Cells beyond its length are leftovers
        // of earlier resizes that were not archived; they must not show up
        // when the view is widened.
        final data = line.data;
        data.fillRange(
            min(line.length * _cellSize, data.length), data.length, 0);
        _pinned[absolute] = line;
      } else {
        _release(line, absolute);
      }
    }
    lines.clear();

    _ringStart = (_ringStart + count) & mask;
    _hotLength -= count;
    _hotStart += count;

    if (_blocks.isEmpty) {
      _nextSpill = block.firstAbsolute;
    }
    _blocks.addLast(block);
    _memoryBytes += block.size;
  }

  ScrollbackBlockStore? get _store => _storeFailed ? null : _options.store;

  /// Keeps the archive within its budgets: spills the oldest in-memory blocks
  /// to the store, or drops the oldest blocks when there is no store (left).
  void _enforceBudgets() {
    final store = _store;
    // Without a usable store this is a memory-only scrollback, with the
    // budget of one.
    final budget = _options.maxMemoryBytes ??
        (store == null
            ? ScrollbackOptions.defaultMaxMemoryBytes
            : ScrollbackOptions.defaultMaxMemoryBytesWithStore);

    if (store == null) {
      while (_memoryBytes > budget && _blocks.isNotEmpty) {
        _dropOldestBlock();
      }
      return;
    }

    // Blocks stay in memory until their write has finished, so what counts
    // against the memory budget here is what has not been handed over yet.
    while (_memoryBytes - _pendingBytes > budget) {
      final first = _blocks.first.firstAbsolute;
      final last = _blocks.last.firstAbsolute;
      final next = max(_nextSpill, first);
      if (next > last) {
        break;
      }
      final block = _blockAt(next);
      if (block.spill != _spillNone) {
        _nextSpill = block.firstAbsolute + _blockLines;
        continue;
      }
      _spill(block, store);
    }

    while (_storedBytes + _pendingBytes > _options.maxStoreBytes &&
        _blocks.isNotEmpty) {
      _dropOldestBlock();
    }

    // A store that cannot keep up must not let memory grow without bound.
    while (_pendingBytes > _options.maxPendingBytes && _blocks.isNotEmpty) {
      _dropOldestBlock();
    }
  }

  void _spill(_Block block, ScrollbackBlockStore store) {
    block.spill = _spillPending;
    _pendingBytes += block.size;
    _nextSpill = block.firstAbsolute + _blockLines;

    Future<bool> result;
    try {
      result = store.put(block.id, block.bytes!);
    } catch (_) {
      result = Future<bool>.value(false);
    }
    result.then(
      (stored) => _spillFinished(block, stored),
      onError: (Object _) => _spillFinished(block, false),
    );
  }

  void _spillFinished(_Block block, bool stored) {
    if (block.dropped) {
      return;
    }
    _pendingBytes -= block.size;
    if (stored) {
      block.spill = _spillStored;
      block.bytes = null;
      _memoryBytes -= block.size;
      _storedBytes += block.size;
      return;
    }

    // The block is still in memory, nothing is lost. Stop using the store and
    // fall back to dropping the oldest blocks when memory runs out.
    block.spill = _spillNone;
    _storeFailed = true;
    final before = length;
    _enforceBudgets();
    if (length != before) {
      onLinesDropped?.call();
    }
  }

  /// Forgets [block], which has already been taken out of [_blocks].
  void _forget(_Block block, {bool removeFromStore = true}) {
    block.dropped = true;
    if (block.lines != null) {
      block.lines = null;
      _cached.remove(block);
    }
    if (block.spill == _spillPending) {
      _pendingBytes -= block.size;
    }
    if (block.bytes != null) {
      _memoryBytes -= block.size;
      block.bytes = null;
    } else {
      _storedBytes -= block.size;
    }
    if (removeFromStore && block.spill != _spillNone) {
      try {
        _options.store?.remove(block.id);
      } catch (_) {
        // A failing store must never break the terminal.
      }
    }
  }

  void _dropOldestBlock() {
    final block = _blocks.first;
    _dropArchived(block.firstAbsolute + _blockLines - _absoluteStart);
  }

  /// Drops the [count] oldest lines, all of which are archived.
  void _dropArchived(int count) {
    final start = _absoluteStart;
    final end = start + count;
    final everything = end == _hotStart;

    if (_pinned.isNotEmpty) {
      if (count == 1) {
        _pinned.remove(start)?.detachFromOwner();
      } else {
        _pinned.removeWhere((absolute, line) {
          if (absolute >= end) {
            return false;
          }
          line.detachFromOwner();
          return true;
        });
      }
    }

    if (everything) {
      // One call instead of one per block when the scrollback is cleared.
      for (final block in _blocks) {
        if (block.spill != _spillNone) {
          try {
            _options.store?.clear();
          } catch (_) {
            // A failing store must never break the terminal.
          }
          break;
        }
      }
    }

    while (_blocks.isNotEmpty) {
      final block = _blocks.first;
      final first = block.firstAbsolute;
      final blockEnd = first + _blockLines;

      final lines = block.lines;
      if (lines != null) {
        final to = min(blockEnd, end);
        for (var absolute = max(first, start); absolute < to; absolute++) {
          _release(lines[absolute - first], absolute);
        }
      }

      if (blockEnd > end) {
        break;
      }
      _blocks.removeFirst();
      _forget(block, removeFromStore: !everything);
    }

    _absoluteStart = end;
  }

  /// Drops the [count] oldest lines.
  void _dropFront(int count) {
    final archived = min(count, _hotStart - _absoluteStart);
    if (archived > 0) {
      _dropArchived(archived);
    }

    final hot = count - archived;
    if (hot > 0) {
      final mask = _ring.length - 1;
      for (var i = 0; i < hot; i++) {
        final slot = (_ringStart + i) & mask;
        _release(_ring[slot]!, _hotStart + i);
        _ring[slot] = null;
      }
      _ringStart = (_ringStart + hot) & mask;
      _hotLength -= hot;
      _hotStart += hot;
      _absoluteStart = _hotStart;
    }
  }

  /// Makes sure that at least the last [count] lines are plain lines that can
  /// be modified, bringing archived blocks back if necessary.
  void ensureHot(int count) {
    while (_hotLength < count && _blocks.isNotEmpty) {
      _unarchiveBlock();
    }
  }

  /// Turns the newest archived block back into hot lines.
  void _unarchiveBlock() {
    final block = _blocks.removeLast();
    final lines = block.lines ?? _restore(block);
    _forget(block);

    final first = max(block.firstAbsolute, _absoluteStart);
    final skip = first - block.firstAbsolute;
    final count = lines.length - skip;

    _reserveHot(_hotLength + count);
    final mask = _ring.length - 1;
    _ringStart = (_ringStart - count) & mask;
    _hotStart = first;
    _hotLength += count;
    for (var i = 0; i < count; i++) {
      _ring[(_ringStart + i) & mask] = lines[skip + i]
        ..attachTo(this, first + i);
    }
    if (_nextSpill > first) {
      _nextSpill = first;
    }
  }

  /// Converts [index] into an index of the hot window, bringing archived
  /// blocks back when it points into the archive.
  int _hotIndexOf(int index) {
    if (index < _hotStart - _absoluteStart) {
      ensureHot(length - index);
    }
    return index - (_hotStart - _absoluteStart);
  }

  /* Mutation */

  /// Sets the line at [index]. Throws if the index is out of bounds.
  operator []=(int index, BufferLine value) {
    RangeError.checkValueInInterval(index, 0, length - 1, 'index');
    _place(_hotIndexOf(index), value);
  }

  /// Replaces the line at [index] with [value] and returns the replaced line.
  BufferLine swap(int index, BufferLine value) {
    RangeError.checkValueInInterval(index, 0, length - 1, 'index');
    final hotIndex = _hotIndexOf(index);
    final result = _hot(hotIndex);
    _place(hotIndex, value);
    return result;
  }

  /// Adds [value] to the end. Drops the oldest line when the buffer is full.
  void push(BufferLine value) {
    if (_hotLength == _ring.length) {
      _reserveHot(_hotLength + 1);
    }
    _ring[(_ringStart + _hotLength) & (_ring.length - 1)] = value
      ..attachTo(this, _hotStart + _hotLength);
    _hotLength++;
    _settle();
  }

  /// Adds all [items] to the end.
  void pushAll(Iterable<BufferLine> items) {
    for (final item in items) {
      push(item);
    }
  }

  /// Removes and returns the last line. Throws if the buffer is empty.
  BufferLine pop() {
    if (_hotLength == 0) {
      ensureHot(1);
    }
    if (_hotLength == 0) {
      throw StateError('Cannot pop from an empty buffer');
    }
    final index = _hotLength - 1;
    final slot = (_ringStart + index) & (_ring.length - 1);
    final line = _ring[slot]!;
    _release(line, _hotStart + index);
    _ring[slot] = null;
    _hotLength--;
    return line;
  }

  /// Inserts [item] at [index], shifting the lines after it down. Drops the
  /// oldest line when the buffer is full.
  void insert(int index, BufferLine item) {
    RangeError.checkValueInInterval(index, 0, length, 'index');
    if (index == length) {
      return push(item);
    }

    final hotIndex = _hotIndexOf(index);
    _reserveHot(_hotLength + 1);
    final mask = _ring.length - 1;
    for (var i = _hotLength - 1; i >= hotIndex; i--) {
      final line = _ring[(_ringStart + i) & mask]!;
      _ring[(_ringStart + i + 1) & mask] = line
        ..attachTo(this, _hotStart + i + 1);
    }
    _ring[(_ringStart + hotIndex) & mask] = item
      ..attachTo(this, _hotStart + hotIndex);
    _hotLength++;
    _settle();
  }

  /// Inserts [items] at [index] in order.
  void insertAll(int index, List<BufferLine> items) {
    for (var i = 0; i < items.length; i++) {
      final before = length;
      insert(min(index + i, length), items[i]);
      if (length == before) {
        // The buffer is full: the insertion pushed out the oldest line and
        // everything moved up by one.
        index--;
        if (index + i + 1 < 0) {
          return;
        }
      }
    }
  }

  /// Removes [count] lines starting at [index], shifting the lines after them
  /// up.
  void remove(int index, [int count = 1]) {
    if (count <= 0 || index >= length) {
      return;
    }
    RangeError.checkNotNegative(index, 'index');
    count = min(count, length - index);

    final hotIndex = _hotIndexOf(index);
    final mask = _ring.length - 1;
    for (var i = hotIndex; i < hotIndex + count; i++) {
      _release(_ring[(_ringStart + i) & mask]!, _hotStart + i);
    }
    for (var i = hotIndex + count; i < _hotLength; i++) {
      final line = _ring[(_ringStart + i) & mask]!;
      _ring[(_ringStart + i - count) & mask] = line
        ..attachTo(this, _hotStart + i - count);
    }
    for (var i = _hotLength - count; i < _hotLength; i++) {
      _ring[(_ringStart + i) & mask] = null;
    }
    _hotLength -= count;
  }

  /// Drops the [count] oldest lines. Used to clear the scrollback; the lines
  /// that remain keep their order and their anchors, with new indexes.
  void trimStart(int count) {
    count = min(count, length);
    if (count > 0) {
      _dropFront(count);
    }
  }

  /// Removes all lines.
  void clear() {
    trimStart(length);
    _ringStart = 0;
  }

  /// Replaces all lines with [replacement], keeping at most the last
  /// [maxLength] of them.
  void replaceWith(List<BufferLine> replacement) {
    clear();
    final start = max(0, replacement.length - maxLength);
    for (var i = start; i < replacement.length; i++) {
      push(replacement[i]);
    }
  }

  /// Wraps the hot lines again for a view that changed from [oldWidth] to
  /// [newWidth] columns, and shows restored lines at the new width from now
  /// on.
  ///
  /// Archived lines are not touched: they keep the wrapping they had when
  /// they were archived, because reflowing a scrollback of hundreds of
  /// thousands of lines on every resize would stall the terminal. See
  /// [decodeLineBlock] for how they are shown in a narrower view.
  void reflow(int oldWidth, int newWidth) {
    final hot = List<BufferLine>.generate(_hotLength, _hot);
    // The first hot line may continue a line whose beginning is archived.
    // Reflow treats it as the start of a line; keep the two joined.
    final continuesArchive =
        archivedLength > 0 && hot.isNotEmpty && hot.first.isWrapped;

    final result = reflowLines(hot, oldWidth, newWidth);
    if (continuesArchive && result.isNotEmpty) {
      result.first.isWrapped = true;
    }

    for (var i = 0; i < _hotLength; i++) {
      final slot = (_ringStart + i) & (_ring.length - 1);
      _ring[slot]!.detachFromOwner();
      _ring[slot] = null;
    }
    _hotLength = 0;
    _ringStart = 0;
    _reserveHot(result.length);
    for (var i = 0; i < result.length; i++) {
      _ring[i] = result[i]..attachTo(this, _hotStart + i);
    }
    _hotLength = result.length;

    viewWidth = newWidth;
    _settle();
  }

  /// Sets the number of cells shown by every line to [newWidth] without
  /// wrapping anything again.
  void resizeLines(int newWidth) {
    for (var i = 0; i < _hotLength; i++) {
      _hot(i).resize(newWidth);
    }
    viewWidth = newWidth;
  }

  String debugDump() {
    final buffer = StringBuffer();
    buffer.writeln('BufferLines:');
    for (var i = 0; i < length; i++) {
      buffer.writeln('  $i: ${this[i]}');
    }
    return buffer.toString();
  }
}
