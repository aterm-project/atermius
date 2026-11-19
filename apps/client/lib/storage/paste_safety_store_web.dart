import 'package:web/web.dart' as web;

import 'paste_safety_store.dart';

/// 浏览器端 localStorage 实现的粘贴安全护栏开关存储。
class BrowserPasteSafetyStore implements PasteSafetyStore {
  static const _key = 'atermius.paste-safety.v1';

  @override
  Future<String?> read() async {
    try {
      final value = web.window.localStorage.getItem(_key);
      return value == null || value.length > 16 ? null : value;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String value) async =>
      web.window.localStorage.setItem(_key, value);
}

PasteSafetyStore createPasteSafetyStore() => BrowserPasteSafetyStore();
