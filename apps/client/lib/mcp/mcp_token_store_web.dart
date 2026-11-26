import 'mcp_token_store.dart';

/// Browsers cannot host the MCP listener, so there is no token to keep.
class UnavailableMcpTokenStore implements McpTokenStore {
  @override
  Future<String?> read(String scope) =>
      Future.error(UnsupportedError('MCP is unavailable in the browser.'));

  @override
  Future<void> write(String scope, String token) =>
      Future.error(UnsupportedError('MCP is unavailable in the browser.'));
}

McpTokenStore createStore() => UnavailableMcpTokenStore();
