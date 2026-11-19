import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_controller.dart';
import '../domain/open_workspace_snapshot.dart';
import '../domain/window_combination.dart';
import '../storage/open_workspace_store.dart';

/// Replaces the browser's storage in tests.
@visibleForTesting
OpenWorkspaceStore? debugOpenWorkspaceStore;

/// Replaces [OpenWorkspaceKeeper.vaultDelay] in tests.
@visibleForTesting
Duration? debugOpenWorkspaceVaultDelay;

/// Makes the browser client remember its open tabs and bring them back.
///
/// The browser client is only a view: a reload forgets every tab. While the
/// unlocked workspace is on screen this keeps a snapshot of the open tabs
/// (which Hosts, their order, the splits, the active pane) up to date, in the
/// Vault for the user's other browsers and in this browser for the next
/// reload, and once per page load opens the tabs of the latest snapshot
/// again. Each tab connects anew; nothing of the old sessions is kept.
///
/// One keeper lives as long as the unlocked workspace is on screen. What must
/// outlive a lock ("already brought back since the page was loaded") is kept
/// on the [AppController].
class OpenWorkspaceKeeper {
  OpenWorkspaceKeeper({
    required this.app,
    required this.scope,
    required this.capture,
    required this.restore,
    OpenWorkspaceStore? store,
    DateTime Function()? now,
    this.captureDelay = const Duration(milliseconds: 1200),
    Duration? vaultDelay,
    this.syncWait = const Duration(seconds: 3),
    this.arrivalWait = const Duration(seconds: 20),
  }) : _store = store ?? debugOpenWorkspaceStore ?? createOpenWorkspaceStore(),
       vaultDelay =
           vaultDelay ??
           debugOpenWorkspaceVaultDelay ??
           const Duration(seconds: 15),
       _now = now ?? DateTime.now;

  /// How long the tabs must stay as they are before the synced copy is
  /// written. This browser's own copy is written at once and is what a
  /// reload uses; the synced copy is for other browsers and can wait.
  ///
  /// Writing it at once made opening a terminal slow: the tab changes the
  /// snapshot, the snapshot is uploaded, the server's hint about the upload
  /// asks for another sync, and the SSH host key check of that very tab,
  /// which needs a completed sync of its own, queued behind all of it
  /// (about 10 s before the first-use prompt, 10 s more to connect).
  final Duration vaultDelay;

  final AppController app;

  /// Server, account and Vault of the unlocked workspace; null while there
  /// is none (locked, signed out).
  final String? Function() scope;

  /// The open tabs as a layout, or null when no tab is open. May throw while
  /// the tabs cannot be described; the snapshot then stays as it is.
  final WindowCombination? Function() capture;

  /// Opens the tabs of a layout. Hosts that are gone are left out.
  final Future<void> Function(WindowCombination layout) restore;

  /// A change of the tabs is stored once they stayed the same this long.
  final Duration captureDelay;

  /// How long the tabs wait for the first sync after unlocking, which may
  /// bring a later snapshot from another browser than the one kept here.
  final Duration syncWait;

  /// How long a snapshot may still arrive (the first sync of a new browser)
  /// and be opened, as long as the user has not opened a tab.
  final Duration arrivalWait;

  final OpenWorkspaceStore _store;
  final DateTime Function() _now;
  final List<Listenable> _sources = [];
  bool _disposed = false;

  // Storing.
  String? _scope;
  String? _observed;
  Timer? _storeTimer, _vaultTimer;
  int _closuresSeen = 0;
  bool _emptiedByUser = false;

  // Bringing back.
  String? _waitingScope;
  Timer? _syncWaitTimer, _arrivalTimer;
  bool _syncSeen = false, _syncWaitOver = false, _arrivalOver = false;
  bool _restoring = false;

  /// Starts following [sources] (everything the tab layout depends on).
  void attach(Iterable<Listenable> sources) {
    if (_disposed || _sources.isNotEmpty) return;
    _sources.addAll(sources);
    for (final source in _sources) {
      source.addListener(changed);
    }
    changed();
  }

  void dispose() {
    _disposed = true;
    for (final source in _sources) {
      source.removeListener(changed);
    }
    _sources.clear();
    // A change that was not stored yet is dropped with the workspace; the
    // snapshot is never rewritten because the workspace goes away.
    _storeTimer?.cancel();
    _vaultTimer?.cancel();
    _syncWaitTimer?.cancel();
    _arrivalTimer?.cancel();
  }

  /// Something the tab layout depends on may have changed.
  void changed() {
    if (_disposed) return;
    _considerRestore();
    _observe();
  }

  bool get _tabsOpen => app.terminalTabs.any((tab) => !tab.closed);

  OpenWorkspaceSnapshot? _stored(String scope) => newerOpenWorkspaceSnapshot(
    OpenWorkspaceSnapshot.tryDecode(_store.read(scope)),
    app.syncedOpenWorkspaceSnapshot,
  );

  // -- Bringing the tabs back -------------------------------------------------

  void _considerRestore() {
    final current = scope();
    if (current == null ||
        _restoring ||
        app.openWorkspaceRestoreHandled.contains(current)) {
      return;
    }
    // Tabs are open already (the user was faster): theirs stay, alone.
    if (_tabsOpen) return _handled(current);
    if (app.vaultRecordsLoadedFor != app.currentVaultId) return;
    if (_waitingScope != current) {
      _waitingScope = current;
      _syncSeen = _syncWaitOver = _arrivalOver = false;
      _syncWaitTimer?.cancel();
      _arrivalTimer?.cancel();
      _syncWaitTimer = Timer(syncWait, () {
        _syncWaitOver = true;
        changed();
      });
      _arrivalTimer = Timer(arrivalWait, () {
        _arrivalOver = true;
        changed();
      });
    }
    if (app.syncing) _syncSeen = true;
    if (!(_syncSeen && !app.syncing) && !_syncWaitOver && !_arrivalOver) {
      return;
    }
    final snapshot = _stored(current);
    if (snapshot == null) {
      if (_arrivalOver) _handled(current);
      return;
    }
    _handled(current);
    final layout = snapshot.layout;
    if (layout == null) return;
    _restoring = true;
    // Not from inside the notification that got us here: opening tabs
    // rebuilds the workspace.
    unawaited(
      Future<void>.microtask(() => _disposed ? null : restore(layout))
          .then((_) {}, onError: (Object _) {})
          .whenComplete(() {
            _restoring = false;
            changed();
          }),
    );
  }

  void _handled(String scope) {
    app.openWorkspaceRestoreHandled.add(scope);
    _syncWaitTimer?.cancel();
    _arrivalTimer?.cancel();
  }

  // -- Storing the tabs ---------------------------------------------------------

  WindowCombination? _capture() {
    final layout = capture();
    // Also checks that it only holds what a snapshot may hold.
    OpenWorkspaceSnapshot.capture(layout, at: _now());
    return layout;
  }

  void _observe() {
    final current = scope();
    if (current != _scope) {
      _scope = current;
      _observed = null;
      _storeTimer?.cancel();
      _vaultTimer?.cancel();
      _emptiedByUser = false;
      _closuresSeen = app.terminalTabClosures;
    }
    // Nothing is stored before the stored tabs were brought back (or it was
    // decided that they are not), nor while they are being opened.
    if (current == null ||
        _restoring ||
        !app.openWorkspaceRestoreHandled.contains(current)) {
      return;
    }
    final WindowCombination? layout;
    try {
      layout = _capture();
    } on Object {
      return;
    }
    if (layout == null) {
      // No tab is left. Only the user closing the last one empties the
      // snapshot; a lock, a sign-out or a dropped workspace does not.
      if (app.terminalTabClosures != _closuresSeen) _emptiedByUser = true;
    } else {
      _emptiedByUser = false;
      _closuresSeen = app.terminalTabClosures;
    }
    final key = OpenWorkspaceSnapshot.contentKeyOf(layout);
    if (key == _observed) return;
    _observed = key;
    _storeTimer?.cancel();
    _storeTimer = Timer(captureDelay, _storeNow);
  }

  void _storeNow() {
    final current = scope();
    if (_disposed || current == null || current != _scope || _restoring) {
      return;
    }
    // Whatever was waiting to be written is older than this capture.
    _vaultTimer?.cancel();
    _vaultTimer = null;
    final OpenWorkspaceSnapshot snapshot;
    try {
      snapshot = OpenWorkspaceSnapshot.capture(capture(), at: _now());
      if (snapshot.layout == null && !_emptiedByUser) return;
      final key = snapshot.contentKey;
      final encoded = snapshot.encode();
      if (OpenWorkspaceSnapshot.tryDecode(_store.read(current))?.contentKey !=
          key) {
        _store.write(current, encoded);
      }
      if (app.syncedOpenWorkspaceSnapshot?.contentKey == key) return;
    } on Object {
      return;
    }
    void save() {
      _vaultTimer = null;
      if (_disposed || scope() != current || _restoring) return;
      // Not stored (read-only Vault, offline lock, ...): this browser's copy
      // is enough for a reload, and the next change tries again.
      unawaited(
        app.saveOpenWorkspaceSnapshot(snapshot).then((_) {}, onError: (_) {}),
      );
    }

    if (vaultDelay == Duration.zero) {
      save();
    } else {
      _vaultTimer = Timer(vaultDelay, save);
    }
  }
}
