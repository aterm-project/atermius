import 'mcp_listen_settings_store.dart';

/// Browsers cannot listen; nothing is stored.
McpListenSettingsStore createStore() => MemoryMcpListenSettingsStore();
