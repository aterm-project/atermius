import 'dart:io';

import 'package:flutter/services.dart';

import 'clipboard_secret_marker.dart';
import 'rdp_local_drives_store_native.dart' show deviceLocalDirectory;

/// An empty-content file in the device-local app directory (Local AppData
/// on Windows; excluded from Android Auto Backup and device transfer).
class FileClipboardSecretMarker implements ClipboardSecretMarker {
  FileClipboardSecretMarker({Future<Directory> Function()? directory})
    : _directory = directory ?? deviceLocalDirectory;
  final Future<Directory> Function() _directory;

  Future<File?> _file() async {
    try {
      return File('${(await _directory()).path}/clipboard-secret-v1');
    } on MissingPluginException {
      // No platform storage at all (unit tests): nothing is kept, so there
      // is nothing an earlier run could have left either.
      return null;
    }
  }

  @override
  Future<bool> read() async => await (await _file())?.exists() ?? false;

  @override
  Future<void> write() async {
    final file = await _file();
    if (file == null) return;
    await file.parent.create(recursive: true);
    await file.writeAsString('1\n', flush: true);
  }

  @override
  Future<void> clear() async {
    final file = await _file();
    if (file != null && await file.exists()) await file.delete();
  }
}

ClipboardSecretMarker createMarker() => FileClipboardSecretMarker();
