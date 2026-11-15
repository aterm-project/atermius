import 'terminal_scrollback_store_native.dart'
    if (dart.library.js_interop) 'terminal_scrollback_store_web.dart'
    as platform;

/// Device-local terminal scrollback length (a line count as a decimal string).
///
/// Deliberately outside the encrypted Vault/profile stores and never synced:
/// it is non-secret, sized for this device's memory, and must be readable by
/// credential-free terminal child windows.
abstract interface class TerminalScrollbackStore {
  Future<String?> read();

  Future<void> write(String value);
}

TerminalScrollbackStore createTerminalScrollbackStore() =>
    platform.createTerminalScrollbackStore();

/// In-memory store for tests.
class MemoryTerminalScrollbackStore implements TerminalScrollbackStore {
  MemoryTerminalScrollbackStore([this.value]);
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
