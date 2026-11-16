import 'package:xterm/xterm.dart';

/// Returns a terminal to the state a newly started shell expects, without
/// touching its contents or the cursor position.
///
/// A program on the far side owns the terminal's modes while it runs: vim,
/// tmux, htop and the like switch to the alternate screen, turn on mouse
/// reporting, bracketed paste, application cursor keys and so on, and turn
/// them off again when they exit. When the connection drops they never get
/// the chance. The tab keeps its terminal across a reconnect, so without
/// this the next shell inherits those modes: the wheel is sent to it as
/// mouse reports it prints as text, there is no scrollback because the
/// alternate screen is still showing, pastes arrive wrapped in markers and
/// arrow keys send the application form.
///
/// It is written through [Terminal.write] rather than applied as a method so
/// that every replica fed from the same output (detached windows replaying a
/// mirrored terminal) is reset with it.
const String terminalSessionReset =
    // End an escape sequence the dropped connection left unfinished, so it
    // cannot swallow the start of the next session's output. ESC cancels a
    // CSI; ESC followed by anything but a backslash abandons an OSC (CAN is
    // otherwise ignored); the string terminator ends an oversized OSC that is
    // being discarded. With nothing unfinished all three do nothing.
    '\x1b\x18\x1b\\'
    // Leave the alternate screen; what follows applies to the main screen.
    '\x1b[?1049l'
    // Mouse tracking (9, 1000-1003) and its encodings (1005, 1006, 1015),
    // focus reports (1004), wheel-as-arrows (1007), bracketed paste (2004),
    // application cursor keys (1) and keypad (66), origin mode (6), reverse
    // video (5).
    '\x1b[?9;1000;1001;1002;1003;1004;1005;1006;1007;1015;2004;1;66;6;5l'
    // Auto-wrap and a visible cursor.
    '\x1b[?7;25h'
    // Insert mode and line-feed/new-line mode.
    '\x1b[4;20l'
    // Numeric keypad.
    '\x1b>'
    // Scroll region back to the whole screen (does not move the cursor here).
    '\x1b[r'
    // ASCII in both character-set slots, slot 0 selected: a session dropped
    // while line drawing was selected would otherwise show letters as boxes.
    '\x1b(B\x1b)B\x0f'
    // Default colours and attributes.
    '\x1b[0m';

/// Applies [terminalSessionReset]. Call it when a terminal's connection ends
/// and again before another connection is attached to the same terminal.
void resetTerminalForNewSession(Terminal terminal) {
  terminal.write(terminalSessionReset);
}
