import 'open_workspace_store.dart';

/// Only the browser client remembers its open tabs.
OpenWorkspaceStore createOpenWorkspaceStore() => MemoryOpenWorkspaceStore();
