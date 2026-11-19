import 'package:web/web.dart' as web;

import 'ssh_keepalive_store.dart';

/// 浏览器端 localStorage 实现的 SSH 保活策略存储。
class BrowserSshKeepaliveStore implements SshKeepaliveStore {
  static const _key = 'atermius.ssh-keepalive.v1';

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

SshKeepaliveStore createSshKeepaliveStore() => BrowserSshKeepaliveStore();
