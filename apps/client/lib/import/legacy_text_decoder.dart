/// Decoding for text files written by Windows desktop apps in the system
/// ANSI code page (for example MobaXterm's `MobaXterm.ini` and
/// `.mxtsessions` exports).
///
/// The file itself does not say which code page wrote it. UTF-8 is used when
/// the bytes are valid UTF-8. Otherwise the code page that matches the app
/// language is preferred (Chinese Windows writes GBK, Japanese Windows
/// Shift_JIS, Russian Windows Windows-1251, Western Windows Windows-1252).
/// Under any other app language the text decides: accented Latin words read
/// as Windows-1252, Cyrillic words as Windows-1251, and a double-byte code
/// page is accepted only when the text clearly looks like Chinese or
/// Japanese. Korean (949) and Traditional Chinese (950) files are not
/// recognised; such files must be saved as UTF-8.
library;

import 'dart:convert';

import 'legacy_codepage_tables.dart';

enum LegacyCodePage { utf8, gbk, shiftJis, windows1251, windows1252 }

const _hole = 0xFFFD;

/// The ANSI code page Windows uses for [languageCode] (an app language).
LegacyCodePage preferredLegacyCodePage(String? languageCode) =>
    switch (languageCode) {
      'zh' => LegacyCodePage.gbk,
      'ja' => LegacyCodePage.shiftJis,
      'ru' => LegacyCodePage.windows1251,
      _ => LegacyCodePage.windows1252,
    };

/// Decodes [bytes] and reports which code page was used. Never throws: when
/// nothing decodes cleanly, undefined Windows-1252 bytes become U+FFFD.
({String text, LegacyCodePage codePage}) decodeWindowsText(
  List<int> bytes, {
  String? languageCode,
}) {
  var body = bytes;
  if (body.length >= 3 &&
      body[0] == 0xEF &&
      body[1] == 0xBB &&
      body[2] == 0xBF) {
    body = body.sublist(3);
  }
  try {
    return (
      text: utf8.decode(body, allowMalformed: false),
      codePage: LegacyCodePage.utf8,
    );
  } on FormatException {
    // Not UTF-8: a legacy ANSI code page.
  }
  final preferred = preferredLegacyCodePage(languageCode);
  if (preferred == LegacyCodePage.gbk || preferred == LegacyCodePage.shiftJis) {
    final text = decodeLegacyCodePage(body, preferred);
    if (text != null) return (text: text, codePage: preferred);
  }
  if (preferred == LegacyCodePage.windows1252) {
    // Accented Latin letters pair up like GB2312 characters too ("ção" is
    // E7 E3 6F): words decide before any double-byte guess.
    if (_wordsIn(body, cp1252High, _isLatinLetter, maxRun: 3)) {
      return (
        text: decodeLegacyCodePage(body, LegacyCodePage.windows1252)!,
        codePage: LegacyCodePage.windows1252,
      );
    }
    if (_wordsIn(body, cp1251High, _isCyrillicLetter, caseShaped: true)) {
      return (
        text: decodeLegacyCodePage(body, LegacyCodePage.windows1251)!,
        codePage: LegacyCodePage.windows1251,
      );
    }
  }
  // Cyrillic Windows-1251 text pairs up like GB2312 characters, so a Russian
  // user's file is never guessed to be Chinese or Japanese.
  for (final page in const [LegacyCodePage.gbk, LegacyCodePage.shiftJis]) {
    if (page == preferred || preferred == LegacyCodePage.windows1251) continue;
    final text = decodeLegacyCodePage(body, page);
    if (text != null && _looksLike(page, body)) {
      return (text: text, codePage: page);
    }
  }
  final singles = preferred == LegacyCodePage.windows1251
      ? const [LegacyCodePage.windows1251, LegacyCodePage.windows1252]
      : const [LegacyCodePage.windows1252, LegacyCodePage.windows1251];
  for (final page in singles) {
    final text = decodeLegacyCodePage(body, page);
    if (text != null) return (text: text, codePage: page);
  }
  return (
    text: _decodeSingle(body, cp1252High, strict: false)!,
    codePage: LegacyCodePage.windows1252,
  );
}

/// Strictly decodes [bytes] in [page]; null when any sequence is invalid.
String? decodeLegacyCodePage(List<int> bytes, LegacyCodePage page) =>
    switch (page) {
      LegacyCodePage.utf8 => _tryUtf8(bytes),
      LegacyCodePage.gbk => _decodeDouble(bytes, gbk: true),
      LegacyCodePage.shiftJis => _decodeDouble(bytes, gbk: false),
      LegacyCodePage.windows1251 => _decodeSingle(bytes, cp1251High),
      LegacyCodePage.windows1252 => _decodeSingle(bytes, cp1252High),
    };

String? _tryUtf8(List<int> bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    return null;
  }
}

String? _decodeSingle(List<int> bytes, String high, {bool strict = true}) {
  final units = List<int>.filled(bytes.length, 0);
  for (var index = 0; index < bytes.length; index++) {
    final byte = bytes[index];
    if (byte < 0x80) {
      units[index] = byte;
      continue;
    }
    final unit = high.codeUnitAt(byte - 0x80);
    if (unit == _hole && strict) return null;
    units[index] = unit;
  }
  return String.fromCharCodes(units);
}

/// Row of [lead] in the double-byte table, or -1 when it is not a lead byte.
int _leadRow(int lead, {required bool gbk}) {
  if (gbk) {
    return lead >= gbkLeadFirst && lead <= gbkLeadLast
        ? lead - gbkLeadFirst
        : -1;
  }
  if (lead >= 0x81 && lead <= 0x9F) return lead - 0x81;
  if (lead >= 0xE0 && lead <= 0xFC) return 31 + lead - 0xE0;
  return -1;
}

String? _decodeDouble(List<int> bytes, {required bool gbk}) {
  final table = gbk ? gbkTable : cp932Table;
  final units = <int>[];
  var index = 0;
  while (index < bytes.length) {
    final byte = bytes[index];
    if (byte < 0x80) {
      units.add(byte);
      index++;
      continue;
    }
    if (gbk && byte == 0x80) {
      units.add(0x20AC); // Windows code page 936 maps 0x80 to the euro sign.
      index++;
      continue;
    }
    if (!gbk && byte >= 0xA1 && byte <= 0xDF) {
      units.add(0xFF61 + byte - 0xA1); // Half-width katakana.
      index++;
      continue;
    }
    final row = _leadRow(byte, gbk: gbk);
    if (row < 0 || index + 1 >= bytes.length) return null;
    final trail = bytes[index + 1];
    if (trail < legacyTrailFirst) return null;
    final unit = table.codeUnitAt(row * legacyTrailCount + trail - legacyTrailFirst);
    if (unit == _hole) return null;
    units.add(unit);
    index += 2;
  }
  return String.fromCharCodes(units);
}

/// True when [bytes] has non-ASCII bytes and, read with the single-byte [high]
/// table, every one of them is a letter that [isLetter] accepts. With
/// [maxRun], no run of consecutive non-ASCII bytes is longer (accented Latin
/// words have one or two accented letters in a row; Chinese and Cyrillic
/// words are runs of them). With [caseShaped], each run reads as a lower-case,
/// upper-case or capitalised word, which random double-byte pairs rarely do.
bool _wordsIn(
  List<int> bytes,
  String high,
  bool Function(int unit) isLetter, {
  int? maxRun,
  bool caseShaped = false,
}) {
  var seen = false;
  var index = 0;
  while (index < bytes.length) {
    if (bytes[index] < 0x80) {
      index++;
      continue;
    }
    final start = index;
    while (index < bytes.length && bytes[index] >= 0x80) {
      final unit = high.codeUnitAt(bytes[index] - 0x80);
      if (unit == _hole || !isLetter(unit)) return false;
      index++;
    }
    if (maxRun != null && index - start > maxRun) return false;
    if (caseShaped) {
      // The word may start with ASCII letters only in mixed text; judge the
      // non-ASCII run, which holds all of a Cyrillic word.
      final run = [
        for (var at = start; at < index; at++) high.codeUnitAt(bytes[at] - 0x80),
      ];
      final rest = run.skip(1);
      final restLower = rest.every((unit) => _lower(unit) == unit);
      final restUpper = rest.every((unit) => _upper(unit) == unit);
      if (!restLower && !restUpper) return false;
      if (restUpper && run.length > 1 && _lower(run.first) == run.first) {
        return false; // "аБВ" is not a word.
      }
    }
    seen = true;
  }
  return seen;
}

/// Letters of the Windows-1252 upper half: À–ÿ without × and ÷, and Š š Œ œ
/// Ž ž Ÿ.
bool _isLatinLetter(int unit) =>
    (unit >= 0xC0 && unit <= 0xFF && unit != 0xD7 && unit != 0xF7) ||
    const {0x0160, 0x0161, 0x0152, 0x0153, 0x017D, 0x017E, 0x0178}
        .contains(unit);

/// Cyrillic letters (А–я, Ё ё and the Ukrainian, Belarusian and South Slavic
/// letters Windows-1251 carries).
bool _isCyrillicLetter(int unit) => unit >= 0x0400 && unit <= 0x045F ||
    unit == 0x0490 ||
    unit == 0x0491;

int _lower(int unit) {
  if (unit >= 0x0410 && unit <= 0x042F) return unit + 0x20;
  if (unit >= 0x0400 && unit <= 0x040F) return unit + 0x50;
  if (unit == 0x0490) return 0x0491;
  return unit;
}

int _upper(int unit) {
  if (unit >= 0x0430 && unit <= 0x044F) return unit - 0x20;
  if (unit >= 0x0450 && unit <= 0x045F) return unit - 0x50;
  if (unit == 0x0491) return 0x0490;
  return unit;
}

/// True when the double-byte pairs in [bytes] look like real text in [page]
/// rather than Western or Cyrillic single-byte text that happens to decode.
bool _looksLike(LegacyCodePage page, List<int> bytes) {
  var pairs = 0;
  var kana = 0;
  var index = 0;
  while (index < bytes.length) {
    final byte = bytes[index];
    if (byte < 0x80) {
      index++;
      continue;
    }
    if (page == LegacyCodePage.shiftJis && byte >= 0xA1 && byte <= 0xDF) {
      return false; // Half-width katakana is rare in real names.
    }
    if (index + 1 >= bytes.length) return false;
    final trail = bytes[index + 1];
    if (page == LegacyCodePage.gbk) {
      // GB2312 area: the characters everyday Chinese text uses.
      if (byte < 0xA1 || byte > 0xF7 || trail < 0xA1 || trail > 0xFE) {
        return false;
      }
    } else if (byte == 0x82 || byte == 0x83) {
      kana++; // Hiragana and katakana rows.
    }
    pairs++;
    index += 2;
  }
  return pairs > 0 && (page == LegacyCodePage.gbk || kana > 0);
}
