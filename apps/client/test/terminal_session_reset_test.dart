import 'package:aterm_client/terminal/mirrored_terminal.dart';
import 'package:aterm_client/terminal/terminal_session_reset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// What a full-screen program with mouse support (vim `mouse=a`, tmux
/// `mouse on`, htop, mc) leaves switched on while it runs.
const _fullScreenProgram =
    '\x1b[?1049h\x1b[?1h\x1b=\x1b[?1000h\x1b[?1002h\x1b[?1006h'
    '\x1b[?1004h\x1b[?2004h\x1b[?25l\x1b[4h\x1b[?6h\x1b[?7l'
    '\x1b[5;10r\x1b(0\x1b[1;31m';

void main() {
  late Terminal terminal;
  late List<String> sent;

  setUp(() {
    sent = [];
    terminal = Terminal(maxLines: 1000, onOutput: sent.add);
    terminal.resize(80, 24);
  });

  test('a dropped full-screen program leaves the wheel reporting to the '
      'next shell; the reset stops that', () {
    terminal.write('prompt\$ vim\r\n');
    terminal.write(_fullScreenProgram);

    // This is the bug: after the drop the wheel is still sent as a mouse
    // report, which the next shell prints as text.
    expect(terminal.isUsingAltBuffer, isTrue);
    expect(
      terminal.mouseInput(
        TerminalMouseButton.wheelDown,
        TerminalMouseButtonState.down,
        const CellOffset(9, 4),
      ),
      isTrue,
    );
    expect(sent.single, '\x1b[<65;10;5M');
    sent.clear();

    resetTerminalForNewSession(terminal);

    expect(terminal.isUsingAltBuffer, isFalse);
    expect(terminal.mouseMode, MouseMode.none);
    expect(terminal.mouseReportMode, MouseReportMode.normal);
    expect(
      terminal.mouseInput(
        TerminalMouseButton.wheelDown,
        TerminalMouseButtonState.down,
        const CellOffset(9, 4),
      ),
      isFalse,
    );
    expect(
      terminal.mouseInput(
        TerminalMouseButton.left,
        TerminalMouseButtonState.down,
        const CellOffset(9, 4),
      ),
      isFalse,
    );
    expect(sent, isEmpty);
  });

  test('every mouse tracking mode and encoding is switched off', () {
    for (final tracking in [9, 1000, 1001, 1002, 1003]) {
      for (final encoding in [null, 1005, 1006, 1015]) {
        terminal.write('\x1b[?${tracking}h');
        if (encoding != null) terminal.write('\x1b[?${encoding}h');
        resetTerminalForNewSession(terminal);
        expect(terminal.mouseMode, MouseMode.none, reason: '$tracking');
        expect(
          terminal.mouseReportMode,
          MouseReportMode.normal,
          reason: '$tracking/$encoding',
        );
      }
    }
  });

  test('keyboard, paste and screen modes return to their defaults', () {
    terminal.write(_fullScreenProgram);
    terminal.write('\x1b[?1007h\x1b[?5h\x1b[20h');
    resetTerminalForNewSession(terminal);

    expect(terminal.cursorKeysMode, isFalse);
    expect(terminal.appKeypadMode, isFalse);
    expect(terminal.bracketedPasteMode, isFalse);
    expect(terminal.reportFocusMode, isFalse);
    expect(terminal.altBufferMouseScrollMode, isFalse);
    expect(terminal.insertMode, isFalse);
    expect(terminal.lineFeedMode, isFalse);
    expect(terminal.originMode, isFalse);
    expect(terminal.autoWrapMode, isTrue);
    expect(terminal.cursorVisibleMode, isTrue);
    expect(terminal.reverseDisplayMode, isFalse);

    // Arrow keys and pastes go out in the plain form again.
    terminal.keyInput(TerminalKey.arrowUp);
    terminal.paste('ls');
    expect(sent, ['\x1b[A', 'ls']);
  });

  test('the main screen keeps its text and cursor; new output continues '
      'there in plain ASCII with default colours', () {
    terminal.write('first\r\nprompt\$ top');
    final cursorX = terminal.buffer.cursorX;
    final cursorY = terminal.buffer.absoluteCursorY;
    // Main-screen state a dropped program can leave behind too.
    terminal.write('\x1b[5;10r\x1b(0\x1b[1;31m\x1b[?1049h\x1b(0full screen');

    resetTerminalForNewSession(terminal);

    expect(terminal.buffer.cursorX, cursorX);
    expect(terminal.buffer.absoluteCursorY, cursorY);
    expect(terminal.buffer.marginTop, 0);
    expect(terminal.buffer.marginBottom, terminal.viewHeight - 1);
    terminal.write('\r\nqx');
    final text = terminal.buffer.getText();
    expect(text, contains('first'));
    expect(text, contains('prompt\$ top'));
    // `q` and `x` are line-drawing glyphs while the DEC graphics set is on.
    expect(text, contains('qx'));
    expect(text, isNot(contains('full screen')));
    final line = terminal.buffer.lines[terminal.buffer.absoluteCursorY];
    expect(line.getForeground(0), 0);
    expect(line.getAttributes(0), 0);
  });

  test('scrollback works again: lines scroll off the main screen', () {
    terminal.write(_fullScreenProgram);
    resetTerminalForNewSession(terminal);
    for (var i = 0; i < 100; i++) {
      terminal.write('line $i\r\n');
    }
    expect(terminal.buffer.height, greaterThan(terminal.viewHeight + 50));
    expect(terminal.buffer.getText(), contains('line 0'));
  });

  group('an escape sequence cut off by the drop does not swallow the next '
      'session', () {
    for (final (name, partial) in [
      ('lone ESC', '\x1b'),
      ('OSC introducer only', '\x1b]'),
      ('discarded CSI', '\x1b[${'1;' * 3000}'),
      ('CSI', '\x1b[38;5'),
      ('private CSI', '\x1b[?10'),
      ('window title', '\x1b]0;user@host: ~/proj'),
      ('title with a pending ESC', '\x1b]0;user@host\x1b'),
      ('charset designation', '\x1b('),
      ('oversized title', '\x1b]0;${'x' * 70000}'),
    ]) {
      test(name, () {
        final titles = <String>[];
        terminal.onTitleChange = titles.add;
        terminal.write('before\r\n');
        terminal.write(partial);

        resetTerminalForNewSession(terminal);
        terminal.write('Last login: today\r\n');

        final text = terminal.buffer.getText();
        expect(text, contains('before'));
        expect(text, contains('Last login: today'));
        // Nothing of the reset itself is printed.
        expect(text, isNot(contains('1049')));
        expect(text, isNot(contains('\\')));
        // The half-received title is dropped, not applied.
        expect(titles, isEmpty);
      });
    }
  });

  test('is harmless on a fresh terminal and when repeated', () {
    resetTerminalForNewSession(terminal);
    terminal.write('hello');
    resetTerminalForNewSession(terminal);
    resetTerminalForNewSession(terminal);
    terminal.write(' world');
    expect(terminal.buffer.getText().trim(), 'hello world');
    expect(terminal.buffer.cursorX, 11);
    expect(terminal.isUsingAltBuffer, isFalse);
    expect(sent, isEmpty);
  });

  test('replicas fed from the mirrored output are reset with the terminal', () {
    final source = MirroredTerminal(maxLines: 1000);
    source.resize(80, 24);
    final replica = Terminal(maxLines: 1000);
    replica.resize(80, 24);
    source.mirroredOutput.listen((chunk) => replica.write(chunk.data));

    source.write(_fullScreenProgram);
    expect(replica.isUsingAltBuffer, isTrue);
    expect(replica.mouseMode, isNot(MouseMode.none));

    resetTerminalForNewSession(source);
    expect(replica.isUsingAltBuffer, isFalse);
    expect(replica.mouseMode, MouseMode.none);

    // A window opened later replays the retained history.
    final late_ = Terminal(maxLines: 1000);
    late_.resize(80, 24);
    source.history.forEach(late_.write);
    expect(late_.isUsingAltBuffer, isFalse);
    expect(late_.mouseMode, MouseMode.none);
    expect(late_.bracketedPasteMode, isFalse);
  });

  test('a reconnected session starts on its own line, an empty terminal '
      'stays untouched', () {
    beginTerminalSession(terminal);
    expect(terminal.buffer.cursorX, 0);
    expect(terminal.buffer.absoluteCursorY, 0);

    terminal.write('user@host:~\$ ');
    beginTerminalSession(terminal);
    terminal.write('Last login');
    expect(terminal.buffer.lines[0].toString(), startsWith('user@host:~\$'));
    expect(terminal.buffer.lines[0].toString(), isNot(contains('Last login')));
    expect(terminal.buffer.lines[1].toString(), startsWith('Last login'));

    // Already at the start of a line: no blank line is added.
    terminal.write('\r\n');
    beginTerminalSession(terminal);
    terminal.write('next');
    expect(terminal.buffer.lines[2].toString(), startsWith('next'));
  });
}
