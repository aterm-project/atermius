import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/xterm.dart';

void main() {
  late Terminal terminal;

  setUp(() {
    terminal = Terminal(maxLines: 100);
    terminal.resize(40, 10);
  });

  CursorStyle style() => terminal.cursor;

  test('CSI > 4 ; 2 m (modifyOtherKeys) is not an SGR underline', () {
    // Sent by full-screen CLIs such as Claude Code when they start.
    terminal.write('\x1b[>4;2m');
    expect(style().isUnderline, isFalse);
    expect(style().attrs, 0);

    terminal.write('\x1b[>4m\x1b[?4m\x1b[>1;2m');
    expect(style().attrs, 0);
  });

  test('plain SGR underline still works', () {
    terminal.write('\x1b[4m');
    expect(style().isUnderline, isTrue);
    terminal.write('\x1b[24m');
    expect(style().isUnderline, isFalse);
  });

  test('colon underline styles set and clear underline only', () {
    terminal.write('\x1b[4:3m');
    expect(style().isUnderline, isTrue);
    expect(style().background, 0);

    terminal.write('\x1b[4:0m');
    expect(style().isUnderline, isFalse);
    expect(style().background, 0);
  });

  test('colon colour forms match the semicolon forms', () {
    terminal.write('\x1b[38;2;10;20;30;48;5;200m');
    final foreground = style().foreground;
    final background = style().background;

    terminal.write('\x1b[0m\x1b[38:2::10:20:30;48:5:200m');
    expect(style().foreground, foreground);
    expect(style().background, background);

    terminal.write('\x1b[0m\x1b[38:2:10:20:30m');
    expect(style().foreground, foreground);
  });

  test('underline colour is skipped, not read as attributes', () {
    terminal.write('\x1b[58;5;4m');
    expect(style().attrs, 0);
    terminal.write('\x1b[58;2;4;5;7m');
    expect(style().attrs, 0);
    terminal.write('\x1b[58:2::4:5:7;1m');
    expect(style().attrs, CellAttr.bold);
  });

  test('truncated extended colours do not throw', () {
    terminal.write('\x1b[38m\x1b[38;2;1m\x1b[48;5m\x1b[58m');
    terminal.write('ok');
    expect(terminal.buffer.lines[0].getText().trimRight(), 'ok');
  });
}
