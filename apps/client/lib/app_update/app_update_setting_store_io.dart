import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_update_controller.dart';

/// Device-local choice between automatic and announced-only updates: one
/// character in a plain file next to the other device preferences. Not
/// synchronized and not part of any export.
class FileAppUpdateSettingStore implements AppUpdateSettingStore {
  FileAppUpdateSettingStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File('${(await _directory()).path}/app-update-automatic-v1');

  @override
  Future<bool?> readAutomatic() async {
    final file = await _file();
    if (!await file.exists() || await file.length() > 8) return null;
    return switch ((await file.readAsString()).trim()) {
      '1' => true,
      '0' => false,
      _ => null,
    };
  }

  @override
  Future<void> writeAutomatic(bool value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.app-update-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(value ? '1' : '0', flush: true);
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}
