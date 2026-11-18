import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'open_workspace_store_stub.dart'
    if (dart.library.js_interop) 'open_workspace_store_web.dart'
    as platform;

/// This browser's own copy of the open-workspace snapshot, one per signed-in
/// account and Vault.
///
/// It restores the tabs after a reload before the first sync has finished, and
/// is the only copy when the Vault cannot be written. It holds the same
/// non-secret layout as the synced copy (Host references, split tree) and is
/// never read on another device.
abstract interface class OpenWorkspaceStore {
  /// The stored snapshot of [scope], or null. Never throws.
  String? read(String scope);

  /// Replaces the stored snapshot of [scope]. Never throws.
  void write(String scope, String value);
}

OpenWorkspaceStore createOpenWorkspaceStore() =>
    platform.createOpenWorkspaceStore();

/// The storage key of [scope] (server, account and Vault), which does not
/// reveal them.
String openWorkspaceStorageKey(String scope) =>
    'atermius.open-workspace.v1.'
    '${sha256.convert(utf8.encode(scope)).toString().substring(0, 32)}';

/// In-memory store, for tests and for platforms that keep no copy.
class MemoryOpenWorkspaceStore implements OpenWorkspaceStore {
  final Map<String, String> values = {};
  int writes = 0;

  @override
  String? read(String scope) => values[scope];

  @override
  void write(String scope, String value) {
    writes++;
    values[scope] = value;
  }
}
