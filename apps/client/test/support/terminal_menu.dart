// Opens a terminal session's function menu, which lives in the actions of
// its pane's white handle (or, in a saved-layout split, in the pane header).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final terminalMenu = find.byKey(const ValueKey('terminal_function_menu'));

/// Reveals the function menu button: taps the white handle of the pane
/// first when its actions are hidden.
Future<void> revealTerminalMenu(WidgetTester tester) async {
  if (terminalMenu.evaluate().isEmpty) {
    final handle = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('pane-handle-'),
    );
    await tester.tap(handle.first);
    await tester.pumpAndSettle();
  }
  expect(terminalMenu, findsOneWidget);
}

/// Opens the function menu (the one inside [within], when there are
/// several saved-layout panes).
Future<void> openTerminalMenu(WidgetTester tester, {Finder? within}) async {
  final menu = within == null
      ? terminalMenu
      : find.descendant(of: within, matching: terminalMenu);
  if (within == null) await revealTerminalMenu(tester);
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
}

/// Runs the function menu entry [id].
Future<void> openTerminalAction(WidgetTester tester, String id) async {
  await openTerminalMenu(tester);
  final action = find.byKey(ValueKey(id));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}
