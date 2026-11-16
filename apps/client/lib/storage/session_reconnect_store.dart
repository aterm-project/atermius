import 'session_reconnect_store_native.dart'
    if (dart.library.js_interop) 'session_reconnect_store_web.dart'
    as platform;

/// Device-local policy for reconnecting dropped sessions (automatic on/off,
/// retry interval and time limit as one short string).
///
/// Deliberately outside the encrypted Vault/profile stores and never synced:
/// it is non-secret and describes how this device's network behaves.
abstract interface class SessionReconnectStore {
  Future<String?> read();

  Future<void> write(String value);
}

SessionReconnectStore createSessionReconnectStore() =>
    platform.createSessionReconnectStore();

/// In-memory store for tests.
class MemorySessionReconnectStore implements SessionReconnectStore {
  MemorySessionReconnectStore([this.value]);
  String? value;
  int writes = 0;
  Object? failWith;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    writes++;
    if (failWith case final error?) throw error;
    this.value = value;
  }
}
