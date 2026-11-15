import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:xterm/xterm.dart';

import '../storage/keyword_highlight_store.dart';
import 'keyword_highlight_rules.dart';

export 'keyword_highlight_rules.dart';

/// Why [TerminalKeywordHighlighter.addKeyword] did or did not add a keyword.
enum KeywordAddResult { added, duplicate, invalid, full }

/// The color a highlight group gets on one terminal theme.
@immutable
class KeywordHighlightAppearance {
  const KeywordHighlightAppearance(this.ansi, this.color, {required this.bold});

  /// ANSI index (0..15) actually used: the normal or the bright variant.
  final int ansi;
  final Color color;

  /// Set when even the better variant is hard to tell from the theme's
  /// default text color; weight then carries the emphasis.
  final bool bold;
}

/// Terminal keyword highlighting: the device-local preference, and the
/// display-only decorator every terminal view of the app uses.
///
/// Words of enabled groups, addresses and links are drawn in the group's
/// color while they are plain text (default colors). Text a program colored
/// itself, full-screen programs (alternate screen) and the terminal buffer
/// are left alone: copying, searching, session logs and `terminal_read` see
/// exactly what they saw before.
///
/// Work per paint is bounded: a line is analysed once and remembered by its
/// content, so repainting, scrolling back over seen lines and repeated lines
/// cost one hash and one comparison each, and the regular expression only
/// runs for content not seen before.
class TerminalKeywordHighlighter extends ChangeNotifier
    implements TerminalForegroundDecorator {
  TerminalKeywordHighlighter({KeywordHighlightSettings? settings})
    : _settings = settings ?? KeywordHighlightSettings.defaults() {
    _matcher = KeywordHighlightMatcher.compile(_settings);
  }

  static TerminalKeywordHighlighter? _instance;

  /// Process-wide highlighter used by every terminal view.
  static TerminalKeywordHighlighter get instance =>
      _instance ??= TerminalKeywordHighlighter();

  @visibleForTesting
  static set debugInstance(TerminalKeywordHighlighter? highlighter) =>
      _instance = highlighter;

  /// Cells analysed per line. Longer lines are highlighted up to here.
  static const maxAnalysedCells = 512;

  /// Distinct line contents remembered (least recently used are dropped).
  static const maxCachedLines = 2048;

  KeywordHighlightSettings _settings;
  late KeywordHighlightMatcher _matcher;
  int _revision = 0;

  KeywordHighlightStore? _store;
  bool _writeFailed = false;
  int _writeRevision = 0;
  Future<void> _writeChain = Future<void>.value();
  bool _disposed = false;

  KeywordHighlightSettings get settings => _settings;

  /// Whether persisting the latest change failed; it still applies now.
  bool get writeFailed => _writeFailed;

  /// Reads the stored preference. A missing, oversized or malformed document
  /// and read failures leave the defaults in place without rewriting the
  /// stored value.
  Future<void> load(KeywordHighlightStore store) async {
    _store = store;
    String? document;
    try {
      document = await store.read().timeout(const Duration(seconds: 2));
    } on Object {
      document = null;
    }
    _apply(
      KeywordHighlightSettings.decode(document) ??
          KeywordHighlightSettings.defaults(),
    );
  }

  /// Applies [next] to every open terminal at once and persists it. Writes
  /// are serialized and coalesced, so the last change always wins on disk.
  Future<void> update(KeywordHighlightSettings next) {
    if (!_apply(next)) return Future<void>.value();
    final store = _store;
    if (store == null) return Future<void>.value();
    final revision = ++_writeRevision;
    final chained = _writeChain.then((_) async {
      if (revision != _writeRevision || _disposed) return;
      var failed = false;
      try {
        // The defaults are stored as "nothing", so they follow app updates.
        await store.write(next.isDefault ? null : next.encode());
      } on Object {
        failed = true;
      }
      if (revision != _writeRevision || _disposed) return;
      if (failed != _writeFailed) {
        _writeFailed = failed;
        notifyListeners();
      }
    });
    _writeChain = chained;
    return chained;
  }

  bool _apply(KeywordHighlightSettings next) {
    if (next == _settings) return false;
    _settings = next;
    _matcher = KeywordHighlightMatcher.compile(next);
    _revision++;
    _cache.clear();
    notifyListeners();
    return true;
  }

  Future<void> setEnabled(bool enabled) =>
      update(_settings.copyWith(enabled: enabled));

  Future<void> setGroupEnabled(String id, bool enabled) =>
      _updateGroup(id, (group) => group.copyWith(enabled: enabled));

  Future<void> setGroupColor(String id, KeywordHighlightColor color) =>
      _updateGroup(id, (group) => group.copyWith(color: color));

  Future<void> _updateGroup(
    String id,
    KeywordHighlightGroup Function(KeywordHighlightGroup) change,
  ) {
    final group = _settings.group(id);
    if (group == null) return Future<void>.value();
    return update(_settings.withGroup(change(group)));
  }

  /// Adds the word or phrase [raw] to group [id].
  KeywordAddResult addKeyword(String id, String raw) {
    final group = _settings.group(id);
    final keyword = normalizeHighlightKeyword(raw);
    if (group == null || group.isPattern || keyword == null) {
      return KeywordAddResult.invalid;
    }
    if (group.keywords.contains(keyword)) return KeywordAddResult.duplicate;
    if (group.keywords.length >= KeywordHighlightLimits.maxKeywordsPerGroup) {
      return KeywordAddResult.full;
    }
    update(
      _settings.withGroup(
        group.copyWith(keywords: [...group.keywords, keyword]),
      ),
    );
    return KeywordAddResult.added;
  }

  Future<void> removeKeyword(String id, String keyword) => _updateGroup(
    id,
    (group) => group.copyWith(
      keywords: [
        for (final existing in group.keywords)
          if (existing != keyword) existing,
      ],
    ),
  );

  /// Adds a custom group named [rawName]. Returns its id, or null when the
  /// name is unusable or no more groups fit.
  String? addGroup(String rawName) {
    final name = normalizeHighlightGroupName(rawName);
    if (name == null) return null;
    final added = _settings.withNewGroup(name);
    if (added == null) return null;
    update(added.$1);
    return added.$2.id;
  }

  Future<void> removeGroup(String id) => update(_settings.withoutGroup(id));

  Future<void> restoreDefaults() => update(KeywordHighlightSettings.defaults());

  // ---------------------------------------------------------------- colors

  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
  }

  /// "Redmean" color difference: cheap and close enough to perception to
  /// tell whether two text colors can be told apart at a glance.
  static double _difference(Color a, Color b) {
    final ar = a.r * 255, ag = a.g * 255, ab = a.b * 255;
    final br = b.r * 255, bg = b.g * 255, bb = b.b * 255;
    final mean = (ar + br) / 2;
    final dr = ar - br, dg = ag - bg, db = ab - bb;
    return math.sqrt(
      (2 + mean / 256) * dr * dr +
          4 * dg * dg +
          (2 + (255 - mean) / 256) * db * db,
    );
  }

  static const _readableContrast = 4.5;
  static const _distinctDifference = 150.0;

  /// Whether [bright] is a lighter or stronger take on [normal] rather than
  /// another color altogether (some palettes use the bright slots for grays).
  static bool _sameHue(Color normal, Color bright) {
    final a = HSVColor.fromColor(normal), b = HSVColor.fromColor(bright);
    if (b.saturation < .25) return false;
    if (a.saturation < .15) return true;
    final distance = (a.hue - b.hue).abs();
    return math.min(distance, 360 - distance) <= 50;
  }

  /// How [color] is drawn on [theme]. Normally the theme's own ANSI color;
  /// its bright variant instead when that is the same hue and either reads
  /// better on the theme's background or, unlike the normal one, can be told
  /// from the default text. Bold when the result still looks like the default
  /// text color (green words on a green-text palette).
  static KeywordHighlightAppearance appearanceOf(
    TerminalTheme theme,
    KeywordHighlightColor color,
  ) {
    final normal = terminalAnsiColor(theme, color.ansi);
    final bright = terminalAnsiColor(theme, color.ansi + 8);
    var useBright = false;
    if (_sameHue(normal, bright)) {
      final normalContrast = _contrast(normal, theme.background);
      final brightContrast = _contrast(bright, theme.background);
      if (normalContrast < _readableContrast) {
        useBright = brightContrast > normalContrast;
      } else if (brightContrast >= _readableContrast) {
        useBright =
            _difference(normal, theme.foreground) < _distinctDifference &&
            _difference(bright, theme.foreground) >= _distinctDifference;
      }
    }
    final value = useBright ? bright : normal;
    return KeywordHighlightAppearance(
      useBright ? color.ansi + 8 : color.ansi,
      value,
      bold: _difference(value, theme.foreground) < _distinctDifference,
    );
  }

  final _styles = Expando<_ThemeStyles>('keyword highlight styles');

  // --------------------------------------------------------------- decorator

  @override
  List<TerminalForegroundStyle>? beginPaint(
    Terminal terminal,
    TerminalTheme theme,
  ) {
    // Off, or a full-screen program owns the screen: nothing per line.
    if (_matcher.isEmpty || terminal.isUsingAltBuffer) return null;
    var styles = _styles[theme];
    if (styles == null || styles.revision != _revision) {
      styles = _styles[theme] = _ThemeStyles(_revision, [
        for (final group in _matcher.groups)
          () {
            final look = appearanceOf(theme, group.color);
            return TerminalForegroundStyle.ansi(
              look.ansi,
              flags:
                  (look.bold ? CellFlags.bold : 0) |
                  (group.builtin == KeywordHighlightBuiltin.url
                      ? CellFlags.underline
                      : 0),
            );
          }(),
      ]);
    }
    return styles.styles;
  }

  // Key layout: [flags, cell content...]. Cell content words carry the code
  // point and the cell width, so equal keys mean equal text in equal columns.
  static const _flagWrapped = 1;
  static const _flagFullRow = 2;
  static const _flagTruncated = 4;

  final _scratch = Uint32List(maxAnalysedCells + 1);
  final _cache = <int, _CachedLine>{};

  /// How many lines went through the regular expression so far. Repaints of
  /// unchanged lines must not increase it.
  @visibleForTesting
  int debugAnalysedLines = 0;

  @visibleForTesting
  int get debugCachedLines => _cache.length;

  /// The groups that currently produce highlights; a span's
  /// [TerminalForegroundSpan.style] indexes this list.
  List<KeywordHighlightGroup> get activeGroups => _matcher.groups;

  @override
  List<TerminalForegroundSpan>? spansFor(BufferLine line) {
    final width = line.length;
    // A wide character in the last column reports one cell past the row.
    final trimmed = math.min(line.getTrimmedLength(width), width);
    if (trimmed <= 0) return null;
    final cells = math.min(trimmed, maxAnalysedCells);
    final key = _scratch;
    key[0] =
        (line.isWrapped ? _flagWrapped : 0) |
        (trimmed >= width ? _flagFullRow : 0) |
        (trimmed > cells ? _flagTruncated : 0);
    var hash = key[0];
    for (var i = 0; i < cells; i++) {
      final content = line.getContent(i);
      key[i + 1] = content;
      hash = 0x1fffffff & (hash + content);
      hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
      hash ^= hash >> 6;
    }
    hash = 0x1fffffff & (hash + cells);

    final cached = _cache.remove(hash);
    if (cached != null && cached.matches(key, cells + 1)) {
      _cache[hash] = cached; // Most recently used.
      return cached.spans;
    }
    final entry = _CachedLine(
      Uint32List.fromList(Uint32List.sublistView(key, 0, cells + 1)),
      _analyse(key, cells, width),
    );
    _cache[hash] = entry;
    if (_cache.length > maxCachedLines) _cache.remove(_cache.keys.first);
    return entry.spans;
  }

  /// Runs the matcher over the [cells] cells in [key] (after its flags word)
  /// and maps the matches back to cell columns.
  List<TerminalForegroundSpan>? _analyse(Uint32List key, int cells, int width) {
    debugAnalysedLines++;
    final flags = key[0];
    // Text as the user reads it, and for every UTF-16 unit the cell it is in.
    // A wide character takes two cells but is one character of text; a
    // skipped (never written) cell reads as a space.
    final units = Uint16List(cells * 2);
    final columns = Uint16List(cells * 2);
    var length = 0;
    var afterWide = false;
    for (var i = 0; i < cells; i++) {
      final content = key[i + 1];
      var codePoint = content & CellContent.codepointMask;
      final wideTail = codePoint == 0 && afterWide;
      afterWide = content >> CellContent.widthShift == 2;
      if (wideTail) continue;
      if (codePoint == 0) codePoint = 0x20;
      if (codePoint >= 0x10000) {
        codePoint -= 0x10000;
        units[length] = 0xd800 | (codePoint >> 10);
        columns[length++] = i;
        units[length] = 0xdc00 | (codePoint & 0x3ff);
        columns[length++] = i;
      } else {
        units[length] = codePoint;
        columns[length++] = i;
      }
    }
    final text = String.fromCharCodes(units, 0, length);

    List<TerminalForegroundSpan>? spans;
    _matcher.match(text, (start, end, slot) {
      final first = columns[start];
      final lastCell = columns[end - 1];
      final last =
          lastCell + (key[lastCell + 1] >> CellContent.widthShift == 2 ? 2 : 1);
      // A match touching an edge the text may continue across (a soft wrap,
      // or the analysis limit) could be part of a longer word: leave it.
      if (first == 0 && flags & _flagWrapped != 0) return;
      if (last >= width && flags & _flagFullRow != 0) return;
      if (end == length && flags & _flagTruncated != 0) return;
      (spans ??= []).add(TerminalForegroundSpan(first, last, slot));
    });
    return spans;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The ANSI color [index] (0..15) of [theme].
Color terminalAnsiColor(TerminalTheme theme, int index) => switch (index) {
  0 => theme.black,
  1 => theme.red,
  2 => theme.green,
  3 => theme.yellow,
  4 => theme.blue,
  5 => theme.magenta,
  6 => theme.cyan,
  7 => theme.white,
  8 => theme.brightBlack,
  9 => theme.brightRed,
  10 => theme.brightGreen,
  11 => theme.brightYellow,
  12 => theme.brightBlue,
  13 => theme.brightMagenta,
  14 => theme.brightCyan,
  _ => theme.brightWhite,
};

class _ThemeStyles {
  _ThemeStyles(this.revision, this.styles);
  final int revision;
  final List<TerminalForegroundStyle> styles;
}

class _CachedLine {
  _CachedLine(this.key, this.spans);
  final Uint32List key;
  final List<TerminalForegroundSpan>? spans;

  bool matches(Uint32List other, int length) {
    final key = this.key;
    if (key.length != length) return false;
    for (var i = 0; i < length; i++) {
      if (key[i] != other[i]) return false;
    }
    return true;
  }
}
