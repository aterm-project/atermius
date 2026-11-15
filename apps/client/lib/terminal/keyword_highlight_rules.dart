import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Rule model, defaults, strict parsing and matching for terminal keyword
/// highlighting. Pure Dart: nothing here knows about terminal cells, themes
/// or widgets (see `keyword_highlighter.dart` for those).

/// A highlight color: one of the six chromatic ANSI hues. The actual color
/// always comes from the terminal theme, so it follows the chosen palette.
enum KeywordHighlightColor {
  red('red', 1),
  green('green', 2),
  yellow('yellow', 3),
  blue('blue', 4),
  magenta('magenta', 5),
  cyan('cyan', 6);

  const KeywordHighlightColor(this.id, this.ansi);

  /// Stable stored identifier. Never localized.
  final String id;

  /// ANSI index of the normal variant; the bright variant is `ansi + 8`.
  final int ansi;

  static KeywordHighlightColor? byId(Object? id) {
    for (final color in values) {
      if (color.id == id) return color;
    }
    return null;
  }
}

/// The built-in groups. [error]..[info] are keyword lists the user can edit;
/// [address] and [url] recognize patterns instead of words.
enum KeywordHighlightBuiltin {
  error('error', KeywordHighlightColor.red),
  warning('warning', KeywordHighlightColor.yellow),
  success('success', KeywordHighlightColor.green),
  info('info', KeywordHighlightColor.cyan),
  address('address', KeywordHighlightColor.magenta),
  url('url', KeywordHighlightColor.blue);

  const KeywordHighlightBuiltin(this.id, this.defaultColor);

  /// Stable stored identifier. Never localized.
  final String id;
  final KeywordHighlightColor defaultColor;

  /// Whether this group recognizes patterns (addresses, links) rather than a
  /// keyword list.
  bool get isPattern => this == address || this == url;

  List<String> get defaultKeywords => switch (this) {
    error => _defaultErrorKeywords,
    warning => _defaultWarningKeywords,
    success => _defaultSuccessKeywords,
    info => _defaultInfoKeywords,
    address || url => const [],
  };

  static KeywordHighlightBuiltin? byId(Object? id) {
    for (final builtin in values) {
      if (builtin.id == id) return builtin;
    }
    return null;
  }
}

// Words that almost always mean what they say in command output and logs.
// Everyday words ("no", "new", "on", "off", "yes", "true") are left out on
// purpose so that normal output does not turn into confetti.
const _defaultErrorKeywords = <String>[
  'error',
  'errors',
  'fail',
  'fails',
  'failed',
  'failing',
  'failure',
  'failures',
  'fatal',
  'critical',
  'crit',
  'emerg',
  'denied',
  'refused',
  'rejected',
  'forbidden',
  'unauthorized',
  'invalid',
  'exception',
  'traceback',
  'panic',
  'abort',
  'aborted',
  'killed',
  'crashed',
  'unreachable',
  'cannot',
  'no such file',
  'not found',
  'segfault',
  'segmentation fault',
  'core dumped',
  'out of memory',
  'corrupted',
  'down',
];

const _defaultWarningKeywords = <String>[
  'warn',
  'warning',
  'warnings',
  'caution',
  'deprecated',
  'deprecation',
  'timeout',
  'timed out',
  'retry',
  'retrying',
  'degraded',
  'skipped',
  'unstable',
  'expired',
  'insecure',
  'disabled',
  'disconnected',
  'offline',
];

const _defaultSuccessKeywords = <String>[
  'ok',
  'success',
  'successful',
  'successfully',
  'succeeded',
  'done',
  'pass',
  'passed',
  'complete',
  'completed',
  'active',
  'active (running)',
  'enabled',
  'connected',
  'established',
  'accepted',
  'up',
  'ready',
  'running',
  'started',
  'online',
  'healthy',
];

const _defaultInfoKeywords = <String>[
  'info',
  'notice',
  'note',
  'debug',
  'trace',
  'hint',
];

/// Size limits of the stored preference. Parsing drops whatever exceeds them.
abstract final class KeywordHighlightLimits {
  /// Custom groups in addition to the built-in ones.
  static const maxCustomGroups = 8;
  static const maxKeywordsPerGroup = 64;

  /// UTF-16 code units of one keyword or phrase.
  static const maxKeywordLength = 40;
  static const maxGroupNameLength = 32;

  /// UTF-16 code units of the whole stored document.
  static const maxStoredLength = 64 * 1024;
}

bool _isWordUnit(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5a) ||
    (unit >= 0x61 && unit <= 0x7a) ||
    unit == 0x5f;

/// Removes control characters and unpaired surrogates and collapses runs of
/// whitespace into single spaces. Returns the trimmed result.
String _cleanText(String raw) {
  final out = StringBuffer();
  var pendingSpace = false;
  for (var i = 0; i < raw.length; i++) {
    final unit = raw.codeUnitAt(i);
    final isSpace =
        unit == 0x20 ||
        unit == 0x09 ||
        unit == 0x0a ||
        unit == 0x0d ||
        unit == 0xa0 ||
        unit == 0x3000;
    if (isSpace) {
      pendingSpace = out.isNotEmpty;
      continue;
    }
    if (unit < 0x20 || (unit >= 0x7f && unit < 0xa0)) continue;
    if (unit >= 0xd800 && unit <= 0xdbff) {
      final next = i + 1 < raw.length ? raw.codeUnitAt(i + 1) : 0;
      if (next < 0xdc00 || next > 0xdfff) continue;
      if (pendingSpace) out.writeCharCode(0x20);
      pendingSpace = false;
      out
        ..writeCharCode(unit)
        ..writeCharCode(next);
      i++;
      continue;
    }
    if (unit >= 0xdc00 && unit <= 0xdfff) continue;
    if (pendingSpace) out.writeCharCode(0x20);
    pendingSpace = false;
    out.writeCharCode(unit);
  }
  return out.toString();
}

/// The stored form of a keyword or phrase typed by the user: lowercase,
/// single spaces, no control characters. Null when nothing usable is left or
/// it is longer than [KeywordHighlightLimits.maxKeywordLength].
String? normalizeHighlightKeyword(String raw) {
  final value = _cleanText(raw).toLowerCase();
  if (value.isEmpty || value.length > KeywordHighlightLimits.maxKeywordLength) {
    return null;
  }
  return value;
}

/// The stored form of a custom group name, or null when it is empty or too
/// long.
String? normalizeHighlightGroupName(String raw) {
  final value = _cleanText(raw);
  if (value.isEmpty ||
      value.length > KeywordHighlightLimits.maxGroupNameLength) {
    return null;
  }
  return value;
}

/// One highlight rule group: a color and what it applies to.
@immutable
class KeywordHighlightGroup {
  const KeywordHighlightGroup._({
    required this.id,
    required this.builtin,
    required this.name,
    required this.enabled,
    required this.color,
    required this.keywords,
  });

  /// A built-in group in its default state.
  factory KeywordHighlightGroup.builtin(KeywordHighlightBuiltin builtin) =>
      KeywordHighlightGroup._(
        id: builtin.id,
        builtin: builtin,
        name: '',
        enabled: true,
        color: builtin.defaultColor,
        keywords: builtin.defaultKeywords,
      );

  /// Stable identifier: a [KeywordHighlightBuiltin.id], or `custom-<n>`.
  final String id;

  /// Null for a group the user added.
  final KeywordHighlightBuiltin? builtin;

  /// Name of a custom group. Built-in groups are named by the UI (localized).
  final String name;
  final bool enabled;
  final KeywordHighlightColor color;

  /// Normalized (see [normalizeHighlightKeyword]) and unique. Always empty
  /// for pattern groups.
  final List<String> keywords;

  bool get isPattern => builtin?.isPattern ?? false;

  /// Whether the keyword list differs from the built-in default.
  bool get hasCustomKeywords =>
      builtin != null && !listEquals(keywords, builtin!.defaultKeywords);

  KeywordHighlightGroup copyWith({
    String? name,
    bool? enabled,
    KeywordHighlightColor? color,
    List<String>? keywords,
  }) => KeywordHighlightGroup._(
    id: id,
    builtin: builtin,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    color: color ?? this.color,
    keywords: keywords == null ? this.keywords : List.unmodifiable(keywords),
  );

  @override
  bool operator ==(Object other) =>
      other is KeywordHighlightGroup &&
      other.id == id &&
      other.name == name &&
      other.enabled == enabled &&
      other.color == color &&
      listEquals(other.keywords, keywords);

  @override
  int get hashCode =>
      Object.hash(id, name, enabled, color, Object.hashAll(keywords));
}

/// The whole device-local preference.
@immutable
class KeywordHighlightSettings {
  const KeywordHighlightSettings._(this.enabled, this.groups);

  /// Everything on, the built-in groups with their default lists and colors.
  factory KeywordHighlightSettings.defaults() => KeywordHighlightSettings._(
    true,
    List.unmodifiable([
      for (final builtin in KeywordHighlightBuiltin.values)
        KeywordHighlightGroup.builtin(builtin),
    ]),
  );

  /// Master switch.
  final bool enabled;

  /// Built-in groups first (always all of them, in enum order), then custom
  /// groups in the order they were added.
  final List<KeywordHighlightGroup> groups;

  Iterable<KeywordHighlightGroup> get customGroups =>
      groups.where((group) => group.builtin == null);

  bool get isDefault => this == KeywordHighlightSettings.defaults();

  KeywordHighlightGroup? group(String id) {
    for (final group in groups) {
      if (group.id == id) return group;
    }
    return null;
  }

  KeywordHighlightSettings copyWith({bool? enabled}) =>
      KeywordHighlightSettings._(enabled ?? this.enabled, groups);

  KeywordHighlightSettings withGroup(KeywordHighlightGroup next) =>
      KeywordHighlightSettings._(
        enabled,
        List.unmodifiable([
          for (final group in groups) group.id == next.id ? next : group,
        ]),
      );

  KeywordHighlightSettings withoutGroup(String id) =>
      KeywordHighlightSettings._(
        enabled,
        List.unmodifiable([
          for (final group in groups)
            if (group.builtin != null || group.id != id) group,
        ]),
      );

  /// Appends a custom group named [name] (already normalized). Returns null
  /// when [KeywordHighlightLimits.maxCustomGroups] is reached.
  (KeywordHighlightSettings, KeywordHighlightGroup)? withNewGroup(
    String name, {
    KeywordHighlightColor color = KeywordHighlightColor.magenta,
  }) {
    if (customGroups.length >= KeywordHighlightLimits.maxCustomGroups) {
      return null;
    }
    var n = 1;
    while (group('custom-$n') != null) {
      n++;
    }
    final added = KeywordHighlightGroup._(
      id: 'custom-$n',
      builtin: null,
      name: name,
      enabled: true,
      color: color,
      keywords: const [],
    );
    return (
      KeywordHighlightSettings._(
        enabled,
        List.unmodifiable([...groups, added]),
      ),
      added,
    );
  }

  /// The stored document. Built-in keyword lists are written only when they
  /// differ from the defaults, so untouched lists follow later app versions.
  String encode() => jsonEncode({
    'v': 1,
    'enabled': enabled,
    'groups': [
      for (final group in groups)
        {
          'id': group.id,
          if (group.builtin == null) 'name': group.name,
          'enabled': group.enabled,
          'color': group.color.id,
          if (!group.isPattern &&
              (group.builtin == null || group.hasCustomKeywords))
            'keywords': group.keywords,
        },
    ],
  });

  /// Strict, sanitizing parse of a stored document. Anything that is not a
  /// version 1 document yields null (the caller then uses the defaults);
  /// inside a valid document, unknown or malformed entries are dropped and
  /// everything is clamped to [KeywordHighlightLimits].
  static KeywordHighlightSettings? decode(String? source) {
    if (source == null ||
        source.isEmpty ||
        source.length > KeywordHighlightLimits.maxStoredLength) {
      return null;
    }
    final Object? document;
    try {
      document = jsonDecode(source);
    } on Object {
      return null;
    }
    if (document is! Map || document['v'] != 1) return null;
    final enabled = document['enabled'];
    final rawGroups = document['groups'];
    if (enabled is! bool || rawGroups is! List) return null;

    final builtins = <KeywordHighlightBuiltin, KeywordHighlightGroup>{};
    final customs = <KeywordHighlightGroup>[];
    final customIds = <String>{};
    for (final raw in rawGroups) {
      if (raw is! Map) continue;
      final id = raw['id'];
      if (id is! String) continue;
      final builtin = KeywordHighlightBuiltin.byId(id);
      final groupEnabled = raw['enabled'];
      final on = groupEnabled is bool ? groupEnabled : true;
      final color = KeywordHighlightColor.byId(raw['color']);
      if (builtin != null) {
        if (builtins.containsKey(builtin)) continue;
        final rawKeywords = raw['keywords'];
        builtins[builtin] = KeywordHighlightGroup._(
          id: builtin.id,
          builtin: builtin,
          name: '',
          enabled: on,
          color: color ?? builtin.defaultColor,
          keywords: builtin.isPattern || rawKeywords is! List
              ? builtin.defaultKeywords
              : _sanitizeKeywords(rawKeywords),
        );
        continue;
      }
      if (!_customId.hasMatch(id) ||
          customIds.contains(id) ||
          customs.length >= KeywordHighlightLimits.maxCustomGroups) {
        continue;
      }
      final rawName = raw['name'];
      final name = rawName is String
          ? normalizeHighlightGroupName(rawName)
          : null;
      if (name == null) continue;
      final rawKeywords = raw['keywords'];
      customIds.add(id);
      customs.add(
        KeywordHighlightGroup._(
          id: id,
          builtin: null,
          name: name,
          enabled: on,
          color: color ?? KeywordHighlightColor.magenta,
          keywords: rawKeywords is List
              ? _sanitizeKeywords(rawKeywords)
              : const [],
        ),
      );
    }
    return KeywordHighlightSettings._(
      enabled,
      List.unmodifiable([
        for (final builtin in KeywordHighlightBuiltin.values)
          builtins[builtin] ?? KeywordHighlightGroup.builtin(builtin),
        ...customs,
      ]),
    );
  }

  static final _customId = RegExp(r'^custom-[1-9][0-9]{0,3}$');

  static List<String> _sanitizeKeywords(List<Object?> raw) {
    final seen = <String>{};
    for (final entry in raw) {
      if (seen.length >= KeywordHighlightLimits.maxKeywordsPerGroup) break;
      if (entry is! String ||
          entry.length > 4 * KeywordHighlightLimits.maxKeywordLength) {
        continue;
      }
      final keyword = normalizeHighlightKeyword(entry);
      if (keyword != null) seen.add(keyword);
    }
    return List.unmodifiable(seen);
  }

  @override
  bool operator ==(Object other) =>
      other is KeywordHighlightSettings &&
      other.enabled == enabled &&
      listEquals(other.groups, groups);

  @override
  int get hashCode => Object.hash(enabled, Object.hashAll(groups));
}

/// Receives one match: UTF-16 offsets `[start, end)` into the matched text
/// and the index of the group in [KeywordHighlightMatcher.groups].
typedef KeywordMatchSink = void Function(int start, int end, int slot);

enum _Kind { customKeyword, url, mac, ipv6, ipv4, builtinKeyword }

/// The enabled rules of a [KeywordHighlightSettings], compiled into a single
/// regular expression.
///
/// Matching is case-insensitive. Keywords match on word boundaries (a letter,
/// digit or underscore next to a keyword's own first or last letter prevents
/// the match), phrases allow any number of spaces between their words.
///
/// Where rules overlap, the match that starts first wins; for the same start
/// the order is: keywords of custom groups, links, MAC addresses, IPv6, IPv4,
/// keywords of built-in groups. Among keywords the longest wins, then the
/// group that comes first.
class KeywordHighlightMatcher {
  KeywordHighlightMatcher._(
    this.groups,
    this._pattern,
    this._kinds,
    this._slots,
  );

  /// A matcher for the enabled groups of [settings]; [isEmpty] when the
  /// master switch is off or nothing is enabled.
  factory KeywordHighlightMatcher.compile(KeywordHighlightSettings settings) {
    final groups = <KeywordHighlightGroup>[];
    final slots = <String, int>{};
    final custom = <String>[];
    final builtin = <String>[];
    int? addressSlot;
    int? urlSlot;
    if (settings.enabled) {
      // Custom groups first: for the same keyword they win over built-ins.
      final ordered = [
        ...settings.customGroups,
        ...settings.groups.where((group) => group.builtin != null),
      ];
      for (final group in ordered) {
        if (!group.enabled) continue;
        if (group.builtin == KeywordHighlightBuiltin.address) {
          addressSlot = groups.length;
          groups.add(group);
        } else if (group.builtin == KeywordHighlightBuiltin.url) {
          urlSlot = groups.length;
          groups.add(group);
        } else {
          var used = false;
          for (final keyword in group.keywords) {
            if (slots.containsKey(keyword)) continue;
            slots[keyword] = groups.length;
            (group.builtin == null ? custom : builtin).add(keyword);
            used = true;
          }
          if (used) groups.add(group);
        }
      }
    }

    final parts = <String>[];
    final kinds = <_Kind>[];
    void add(_Kind kind, String pattern) {
      kinds.add(kind);
      parts.add('($pattern)');
    }

    if (custom.isNotEmpty) add(_Kind.customKeyword, _alternation(custom));
    if (urlSlot != null) add(_Kind.url, _url);
    if (addressSlot != null) {
      add(_Kind.mac, _mac);
      add(_Kind.ipv6, _ipv6);
      add(_Kind.ipv4, '$_ipv4$_ipv4Prefix$_ipv4End');
    }
    if (builtin.isNotEmpty) add(_Kind.builtinKeyword, _alternation(builtin));

    return KeywordHighlightMatcher._(
      List.unmodifiable(groups),
      parts.isEmpty ? null : RegExp(parts.join('|'), caseSensitive: false),
      kinds,
      _MatcherSlots(slots, addressSlot ?? -1, urlSlot ?? -1),
    );
  }

  /// The groups that can produce matches, indexed by the `slot` passed to a
  /// [KeywordMatchSink].
  final List<KeywordHighlightGroup> groups;
  final RegExp? _pattern;
  final List<_Kind> _kinds;
  final _MatcherSlots _slots;

  /// Whether nothing can ever match (the caller can skip all work).
  bool get isEmpty => _pattern == null;

  static const _word = '[A-Za-z0-9_]';
  static const _octet = r'(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)';
  static const _ipv4 = '(?:$_octet\\.){3}$_octet';
  static const _ipv4Prefix = r'(?:/(?:3[0-2]|[12]?\d))?';
  // Not the head of a longer dotted number (1.2.3.4.5) or of a word.
  static const _ipv4End = '(?!$_word|\\.\\d)';
  static const _hex = '[0-9a-f]';
  static const _mac =
      '(?:(?:$_hex{2}:){5}$_hex{2}|(?:$_hex{2}-){5}$_hex{2}'
      '|$_hex{4}\\.$_hex{4}\\.$_hex{4})(?!$_word|[:.-]$_hex)';
  static const _h = '$_hex{1,4}';
  // Every valid textual form: full, with one "::" and with an embedded IPv4.
  // Plain colon separated numbers such as 12:30:45 have no form here.
  static const _ipv6 =
      '(?:(?:$_h:){7}$_h'
      '|(?:$_h:){1,7}:'
      '|(?:$_h:){1,6}:$_h'
      '|(?:$_h:){1,5}(?::$_h){1,2}'
      '|(?:$_h:){1,4}(?::$_h){1,3}'
      '|(?:$_h:){1,3}(?::$_h){1,4}'
      '|(?:$_h:){1,2}(?::$_h){1,5}'
      '|$_h:(?::$_h){1,6}'
      '|::(?:ffff(?::0{1,4})?:)?$_ipv4'
      '|:(?::$_h){1,7})'
      r'(?:%[0-9a-z]{1,16})?(?:/(?:12[0-8]|1[01]\d|[1-9]?\d))?'
      '(?!$_word|:|\\.$_word)';
  // scheme://rest, without the punctuation that usually follows a link.
  static const _url =
      r'[a-z][a-z0-9+.\-]{1,15}://'
      r'''[^\s<>"'`]*[^\s<>"'`.,;:!?)\]}]''';

  static String _alternation(List<String> keywords) {
    final sorted = [...keywords]
      ..sort((a, b) {
        final byLength = b.length.compareTo(a.length);
        return byLength != 0 ? byLength : a.compareTo(b);
      });
    final out = StringBuffer();
    for (final keyword in sorted) {
      if (out.isNotEmpty) out.write('|');
      out.write(RegExp.escape(keyword).replaceAll(' ', ' +'));
      if (_isWordUnit(keyword.codeUnitAt(keyword.length - 1))) {
        out.write('(?!$_word)');
      }
    }
    return out.toString();
  }

  /// Reports every match in [text] to [sink], in order and never overlapping.
  void match(String text, KeywordMatchSink sink) {
    final pattern = _pattern;
    if (pattern == null) return;
    var position = 0;
    while (position < text.length) {
      final iterator = pattern.allMatches(text, position).iterator;
      if (!iterator.moveNext()) return;
      final match = iterator.current;
      final start = match.start;
      final slot = _accept(text, match);
      if (slot < 0) {
        // Starts inside a word, a number or a longer address: look again
        // from the next character.
        position = start + 1;
        continue;
      }
      sink(start, match.end, slot);
      position = match.end;
    }
  }

  /// The slot of [match], or -1 when its left side rules it out. (The left
  /// boundary is checked here rather than with a lookbehind, which older
  /// browser engines do not support.)
  int _accept(String text, RegExpMatch match) {
    var kind = _Kind.builtinKeyword;
    for (var i = 0; i < _kinds.length; i++) {
      if (match.group(i + 1) != null) {
        kind = _kinds[i];
        break;
      }
    }
    final start = match.start;
    final before = start == 0 ? 0x20 : text.codeUnitAt(start - 1);
    switch (kind) {
      case _Kind.customKeyword:
      case _Kind.builtinKeyword:
        if (_isWordUnit(text.codeUnitAt(start)) && _isWordUnit(before)) {
          return -1;
        }
        return _slots.keyword(text.substring(start, match.end));
      case _Kind.url:
        return _isWordUnit(before) ? -1 : _slots.url;
      case _Kind.ipv4:
        return _isWordUnit(before) || before == 0x2e ? -1 : _slots.address;
      case _Kind.mac:
        return _isWordUnit(before) ||
                before == 0x3a ||
                before == 0x2d ||
                before == 0x2e
            ? -1
            : _slots.address;
      case _Kind.ipv6:
        return _isWordUnit(before) || before == 0x3a || before == 0x2e
            ? -1
            : _slots.address;
    }
  }
}

class _MatcherSlots {
  _MatcherSlots(this._keywords, this.address, this.url);
  final Map<String, int> _keywords;
  final int address;
  final int url;

  static final _spaces = RegExp(' {2,}');

  int keyword(String matched) {
    var key = matched.toLowerCase();
    if (key.contains('  ')) key = key.replaceAll(_spaces, ' ');
    return _keywords[key] ?? -1;
  }
}
