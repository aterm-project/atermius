import 'dart:async';

import 'package:flutter/foundation.dart';

import '../storage/terminal_scrollback_store.dart';

/// Scrollback lengths (lines kept per terminal) the user can choose from.
const terminalScrollbackChoices = [
  10000,
  50000,
  100000,
  500000,
  1000000,
  5000000,
];

/// Scrollback used until the user chooses, and whenever the stored value is
/// missing or not one of [terminalScrollbackChoices].
const terminalScrollbackDefault = 100000;

/// Sanitizes a stored scrollback preference.
///
/// Only the exact decimal form of one of [terminalScrollbackChoices] is
/// accepted (surrounding whitespace is ignored). Anything else, including
/// garbage, signs, other numbers and values written by a newer version, yields
/// [terminalScrollbackDefault], so a terminal can never be created with an
/// unbounded or nonsensical limit.
int parseTerminalScrollback(String? stored) {
  if (stored == null || stored.length > 64) return terminalScrollbackDefault;
  final value = stored.trim();
  for (final choice in terminalScrollbackChoices) {
    if (value == '$choice') return choice;
  }
  return terminalScrollbackDefault;
}

/// `maxLines` for a terminal created now: the device's scrollback preference.
/// Terminals that already exist keep the limit they were created with.
int get terminalScrollbackLines => TerminalScrollbackController.instance.lines;

/// Device-local scrollback length for terminals opened from now on.
///
/// Every terminal surface on this device (local profile, cloud workspace and
/// separate terminal windows, which read the same store at startup) passes
/// [lines] as `maxLines` when it creates a terminal. The value is never synced
/// or stored in a Vault.
class TerminalScrollbackController extends ChangeNotifier {
  TerminalScrollbackController();

  static TerminalScrollbackController? _instance;

  /// Process-wide controller used by the app roots and terminal sessions.
  static TerminalScrollbackController get instance =>
      _instance ??= TerminalScrollbackController();

  @visibleForTesting
  static set debugInstance(TerminalScrollbackController? controller) =>
      _instance = controller;

  TerminalScrollbackStore? _store;
  int _lines = terminalScrollbackDefault;
  int _selectionRevision = 0;
  bool _writeFailed = false;
  int _writeRevision = 0;
  Future<void>? _writeChain;
  bool _disposed = false;

  /// Lines of scrollback for terminals created from now on.
  int get lines => _lines;

  /// Whether persisting the latest selection failed; it still applies now.
  bool get writeFailed => _writeFailed;

  /// Reads the stored choice. Unknown values (e.g. written by a newer
  /// version) and read failures fall back to [terminalScrollbackDefault]
  /// without rewriting the stored value. Never throws.
  Future<void> load(TerminalScrollbackStore store) async {
    _store = store;
    final revision = _selectionRevision;
    String? stored;
    try {
      stored = await store.read().timeout(const Duration(seconds: 2));
    } on Object {
      stored = null;
    }
    // A choice made while the read was in flight wins over the stored value.
    if (_disposed || revision != _selectionRevision) return;
    final next = parseTerminalScrollback(stored);
    if (next != _lines) {
      _lines = next;
      notifyListeners();
    }
  }

  /// Applies [lines] immediately (for terminals opened afterwards) and
  /// persists it. Writes are serialized and coalesced like the terminal
  /// palette, so the last selection always wins on disk.
  Future<void> select(int lines) {
    if (!terminalScrollbackChoices.contains(lines)) {
      throw ArgumentError.value(lines, 'lines', 'Unsupported scrollback');
    }
    _selectionRevision++;
    if (lines != _lines) {
      _lines = lines;
      notifyListeners();
    }
    final store = _store;
    if (store == null) return Future<void>.value();
    final revision = ++_writeRevision;
    // Created per call so the chain runs in the caller's zone.
    final previous = _writeChain ?? Future<void>.value();
    final next = previous.then((_) async {
      if (revision != _writeRevision || _disposed) return;
      var failed = false;
      try {
        await store.write('$lines');
      } on Object {
        failed = true;
      }
      if (revision != _writeRevision || _disposed) return;
      if (failed != _writeFailed) {
        _writeFailed = failed;
        notifyListeners();
      }
    });
    _writeChain = next;
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
