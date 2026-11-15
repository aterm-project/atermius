import 'package:web/web.dart' as web;

import 'keyword_highlight_store.dart';

class BrowserKeywordHighlightStore implements KeywordHighlightStore {
  static const _key = 'atermius.terminal-keyword-highlight.v1';

  @override
  Future<String?> read() async {
    try {
      final value = web.window.localStorage.getItem(_key);
      return value == null ||
              value.isEmpty ||
              value.length > KeywordHighlightStore.maxLength
          ? null
          : value;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(String? document) async {
    if (document == null) {
      web.window.localStorage.removeItem(_key);
      return;
    }
    if (document.length > KeywordHighlightStore.maxLength) {
      throw ArgumentError.value(document.length, 'document', 'Too long');
    }
    web.window.localStorage.setItem(_key, document);
  }
}

KeywordHighlightStore createKeywordHighlightStore() =>
    BrowserKeywordHighlightStore();
