import 'package:web/web.dart' as web;

import 'open_workspace_store.dart';

class BrowserOpenWorkspaceStore implements OpenWorkspaceStore {
  static const _maxLength = 40000;

  @override
  String? read(String scope) {
    try {
      final value = web.window.localStorage.getItem(
        openWorkspaceStorageKey(scope),
      );
      return value == null || value.length > _maxLength ? null : value;
    } on Object {
      return null;
    }
  }

  @override
  void write(String scope, String value) {
    try {
      web.window.localStorage.setItem(openWorkspaceStorageKey(scope), value);
    } on Object {
      // Storage is blocked or full: the synced copy still restores the tabs.
    }
  }
}

OpenWorkspaceStore createOpenWorkspaceStore() => BrowserOpenWorkspaceStore();
