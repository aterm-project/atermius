import 'clipboard_secret_marker_native.dart'
    if (dart.library.js_interop) 'clipboard_secret_marker_web.dart'
    as platform;

/// Device-local note that an Atermius run put a secret on the system
/// clipboard (see SensitiveClipboard.markSecret). It holds nothing about
/// the secret, not even a hash: only that one was copied. A later run that
/// finds it treats the first clipboard text it would sync automatically as
/// that secret. Never synced, exported or backed up.
abstract interface class ClipboardSecretMarker {
  /// Whether the note exists. Throws when that cannot be told.
  Future<bool> read();
  Future<void> write();
  Future<void> clear();
}

ClipboardSecretMarker createClipboardSecretMarker() => platform.createMarker();

class MemoryClipboardSecretMarker implements ClipboardSecretMarker {
  MemoryClipboardSecretMarker({this.present = false});
  bool present;

  /// Thrown by [read] when set (an unreadable store).
  Object? readError;
  int writes = 0, clears = 0;

  @override
  Future<bool> read() async {
    final error = readError;
    if (error != null) throw error;
    return present;
  }

  @override
  Future<void> write() async {
    writes++;
    present = true;
  }

  @override
  Future<void> clear() async {
    clears++;
    present = false;
  }
}
