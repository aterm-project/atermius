import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/selection_mode.dart';

class TerminalActions extends StatelessWidget {
  const TerminalActions({
    super.key,
    required this.terminal,
    required this.controller,
    required this.child,
  });

  final Terminal terminal;

  final TerminalController controller;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (intent) async {
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            final text = data?.text;
            if (text != null) {
              terminal.paste(text);
              controller.clearSelection();
            }
            return null;
          },
        ),
        CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
          onInvoke: (intent) async {
            final selection = controller.selection;

            if (selection == null) {
              return;
            }

            final text = terminal.buffer.getText(selection);

            await Clipboard.setData(ClipboardData(text: text));

            return null;
          },
        ),
        SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
          onInvoke: (intent) {
            // Everything in the buffer: the scrollback above the screen as
            // well as the screen itself, not only the rows in view. On the
            // alternate screen (full-screen programs) that is the screen,
            // which has no scrollback.
            controller.setSelection(
              terminal.buffer.createAnchor(0, 0),
              terminal.buffer.createAnchor(
                terminal.viewWidth,
                terminal.buffer.height - 1,
              ),
              mode: SelectionMode.line,
            );
            return null;
          },
        ),
      },
      child: child,
    );
  }
}
