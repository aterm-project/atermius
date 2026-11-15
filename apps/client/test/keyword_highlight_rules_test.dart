import 'dart:convert';

import 'package:aterm_client/terminal/keyword_highlight_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every match in [text] as `(matched text, group id)`.
List<(String, String)> matchesIn(
  String text, [
  KeywordHighlightSettings? settings,
]) {
  final matcher = KeywordHighlightMatcher.compile(
    settings ?? KeywordHighlightSettings.defaults(),
  );
  final found = <(String, String)>[];
  var previousEnd = 0;
  matcher.match(text, (start, end, slot) {
    expect(start, greaterThanOrEqualTo(previousEnd), reason: 'overlap');
    expect(end, greaterThan(start));
    previousEnd = end;
    found.add((text.substring(start, end), matcher.groups[slot].id));
  });
  return found;
}

List<String> textsIn(String text, [KeywordHighlightSettings? settings]) => [
  for (final match in matchesIn(text, settings)) match.$1,
];

KeywordHighlightSettings withCustom(
  String name,
  List<String> keywords, {
  KeywordHighlightSettings? base,
}) {
  final (settings, group) = (base ?? KeywordHighlightSettings.defaults())
      .withNewGroup(name)!;
  return settings.withGroup(group.copyWith(keywords: keywords));
}

void main() {
  group('keywords', () {
    test('match whole words only', () {
      expect(
        textsIn('terror book token okay errors_x error2 xerror failedx'),
        isEmpty,
      );
      expect(matchesIn('an error.'), [('error', 'error')]);
      expect(matchesIn('[OK] done'), [('OK', 'success'), ('done', 'success')]);
      expect(textsIn('error: x'), ['error']);
      expect(textsIn('(failed)'), ['failed']);
      // Punctuation, including a hyphen, ends a word; an underscore does not.
      expect(textsIn('error-prone'), ['error']);
      expect(textsIn('error_code'), isEmpty);
      expect(textsIn('up-to-date'), ['up']);
    });

    test('are case-insensitive', () {
      expect(matchesIn('ERROR Error eRRoR Warning INFO'), [
        ('ERROR', 'error'),
        ('Error', 'error'),
        ('eRRoR', 'error'),
        ('Warning', 'warning'),
        ('INFO', 'info'),
      ]);
    });

    test('phrases match as one, with any number of spaces', () {
      expect(matchesIn('ls: x: No such file or directory'), [
        ('No such file', 'error'),
      ]);
      expect(textsIn('no   such  file'), ['no   such  file']);
      expect(matchesIn('command not found'), [('not found', 'error')]);
      expect(matchesIn('connect timed out'), [('timed out', 'warning')]);
      expect(matchesIn('Segmentation fault (core dumped)'), [
        ('Segmentation fault', 'error'),
        ('core dumped', 'error'),
      ]);
      // The longer phrase wins over the word it starts with.
      expect(matchesIn('Active: active (running) since'), [
        ('Active', 'success'),
        ('active (running)', 'success'),
      ]);
      expect(textsIn('no such filesystem'), isEmpty);
    });

    test('built-in groups cover the usual log vocabulary', () {
      String? groupOf(String word) => matchesIn(word).singleOrNull?.$2;
      for (final word in [
        'error',
        'errors',
        'fail',
        'failed',
        'failure',
        'fatal',
        'critical',
        'denied',
        'refused',
        'exception',
        'panic',
        'unreachable',
        'segfault',
      ]) {
        expect(groupOf(word), 'error', reason: word);
      }
      for (final word in [
        'warn',
        'warning',
        'deprecated',
        'timeout',
        'retry',
      ]) {
        expect(groupOf(word), 'warning', reason: word);
      }
      for (final word in [
        'ok',
        'success',
        'successful',
        'succeeded',
        'done',
        'passed',
        'complete',
        'completed',
        'enabled',
        'connected',
        'up',
      ]) {
        expect(groupOf(word), 'success', reason: word);
      }
      for (final word in ['info', 'notice', 'debug']) {
        expect(groupOf(word), 'info', reason: word);
      }
      // Everyday words stay plain.
      expect(
        textsIn('yes no on off new old true false the is in to of'),
        isEmpty,
      );
    });

    test('custom keywords may be CJK, symbols or regex metacharacters', () {
      final settings = withCustom('mine', [
        '错误',
        'c++',
        'a.b',
        '[fail]',
        r'$?',
      ]);
      expect(matchesIn('发生错误了', settings), [('错误', 'custom-1')]);
      expect(textsIn('use c++ here', settings), ['c++']);
      expect(textsIn('axb a.b', settings), ['a.b']);
      expect(textsIn('x[FAIL]y', settings), ['[FAIL]']);
      expect(textsIn(r'echo $?', settings), [r'$?']);
    });
  });

  group('addresses', () {
    test('IPv4 addresses, with an optional prefix length', () {
      for (final address in [
        '10.0.0.1',
        '192.168.1.254',
        '255.255.255.255',
        '0.0.0.0',
        '172.16.0.0/12',
        '10.1.2.3/32',
      ]) {
        expect(matchesIn('from $address port'), [(address, 'address')]);
      }
      expect(textsIn('10.0.0.1:8080'), ['10.0.0.1']);
      expect(textsIn('(10.0.0.1).'), ['10.0.0.1']);
      expect(textsIn('10.0.0.1-10.0.0.9'), ['10.0.0.1', '10.0.0.9']);
    });

    test('numbers that only look like IPv4 are left alone', () {
      for (final text in [
        'version 1.2.3',
        'v1.2.3.4',
        '1.2.3.4.5',
        '256.1.1.1',
        '1.2.3.999',
        '01.02.03.04',
        '3.14',
        '12:30:45',
        '2026-11-15',
        'Python 3.11.2',
        'x1.2.3.4',
        '1.2.3.4x',
        '5.10.0-28-amd64',
      ]) {
        expect(textsIn(text), isEmpty, reason: text);
      }
    });

    test('IPv6 addresses in every textual form', () {
      for (final address in [
        '::1',
        'fe80::1',
        'fe80::1%eth0',
        '2001:db8::ff00:42:8329',
        '2001:0db8:85a3:0000:0000:8a2e:0370:7334',
        '2001:db8::/32',
        '2001:db8:1::',
        '::ffff:192.168.1.1',
        'FE80::AB:1',
      ]) {
        expect(matchesIn('addr $address x'), [(address, 'address')]);
      }
      expect(textsIn('[::1]:8080'), ['::1']);
      expect(textsIn('inet6 fe80::1/64 scope link'), ['fe80::1/64']);
      expect(textsIn('ends with 2001:db8::1.'), ['2001:db8::1']);
    });

    test('colon separated text that is not IPv6 is left alone', () {
      for (final text in [
        '12:30:45',
        '00:11:22',
        '10:20',
        'std::string',
        'Foo::Bar',
        'File::Find::name',
        '::',
        'a:b:c',
        '1:2:3:4:5:6:7',
        'key:value',
        '2026-11-15T12:30:45.123Z',
      ]) {
        expect(textsIn(text), isEmpty, reason: text);
      }
    });

    test('MAC addresses in the three usual notations', () {
      for (final address in [
        '00:1a:2B:3c:4D:5e',
        '00-1A-2B-3C-4D-5E',
        '001a.2b3c.4d5e',
      ]) {
        expect(matchesIn('ether $address txqueuelen'), [(address, 'address')]);
      }
      for (final text in [
        '00:1a:2b:3c:4d',
        '00:1a:2b:3c:4d:5e:6f',
        '00:1a:2b:3c:4d:5g',
        'x00:1a:2b:3c:4d:5e',
        '001a.2b3c',
      ]) {
        expect(textsIn(text), isEmpty, reason: text);
      }
    });
  });

  group('links', () {
    test('scheme://… up to whitespace, without trailing punctuation', () {
      expect(matchesIn('see https://example.com/a?b=c#d now'), [
        ('https://example.com/a?b=c#d', 'url'),
      ]);
      expect(textsIn('(http://x.y/z).'), ['http://x.y/z']);
      expect(textsIn('ssh://user@host:22, then'), ['ssh://user@host:22']);
      expect(textsIn('<ftp://h/f>'), ['ftp://h/f']);
      expect(textsIn('"s3://bucket/key"'), ['s3://bucket/key']);
      expect(textsIn('HTTPS://EXAMPLE.COM'), ['HTTPS://EXAMPLE.COM']);
    });

    test('things that are not links', () {
      for (final text in ['http:/x', 'a://b', '://x', 'http://', 'x https:']) {
        expect(textsIn(text), isEmpty, reason: text);
      }
    });
  });

  group('overlapping rules', () {
    test('a link is one match even when it contains other rules', () {
      expect(matchesIn('GET http://10.0.0.1/error/failed ok'), [
        ('http://10.0.0.1/error/failed', 'url'),
        ('ok', 'success'),
      ]);
    });

    test('the match that starts first wins', () {
      final settings = withCustom('mine', ['refused by peer']);
      expect(matchesIn('connection refused by peer', settings), [
        ('refused by peer', 'custom-1'),
      ]);
      // "not found" starts before the custom "found".
      expect(matchesIn('not found', withCustom('mine', ['found'])), [
        ('not found', 'error'),
      ]);
    });

    test('custom groups win over built-in groups and patterns', () {
      expect(matchesIn('error', withCustom('mine', ['error'])), [
        ('error', 'custom-1'),
      ]);
      expect(matchesIn('at 10.0.0.1', withCustom('mine', ['10.0.0.1'])), [
        ('10.0.0.1', 'custom-1'),
      ]);
      // The same keyword in two custom groups: the first group keeps it.
      final two = withCustom('second', [
        'beta',
      ], base: withCustom('first', ['beta']));
      expect(matchesIn('beta', two), [('beta', 'custom-1')]);
    });

    test('switched-off groups and the master switch', () {
      final defaults = KeywordHighlightSettings.defaults();
      final noErrors = defaults.withGroup(
        defaults.group('error')!.copyWith(enabled: false),
      );
      expect(matchesIn('error warning 10.0.0.1', noErrors), [
        ('warning', 'warning'),
        ('10.0.0.1', 'address'),
      ]);
      final noAddresses = defaults.withGroup(
        defaults.group('address')!.copyWith(enabled: false),
      );
      expect(textsIn('error 10.0.0.1 ::1', noAddresses), ['error']);
      final off = KeywordHighlightMatcher.compile(
        defaults.copyWith(enabled: false),
      );
      expect(off.isEmpty, isTrue);
      expect(off.groups, isEmpty);
      off.match('error', (_, _, _) => fail('disabled'));
    });
  });

  group('stored document', () {
    test('defaults round-trip and keep built-in lists out of the file', () {
      final defaults = KeywordHighlightSettings.defaults();
      expect(defaults.isDefault, isTrue);
      expect(defaults.enabled, isTrue);
      expect(defaults.groups.map((group) => group.id), [
        'error',
        'warning',
        'success',
        'info',
        'address',
        'url',
      ]);
      expect(defaults.groups.every((group) => group.enabled), isTrue);
      final document = defaults.encode();
      expect(document, isNot(contains('keywords')));
      expect(KeywordHighlightSettings.decode(document), defaults);
    });

    test('customized settings round-trip', () {
      var settings = KeywordHighlightSettings.defaults().copyWith(
        enabled: false,
      );
      final error = settings.group('error')!;
      settings = settings.withGroup(
        error.copyWith(
          color: KeywordHighlightColor.magenta,
          keywords: [...error.keywords.skip(2), 'oops'],
        ),
      );
      settings = settings.withGroup(
        settings.group('url')!.copyWith(enabled: false),
      );
      settings = withCustom('My group', ['bgp', 'link flap'], base: settings);
      final decoded = KeywordHighlightSettings.decode(settings.encode())!;
      expect(decoded, settings);
      expect(decoded.isDefault, isFalse);
      expect(decoded.group('custom-1')!.name, 'My group');
      expect(decoded.group('error')!.keywords, contains('oops'));
      expect(decoded.group('error')!.keywords, isNot(contains('error')));
    });

    test('anything but a version 1 document is rejected', () {
      for (final source in [
        null,
        '',
        'x',
        '[]',
        '42',
        '{}',
        '{"v":2,"enabled":true,"groups":[]}',
        '{"v":1,"enabled":"yes","groups":[]}',
        '{"v":1,"enabled":true,"groups":{}}',
        '{"v":1,"enabled":true',
      ]) {
        expect(KeywordHighlightSettings.decode(source), isNull, reason: source);
      }
      final huge = jsonEncode({
        'v': 1,
        'enabled': true,
        'groups': [],
        'pad': 'x' * KeywordHighlightLimits.maxStoredLength,
      });
      expect(KeywordHighlightSettings.decode(huge), isNull);
    });

    test('malformed entries are dropped and everything is clamped', () {
      final decoded = KeywordHighlightSettings.decode(
        jsonEncode({
          'v': 1,
          'enabled': true,
          'unknown': {'ignored': true},
          'groups': [
            'nonsense',
            {'id': 7},
            {
              'id': 'no-such-builtin',
              'keywords': ['x'],
            },
            {
              'id': 'error',
              'enabled': 'no',
              'color': 'ultraviolet',
              'keywords': [
                '  Mixed   CASE  ',
                'mixed case',
                '',
                '   ',
                42,
                null,
                'tab\tand\nnewline',
                'ctrl\u0001\u007fchar',
                'x' * (KeywordHighlightLimits.maxKeywordLength + 1),
                'lone\ud800surrogate',
              ],
            },
            {
              'id': 'error',
              'keywords': ['second entry is ignored'],
            },
            {
              'id': 'address',
              'color': 'green',
              'keywords': ['ignored'],
            },
            {'id': 'custom-1', 'name': '  Spaced\n name ', 'color': 'cyan'},
            {'id': 'custom-1', 'name': 'duplicate id'},
            {'id': 'custom-x', 'name': 'bad id'},
            {'id': 'custom-2'},
            {'id': 'custom-3', 'name': ''},
            {
              'id': 'custom-4',
              'name': 'n' * (KeywordHighlightLimits.maxGroupNameLength + 1),
            },
            {
              'id': 'custom-5',
              'name': 'many',
              'keywords': [for (var i = 0; i < 200; i++) 'kw$i'],
            },
          ],
        }),
      )!;
      final error = decoded.group('error')!;
      expect(error.enabled, isTrue);
      expect(error.color, KeywordHighlightColor.red);
      expect(error.keywords, [
        'mixed case',
        'tab and newline',
        'ctrlchar',
        'lonesurrogate',
      ]);
      // Missing built-in groups come back with their defaults.
      expect(
        decoded.group('warning'),
        KeywordHighlightGroup.builtin(KeywordHighlightBuiltin.warning),
      );
      final address = decoded.group('address')!;
      expect(address.color, KeywordHighlightColor.green);
      expect(address.keywords, isEmpty);
      expect(decoded.customGroups.map((group) => group.id), [
        'custom-1',
        'custom-5',
      ]);
      expect(decoded.group('custom-1')!.name, 'Spaced name');
      expect(decoded.group('custom-1')!.color, KeywordHighlightColor.cyan);
      expect(
        decoded.group('custom-5')!.keywords,
        hasLength(KeywordHighlightLimits.maxKeywordsPerGroup),
      );
      // What was kept survives another round trip unchanged.
      expect(KeywordHighlightSettings.decode(decoded.encode()), decoded);
    });

    test('no more custom groups than the limit', () {
      final decoded = KeywordHighlightSettings.decode(
        jsonEncode({
          'v': 1,
          'enabled': true,
          'groups': [
            for (var i = 1; i <= 30; i++) {'id': 'custom-$i', 'name': 'g$i'},
          ],
        }),
      )!;
      expect(
        decoded.customGroups,
        hasLength(KeywordHighlightLimits.maxCustomGroups),
      );
      expect(decoded.withNewGroup('one more'), isNull);
      // The largest document the model can produce fits the store limit.
      var largest = decoded;
      final keywords = [
        for (var i = 0; i < KeywordHighlightLimits.maxKeywordsPerGroup; i++)
          '${'错' * (KeywordHighlightLimits.maxKeywordLength - 3)}'
              '${i.toString().padLeft(3, '0')}',
      ];
      for (final group in decoded.groups) {
        if (!group.isPattern) {
          largest = largest.withGroup(group.copyWith(keywords: keywords));
        }
      }
      final document = largest.encode();
      expect(document.length, lessThan(KeywordHighlightLimits.maxStoredLength));
      expect(KeywordHighlightSettings.decode(document), largest);
    });

    test('typed keywords and group names are normalized', () {
      expect(normalizeHighlightKeyword('  Link   DOWN '), 'link down');
      expect(normalizeHighlightKeyword(' \t '), isNull);
      expect(
        normalizeHighlightKeyword(
          'x' * (KeywordHighlightLimits.maxKeywordLength + 1),
        ),
        isNull,
      );
      expect(normalizeHighlightGroupName('  My  Group '), 'My Group');
      expect(normalizeHighlightGroupName(''), isNull);
    });
  });
}
