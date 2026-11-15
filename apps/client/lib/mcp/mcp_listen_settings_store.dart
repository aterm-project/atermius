import 'mcp_listen_settings_store_io.dart'
    if (dart.library.js_interop) 'mcp_listen_settings_store_web.dart'
    as platform;

/// Device-local MCP listening choice (port and bind address; no secrets, no
/// token). Never synced: where this computer listens says nothing about
/// another device.
abstract interface class McpListenSettingsStore {
  Future<String?> read();
  Future<void> write(String value);
}

class MemoryMcpListenSettingsStore implements McpListenSettingsStore {
  MemoryMcpListenSettingsStore([this.value]);
  String? value;
  int writes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    writes++;
    this.value = value;
  }
}

McpListenSettingsStore createMcpListenSettingsStore() => platform.createStore();
