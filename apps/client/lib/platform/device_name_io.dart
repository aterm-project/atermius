import 'dart:io';

import 'package:flutter/services.dart';

const _deviceInfo = MethodChannel('atermius/device_info');

Future<Map<String, Object?>> deviceActivityPayload() async {
  String? name;
  try {
    name = Platform.isIOS || Platform.isAndroid
        ? await _deviceInfo.invokeMethod<String>('name')
        : Platform.localHostname;
  } on Exception {
    // The device can still report its platform when the OS name is unavailable.
  }
  final label = name == null
      ? null
      : String.fromCharCodes(
          name.runes
              .where((rune) => rune >= 32 && (rune < 127 || rune > 159))
              .take(120),
        ).trim();
  return {
    'platform': Platform.operatingSystem,
    if (label != null && label.isNotEmpty) 'device_name': label,
  };
}
