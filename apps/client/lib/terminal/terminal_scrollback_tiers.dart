import 'package:xterm/core.dart';

import 'scrollback_spill_store.dart';

/// Disposes the disk tier of terminals that were dropped without
/// [disposeTerminalScrollback] (an error path, a missed close). Whatever
/// this misses too is removed by [cleanStaleScrollbackSpill] at the next
/// start, and cannot be decrypted in the meantime.
final Finalizer<ScrollbackBlockStore> _orphanedStores = Finalizer(
  (store) => store.dispose(),
);

/// How a new terminal of this application holds its scrollback.
///
/// The most recent lines stay plain, older ones are compressed in memory,
/// and what no longer fits the memory budget moves to an encrypted temporary
/// file that belongs to this one terminal (not in the browser, where the
/// scrollback is memory only). The budgets are the defaults of
/// [ScrollbackOptions]. Every terminal needs its own options: the disk tier
/// has its own key and files.
ScrollbackOptions newTerminalScrollback() {
  final store = createScrollbackSpillStore();
  final options = ScrollbackOptions(store: store);
  if (store != null) {
    _orphanedStores.attach(options, store, detach: store);
  }
  return options;
}

/// Deletes the temporary scrollback file of [terminal], if it has one. Call
/// it when the terminal is discarded (its tab or window was closed). Lines
/// that only lived in that file read as blank lines afterwards; lines still
/// in memory are unaffected.
void disposeTerminalScrollback(Terminal? terminal) {
  final store = terminal?.scrollback.store;
  if (store == null) return;
  _orphanedStores.detach(store);
  store.dispose();
}
