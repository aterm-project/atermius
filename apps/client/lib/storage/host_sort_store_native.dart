import 'dart:io';

import 'host_sort_store.dart';
import 'rdp_local_drives_store_native.dart' show deviceLocalDirectory;

class FileHostSortStore implements HostSortStore {
  FileHostSortStore({Future<Directory> Function()? directory})
    : _directory = directory ?? deviceLocalDirectory;
  final Future<Directory> Function() _directory;
  Future<File> _file() async =>
      File('${(await _directory()).path}/host-sort-v1');

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists() || await file.length() > 524288) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.host-sort-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(value, flush: true);
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

HostSortStore createHostSortStore() => FileHostSortStore();
