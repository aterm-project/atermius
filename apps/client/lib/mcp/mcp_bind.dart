import 'dart:convert';

/// Where the MCP listener accepts connections.
///
/// [loopback] (the default) serves this device only. [lan] listens on every
/// IPv4 interface so other devices on the local network can connect, and
/// [custom] on one address of this device. [code] is the stored value; never
/// rename it.
enum McpBindMode {
  loopback('loopback'),
  lan('lan'),
  custom('custom');

  const McpBindMode(this.code);
  final String code;

  static McpBindMode parse(Object? value) {
    for (final mode in values) {
      if (mode.code == value) return mode;
    }
    return loopback;
  }
}

class McpBind {
  const McpBind.loopback() : mode = McpBindMode.loopback, address = null;
  const McpBind.lan() : mode = McpBindMode.lan, address = null;

  /// [address] must be a literal accepted by [normalizeMcpAddress].
  const McpBind.custom(String this.address) : mode = McpBindMode.custom;

  final McpBindMode mode;

  /// The IP literal of [McpBindMode.custom]; null otherwise.
  final String? address;

  /// Whether devices other than this one may be able to connect.
  bool get exposed => switch (mode) {
    McpBindMode.loopback => false,
    McpBindMode.lan => true,
    McpBindMode.custom => !_isLoopbackLiteral(address!),
  };

  @override
  bool operator ==(Object other) =>
      other is McpBind && other.mode == mode && other.address == address;

  @override
  int get hashCode => Object.hash(mode, address);

  @override
  String toString() => address == null ? mode.code : '${mode.code}($address)';
}

bool _isLoopbackLiteral(String address) =>
    address == '::1' || address.startsWith('127.');

/// The canonical form of an IPv4 or IPv6 literal, or null when [input] is not
/// one. Host names are never accepted: the listener binds an address.
String? normalizeMcpAddress(String input) {
  final text = input.trim();
  if (text.isEmpty || text.length > 45) return null;
  try {
    return Uri.parseIPv4Address(text).join('.');
  } on FormatException {
    // Not IPv4.
  }
  if (!text.contains(':') || text.contains('%')) return null;
  try {
    Uri.parseIPv6Address(text);
    return text.toLowerCase();
  } on FormatException {
    return null;
  }
}

/// Whether a peer with this raw address (4 or 16 bytes) may use a listener
/// that is reachable from other devices: this device itself, private and
/// link-local networks and carrier-grade NAT space (used by overlay VPNs).
/// Public addresses are refused, so a machine with a public interface never
/// serves MCP to the internet.
bool mcpPeerAllowed(List<int> raw) {
  if (raw.length == 4) {
    final a = raw[0], b = raw[1];
    return a == 127 ||
        a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 169 && b == 254) ||
        (a == 100 && b >= 64 && b <= 127);
  }
  if (raw.length != 16) return false;
  final mapped =
      raw.take(10).every((byte) => byte == 0) &&
      raw[10] == 0xff &&
      raw[11] == 0xff;
  if (mapped) return mcpPeerAllowed(raw.sublist(12));
  final loopback = raw.take(15).every((byte) => byte == 0) && raw[15] == 1;
  return loopback ||
      (raw[0] & 0xfe) == 0xfc || // fc00::/7 unique local
      (raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80); // fe80::/10 link-local
}

/// Device-local listening choice (no secrets): port and bind address.
class McpListenSettings {
  const McpListenSettings({
    this.port = mcpDefaultPort,
    this.bind = const McpBind.loopback(),
    this.enabled = false,
  });

  final int port;
  final McpBind bind;

  /// The user enabled MCP and has not stopped it: it starts again by itself
  /// whenever the workspace is unlocked or Atermius starts on this device.
  final bool enabled;

  McpListenSettings copyWith({bool? enabled}) => McpListenSettings(
    port: port,
    bind: bind,
    enabled: enabled ?? this.enabled,
  );

  /// Strict parse; anything invalid falls back to the loopback default.
  static McpListenSettings parse(String? raw) {
    if (raw == null || raw.length > mcpListenSettingsMaxLength) {
      return const McpListenSettings();
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const McpListenSettings();
    }
    if (decoded is! Map || decoded['v'] != 1) return const McpListenSettings();
    final port = decoded['port'];
    final mode = McpBindMode.parse(decoded['bind']);
    final address = decoded['address'];
    final normalized = address is String ? normalizeMcpAddress(address) : null;
    return McpListenSettings(
      port: port is int && port >= 1024 && port <= 65535
          ? port
          : mcpDefaultPort,
      bind: switch (mode) {
        McpBindMode.loopback => const McpBind.loopback(),
        McpBindMode.lan => const McpBind.lan(),
        // A custom choice without a usable address is not a choice.
        McpBindMode.custom =>
          normalized == null
              ? const McpBind.loopback()
              : McpBind.custom(normalized),
      },
      enabled: decoded['enabled'] == true,
    );
  }

  String encode() => jsonEncode({
    'v': 1,
    'port': port,
    'bind': bind.mode.code,
    'address': ?bind.address,
    if (enabled) 'enabled': true,
  });
}

const mcpDefaultPort = 8765;
const mcpListenSettingsMaxLength = 256;
