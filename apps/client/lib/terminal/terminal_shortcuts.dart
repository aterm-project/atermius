import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../domain/vault_preference.dart';

/// Finds an exact synchronized semantic binding for one terminal key event.
/// The `mod` modifier is interpreted locally and is never serialized as a
/// physical key.
TerminalShortcutAction? terminalShortcutActionForKeyEvent({
  required TerminalShortcutBindings bindings,
  required LogicalKeyboardKey logicalKey,
  required bool controlPressed,
  required bool metaPressed,
  required bool altPressed,
  required bool shiftPressed,
  required TargetPlatform platform,
}) {
  final useMetaForMod =
      platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
  final modPressed = useMetaForMod ? metaPressed : controlPressed;
  final unexpectedPrimaryModifier = useMetaForMod
      ? controlPressed
      : metaPressed;
  final key = logicalKey.keyLabel.toLowerCase();
  for (final action in TerminalShortcutAction.values) {
    final tokens = bindings.chordFor(action).split('+');
    final expectedModifiers = tokens.take(tokens.length - 1).toSet();
    if (tokens.last != key ||
        expectedModifiers.contains('mod') != modPressed ||
        expectedModifiers.contains('alt') != altPressed ||
        expectedModifiers.contains('shift') != shiftPressed ||
        unexpectedPrimaryModifier) {
      continue;
    }
    return action;
  }
  return null;
}

/// Dispatches a matching semantic binding and reports whether the terminal
/// consumed the key event. Unmatched combinations remain available to xterm.
KeyEventResult dispatchTerminalShortcut({
  required TerminalShortcutBindings bindings,
  required LogicalKeyboardKey logicalKey,
  required bool controlPressed,
  required bool metaPressed,
  required bool altPressed,
  required bool shiftPressed,
  required TargetPlatform platform,
  required void Function(TerminalShortcutAction action) onAction,
}) {
  final action = terminalShortcutActionForKeyEvent(
    bindings: bindings,
    logicalKey: logicalKey,
    controlPressed: controlPressed,
    metaPressed: metaPressed,
    altPressed: altPressed,
    shiftPressed: shiftPressed,
    platform: platform,
  );
  if (action == null) return KeyEventResult.ignored;
  onAction(action);
  return KeyEventResult.handled;
}

/// Routes the configured search action from any focused workspace control.
class WorkspaceSearchShortcut extends StatelessWidget {
  const WorkspaceSearchShortcut({
    super.key,
    required this.bindings,
    required this.onToggle,
    required this.child,
  });

  final TerminalShortcutBindings bindings;
  final VoidCallback? onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent || onToggle == null)
        return KeyEventResult.ignored;
      final keys = HardwareKeyboard.instance;
      final action = terminalShortcutActionForKeyEvent(
        bindings: bindings,
        logicalKey: event.logicalKey,
        controlPressed: keys.isControlPressed,
        metaPressed: keys.isMetaPressed,
        altPressed: keys.isAltPressed,
        shiftPressed: keys.isShiftPressed,
        platform: defaultTargetPlatform,
      );
      if (action != TerminalShortcutAction.search)
        return KeyEventResult.ignored;
      onToggle!();
      return KeyEventResult.handled;
    },
    child: child,
  );
}
