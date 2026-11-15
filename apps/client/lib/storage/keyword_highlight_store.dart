import 'keyword_highlight_store_native.dart'
    if (dart.library.js_interop) 'keyword_highlight_store_web.dart'
    as platform;

/// Device-local terminal keyword highlighting preference (one small JSON
/// document, or absent for the defaults).
///
/// Like the terminal palette it lives outside the encrypted Vault/profile
/// stores: it is non-secret, never synced, and must be readable by
/// credential-free terminal child windows.
abstract interface class KeywordHighlightStore {
  /// Longest document either platform store reads or keeps.
  static const maxLength = 64 * 1024;

  Future<String?> read();

  /// Null removes the stored document (back to the defaults).
  Future<void> write(String? document);
}

KeywordHighlightStore createKeywordHighlightStore() =>
    platform.createKeywordHighlightStore();

/// In-memory store for tests.
class MemoryKeywordHighlightStore implements KeywordHighlightStore {
  MemoryKeywordHighlightStore([this.value]);
  String? value;
  int writes = 0;
  Object? failWith;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String? document) async {
    writes++;
    if (failWith case final error?) throw error;
    value = document;
  }
}
