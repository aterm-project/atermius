import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'mcp_access_policy.dart' show mcpAccessPolicyMaxScopeLength;
import 'mcp_token_store.dart';

/// Keeps each scope's token in the platform's protected storage (Keychain,
/// Android Keystore, Windows DPAPI, Secret Service). The key is a hash of the
/// scope so profile and account identifiers never appear in it.
class SecureMcpTokenStore implements McpTokenStore {
  SecureMcpTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(String scope) {
    if (scope.isEmpty || scope.length > mcpAccessPolicyMaxScopeLength) {
      throw ArgumentError.value(scope.length, 'scope');
    }
    return 'atermius.mcp-token.v1.${sha256.convert(utf8.encode(scope))}';
  }

  @override
  Future<String?> read(String scope) => _storage.read(key: _key(scope));

  @override
  Future<void> write(String scope, String token) =>
      _storage.write(key: _key(scope), value: token);
}

McpTokenStore createStore() => SecureMcpTokenStore();
