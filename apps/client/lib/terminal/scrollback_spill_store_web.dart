import 'package:xterm/core.dart' show ScrollbackBlockStore;

/// The browser has no disk tier: scrollback beyond the memory budget is
/// dropped, exactly as without a store.
ScrollbackBlockStore? createScrollbackSpillStore() => null;

/// Nothing is ever written in the browser, so there is nothing to sweep.
Future<void> cleanStaleScrollbackSpill() async {}
