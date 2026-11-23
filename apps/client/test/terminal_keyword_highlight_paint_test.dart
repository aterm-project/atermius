import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/terminal/keyword_highlighter.dart';
import 'package:aterm_client/ui/terminal_color_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

// The test font draws (almost) every glyph as a filled box in the text color
// ("p" is the exception: a box below the baseline), so the
// pixel in the middle of a cell is exactly that cell's foreground color.

final _dark = buildTerminalColorTheme(VaultTerminalThemeChoice.atermDark);
final _light = buildTerminalColorTheme(VaultTerminalThemeChoice.light);

Color _rule(TerminalTheme theme, KeywordHighlightColor color) =>
    TerminalKeywordHighlighter.appearanceOf(theme, color).color;

class _Shot {
  _Shot(this._pixels, this._width, this.cell);
  final ByteData _pixels;
  final int _width;
  final Size cell;

  /// The color in the middle of the cell at [column], [row].
  Color at(int column, int row) {
    final x = (column * cell.width + cell.width / 2).floor();
    final y = (row * cell.height + cell.height / 2).floor();
    final offset = (y * _width + x) * 4;
    return Color.fromARGB(
      _pixels.getUint8(offset + 3),
      _pixels.getUint8(offset),
      _pixels.getUint8(offset + 1),
      _pixels.getUint8(offset + 2),
    );
  }

  List<Color> row(int row, int from, int to) => [
    for (var column = from; column < to; column++) at(column, row),
  ];
}

class _View {
  _View({TerminalKeywordHighlighter? highlighter})
    : highlighter = highlighter ?? TerminalKeywordHighlighter();

  final terminal = Terminal(maxLines: 2000);
  final controller = TerminalController();
  final TerminalKeywordHighlighter highlighter;
  final _boundary = GlobalKey();

  Future<void> pump(
    WidgetTester tester, {
    TerminalTheme? theme,
    bool decorate = true,
    TerminalForegroundDecorator? decorator,
    bool autofocus = false,
  }) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: _boundary,
          child: TerminalView(
            terminal,
            controller: controller,
            theme: theme ?? _dark,
            padding: EdgeInsets.zero,
            autofocus: autofocus,
            textStyle: const TerminalStyle(fontSize: 20),
            foregroundDecorator: decorate ? decorator ?? highlighter : null,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  RenderTerminal render(WidgetTester tester) =>
      tester.state<TerminalViewState>(find.byType(TerminalView)).renderTerminal;

  Future<_Shot> shot(WidgetTester tester) async {
    await tester.pump();
    final cell = render(tester).cellSize;
    final boundary =
        _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    late _Shot result;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      result = _Shot(data!, image.width, cell);
      image.dispose();
    });
    return result;
  }

  CellAnchor anchor(int column, int row) =>
      terminal.buffer.createAnchorFromOffset(CellOffset(column, row));
}

/// Counts what the view asks of the decorator it wraps.
class _Counting implements TerminalForegroundDecorator {
  _Counting(this.inner);
  final TerminalKeywordHighlighter inner;
  int paints = 0;
  int lookups = 0;

  @override
  List<TerminalForegroundStyle>? beginPaint(
    Terminal terminal,
    TerminalTheme theme,
  ) {
    paints++;
    return inner.beginPaint(terminal, theme);
  }

  @override
  List<TerminalForegroundSpan>? spansFor(BufferLine line) {
    lookups++;
    return inner.spansFor(line);
  }

  @override
  void addListener(VoidCallback listener) => inner.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => inner.removeListener(listener);
}

void main() {
  testWidgets('plain matching text is drawn in the color of its rule', (
    tester,
  ) async {
    for (final theme in [_dark, _light]) {
      final view = _View()
        ..terminal.write('an error ok 10.0.0.1 at ssh://a.bc x');
      await view.pump(tester, theme: theme);
      final shot = await view.shot(tester);
      final red = _rule(theme, KeywordHighlightColor.red);
      final green = _rule(theme, KeywordHighlightColor.green);
      final magenta = _rule(theme, KeywordHighlightColor.magenta);
      final blue = _rule(theme, KeywordHighlightColor.blue);
      expect(shot.row(0, 0, 2), everyElement(theme.foreground));
      expect(shot.at(2, 0), theme.background);
      expect(shot.row(0, 3, 8), everyElement(red));
      expect(shot.row(0, 9, 11), everyElement(green));
      expect(shot.row(0, 12, 20), everyElement(magenta));
      expect(shot.row(0, 21, 23), everyElement(theme.foreground));
      expect(shot.row(0, 24, 34), everyElement(blue));
      expect(shot.at(35, 0), theme.foreground);

      // Without the hook the same buffer is all default text.
      await view.pump(tester, theme: theme, decorate: false);
      final plain = await view.shot(tester);
      for (final column in [0, 3, 7, 9, 12, 19, 24, 33, 35]) {
        expect(plain.at(column, 0), theme.foreground, reason: '$column');
      }
      // Display only: the buffer text is what the program wrote.
      expect(
        view.terminal.buffer.lines[0].getText().trimRight(),
        'an error ok 10.0.0.1 at ssh://a.bc x',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('text the program styled itself keeps its own colors', (
    tester,
  ) async {
    final view = _View()
      ..terminal.write(
        [
          '\x1b[33merror\x1b[0m', // colored
          '\x1b[44merror\x1b[0m', // on a background
          '\x1b[7merror\x1b[0m', // inverse
          '\x1b[2merror\x1b[0m', // faint
          'err\x1b[31mor\x1b[0m failed', // partly colored word
          '\x1b[0;2;36m[MCP] ssh_exec error failed 10.0.0.1\x1b[0m',
          '\x1b[38;5;208merror\x1b[0m \x1b[38;2;1;2;3mfailed\x1b[0m',
          '\x1b[1merror\x1b[0m \x1b[4mfailed\x1b[0m', // bold / underline only
        ].join('\r\n'),
      );
    await view.pump(tester);
    final decorated = await view.shot(tester);
    await view.pump(tester, decorate: false);
    final plain = await view.shot(tester);
    final red = _rule(_dark, KeywordHighlightColor.red);

    expect(decorated.row(0, 0, 5), everyElement(_dark.yellow));
    expect(decorated.row(1, 0, 5), everyElement(_dark.foreground));
    expect(decorated.row(2, 0, 5), everyElement(_dark.background));
    for (final row in [0, 1, 2, 3, 5, 6]) {
      // Identical with and without highlighting, cell by cell.
      expect(decorated.row(row, 0, 40), plain.row(row, 0, 40), reason: '$row');
    }
    // A partly colored word is left alone as a whole; the plain word after
    // it is highlighted.
    expect(decorated.row(4, 0, 3), everyElement(_dark.foreground));
    expect(decorated.row(4, 3, 5), everyElement(_dark.red));
    expect(decorated.row(4, 6, 12), everyElement(red));
    expect(plain.row(4, 6, 12), everyElement(_dark.foreground));
    // The [MCP] line is dim cyan either way.
    expect(decorated.at(17, 5), isNot(red));
    expect(decorated.at(17, 5), isNot(_dark.foreground));
    // Bold or underlined default-colored text is still plain text.
    expect(decorated.row(7, 0, 5), everyElement(red));
    expect(decorated.row(7, 6, 12), everyElement(red));
    expect(plain.row(7, 0, 5), everyElement(_dark.foreground));
  });

  testWidgets('nothing is recolored in the alternate screen', (tester) async {
    final view = _View()..terminal.write('error failed');
    await view.pump(tester);
    final red = _rule(_dark, KeywordHighlightColor.red);
    expect((await view.shot(tester)).row(0, 0, 5), everyElement(red));

    view.terminal.write('\x1b[?1049h\x1b[Herror failed 10.0.0.1');
    expect(view.terminal.isUsingAltBuffer, isTrue);
    final alternate = await view.shot(tester);
    expect(alternate.row(0, 0, 5), everyElement(_dark.foreground));
    expect(alternate.row(0, 6, 12), everyElement(_dark.foreground));
    expect(alternate.at(13, 0), _dark.foreground);

    view.terminal.write('\x1b[?1049l');
    expect((await view.shot(tester)).row(0, 0, 5), everyElement(red));
  });

  testWidgets('switches, colors and keywords apply to an open terminal', (
    tester,
  ) async {
    final view = _View()..terminal.write('error ok foo');
    await view.pump(tester);
    final red = _rule(_dark, KeywordHighlightColor.red);
    final green = _rule(_dark, KeywordHighlightColor.green);
    final highlighter = view.highlighter;
    // Only the highlighter changes below; the widget is never rebuilt.
    Future<_Shot> now() => view.shot(tester);

    var shot = await now();
    expect(shot.row(0, 0, 5), everyElement(red));
    expect(shot.row(0, 6, 8), everyElement(green));
    expect(shot.row(0, 9, 12), everyElement(_dark.foreground));

    await highlighter.setEnabled(false);
    shot = await now();
    expect(shot.row(0, 0, 5), everyElement(_dark.foreground));
    expect(shot.row(0, 6, 8), everyElement(_dark.foreground));

    await highlighter.setEnabled(true);
    await highlighter.setGroupEnabled('error', false);
    shot = await now();
    expect(shot.row(0, 0, 5), everyElement(_dark.foreground));
    expect(shot.row(0, 6, 8), everyElement(green));

    await highlighter.setGroupEnabled('error', true);
    await highlighter.setGroupColor('error', KeywordHighlightColor.cyan);
    shot = await now();
    expect(
      shot.row(0, 0, 5),
      everyElement(_rule(_dark, KeywordHighlightColor.cyan)),
    );

    final id = highlighter.addGroup('mine')!;
    highlighter.addKeyword(id, 'foo');
    await highlighter.setGroupColor(id, KeywordHighlightColor.yellow);
    shot = await now();
    expect(
      shot.row(0, 9, 12),
      everyElement(_rule(_dark, KeywordHighlightColor.yellow)),
    );

    await highlighter.removeGroup(id);
    await highlighter.removeKeyword('success', 'ok');
    shot = await now();
    expect(shot.row(0, 6, 8), everyElement(_dark.foreground));
    expect(shot.row(0, 9, 12), everyElement(_dark.foreground));

    await highlighter.restoreDefaults();
    shot = await now();
    expect(shot.row(0, 0, 5), everyElement(red));
    expect(shot.row(0, 6, 8), everyElement(green));
  });

  testWidgets('selection, search hits and the cursor paint over highlights', (
    tester,
  ) async {
    final view = _View()..terminal.write('error failed fatal');
    await view.pump(tester, autofocus: true);
    final red = _rule(_dark, KeywordHighlightColor.red);
    Matcher near(Color expected) => predicate<Color>(
      (actual) =>
          ((actual.r - expected.r).abs() +
                  (actual.g - expected.g).abs() +
                  (actual.b - expected.b).abs()) *
              255 <=
          6,
      'close to $expected',
    );

    // Selection: the translucent selection color over the highlighted glyph.
    view.controller.setSelection(view.anchor(0, 0), view.anchor(5, 0));
    var shot = await view.shot(tester);
    final selected = Color.alphaBlend(_dark.selection, red);
    expect(selected, isNot(red));
    for (final color in shot.row(0, 0, 5)) {
      expect(color, near(selected));
    }
    expect(shot.row(0, 6, 12), everyElement(red));
    // What is copied is the buffer text, not affected by the colors.
    expect(view.terminal.buffer.getText(view.controller.selection), 'error');
    view.controller.clearSelection();

    // A search hit drawn through the controller's highlight API: a block of
    // the hit color with the text it marks drawn on top, still in the color
    // of its rule. Columns 6-11 are "failed", column 12 the space after it.
    for (final hit in const [
      // What the search uses: an opaque background. Painted alone it would
      // turn the hit into a solid block and hide the very text it found.
      Color(0xFF8A6620),
      Color(0x80FFE08A),
    ]) {
      final highlight = view.controller.highlight(
        p1: view.anchor(6, 0),
        p2: view.anchor(13, 0),
        color: hit,
      );
      shot = await view.shot(tester);
      expect(shot.row(0, 6, 12), everyElement(red), reason: '$hit');
      expect(
        shot.at(12, 0),
        near(Color.alphaBlend(hit, _dark.background)),
        reason: '$hit',
      );
      // Nothing outside the hit changes.
      expect(shot.row(0, 0, 5), everyElement(red));
      expect(shot.row(0, 13, 18), everyElement(red));
      expect(shot.at(5, 0), _dark.background);
      highlight.dispose();
    }

    // The block cursor covers its cell; its neighbours stay highlighted.
    view.terminal.write('\x1b[1;15H');
    shot = await view.shot(tester);
    expect(shot.at(14, 0), _dark.cursor);
    expect(shot.at(13, 0), red);
    expect(shot.at(15, 0), red);
    expect(shot.row(0, 0, 5), everyElement(red));
  });

  testWidgets('wide characters and wrapped lines keep highlights in place', (
    tester,
  ) async {
    final view = _View();
    await view.pump(tester);
    final columns = view.terminal.viewWidth;
    expect(columns, 40);
    view.terminal
      ..write('中文 error 完成 ok\r\n')
      ..write('${'x' * (columns - 4)}failed ok\r\n')
      ..write('${'x' * (columns - 1)}terror ok');
    final shot = await view.shot(tester);
    final red = _rule(_dark, KeywordHighlightColor.red);
    final green = _rule(_dark, KeywordHighlightColor.green);
    // Row 0: 中文 occupies cells 0..3, "error" cells 5..9, 完成 11..14.
    expect(shot.at(4, 0), _dark.background);
    expect(shot.row(0, 5, 10), everyElement(red));
    expect(shot.at(10, 0), _dark.background);
    expect(shot.row(0, 16, 18), everyElement(green));
    for (final column in [0, 1, 2, 3, 11, 12, 13, 14]) {
      expect(shot.at(column, 0), isNot(red), reason: '$column');
      expect(shot.at(column, 0), isNot(green), reason: '$column');
    }
    // Rows 1-2: "fail|ed" split by the wrap is not highlighted in part.
    expect(shot.row(1, 0, columns), everyElement(_dark.foreground));
    expect(shot.row(2, 0, 2), everyElement(_dark.foreground));
    expect(shot.row(2, 3, 5), everyElement(green));
    // Rows 3-4: "t|error" must not light up "error" on the next row.
    expect(shot.row(3, 0, columns), everyElement(_dark.foreground));
    expect(shot.row(4, 0, 5), everyElement(_dark.foreground));
    expect(shot.row(4, 6, 8), everyElement(green));
  });

  testWidgets('repainting unchanged lines does no matching work', (
    tester,
  ) async {
    final highlighter = TerminalKeywordHighlighter();
    final counting = _Counting(highlighter);
    final view = _View(highlighter: highlighter);
    await view.pump(tester, decorator: counting);
    final rows = view.terminal.viewHeight;
    expect(rows, greaterThanOrEqualTo(10));

    // A full screen of log output, every line different.
    for (var i = 0; i < rows - 1; i++) {
      view.terminal.write('job $i failed: 10.0.0.$i timed out\r\n');
    }
    await tester.pump();
    final analysedAfterFirstPaint = highlighter.debugAnalysedLines;
    expect(analysedAfterFirstPaint, rows - 1);

    Future<void> repaint(int times) async {
      for (var i = 0; i < times; i++) {
        view.render(tester).markNeedsPaint();
        await tester.pump();
      }
    }

    final paints = counting.paints;
    final lookups = counting.lookups;
    final clock = Stopwatch()..start();
    await repaint(200);
    clock.stop();
    expect(counting.paints, paints + 200);
    // Every visible line was looked up on every frame...
    expect(counting.lookups, greaterThanOrEqualTo(lookups + 200 * rows));
    // ...and not one of them went through the regular expression again.
    expect(highlighter.debugAnalysedLines, analysedAfterFirstPaint);
    expect(highlighter.debugCachedLines, rows - 1);
    printOnFailure('200 repaints took ${clock.elapsedMilliseconds} ms');

    // One new line of output costs one analysis (plus nothing for the rest).
    view.terminal.write('one more error');
    await repaint(20);
    expect(highlighter.debugAnalysedLines, analysedAfterFirstPaint + 1);

    // Scrolling back over lines seen before is free as well.
    for (var i = 0; i < 300; i++) {
      view.terminal.write('\r\nscroll $i ok');
    }
    await repaint(1);
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    final afterOutput = highlighter.debugAnalysedLines;
    scrollable.position.jumpTo(0);
    await repaint(3);
    final afterScrollUp = highlighter.debugAnalysedLines;
    expect(afterScrollUp - afterOutput, lessThanOrEqualTo(rows + 1));
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await repaint(3);
    scrollable.position.jumpTo(0);
    await repaint(3);
    expect(highlighter.debugAnalysedLines, afterScrollUp);
    expect(
      highlighter.debugCachedLines,
      lessThanOrEqualTo(TerminalKeywordHighlighter.maxCachedLines),
    );

    // Switched off, a paint asks once and then touches no line at all.
    await highlighter.setEnabled(false);
    await tester.pump();
    final offPaints = counting.paints;
    final offLookups = counting.lookups;
    final offAnalysed = highlighter.debugAnalysedLines;
    await repaint(50);
    expect(counting.paints, offPaints + 50);
    expect(counting.lookups, offLookups);
    expect(highlighter.debugAnalysedLines, offAnalysed);

    // The same holds while a full-screen program owns the screen.
    await highlighter.setEnabled(true);
    view.terminal.write('\x1b[?1049h\x1b[Herror in vim');
    await tester.pump();
    final altLookups = counting.lookups;
    await repaint(50);
    expect(counting.lookups, altLookups);
  });

  testWidgets('a view follows a replaced or removed decorator', (tester) async {
    final first = TerminalKeywordHighlighter();
    final second = TerminalKeywordHighlighter(
      settings: KeywordHighlightSettings.defaults().copyWith(enabled: false),
    );
    final view = _View(highlighter: first)..terminal.write('error');
    await view.pump(tester);
    final red = _rule(_dark, KeywordHighlightColor.red);
    expect((await view.shot(tester)).at(0, 0), red);

    await view.pump(tester, decorator: second);
    expect((await view.shot(tester)).at(0, 0), _dark.foreground);
    // The view listens to the new decorator and no longer to the old one.
    await second.setEnabled(true);
    expect((await view.shot(tester)).at(0, 0), red);
    await first.setEnabled(false);
    expect((await view.shot(tester)).at(0, 0), red);

    await view.pump(tester, decorate: false);
    expect((await view.shot(tester)).at(0, 0), _dark.foreground);
    await tester.pumpWidget(const SizedBox.shrink());
    // Unmounted views hold no listener on the shared highlighter.
    // ignore: invalid_use_of_protected_member
    expect(second.hasListeners, isFalse);
    // ignore: invalid_use_of_protected_member
    expect(first.hasListeners, isFalse);
  });
}
