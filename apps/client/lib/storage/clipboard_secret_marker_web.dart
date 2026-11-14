import 'clipboard_secret_marker.dart';

/// Browsers never read the clipboard on their own (automatic sync is remote
/// to local only there), so nothing needs to outlive the page.
class _NoClipboardSecretMarker implements ClipboardSecretMarker {
  @override
  Future<bool> read() async => false;
  @override
  Future<void> write() async {}
  @override
  Future<void> clear() async {}
}

ClipboardSecretMarker createMarker() => _NoClipboardSecretMarker();
