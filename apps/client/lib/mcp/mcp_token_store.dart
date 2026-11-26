import 'dart:convert';
import 'dart:math';

import 'mcp_token_store_io.dart'
    if (dart.library.js_interop) 'mcp_token_store_web.dart'
    as platform;

/// Device-local MCP bearer token, one per workspace scope (local profile ID,
/// or server instance + account + Vault). It stays the same across stops,
/// restarts and app launches and changes only when the user resets it, so an
/// AI client configured once keeps working. Never synced: a token issued on
/// this device must not follow the account to another one.
abstract interface class McpTokenStore {
  /// The saved token for [scope], or null when there is none. Throws when the
  /// store cannot be read; callers must not overwrite a token they could not
  /// read.
  Future<String?> read(String scope);

  Future<void> write(String scope, String token);
}

/// 256 random bits, base64url without padding (43 characters).
String newMcpToken() =>
    base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');

final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');

/// Whether [value] has the shape [newMcpToken] produces.
bool mcpTokenValid(String? value) =>
    value != null && _tokenPattern.hasMatch(value);

/// For tests and embedded hosts.
class MemoryMcpTokenStore implements McpTokenStore {
  final values = <String, String>{};
  Object? readError, writeError;
  int writes = 0;

  @override
  Future<String?> read(String scope) async {
    if (readError case final error?) throw error;
    return values[scope];
  }

  @override
  Future<void> write(String scope, String token) async {
    if (writeError case final error?) throw error;
    writes++;
    values[scope] = token;
  }
}

McpTokenStore createMcpTokenStore() => platform.createStore();
