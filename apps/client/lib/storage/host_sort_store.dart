import 'host_sort_store_native.dart'
    if (dart.library.js_interop) 'host_sort_store_web.dart'
    as platform;

/// This device's home sort choice and scoped host request timestamps.
abstract interface class HostSortStore {
  Future<String?> read();
  Future<void> write(String value);
}

HostSortStore createHostSortStore() => platform.createHostSortStore();

class MemoryHostSortStore implements HostSortStore {
  MemoryHostSortStore([this.value]);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}
