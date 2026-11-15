import 'package:flutter/foundation.dart';
import 'package:xterm/src/core/buffer/cell_flags.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/terminal_theme.dart';

/// How the glyphs of a [TerminalForegroundSpan] are painted.
@immutable
class TerminalForegroundStyle {
  const TerminalForegroundStyle({required this.foreground, this.flags = 0});

  /// A named (ANSI) color, resolved through the view's [TerminalTheme].
  /// [index] is 0..15 in the usual ANSI order.
  const TerminalForegroundStyle.ansi(int index, {this.flags = 0})
      : assert(index >= 0 && index < 16),
        foreground = CellColor.named | index;

  /// Foreground in the cell color encoding ([CellColor]).
  final int foreground;

  /// [CellFlags] added to the cell (for example [CellFlags.underline] or
  /// [CellFlags.bold]). Flags the cell already has are kept.
  final int flags;
}

/// A run of cells `[start, end)` on one line painted with
/// `styles[style]` of the current paint (see
/// [TerminalForegroundDecorator.beginPaint]).
@immutable
class TerminalForegroundSpan {
  const TerminalForegroundSpan(this.start, this.end, this.style)
      : assert(start >= 0 && end > start && style >= 0);

  /// First cell column of the run.
  final int start;

  /// Cell column after the last cell of the run.
  final int end;

  /// Index into the styles returned by
  /// [TerminalForegroundDecorator.beginPaint].
  final int style;

  @override
  String toString() => 'TerminalForegroundSpan($start, $end, style $style)';
}

/// Display-only recoloring of plain terminal text.
///
/// The view asks the decorator for runs of cells to draw in another
/// foreground. Nothing in the [Terminal] buffer changes: selection, copied
/// text, search and everything sent to or read from the terminal are
/// unaffected.
///
/// A run is applied only when every cell in it is plain: default foreground,
/// default background and neither inverse, faint nor invisible. Text the
/// program styled itself therefore keeps the program's colors.
///
/// The view repaints when the decorator notifies its listeners.
abstract class TerminalForegroundDecorator implements Listenable {
  /// Called once at the start of every paint of a view showing [terminal]
  /// with [theme]. Returns the styles that spans of this paint refer to, or
  /// null to leave this paint undecorated (the cheap path: [spansFor] is then
  /// not called at all).
  List<TerminalForegroundStyle>? beginPaint(
    Terminal terminal,
    TerminalTheme theme,
  );

  /// Runs to recolor on [line], sorted by [TerminalForegroundSpan.start] and
  /// not overlapping, or null when there are none.
  ///
  /// Called for every visible line on every paint, so implementations must
  /// cache: the answer may only depend on the content of [line].
  List<TerminalForegroundSpan>? spansFor(BufferLine line);
}

/// Whether the cells `[start, end)` of [line] are all plain, i.e. whether a
/// [TerminalForegroundSpan] covering them is applied.
bool terminalCellsArePlain(BufferLine line, int start, int end) {
  if (end > line.length) return false;
  const styled = CellFlags.inverse | CellFlags.faint | CellFlags.invisible;
  for (var i = start; i < end; i++) {
    if (line.getForeground(i) & CellColor.typeMask != CellColor.normal ||
        line.getBackground(i) & CellColor.typeMask != CellColor.normal ||
        line.getAttributes(i) & styled != 0) {
      return false;
    }
  }
  return true;
}
