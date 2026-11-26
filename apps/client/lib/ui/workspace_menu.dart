import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'app_density.dart';
import 'app_theme.dart';
import 'apple_hig.dart';
import 'surfaces.dart';
import 'workspace_controls.dart';

/// Windows narrower than this open a submenu in place of its parent, with a
/// back row on top, instead of beside it: a phone has no room for a second
/// column next to the first.
const workspaceMenuDrillDownWidth = 600.0;

/// The workspace menu behind the ☰ button at the start of the tab bar.
///
/// [actions] is a tree: [WorkspaceAction.submenu] entries hold related
/// actions and [WorkspaceAction.divider] separates sections. Wide windows
/// cascade a submenu beside the menu (hover or click, arrow keys); narrow
/// ones replace the list with the submenu and a back row. Empty submenus are
/// left out, a submenu with a single entry shows that entry directly, and
/// dividers never lead, trail or repeat.
class WorkspaceMenu extends StatefulWidget {
  const WorkspaceMenu({
    required this.actions,
    required this.builder,
    this.tooltip,
    this.triggerKey,
    this.borderRadius,
    super.key,
  });

  final List<WorkspaceAction> actions;

  /// The trigger's look; `open` is true while the menu is shown.
  final Widget Function(BuildContext context, bool open, bool hovered) builder;
  final String? tooltip;

  /// Key of the tappable trigger.
  final Key? triggerKey;
  final BorderRadius? borderRadius;

  @override
  State<WorkspaceMenu> createState() => _WorkspaceMenuState();
}

class _WorkspaceMenuState extends State<WorkspaceMenu> {
  final _controller = MenuController();
  final _backFocus = FocusNode(debugLabel: 'workspace menu back');

  /// The trigger holds the focus while the menu is open, so Escape and the
  /// arrow keys reach the menu instead of the terminal that had it.
  final _triggerFocus = FocusNode(debugLabel: 'workspace menu');

  /// The first entry of the open level, where the keyboard enters the menu.
  final _firstFocus = FocusNode(debugLabel: 'workspace menu first');

  /// Submenu ids opened in place (narrow windows only).
  final _path = <String>[];
  FocusNode? _focusBeforeOpen;

  /// The last thing outside the menu that had the focus, and when it lost
  /// it. Opening the menu by click or by a screen reader's tap takes the
  /// focus from a text field (the terminal) a moment before the menu opens.
  FocusNode? _lastFocus;
  DateTime? _lastFocusLeftAt;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_trackFocus);
  }

  void _trackFocus() {
    if (_controller.isOpen) return;
    final now = FocusManager.instance.primaryFocus;
    if (now == null || now is FocusScopeNode || now == _triggerFocus) {
      if (_lastFocus != null) _lastFocusLeftAt ??= DateTime.now();
      return;
    }
    _lastFocus = now;
    _lastFocusLeftAt = null;
  }

  bool _hovered = false;

  @override
  void dispose() {
    FocusManager.instance.removeListener(_trackFocus);
    _backFocus.dispose();
    _triggerFocus.dispose();
    _firstFocus.dispose();
    super.dispose();
  }

  bool get _drillDown =>
      MediaQuery.sizeOf(context).width < workspaceMenuDrillDownWidth;

  void _toggle() {
    if (_controller.isOpen) {
      _controller.close();
    } else {
      _controller.open();
    }
  }

  /// Keyboard on the trigger: open the menu and step into its first entry,
  /// as Enter, Space or Down does on a native menu button.
  void _openFromKeyboard() {
    if (!_controller.isOpen) _controller.open();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final first = _path.isEmpty ? _firstFocus : _backFocus;
      if (first.context != null) first.requestFocus();
    });
  }

  void _handleOpen() {
    AppleHaptics.selection(context);
    final primary = FocusManager.instance.primaryFocus;
    final left = _lastFocusLeftAt;
    // A click, or a screen reader's tap (which first moves the focus onto
    // the trigger), took the focus from a text field a moment ago: give it
    // back there. A trigger reached with Tab long before keeps it.
    final recent =
        left != null &&
        DateTime.now().difference(left) < const Duration(seconds: 2);
    _focusBeforeOpen =
        primary == null || primary is FocusScopeNode || primary == _triggerFocus
        ? (recent ? _lastFocus : null)
        : primary;
    setState(_path.clear);
  }

  void _handleClose() {
    final previous = _focusBeforeOpen;
    _focusBeforeOpen = null;
    if (mounted) setState(_path.clear);
    // The trigger, or a hovered or arrowed-to item that is gone with the
    // menu, has the focus. Give it back to what had it (usually the
    // terminal) before the chosen action runs; the action may then move it
    // on, to a dialog say.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final now = FocusManager.instance.primaryFocus;
      final lost =
          now == null ||
          now == _triggerFocus ||
          now is FocusScopeNode ||
          now.context == null;
      if (!lost || previous == null) return;
      if (previous.context != null && previous.canRequestFocus) {
        previous.requestFocus();
      }
    });
  }

  Future<void> _run(WorkspaceAction action) async {
    if (!mounted) return;
    AppleHaptics.light(context);
    try {
      await action.run();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.l10n.theActionDidntCompleteTryAgain)),
        );
      }
    }
  }

  void _enter(WorkspaceAction submenu) {
    setState(() => _path.add(submenu.id));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_backFocus.context != null) _backFocus.requestFocus();
    });
  }

  void _back() {
    if (_path.isEmpty) return;
    setState(_path.removeLast);
  }

  /// The panel is a floating block: the block radius, no outline, a soft
  /// floating shadow, and rows [AppDensity.blockInset] in from its edge.
  MenuStyle _style(BuildContext context, {required bool drillDown}) {
    final palette = context.palette;
    final density = AppDensity.of(context);
    final screen = MediaQuery.sizeOf(context).width;
    final width = math.max(200.0, math.min(300.0, screen - 16));
    return MenuStyle(
      backgroundColor: WidgetStatePropertyAll(
        palette.isDark ? palette.surfaceRaised : palette.surface,
      ),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      // A menu panel casts a Material elevation shadow, not a BoxShadow
      // list; this one is matched to [appFloatingShadow] (a wide soft drop
      // plus a faint contact shadow).
      elevation: const WidgetStatePropertyAll(8),
      shadowColor: WidgetStatePropertyAll(
        Colors.black.withValues(alpha: palette.isDark ? .9 : .32),
      ),
      shape: WidgetStatePropertyAll(workspaceMenuBorder(context)),
      padding: WidgetStatePropertyAll(EdgeInsets.all(density.blockInset)),
      // One width for every level of a drill-down, so going in and out does
      // not make the panel jump; cascaded panels size to their labels.
      minimumSize: WidgetStatePropertyAll(Size(drillDown ? width : 232, 0)),
      maximumSize: WidgetStatePropertyAll(
        Size(drillDown ? width : 360, double.infinity),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final drillDown = _drillDown;
    final style = _style(context, drillDown: drillDown);
    final radius =
        widget.borderRadius ??
        BorderRadius.circular(AppDensity.of(context).radiusMd);
    return MenuAnchor(
      controller: _controller,
      childFocusNode: _triggerFocus,
      // A click outside only closes the menu, as a native one does; it must
      // not also switch a tab or land in the terminal.
      consumeOutsideTap: true,
      // Panels honour the width range of [style].
      crossAxisUnconstrained: false,
      // Opens and closes at once, like a native menu. MenuAnchor's own
      // reveal takes 500 ms (popup menus here take 160), and while it
      // closes it would still swallow a click outside.
      animated: false,
      style: style,
      alignmentOffset: const Offset(0, 4),
      onOpen: _handleOpen,
      onClose: _handleClose,
      menuChildren: drillDown
          ? _drillDownChildren(context)
          : _cascadeChildren(context, widget.actions, style, top: true),
      builder: (context, controller, _) {
        final open = controller.isOpen;
        final keys = <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.arrowDown):
              _openFromKeyboard,
          if (!open) ...{
            const SingleActivator(LogicalKeyboardKey.enter): _openFromKeyboard,
            const SingleActivator(LogicalKeyboardKey.numpadEnter):
                _openFromKeyboard,
            const SingleActivator(LogicalKeyboardKey.space): _openFromKeyboard,
          },
        };
        Widget trigger = MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: InkWell(
            key: widget.triggerKey,
            focusNode: _triggerFocus,
            borderRadius: radius,
            onTap: _toggle,
            child: widget.builder(context, open, _hovered),
          ),
        );
        trigger = CallbackShortcuts(bindings: keys, child: trigger);
        trigger = Semantics(button: true, expanded: open, child: trigger);
        final tooltip = widget.tooltip;
        if (tooltip != null) {
          trigger = Tooltip(message: tooltip, child: trigger);
        }
        // The menu is not a route: without this, Android's Back (and the
        // browser's) would leave the page or the app under the open menu.
        return PopScope(
          canPop: !open,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || !_controller.isOpen) return;
            if (_path.isNotEmpty) {
              _back();
            } else {
              _controller.close();
            }
          },
          child: trigger,
        );
      },
    );
  }

  // ------------------------------------------------------------ cascading

  List<Widget> _cascadeChildren(
    BuildContext context,
    List<WorkspaceAction> actions,
    MenuStyle style, {
    bool top = false,
  }) {
    final shown = normalizeWorkspaceMenu(actions);
    final first = top ? shown.firstOrNull : null;
    return _menuLevel([
      for (final action in shown)
        if (action.isDivider)
          const _MenuDivider()
        else if (action.isSubmenu)
          SubmenuButton(
            key: ValueKey(action.id),
            focusNode: identical(action, first) ? _firstFocus : null,
            menuStyle: style,
            style: _rowStyle(context),
            // The submenu panel overlaps this panel's edge by 4 px; its
            // first row lines up with this one (SubmenuButton subtracts the
            // panel's top padding itself).
            alignmentOffset: Offset(AppDensity.of(context).blockInset - 4, 0),
            submenuIcon: WidgetStatePropertyAll(_chevron(context)),
            leadingIcon: _icon(context, action),
            menuChildren: _cascadeChildren(context, action.children, style),
            child: _label(context, action),
          )
        else
          _leaf(
            context,
            action,
            focusNode: identical(action, first) ? _firstFocus : null,
          ),
    ]);
  }

  /// One level of the menu, announced as a menu of menu items. A single
  /// child, so the panel's per-entry fade becomes one fade for the level.
  List<Widget> _menuLevel(List<Widget> entries) => [
    if (entries.isNotEmpty)
      Semantics(
        role: SemanticsRole.menu,
        container: true,
        explicitChildNodes: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: entries,
        ),
      ),
  ];

  Widget _chevron(BuildContext context) => Icon(
    Icons.chevron_right_rounded,
    size: AppDensity.of(context).menuIconSize,
    color: context.palette.muted,
  );

  // ----------------------------------------------------------- drill-down

  List<Widget> _drillDownChildren(BuildContext context) {
    // Follow the open path; a submenu that went away while open (the Vault
    // list after a lock, say) drops the reader back to the top.
    var level = normalizeWorkspaceMenu(widget.actions);
    WorkspaceAction? current;
    for (final id in _path) {
      final next = level
          .where((entry) => entry.isSubmenu && entry.id == id)
          .firstOrNull;
      if (next == null) {
        current = null;
        level = normalizeWorkspaceMenu(widget.actions);
        break;
      }
      current = next;
      level = normalizeWorkspaceMenu(next.children);
    }
    // At the top level the keyboard enters on the first entry; inside a
    // submenu, on the back row.
    final first = current == null ? level.firstOrNull : null;
    final entries = [
      for (final action in level)
        if (action.isDivider)
          const _MenuDivider()
        else if (action.isSubmenu)
          MenuItemButton(
            key: ValueKey(action.id),
            focusNode: identical(action, first) ? _firstFocus : null,
            closeOnActivate: false,
            style: _rowStyle(context),
            leadingIcon: _icon(context, action),
            trailingIcon: _chevron(context),
            onPressed: action.enabled ? () => _enter(action) : null,
            child: _label(context, action),
          )
        else
          _leaf(
            context,
            action,
            focusNode: identical(action, first) ? _firstFocus : null,
          ),
    ];
    if (current == null) return _menuLevel(entries);
    return _menuLevel([
      CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): _back,
          const SingleActivator(LogicalKeyboardKey.backspace): _back,
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MenuItemButton(
              key: const ValueKey('workspace_menu_back'),
              focusNode: _backFocus,
              closeOnActivate: false,
              style: _rowStyle(context),
              leadingIcon: Icon(
                Icons.chevron_left_rounded,
                size: AppDensity.of(context).menuIconSize,
              ),
              onPressed: _back,
              child: Semantics(
                role: SemanticsRole.menuItem,
                hint: MaterialLocalizations.of(context).backButtonTooltip,
                child: Text(
                  current.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const _MenuDivider(),
            ...entries,
          ],
        ),
      ),
    ]);
  }

  // -------------------------------------------------------------- entries

  Widget _leaf(
    BuildContext context,
    WorkspaceAction action, {
    FocusNode? focusNode,
  }) {
    final error = Theme.of(context).colorScheme.error;
    return Semantics(
      selected: action.checked ? true : null,
      child: MenuItemButton(
        key: ValueKey(action.id),
        focusNode: focusNode,
        leadingIcon: _icon(context, action),
        trailingIcon: action.checked
            ? Icon(
                Icons.check_rounded,
                size: AppDensity.of(context).menuIconSize,
                color: context.palette.accentText,
              )
            : null,
        onPressed: action.enabled ? () => _run(action) : null,
        style: _rowStyle(
          context,
          foreground: action.destructive ? error : null,
        ),
        child: _label(context, action),
      ),
    );
  }

  /// A row: [AppDensity.blockInset] in from the panel edge (the panel's
  /// padding), so its highlight takes the concentric radius of the panel.
  ButtonStyle _rowStyle(BuildContext context, {Color? foreground}) {
    final density = AppDensity.of(context);
    return MenuItemButton.styleFrom(
      foregroundColor: foreground,
      iconColor: foreground,
      shape: appleSquircleBorder(
        BorderRadius.circular(
          concentricRadius(density.radiusLg, density.blockInset),
        ),
        platform: Theme.of(context).platform,
      ),
    );
  }

  Widget _icon(BuildContext context, WorkspaceAction action) =>
      Icon(action.icon, size: AppDensity.of(context).menuIconSize);

  /// The entry's text. Its menu-item role merges into the button's own
  /// semantics node.
  Widget _label(BuildContext context, WorkspaceAction action) => Semantics(
    role: SemanticsRole.menuItem,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: Text(action.label, maxLines: 2, overflow: TextOverflow.ellipsis),
    ),
  );
}

/// [actions] as the workspace menu shows them: empty submenus dropped, a
/// one-entry submenu replaced by its entry, and no leading, trailing or
/// doubled dividers.
List<WorkspaceAction> normalizeWorkspaceMenu(List<WorkspaceAction> actions) {
  final out = <WorkspaceAction>[];
  for (final action in actions) {
    if (action.isDivider) {
      if (out.isNotEmpty && !out.last.isDivider) out.add(action);
      continue;
    }
    if (action.isSubmenu) {
      final children = normalizeWorkspaceMenu(action.children);
      if (children.isEmpty) continue;
      if (children.length == 1) {
        out.add(children.single);
        continue;
      }
      out.add(
        WorkspaceAction.submenu(
          action.id,
          action.label,
          action.icon,
          children,
          enabled: action.enabled,
        ),
      );
      continue;
    }
    out.add(action);
  }
  while (out.isNotEmpty && out.last.isDivider) {
    out.removeLast();
  }
  return out;
}

/// A soft rule between two sections, inset within the rows' rounded ends.
class _MenuDivider extends StatelessWidget {
  const _MenuDivider();

  @override
  Widget build(BuildContext context) {
    final inset = AppDensity.of(context).controlInset;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Divider(
        height: 1,
        thickness: isAppleContext(context) ? appleHairlineWidth(context) : 1,
        indent: inset,
        endIndent: inset,
        color: context.palette.separator,
      ),
    );
  }
}
