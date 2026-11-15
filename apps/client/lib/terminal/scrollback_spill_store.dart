import 'package:xterm/core.dart' show ScrollbackBlockStore;

import 'scrollback_spill_store_io.dart'
    if (dart.library.js_interop) 'scrollback_spill_store_web.dart'
    as platform;

/// A new disk tier for one terminal's scrollback, or null in the browser,
/// where scrollback stays in memory only.
///
/// The store keeps the terminal's oldest compressed blocks in encrypted
/// files inside the application cache directory. The key is random per
/// store and lives only in memory, so nothing can be read back after the
/// terminal or the application is gone.
///
/// Creating a store is synchronous and touches neither the disk nor
/// libsodium; that happens on the first block the buffer hands over. A store
/// that cannot write reports it through `put` and the buffer falls back to
/// dropping its oldest lines.
///
/// Call `dispose()` on the returned store when its terminal is discarded; it
/// deletes the terminal's files.
ScrollbackBlockStore? createScrollbackSpillStore() =>
    platform.createScrollbackSpillStore();

/// Deletes the scrollback files that earlier, no longer running application
/// processes left behind. Files of running processes, including detached
/// terminal windows, are never touched. Meant to be called once at startup
/// without awaiting it; never throws and does nothing in the browser.
Future<void> cleanStaleScrollbackSpill() =>
    platform.cleanStaleScrollbackSpill();
