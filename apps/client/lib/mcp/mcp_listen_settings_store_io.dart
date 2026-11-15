import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'mcp_bind.dart';
import 'mcp_listen_settings_store.dart';

class FileMcpListenSettingsStore implements McpListenSettingsStore {
  FileMcpListenSettingsStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> _file() async =>
      File('${(await _directory()).path}/mcp-listen-v1.json');

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    if (await file.length() > mcpListenSettingsMaxLength) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.mcp-listen-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(value, flush: true);
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

McpListenSettingsStore createStore() => FileMcpListenSettingsStore();
