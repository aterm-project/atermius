import 'dart:io';

/// The Windows and Android runners register "atermius/clipboard". The
/// real OS decides, not the UI platform a test may override.
bool get hasNativeClipboardBridge => Platform.isAndroid || Platform.isWindows;
