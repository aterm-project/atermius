import 'mcp_protocol.dart';

typedef McpRequestHandler = Future<McpReply> Function(
  Object? body, {
  Map<String, String> headers,
});

abstract interface class McpListener {
  Uri get endpoint;
  Future<void> close();
}

/// Optional listener capability, kept separate so existing [McpListener]
/// implementations (including test fakes) remain source compatible.
///
/// [done] completes exactly once when the listener stops accepting requests,
/// whether through [McpListener.close] or because the platform closed the
/// socket (for example when Android tears the process' sockets down). Owners
/// must treat completion as revocation of the token bound to this listener.
abstract interface class McpObservableListener implements McpListener {
  Future<void> get done;
  bool get closed;
}

/// Optional listener capability: every URL a client may use. A listener bound
/// to all interfaces is reachable at each address of this device; [endpoints]
/// lists them with the preferred one first ([McpListener.endpoint]).
abstract interface class McpAddressedListener implements McpListener {
  List<Uri> get endpoints;
}

/// Optional listener capability: accept a different bearer token from now
/// on (the user reset it). The port and endpoints stay the same; requests
/// already authenticated finish, every later one needs the new token.
abstract interface class McpRekeyableListener implements McpListener {
  void replaceToken(String token);
}
