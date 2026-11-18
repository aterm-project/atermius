import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'app_theme_store.dart';

class BrowserAppThemeStore implements AppThemeStore {
  static const _key = 'atermius.app-theme.v1';

  @override
  Future<String?> read() async {
    try {
      final value = web.window.localStorage.getItem(_key);
      return value == null || value.length > appThemeStoreMaxLength
          ? null
          : value;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String code) async {
    // Update the page in this tab even when storage cannot persist the choice.
    web.window.dispatchEvent(
      web.CustomEvent(
        'atermius:app-theme',
        web.CustomEventInit(detail: code.toJS),
      ),
    );
    web.window.localStorage.setItem(_key, code);
  }
}

AppThemeStore createThemeStore() => BrowserAppThemeStore();
