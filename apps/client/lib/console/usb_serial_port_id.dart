/// Identity of one port of a USB-to-serial adapter on Android, as stored in
/// a Console tab, a window combination and quick connect
/// (`console tty @usb:0403:6001:A50285BI -b 9600`).
///
/// Canonical text: `usb:VVVV:PPPP[:SERIAL][#N]` with the vendor and product
/// ids as four lowercase hex digits, the adapter's USB serial number when it
/// has one Android lets the app read, and the port index N (1-15) for
/// multi-port adapters (port 0 is written without `#0`). Android's own device
/// path (/dev/bus/usb/001/004) changes with every replug, so it is never part
/// of the id; vendor, product and serial number survive a replug and a
/// restart. An id that matches no attached adapter, or several identical
/// adapters without serial numbers, fails to open instead of guessing.
///
/// The alphabet is a strict subset of what tab names, quick connect tokens
/// and window combination panes accept: no whitespace, path separators or
/// control characters.
class UsbSerialPortId {
  UsbSerialPortId({
    required this.vendorId,
    required this.productId,
    this.serial,
    this.port = 0,
  }) {
    if (vendorId < 0 ||
        vendorId > 0xffff ||
        productId < 0 ||
        productId > 0xffff ||
        port < 0 ||
        port > maxPort ||
        (serial != null && !isValidSerial(serial!))) {
      throw const FormatException('Invalid USB serial port');
    }
  }

  /// Highest port index; the Android bridge reports at most 16 ports.
  static const maxPort = 15;

  /// Same alphabet and length as the Android bridge (UsbSerialBridge.SERIAL).
  /// Serial numbers outside it are left out of the id rather than escaped.
  static final _serialPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

  static final _pattern = RegExp(
    r'^usb:([0-9a-fA-F]{4}):([0-9a-fA-F]{4})'
    r'(?::([A-Za-z0-9._-]{1,64}))?(?:#(0|[1-9][0-9]?))?$',
    caseSensitive: false,
  );

  final int vendorId, productId, port;
  final String? serial;

  /// Whether a USB serial number can be part of an id.
  static bool isValidSerial(String serial) => _serialPattern.hasMatch(serial);

  /// Whether [text] claims to be a USB port id (it may still be malformed).
  /// Quick connect uses this to route `usb:` tokens here instead of treating
  /// them as COM ports.
  static bool claims(String text) =>
      text.length >= 4 && text.substring(0, 4).toLowerCase() == 'usb:';

  /// Accepts any case for the prefix and hex digits and an explicit `#0`
  /// (serial numbers keep their case); returns null for anything else,
  /// including ports above [maxPort]. [toString] is the canonical form.
  static UsbSerialPortId? tryParse(String text) {
    final match = _pattern.firstMatch(text);
    if (match == null) return null;
    final port = int.parse(match[4] ?? '0');
    if (port > maxPort) return null;
    return UsbSerialPortId(
      vendorId: int.parse(match[1]!, radix: 16),
      productId: int.parse(match[2]!, radix: 16),
      serial: match[3],
      port: port,
    );
  }

  static String _hex(int value) => value.toRadixString(16).padLeft(4, '0');

  @override
  String toString() =>
      'usb:${_hex(vendorId)}:${_hex(productId)}'
      '${serial == null ? '' : ':$serial'}'
      '${port == 0 ? '' : '#$port'}';

  @override
  bool operator ==(Object other) =>
      other is UsbSerialPortId &&
      other.vendorId == vendorId &&
      other.productId == productId &&
      other.serial == serial &&
      other.port == port;

  @override
  int get hashCode => Object.hash(vendorId, productId, serial, port);
}
