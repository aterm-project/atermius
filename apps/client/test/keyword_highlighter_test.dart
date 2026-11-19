import 'dart:io';

import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/mcp/mcp_activity.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:aterm_client/storage/keyword_highlight_store.dart';
import 'package:aterm_client/storage/keyword_highlight_store_native.dart';
import 'package:aterm_client/terminal/keyword_highlighter.dart';
import 'package:aterm_client/ui/terminal_color_theme.dart';
import 'package:aterm_client/ui/terminal_palette.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

final _dark = buildTerminalColorTheme(VaultTerminalThemeChoice.atermDark);
final _light = buildTerminalColorTheme(VaultTerminalThemeChoice.light);

Terminal _terminal({int width = 80, int height = 24}) =>
    Terminal(maxLines: 5000)..resize(width, height);

/// Highlights of buffer row [row] as `(start column, end column, group id)`.
List<(int, int, String)> _spans(
  TerminalKeywordHighlighter highlighter,
  Terminal terminal,
  int row,
) => [
  for (final span
      in highlighter.spansFor(terminal.buffer.lines[row]) ??
          const <TerminalForegroundSpan>[])
    (span.start, span.end, highlighter.activeGroups[span.style].id),
];

void main() {
  group('cell columns', () {
    test('plain ASCII maps one to one', () {
      final highlighter = TerminalKeywordHighlighter();
      final terminal = _terminal()..write('an error at 10.0.0.1 ok');
      expect(_spans(highlighter, terminal, 0), [
        (3, 8, 'error'),
        (12, 20, 'address'),
        (21, 23, 'success'),
      ]);
      expect(highlighter.spansFor(terminal.buffer.lines[1]), isNull);
    });

    test('wide (CJK) characters take two cells', () {
      final highlighter = TerminalKeywordHighlighter();
      final terminal = _terminal()..write('中文 error 完成 done');
      // 中文 = columns 0..3, space, error = 5..9, space, 完成 = 11..14.
      expect(_spans(highlighter, terminal, 0), [
        (5, 10, 'error'),
        (16, 20, 'success'),
      ]);
      expect(terminal.buffer.lines[0].getText(5, 10), 'error');
      expect(terminal.buffer.lines[0].getText(16, 20), 'done');
    });

    test('a CJK keyword covers both cells of each character', () {
      final (settings, group) = KeywordHighlightSettings.defaults()
          .withNewGroup('中文')!;
      final highlighter = TerminalKeywordHighlighter(
        settings: settings.withGroup(group.copyWith(keywords: ['错误', '失败'])),
      );
      final terminal = _terminal()..write('a 发生错误: 失败');
      expect(_spans(highlighter, terminal, 0), [
        (6, 10, 'custom-1'),
        (12, 16, 'custom-1'),
      ]);
    });

    test('characters outside the BMP and combining marks', () {
      final highlighter = TerminalKeywordHighlighter();
      // U+1F600 is wide: two cells, two UTF-16 units, one character.
      final emoji = _terminal()..write('\u{1F600} error');
      expect(_spans(highlighter, emoji, 0), [(3, 8, 'error')]);
      // A combining acute takes a cell of its own in this buffer.
      final combining = _terminal()..write('é failed \u{1D11E} ok');
      final line = combining.buffer.lines[0];
      final spans = _spans(highlighter, combining, 0);
      expect(spans.map((span) => span.$3), ['error', 'success']);
      for (final (start, end, _) in spans) {
        expect(line.getText(start, end), anyOf('failed', 'ok'));
      }
    });

    test('cells skipped by cursor movement read as spaces', () {
      final highlighter = TerminalKeywordHighlighter();
      final terminal = _terminal()
        ..write('ok\x1b[5Cerror\x1b[3Ctimed\x1b[2Cout');
      expect(_spans(highlighter, terminal, 0), [
        (0, 2, 'success'),
        (7, 12, 'error'),
        (15, 25, 'warning'),
      ]);
    });

    test('a word cut by a soft wrap is never highlighted in part', () {
      final highlighter = TerminalKeywordHighlighter();
      // "failed" wraps after "fail"; "terror" wraps after "t".
      final terminal = _terminal(width: 10)
        ..write('12345 failed ok\r\n')
        ..write('123456789terror ok\r\n')
        ..write('1234 error\r\n')
        ..write('error ok');
      final lines = terminal.buffer.lines;
      expect(lines[0].getText(), '12345 fail');
      expect(lines[1].isWrapped, isTrue);
      expect(_spans(highlighter, terminal, 0), isEmpty);
      expect(_spans(highlighter, terminal, 1), [(3, 5, 'success')]);
      expect(lines[2].getText(), '123456789t');
      expect(lines[3].getText().trimRight(), 'error ok');
      expect(lines[3].isWrapped, isTrue);
      expect(_spans(highlighter, terminal, 2), isEmpty);
      // "error" at the start of the continuation row is really "terror".
      expect(_spans(highlighter, terminal, 3), [(6, 8, 'success')]);
      // A row filled to its last cell may continue: its last word is left.
      expect(lines[4].getText(), '1234 error');
      expect(_spans(highlighter, terminal, 4), isEmpty);
      // The same word on a row of its own is highlighted.
      expect(lines[5].isWrapped, isFalse);
      expect(_spans(highlighter, terminal, 5), [
        (0, 5, 'error'),
        (6, 8, 'success'),
      ]);
    });

    test('only the first cells of a very long line are analysed', () {
      const cap = TerminalKeywordHighlighter.maxAnalysedCells;
      final highlighter = TerminalKeywordHighlighter();
      final terminal = _terminal(width: 700)..write('error ' * 110);
      final spans = _spans(highlighter, terminal, 0);
      expect(spans, isNotEmpty);
      expect(spans.first, (0, 5, 'error'));
      expect(spans.every((span) => span.$2 <= cap), isTrue);
      // 85 whole words fit in 512 cells; the one cut by the limit is left.
      expect(spans, hasLength(85));
      expect(spans.last, (504, 509, 'error'));

      // A word that ends exactly at the limit could be longer: left alone.
      final cut = _terminal(width: 700)
        ..write('${' ' * (cap - 5)}errors and more text after the limit');
      expect(_spans(highlighter, cut, 0), isEmpty);
    });
  });

  group('cache', () {
    test('a line is analysed once, by content', () {
      final highlighter = TerminalKeywordHighlighter();
      final terminal = _terminal();
      for (var i = 0; i < 20; i++) {
        terminal.write('request failed: connection refused\r\n');
      }
      terminal.write('all good\r\n');
      for (var pass = 0; pass < 50; pass++) {
        for (var row = 0; row < 24; row++) {
          highlighter.spansFor(terminal.buffer.lines[row]);
        }
      }
      // Two distinct contents; empty rows are not even looked up.
      expect(highlighter.debugAnalysedLines, 2);
      expect(highlighter.debugCachedLines, 2);
      final first = highlighter.spansFor(terminal.buffer.lines[0]);
      expect(highlighter.spansFor(terminal.buffer.lines[7]), same(first));

      // Changed content is analysed again; the old result is not reused.
      terminal.write('\x1b[1;1Hrequest passed: connection refused');
      expect(_spans(highlighter, terminal, 0).first, (8, 14, 'success'));
      expect(highlighter.debugAnalysedLines, 3);
    });

    test('is bounded and keeps recently used lines', () {
      const limit = TerminalKeywordHighlighter.maxCachedLines;
      final highlighter = TerminalKeywordHighlighter();
      final terminal = _terminal(height: 4);
      for (var i = 0; i < limit + 500; i++) {
        terminal.write('line $i failed\r\n');
      }
      final lines = terminal.buffer.lines;
      highlighter.spansFor(lines[0]);
      for (var row = 1; row < lines.length; row++) {
        highlighter.spansFor(lines[row]);
        // Keep the first line in use while the cache overflows.
        if (row % 100 == 0) highlighter.spansFor(lines[0]);
      }
      expect(highlighter.debugCachedLines, limit);
      final analysed = highlighter.debugAnalysedLines;
      highlighter.spansFor(lines[0]);
      highlighter.spansFor(lines[lines.length - 2]);
      expect(highlighter.debugAnalysedLines, analysed);
      // The oldest unused line was dropped and is analysed again.
      highlighter.spansFor(lines[1]);
      expect(highlighter.debugAnalysedLines, analysed + 1);
      expect(highlighter.debugCachedLines, limit);
    });

    test('a settings change drops cached results and notifies views', () async {
      final highlighter = TerminalKeywordHighlighter();
      final terminal = _terminal()..write('error ok');
      var notifications = 0;
      highlighter.addListener(() => notifications++);
      expect(_spans(highlighter, terminal, 0), hasLength(2));

      await highlighter.setGroupEnabled('error', false);
      expect(notifications, 1);
      expect(highlighter.debugCachedLines, 0);
      expect(_spans(highlighter, terminal, 0), [(6, 8, 'success')]);

      expect(highlighter.addKeyword('success', 'Good'), KeywordAddResult.added);
      expect(
        highlighter.addKeyword('success', ' GOOD '),
        KeywordAddResult.duplicate,
      );
      expect(highlighter.addKeyword('success', '  '), KeywordAddResult.invalid);
      expect(highlighter.addKeyword('url', 'x'), KeywordAddResult.invalid);
      terminal.write(' good');
      expect(_spans(highlighter, terminal, 0), [
        (6, 8, 'success'),
        (9, 13, 'success'),
      ]);
      await highlighter.removeKeyword('success', 'ok');
      expect(_spans(highlighter, terminal, 0), [(9, 13, 'success')]);

      // Unchanged settings do nothing.
      final before = notifications;
      await highlighter.setGroupEnabled('error', false);
      expect(notifications, before);

      await highlighter.restoreDefaults();
      expect(highlighter.settings.isDefault, isTrue);
      expect(_spans(highlighter, terminal, 0), hasLength(2));
    });

    test('a group takes at most the allowed number of keywords', () {
      final highlighter = TerminalKeywordHighlighter();
      final id = highlighter.addGroup('  Mine ')!;
      expect(highlighter.settings.group(id)!.name, 'Mine');
      for (var i = 0; i < KeywordHighlightLimits.maxKeywordsPerGroup; i++) {
        expect(highlighter.addKeyword(id, 'word$i'), KeywordAddResult.added);
      }
      expect(highlighter.addKeyword(id, 'one more'), KeywordAddResult.full);
      for (var i = 1; i < KeywordHighlightLimits.maxCustomGroups; i++) {
        expect(highlighter.addGroup('g$i'), isNotNull);
      }
      expect(highlighter.addGroup('too many'), isNull);
      expect(highlighter.addGroup('   '), isNull);
    });
  });

  group('when a paint is decorated', () {
    test('never in the alternate screen, never when switched off', () async {
      final highlighter = TerminalKeywordHighlighter();
      final terminal = _terminal()..write('error');
      expect(highlighter.beginPaint(terminal, _dark), isNotNull);

      terminal.write('\x1b[?1049h');
      expect(terminal.isUsingAltBuffer, isTrue);
      expect(highlighter.beginPaint(terminal, _dark), isNull);
      terminal.write('\x1b[?1049l');
      expect(highlighter.beginPaint(terminal, _dark), isNotNull);

      await highlighter.setEnabled(false);
      expect(highlighter.beginPaint(terminal, _dark), isNull);
      await highlighter.setEnabled(true);
      for (final group in highlighter.settings.groups) {
        await highlighter.setGroupEnabled(group.id, false);
      }
      expect(highlighter.beginPaint(terminal, _dark), isNull);
    });

    test('styles are resolved once per theme and settings revision', () async {
      final highlighter = TerminalKeywordHighlighter();
      final terminal = _terminal();
      final dark = highlighter.beginPaint(terminal, _dark)!;
      expect(highlighter.beginPaint(terminal, _dark), same(dark));
      expect(dark, hasLength(highlighter.activeGroups.length));
      final light = highlighter.beginPaint(terminal, _light)!;
      expect(light, isNot(same(dark)));
      await highlighter.setGroupColor('error', KeywordHighlightColor.blue);
      final recolored = highlighter.beginPaint(terminal, _dark)!;
      expect(recolored, isNot(same(dark)));
      final slot = highlighter.activeGroups.indexWhere((g) => g.id == 'error');
      expect(
        recolored[slot].foreground,
        const TerminalForegroundStyle.ansi(4).foreground,
      );
    });

    test('the dimmed [MCP] activity lines are explicitly colored', () {
      final highlighter = TerminalKeywordHighlighter();
      final terminal = _terminal();
      McpActivity.show(
        _session(terminal),
        'ssh_exec',
        detail: 'ping 10.0.0.1',
        output: 'error: connection refused\n',
      );
      final lines = terminal.buffer.lines;
      final row = [
        for (var i = 0; i < lines.length; i++)
          if (lines[i].getText().startsWith('[MCP]')) i,
      ].single;
      // The text would match, but none of its cells is plain, so the painter
      // skips every span (see TerminalForegroundDecorator).
      final spans = highlighter.spansFor(lines[row])!;
      expect(spans, isNotEmpty);
      for (final span in spans) {
        expect(
          terminalCellsArePlain(lines[row], span.start, span.end),
          isFalse,
        );
      }
      final echoed = highlighter.spansFor(lines[row + 1])!;
      expect(lines[row + 1].getText(), contains('error: connection refused'));
      for (final span in echoed) {
        expect(
          terminalCellsArePlain(lines[row + 1], span.start, span.end),
          isFalse,
        );
      }
    });
  });

  group('colors follow the terminal palette', () {
    KeywordHighlightAppearance look(
      TerminalTheme theme,
      KeywordHighlightColor color,
    ) => TerminalKeywordHighlighter.appearanceOf(theme, color);

    test('built-in palettes use their own ANSI colors', () {
      for (final theme in [_dark, _light]) {
        for (final color in KeywordHighlightColor.values) {
          final appearance = look(theme, color);
          // 只会在同色相的普通 / 高亮两档之间取舍，且颜色与所选 ANSI 槽位一致。
          expect(
            appearance.ansi,
            anyOf(color.ansi, color.ansi + 8),
            reason: color.id,
          );
          expect(appearance.color, terminalAnsiColor(theme, appearance.ansi));
        }
      }
      for (final color in KeywordHighlightColor.values) {
        if (color == KeywordHighlightColor.green) continue;
        expect(look(_dark, color).ansi, color.ansi, reason: color.id);
        expect(look(_light, color).ansi, color.ansi, reason: color.id);
      }
      // Atermius Dark 默认前景为绿色（806ab78 起为 #21B568）：普通绿与正文难以区分，
      // 因此改用可读且可区分的高亮绿，无需再靠加粗区分。
      final darkGreen = look(_dark, KeywordHighlightColor.green);
      expect(darkGreen.ansi, KeywordHighlightColor.green.ansi + 8);
      expect(darkGreen.bold, isFalse);
      expect(
        look(_light, KeywordHighlightColor.green).ansi,
        KeywordHighlightColor.green.ansi,
      );
      expect(look(_dark, KeywordHighlightColor.red).bold, isFalse);
      expect(look(_dark, KeywordHighlightColor.yellow).bold, isFalse);
      for (final color in KeywordHighlightColor.values) {
        expect(look(_light, color).bold, isFalse, reason: color.id);
      }
    });

    test('a hard to read normal color gives way to its bright variant', () {
      final material = terminalPalettePresets['material-dark']!.toTheme();
      expect(look(material, KeywordHighlightColor.blue).ansi, 12);
      expect(look(material, KeywordHighlightColor.magenta).ansi, 13);
      expect(look(material, KeywordHighlightColor.green).ansi, 10);
      expect(look(material, KeywordHighlightColor.red).ansi, anyOf(1, 9));
      // Solarized uses the bright slots for grays: the hue is kept instead.
      final solarized = terminalPalettePresets['solarized-light']!.toTheme();
      expect(look(solarized, KeywordHighlightColor.green).ansi, 2);
      expect(look(solarized, KeywordHighlightColor.yellow).ansi, 3);
    });

    test('every preset palette resolves every color', () {
      for (final spec in terminalPalettePresets.values) {
        final theme = spec.toTheme();
        for (final color in KeywordHighlightColor.values) {
          final appearance = look(theme, color);
          expect(
            appearance.ansi,
            anyOf(color.ansi, color.ansi + 8),
            reason: '${spec.id} ${color.id}',
          );
          expect(appearance.color, terminalAnsiColor(theme, appearance.ansi));
        }
      }
    });
  });

  group('persistence', () {
    test('loads a stored document and survives a bad one', () async {
      final custom = KeywordHighlightSettings.defaults().copyWith(
        enabled: false,
      );
      final highlighter = TerminalKeywordHighlighter();
      await highlighter.load(MemoryKeywordHighlightStore(custom.encode()));
      expect(highlighter.settings, custom);

      for (final document in [null, 'garbage', '{"v":9}']) {
        final store = MemoryKeywordHighlightStore(document);
        final other = TerminalKeywordHighlighter();
        await other.load(store);
        expect(other.settings.isDefault, isTrue);
        // A document this version cannot read is not overwritten on load.
        expect(store.writes, 0);
        expect(store.value, document);
      }

      final failing = TerminalKeywordHighlighter();
      await failing.load(_ThrowingStore());
      expect(failing.settings.isDefault, isTrue);
    });

    test('changes are written, the defaults are stored as nothing', () async {
      final store = MemoryKeywordHighlightStore();
      final highlighter = TerminalKeywordHighlighter();
      await highlighter.load(store);
      await highlighter.setGroupColor('info', KeywordHighlightColor.blue);
      expect(store.writes, 1);
      expect(
        KeywordHighlightSettings.decode(store.value)!.group('info')!.color,
        KeywordHighlightColor.blue,
      );

      // A burst of changes is coalesced; the last one is what is stored.
      final pending = [
        highlighter.setEnabled(false),
        highlighter.setEnabled(true),
        highlighter.setGroupEnabled('url', false),
      ];
      await Future.wait(pending);
      expect(store.writes, 2);
      expect(
        KeywordHighlightSettings.decode(store.value),
        highlighter.settings,
      );

      final reloaded = TerminalKeywordHighlighter();
      await reloaded.load(store);
      expect(reloaded.settings, highlighter.settings);

      await highlighter.restoreDefaults();
      expect(store.value, isNull);
    });

    test('a failed write is reported and the change still applies', () async {
      final store = MemoryKeywordHighlightStore()
        ..failWith = StateError('full');
      final highlighter = TerminalKeywordHighlighter();
      await highlighter.load(store);
      await highlighter.setEnabled(false);
      expect(highlighter.settings.enabled, isFalse);
      expect(highlighter.writeFailed, isTrue);
      store.failWith = null;
      await highlighter.setEnabled(true);
      expect(highlighter.writeFailed, isFalse);
    });

    test('the file store round-trips and ignores an oversized file', () async {
      final directory = await Directory.systemTemp.createTemp('kw-highlight-');
      addTearDown(() => directory.delete(recursive: true));
      final store = FileKeywordHighlightStore(directory: () async => directory);
      expect(await store.read(), isNull);

      final highlighter = TerminalKeywordHighlighter();
      await highlighter.load(store);
      final id = highlighter.addGroup('网络')!;
      highlighter.addKeyword(id, 'BGP 邻居');
      await highlighter.setGroupColor(id, KeywordHighlightColor.yellow);
      final file = File('${directory.path}/terminal-keyword-highlight-v1');
      expect(file.existsSync(), isTrue);
      expect(directory.listSync(), hasLength(1));

      final reloaded = TerminalKeywordHighlighter();
      await reloaded.load(store);
      expect(reloaded.settings, highlighter.settings);
      expect(reloaded.settings.group(id)!.keywords, ['bgp 邻居']);

      await highlighter.restoreDefaults();
      expect(file.existsSync(), isFalse);

      file.writeAsStringSync('x' * (4 * KeywordHighlightStore.maxLength));
      expect(await store.read(), isNull);
      final afterOversized = TerminalKeywordHighlighter();
      await afterOversized.load(store);
      expect(afterOversized.settings.isDefault, isTrue);
      await expectLater(
        store.write('y' * (KeywordHighlightStore.maxLength + 1)),
        throwsArgumentError,
      );
    });
  });
}

class _ThrowingStore implements KeywordHighlightStore {
  @override
  Future<String?> read() async => throw const FileSystemException('denied');

  @override
  Future<void> write(String? document) async {}
}

McpSession _session(Terminal terminal) => McpSession(
  id: 's1',
  name: 'test',
  kind: 'ssh',
  state: 'connected',
  isAlive: () => true,
  focus: () {},
  close: () async {},
  input: (_) {},
  terminal: terminal,
);
