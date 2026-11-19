import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'paste_safety_store.dart';

/// 原生端原子落盘的粘贴安全护栏开关存储（临时文件写入 + rename 防半写损坏）。
class FilePasteSafetyStore implements PasteSafetyStore {
  FilePasteSafetyStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  static const _maxLength = 16;

  Future<File> _file() async =>
      File('${(await _directory()).path}/paste-safety-v1');

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
    final temporary = await file.parent.createTemp('.paste-safety-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(value, flush: true);
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

PasteSafetyStore createPasteSafetyStore() => FilePasteSafetyStore();
