import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/clipboard.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/selection_mode.dart';

typedef TerminalPasteInterceptor = Future<String?> Function(
  BuildContext context,
  String text,
);

class TerminalActions extends StatelessWidget {
  const TerminalActions({
    super.key,
    required this.terminal,
    required this.controller,
    this.readOnly = false,
    this.onBeforePaste,
    required this.child,
  });

  final Terminal terminal;

  final TerminalController controller;

  final bool readOnly;

  /// 在执行粘贴写入终端前的可选异步拦截钩子；返回 `null` 表示取消粘贴。
  final TerminalPasteInterceptor? onBeforePaste;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (intent) async {
            if (readOnly) return null;
            final text = await TerminalClipboard.read(context);
            if (text == null || !context.mounted) return null;
            final interceptor = onBeforePaste;
            final approved =
                interceptor == null ? text : await interceptor(context, text);
            if (approved == null || !context.mounted || readOnly) {
              return null;
            }
            terminal.paste(approved);
            controller.clearSelection();
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
