import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';
import 'app_menu.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'apple_hig.dart';
import 'surfaces.dart';
import 'dialog_frames.dart';

/// Shape of the workspace menus: a floating block with the block radius
/// (a squircle on Apple platforms) and no outline; the menu's shadow sets it
/// off from what it floats over.
OutlinedBorder workspaceMenuBorder(BuildContext context) => appleSquircleBorder(
  BorderRadius.circular(AppDensity.of(context).radiusLg),
  platform: Theme.of(context).platform,
);

class WorkspaceAction {
  const WorkspaceAction(
    this.id,
    this.label,
    this.icon,
    this.run, {
    this.enabled = true,
    this.destructive = false,
    this.checked = false,
  }) : children = const [],
       _kind = _WorkspaceActionKind.action;

  /// A submenu entry. Only the workspace menu ([WorkspaceMenu]) opens it;
  /// flat menus never receive one.
  const WorkspaceAction.submenu(
    this.id,
    this.label,
    this.icon,
    this.children, {
    this.enabled = true,
  }) : run = _noAction,
       destructive = false,
       checked = false,
       _kind = _WorkspaceActionKind.submenu;

  /// A line between two sections of the workspace menu.
  const WorkspaceAction.divider()
    : id = _dividerId,
      label = '',
      icon = Icons.horizontal_rule,
      run = _noAction,
      enabled = false,
      destructive = false,
      checked = false,
      children = const [],
      _kind = _WorkspaceActionKind.divider;

  static const _dividerId = '-';
  static void _noAction() {}

  final String id;
  final String label;
  final IconData icon;
  final FutureOr<void> Function() run;
  final bool enabled;
  final bool destructive;

  /// Marks the current choice in a set of alternatives (the open Vault).
  final bool checked;

  /// Entries of a submenu; empty for an ordinary action.
  final List<WorkspaceAction> children;
  final _WorkspaceActionKind _kind;

  bool get isDivider => _kind == _WorkspaceActionKind.divider;
  bool get isSubmenu => _kind == _WorkspaceActionKind.submenu;
}

enum _WorkspaceActionKind { action, submenu, divider }

/// Every runnable entry of [actions], submenus opened, dividers dropped.
List<WorkspaceAction> flattenWorkspaceActions(List<WorkspaceAction> actions) =>
    [
      for (final action in actions)
        if (action.isSubmenu)
          ...flattenWorkspaceActions(action.children)
        else if (!action.isDivider)
          action,
    ];

class WorkspaceOverflowMenu extends StatelessWidget {
  const WorkspaceOverflowMenu({
    required this.actions,
    this.tooltip,
    this.onOpened,
    this.onClosed,
    this.icon,
    this.padding = const EdgeInsets.all(8),
    this.child,
    this.borderRadius,
    super.key,
  });

  final List<WorkspaceAction> actions;
  final String? tooltip;
  final VoidCallback? onOpened;

  /// Called when the menu closes, with or without a choice (before the
  /// chosen action runs).
  final VoidCallback? onClosed;

  /// Replaces the three-dot trigger icon.
  final Widget? icon;
  final EdgeInsetsGeometry padding;
  final Widget? child;

  /// Shape of the ink on a custom [child] trigger.
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final apple = isAppleContext(context);
    final triggerShape = appleSquircleBorder(
      BorderRadius.circular(AppDensity.of(context).radiusMd),
      platform: platform,
    );
    final customTrigger = child;
    // Looked up now: the menu closes (and a pane handle may drop this button)
    // before the chosen action runs.
    final frame = DialogFrames.frameIdOf(context);
    return PopupMenuButton<String>(
      popUpAnimationStyle: AppMotion.menuStyle(context),
      // Fill, elevation and soft shadow come from the menu theme on every
      // platform.
      shape: workspaceMenuBorder(context),
      clipBehavior: Clip.antiAlias,
      borderRadius: borderRadius,
      tooltip: tooltip ?? context.l10n.more,
      padding: padding,
      onOpened: () {
        AppleHaptics.selection(context);
        onOpened?.call();
      },
      onCanceled: onClosed,
      icon: customTrigger == null
          ? (apple
                ? DecoratedBox(
                    decoration: ShapeDecoration(shape: triggerShape),
                    child: icon ?? const Icon(Icons.more_horiz),
                  )
                : icon ?? const Icon(Icons.more_horiz))
          : null,
      child: customTrigger == null
          ? null
          : (apple
                ? DecoratedBox(
                    decoration: ShapeDecoration(shape: triggerShape),
                    child: customTrigger,
                  )
                : customTrigger),
      onSelected: (id) async {
        onClosed?.call();
        final action = actions.where((action) => action.id == id).firstOrNull;
        if (action == null || !action.enabled) return;
        AppleHaptics.light(context);
        try {
          // Dialogs of a pane's own menu open in that pane.
          await DialogFrames.runInFrame(frame, action.run);
        } on Object {
          if (context.mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              SnackBar(
                content: Text(context.l10n.theActionDidntCompleteTryAgain),
              ),
            );
          }
        }
      },
      itemBuilder: (_) => actions
          .map(
            (action) => appMenuItem<String>(
              context,
              key: ValueKey(action.id),
              value: action.id,
              enabled: action.enabled,
              child: AppMenuLabel(
                action.icon,
                action.label,
                color: action.destructive
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
          )
          .toList(),
    );
  }
}

Future<void> showWorkspaceContextMenu(
  BuildContext context,
  Offset position,
  List<WorkspaceAction> actions,
) async {
  AppleHaptics.selection(context);
  final frame = DialogFrames.frameIdOf(context);
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final localPosition = overlay.globalToLocal(position);
  final id = await showMenu<String>(
    popUpAnimationStyle: AppMotion.menuStyle(context),
    context: context,
    shape: workspaceMenuBorder(context),
    clipBehavior: Clip.antiAlias,
    position: RelativeRect.fromRect(
      Rect.fromLTWH(localPosition.dx, localPosition.dy, 1, 1),
      Offset.zero & overlay.size,
    ),
    items: actions
        .map(
          (action) => appMenuItem<String>(
            context,
            value: action.id,
            enabled: action.enabled,
            child: AppMenuLabel(
              action.icon,
              action.label,
              color: action.destructive
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
          ),
        )
        .toList(),
  );
  if (id == null || !context.mounted) return;
  final action = actions.where((entry) => entry.id == id).firstOrNull;
  if (action != null && action.enabled) {
    AppleHaptics.light(context);
    try {
      await DialogFrames.runInFrame(frame, action.run);
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(context.l10n.theActionDidntCompleteTryAgain)),
        );
      }
    }
  }
}

Future<void> showHostProperties(
  BuildContext context,
  HostRecord host, {
  String? state,
  VoidCallback? onEdit,
}) => showAppDialog<void>(
  context: context,
  builder: (context) {
    final apple = isAppleContext(context);
    final palette = context.palette;
    final rows = [
      for (final entry in <String, String>{
        context.l10n.name: host.name,
        context.l10n.address: host.address,
        context.l10n.port2: '${host.port}',
        context.l10n.userName: host.username,
        context.l10n.protocol2: host.protocol == HostProtocol.ssh
            ? 'SSH / SFTP / SCP'
            : host.protocol == HostProtocol.telnet
            ? context.l10n.telnetProtocolUnencrypted
            : host.protocol.label,
        context.l10n.propertyAuthentication:
            host.protocol == HostProtocol.telnet
            ? context.l10n.telnetInteractiveLogin
            : host.authKind == AuthKind.password
            ? context.l10n.password2
            : context.l10n.sshKey,
        context.l10n.propertyStatus: ?state,
        context.l10n.propertyRoute: host.jumpHostId == null
            ? context.l10n.directConnection2
            : context.l10n.viaJumpHost,
        if (host.tags.isNotEmpty)
          context.l10n.propertyTags: host.tags.join(', '),
      }.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 112,
                child: Text(
                  entry.key,
                  style: apple ? TextStyle(color: palette.muted) : null,
                ),
              ),
              Expanded(child: SelectableText(entry.value)),
            ],
          ),
        ),
    ];
    final contentColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
    return AlertDialog(
      title: Text(context.l10n.connectionProperties),
      content: SizedBox(
        width: appDialogWidth(context, 400),
        child: SingleChildScrollView(
          // Apple groups the rows in an inset block (the next fill level
          // inside the dialog, no outline).
          child: apple
              ? AppBlock(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: contentColumn,
                )
              : contentColumn,
        ),
      ),
      actions: [
        if (onEdit != null)
          TextButton.icon(
            key: const ValueKey('host_properties_edit'),
            onPressed: () {
              AppleHaptics.selection(context);
              Navigator.pop(context);
              onEdit();
            },
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: Text(context.l10n.editHost),
          ),
        TextButton(
          onPressed: () {
            AppleHaptics.selection(context);
            Navigator.pop(context);
          },
          child: Text(context.l10n.close2),
        ),
      ],
    );
  },
);
