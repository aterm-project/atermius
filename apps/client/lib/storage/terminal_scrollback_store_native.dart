import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'terminal_scrollback_store.dart';

class FileTerminalScrollbackStore implements TerminalScrollbackStore {
  FileTerminalScrollbackStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  static const _maxLength = 64;

  Future<File> _file() async =>
      File('${(await _directory()).path}/terminal-scrollback-v1');

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    if (await file.length() > _maxLength) return null;
    final value = (await file.readAsString()).trim();
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.terminal-scrollback-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(value, flush: true);
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

TerminalScrollbackStore createTerminalScrollbackStore() =>
    FileTerminalScrollbackStore();
