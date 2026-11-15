import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

// The platform places the input method's composition and candidate windows
// from what the text input connection is told: the size and transform of the
// editable area and the caret / composing ("marked text") rectangles inside
// it. Windows and Linux read only the composing rectangle; a terminal that
// never sent it had its candidates shown in the top left corner of the window.

const _left = 120.0;
const _top = 64.0;

List<MethodCall> _calls(WidgetTester tester, String method) =>
    tester.testTextInput.log.where((call) => call.method == method).toList();

/// Where the platform would put the candidate window: the composing
/// rectangle moved by the editable area's transform, like the Windows and
/// Linux embedders compute it.
Rect _candidateAnchor(WidgetTester tester) {
  final area = _calls(tester, 'TextInput.setEditableSizeAndTransform').last;
  final marked = _calls(tester, 'TextInput.setMarkedTextRect').last;
  final transform = Matrix4.fromList(
    (area.arguments['transform'] as List).cast<double>(),
  );
  final rect = Rect.fromLTWH(
    marked.arguments['x'] as double,
    marked.arguments['y'] as double,
    marked.arguments['width'] as double,
    marked.arguments['height'] as double,
  );
  return MatrixUtils.transformRect(transform, rect);
}

Future<(Terminal, TerminalViewState)> _pump(
  WidgetTester tester, {
  FocusNode? focusNode,
  double left = _left,
  double top = _top,
}) async {
  final terminal = Terminal();
  final key = GlobalKey<TerminalViewState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.only(left: left, top: top),
          child: TerminalView(
            terminal,
            key: key,
            focusNode: focusNode,
            autofocus: true,
            padding: EdgeInsets.zero,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (terminal, key.currentState!);
}

void main() {
  testWidgets('the candidate window is anchored at the cursor cell', (
    tester,
  ) async {
    final (terminal, view) = await _pump(tester);
    expect(tester.testTextInput.hasAnyClients, isTrue);
    final cell = view.renderTerminal.cellSize;

    // Fresh terminal: cursor in the first cell, which is not the window's
    // top left corner.
    expect(_candidateAnchor(tester), const Offset(_left, _top) & cell);

    terminal.write('hello');
    await tester.pump();
    expect(
      _candidateAnchor(tester),
      Offset(_left + 5 * cell.width, _top) & cell,
    );
    expect(_candidateAnchor(tester), view.globalCursorRect);

    terminal.write('\r\n\r\nab');
    await tester.pump();
    expect(
      _candidateAnchor(tester),
      Offset(_left + 2 * cell.width, _top + 2 * cell.height) & cell,
    );

    // The caret rectangle (macOS, iOS) says the same as the composing one.
    final caret = _calls(tester, 'TextInput.setCaretRect').last.arguments;
    final marked = _calls(tester, 'TextInput.setMarkedTextRect').last.arguments;
    expect(caret, marked);
    // Like a text field: the rectangle is relative to the editable area,
    // which is the terminal, placed by the transform.
    expect(marked['x'], 2 * cell.width);
    expect(marked['y'], 2 * cell.height);
    expect(marked['width'], cell.width);
    expect(marked['height'], cell.height);
    final area = _calls(
      tester,
      'TextInput.setEditableSizeAndTransform',
    ).last.arguments;
    final size = tester.getSize(find.byType(TerminalView));
    expect(area['width'], size.width);
    expect(area['height'], size.height);
    expect((area['transform'] as List).sublist(12, 14), [_left, _top]);
  });

  testWidgets('follows the terminal when it moves on screen', (tester) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final (terminal, view) = await _pump(tester, focusNode: focusNode);
    terminal.write('abc');
    await tester.pump();
    final cell = view.renderTerminal.cellSize;
    expect(
      _candidateAnchor(tester).topLeft,
      Offset(_left + 3 * cell.width, _top),
    );

    // The pane moves (a split is resized): nothing was written.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.only(left: 300, top: 200),
            child: TerminalView(
              terminal,
              key: view.widget.key,
              focusNode: focusNode,
              autofocus: true,
              padding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_candidateAnchor(tester).topLeft, Offset(300 + 3 * cell.width, 200));
  });

  testWidgets('every cursor move is sent, an unchanged position is not', (
    tester,
  ) async {
    final (terminal, _) = await _pump(tester);
    int sent() => _calls(tester, 'TextInput.setMarkedTextRect').length;
    final atStart = sent();
    expect(atStart, 1);

    // Windows and Linux follow the composing rectangle while typing: each
    // move of the cursor must reach them.
    terminal.write('a');
    await tester.pump();
    expect(sent(), atStart + 1);
    terminal.write('b');
    await tester.pump();
    expect(sent(), atStart + 2);
    terminal.write('\r\n');
    await tester.pump();
    expect(sent(), atStart + 3);

    // Output that leaves the cursor where it was, and plain repaints.
    terminal.write('\x1b[31m\x1b[0m');
    await tester.pump();
    terminal.write('\x1b7 xyz\x1b8');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(sent(), atStart + 3);
    // The terminal did not move: its transform was sent once.
    expect(
        _calls(tester, 'TextInput.setEditableSizeAndTransform'), hasLength(1));
  });

  testWidgets('a new input connection is told the position at once', (
    tester,
  ) async {
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    final (terminal, view) = await _pump(tester, focusNode: focusNode);
    terminal.write('abcd');
    await tester.pump();
    final cell = view.renderTerminal.cellSize;

    focusNode.unfocus();
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isFalse);
    tester.testTextInput.log.clear();

    // Focus comes back without any output or repaint of the content.
    focusNode.requestFocus();
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);
    expect(_calls(tester, 'TextInput.setMarkedTextRect'), isNotEmpty);
    expect(
      _candidateAnchor(tester).topLeft,
      Offset(_left + 4 * cell.width, _top),
    );
  });
}
