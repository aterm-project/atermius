import 'dart:io';

/// The Android runner registers "atermius/clipboard" (ClipboardBridge). The
/// real OS decides, not the UI platform a test may override.
bool get hasAndroidClipboardBridge => Platform.isAndroid;
