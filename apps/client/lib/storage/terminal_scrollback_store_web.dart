import 'package:web/web.dart' as web;

import 'terminal_scrollback_store.dart';

class BrowserTerminalScrollbackStore implements TerminalScrollbackStore {
  static const _key = 'atermius.terminal-scrollback.v1';

  @override
  Future<String?> read() async {
    try {
      final value = web.window.localStorage.getItem(_key);
      return value == null || value.length > 64 ? null : value;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String value) async =>
      web.window.localStorage.setItem(_key, value);
}

TerminalScrollbackStore createTerminalScrollbackStore() =>
    BrowserTerminalScrollbackStore();
