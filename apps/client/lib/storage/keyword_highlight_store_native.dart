import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'keyword_highlight_store.dart';

class FileKeywordHighlightStore implements KeywordHighlightStore {
  FileKeywordHighlightStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  // UTF-8 needs at most three bytes per UTF-16 code unit.
  static const _maxBytes = 3 * KeywordHighlightStore.maxLength;

  Future<File> _file() async =>
      File('${(await _directory()).path}/terminal-keyword-highlight-v1');

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    if (await file.length() > _maxBytes) return null;
    final value = await file.readAsString();
    return value.isEmpty || value.length > KeywordHighlightStore.maxLength
        ? null
        : value;
  }

  @override
  Future<void> write(String? document) async {
    final file = await _file();
    if (document == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    if (document.length > KeywordHighlightStore.maxLength) {
      throw ArgumentError.value(document.length, 'document', 'Too long');
    }
    await file.parent.create(recursive: true);
    final temporary = await file.parent.createTemp('.keyword-highlight-');
    try {
      final candidate = File('${temporary.path}/value');
      await candidate.writeAsString(document, flush: true);
      await candidate.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}

KeywordHighlightStore createKeywordHighlightStore() =>
    FileKeywordHighlightStore();
