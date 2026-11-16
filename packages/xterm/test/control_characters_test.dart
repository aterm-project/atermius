import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  late Terminal terminal;
  var bells = 0;

  setUp(() {
    bells = 0;
    terminal = Terminal(
      maxLines: 100,
      onBell: () => bells++,
    );
    terminal.resize(40, 10);
  });

  String firstLine() => terminal.buffer.lines[0].getText().trimRight();

  test('C0 controls without a function are not printed', () {
    // DLE, DC1 (XON), DC3 (XOFF), NAK, CAN, EM, SUB, FS, GS, RS, US.
    terminal.write('a\x10\x11\x13\x15\x18\x19\x1a\x1c\x1d\x1e\x1fb');
    expect(firstLine(), 'ab');
    expect(terminal.buffer.cursorX, 2);
  });

  test('the C0 controls with a function keep it', () {
    terminal.write('ab\x08c\x07\tZ\r\nnext');
    // Backspace overwrote `b`; the tab moved to column 8 (blank cells are
    // not part of the line's text).
    expect(firstLine(), 'acZ');
    expect(terminal.buffer.lines[0].getCodePoint(8), 'Z'.codeUnitAt(0));
    expect(bells, 1);
    expect(terminal.buffer.lines[1].getText().trimRight(), 'next');
  });
}
