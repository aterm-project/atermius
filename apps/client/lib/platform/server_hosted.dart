import 'package:flutter/foundation.dart';

/// Whether this client is the browser build that an Atermius server serves.
///
/// That build belongs to its server: it has no local mode and no server
/// address to choose. It opens straight on the sign-in page of the server the
/// page came from ([serverHostedOrigin]). Native clients are never hosted.
bool get serverHostedClient => debugServerHostedOverride ?? kIsWeb;

/// The address of the server this page came from (scheme, host and port).
String get serverHostedOrigin => (debugServerHostedBase ?? Uri.base).origin;

/// Whether a hosted page was loaded over plain `http://` from another
/// computer. The browser already accepted that, so the client cannot be any
/// safer than its own page: it connects, and shows the insecure warning.
bool get serverHostedOverPlainHttp {
  final base = debugServerHostedBase ?? Uri.base;
  final host = base.host.toLowerCase();
  return base.scheme == 'http' &&
      host != 'localhost' &&
      host != '127.0.0.1' &&
      host != '::1' &&
      host != '[::1]';
}

@visibleForTesting
bool? debugServerHostedOverride;

@visibleForTesting
Uri? debugServerHostedBase;
