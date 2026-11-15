import 'dart:typed_data';

/// Where a terminal buffer may park compressed scrollback blocks that no
/// longer fit its in-memory budget (for example an encrypted temporary file).
///
/// The terminal core never does file IO or cryptography itself; the embedding
/// application provides an implementation through
/// `ScrollbackOptions.store`. Without one the scrollback is memory only and
/// the oldest blocks are dropped when the memory budget is exceeded.
///
/// Contract:
///
/// * Block ids are non-negative integers chosen by the buffer. They only ever
///   increase and are never reused for the lifetime of the store, also not
///   after [clear].
/// * No method may throw. Failures are reported through the return values.
/// * The buffer keeps its own copy of a block in memory until the future
///   returned by [put] has completed with `true`, so a slow or failing store
///   never loses lines that are still inside the memory tiers.
abstract class ScrollbackBlockStore {
  /// Starts storing [bytes] under [id] and returns immediately. Completes
  /// with `true` once the block can be read back with [get], or with `false`
  /// when it could not be stored (IO error, full disk, store disposed). After
  /// a `false` the buffer stops using the store for new blocks.
  ///
  /// [bytes] must not be modified by the caller afterwards; the store may
  /// keep a reference until the write has finished.
  Future<bool> put(int id, Uint8List bytes);

  /// Synchronously returns the bytes stored under [id], or null when the
  /// block is missing, unreadable or fails authentication. Blocks are small
  /// (a few kilobytes) and the buffer reads them through a cache, so a short
  /// synchronous read is acceptable here. Never throws.
  Uint8List? get(int id);

  /// Forgets the block stored under [id] and lets the store reclaim its
  /// space. Unknown ids are ignored. A [put] for [id] that is still in flight
  /// must not make the block readable again afterwards.
  void remove(int id);

  /// Forgets every block (the scrollback was cleared). The store stays usable
  /// for later [put]s.
  void clear();

  /// Forgets every block and releases all resources. Afterwards [get]
  /// returns null and [put] completes with `false`.
  void dispose();
}
