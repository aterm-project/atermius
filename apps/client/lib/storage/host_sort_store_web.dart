import 'package:web/web.dart' as web;

import 'host_sort_store.dart';

class BrowserHostSortStore implements HostSortStore {
  static const key = 'atermius.host-sort.v1';
  @override
  Future<String?> read() async {
    final value = web.window.localStorage.getItem(key);
    return value != null && value.length <= 524288 ? value : null;
  }

  @override
  Future<void> write(String value) async =>
      web.window.localStorage.setItem(key, value);
}

HostSortStore createHostSortStore() => BrowserHostSortStore();
