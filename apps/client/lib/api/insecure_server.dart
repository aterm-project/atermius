import 'package:flutter/foundation.dart';

/// Development-only permission to talk to one account server without the
/// usual transport guarantees.
///
/// The permission is bound to a single origin (scheme, host and port). For an
/// `https://` origin it lets native clients accept a certificate that fails
/// validation; for an `http://` origin it lets the client use an unencrypted
/// non-loopback address. It never applies to any other host or port, is never
/// synchronised, and only exists while the [ApiClient] it was created for is
/// alive.
@immutable
class InsecureServerPermission {
  const InsecureServerPermission._({
    required this.scheme,
    required this.host,
    required this.port,
  });

  /// The permission the user's opt-in grants for [baseUrl] on this platform,
  /// or null when the option has nothing to permit there:
  ///
  /// * the URL is not an absolute `http(s)` URL;
  /// * a loopback `http://` address, which is always allowed;
  /// * an `https://` address in a browser, where page scripts cannot skip
  ///   certificate validation.
  static InsecureServerPermission? forBaseUrl(
    String baseUrl, {
    bool web = kIsWeb,
  }) {
    final permission = _parse(baseUrl);
    if (permission == null) return null;
    if (permission.scheme == 'http' && isLoopbackServerHost(permission.host)) {
      return null;
    }
    if (permission.scheme == 'https' && web) return null;
    return permission;
  }

  static InsecureServerPermission? _parse(String value) {
    final Uri uri;
    try {
      uri = Uri.parse(value.trim());
    } on FormatException {
      return null;
    }
    final scheme = uri.scheme.toLowerCase();
    if ((scheme != 'https' && scheme != 'http') || uri.host.isEmpty) {
      return null;
    }
    return InsecureServerPermission._(
      scheme: scheme,
      host: _normalizeHost(uri.host),
      port: uri.port,
    );
  }

  /// `https` or `http`.
  final String scheme;

  /// Lower-case host without IPv6 brackets.
  final String host;

  /// Effective port (the scheme default when the URL names none).
  final int port;

  /// Certificate validation is skipped only for `https://` origins; an
  /// `http://` origin has no certificate at all.
  bool get skipsCertificateValidation => scheme == 'https';

  /// Canonical origin for display and comparison, e.g. `https://172.19.99.1`
  /// or `http://dev.example.test:8080`.
  String get origin => Uri(scheme: scheme, host: host, port: port).toString();

  /// Whether a certificate that failed validation may be accepted for a TLS
  /// connection to [host]:[port]. Exactly this origin, nothing else.
  bool permitsCertificateFor(String host, int port) =>
      skipsCertificateValidation &&
      port == this.port &&
      _normalizeHost(host) == this.host;

  /// Whether [uri] (http, https, ws or wss) addresses exactly this origin.
  bool permitsUri(Uri uri) {
    final secure = switch (uri.scheme.toLowerCase()) {
      'https' || 'wss' => true,
      'http' || 'ws' => false,
      _ => null,
    };
    if (secure == null || secure != (scheme == 'https')) return false;
    // Uri only knows the default ports of http and https.
    final uriPort = uri.hasPort ? uri.port : (secure ? 443 : 80);
    return uriPort == port && _normalizeHost(uri.host) == host;
  }

  @override
  bool operator ==(Object other) =>
      other is InsecureServerPermission &&
      other.scheme == scheme &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(scheme, host, port);

  @override
  String toString() => 'InsecureServerPermission($origin)';
}

/// Canonical origin of a user-typed server address, or null when it is not an
/// absolute `http(s)` URL. Used to bind a confirmation to one origin.
String? serverOriginOf(String value) =>
    InsecureServerPermission._parse(value)?.origin;

/// Hosts for which plain HTTP has always been allowed.
bool isLoopbackServerHost(String host) {
  final normalized = _normalizeHost(host);
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1';
}

String _normalizeHost(String host) {
  var value = host.toLowerCase();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  return value;
}
