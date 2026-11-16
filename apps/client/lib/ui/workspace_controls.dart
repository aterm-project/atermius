import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';
import 'app_menu.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'apple_hig.dart';

const workspaceMenuShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(14)),
);

ShapeBorder workspaceMenuBorder(BuildContext context) {
  final theme = Theme.of(context);
  final platform = theme.platform;
  if (isApplePlatform(platform)) {
    return appleSquircleBorder(
      const BorderRadius.all(Radius.circular(12)),
      platform: platform,
      side: BorderSide(
        color: context.palette.line.withValues(
          alpha: context.palette.isDark ? 0.85 : 0.75,
        ),
        width: appleHairlineWidth(context),
      ),
    );
  }
  return theme.popupMenuTheme.shape ?? workspaceMenuShape;
}

class WorkspaceAction {
  const WorkspaceAction(
    this.id,
    this.label,
    this.icon,
    this.run, {
    this.enabled = true,
    this.destructive = false,
  });

  final String id;
  final String label;
  final IconData icon;
  final FutureOr<void> Function() run;
  final bool enabled;
  final bool destructive;
}

class WorkspaceOverflowMenu extends StatelessWidget {
  const WorkspaceOverflowMenu({
    required this.actions,
    this.tooltip,
    this.onOpened,
    this.child,
    super.key,
  });

  final List<WorkspaceAction> actions;
  final String? tooltip;
  final VoidCallback? onOpened;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final apple = isAppleContext(context);
    final palette = context.palette;
    final triggerShape = appleSquircleBorder(
      BorderRadius.circular(apple ? 10 : 8),
      platform: platform,
    );
    final customTrigger = child;
    return PopupMenuButton<String>(
      popUpAnimationStyle: AppMotion.menuStyle(context),
      shape: workspaceMenuBorder(context),
      color: apple ? palette.surfaceRaised : null,
      elevation: apple ? 10 : null,
      shadowColor: apple
          ? Colors.black.withValues(alpha: palette.isDark ? 0.45 : 0.14)
          : null,
      clipBehavior: Clip.antiAlias,
      tooltip: tooltip ?? context.l10n.more,
      onOpened: () {
        AppleHaptics.selection(context);
        onOpened?.call();
      },
      icon: customTrigger == null
          ? (apple
                ? DecoratedBox(
                    decoration: ShapeDecoration(shape: triggerShape),
                    child: const Icon(Icons.more_horiz),
                  )
                : const Icon(Icons.more_horiz))
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
        final action = actions.where((action) => action.id == id).firstOrNull;
        if (action == null || !action.enabled) return;
        AppleHaptics.light(context);
        try {
          await action.run();
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
  final apple = isAppleContext(context);
  final palette = context.palette;
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final localPosition = overlay.globalToLocal(position);
  final id = await showMenu<String>(
    popUpAnimationStyle: AppMotion.menuStyle(context),
    context: context,
    shape: workspaceMenuBorder(context),
    color: apple ? palette.surfaceRaised : null,
    elevation: apple ? 10 : null,
    shadowColor: apple
        ? Colors.black.withValues(alpha: palette.isDark ? 0.45 : 0.14)
        : null,
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
      await action.run();
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
}) => showAppDialog<void>(
  context: context,
  builder: (context) {
    final platform = Theme.of(context).platform;
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
          child: apple
              ? DecoratedBox(
                  decoration: ShapeDecoration(
                    color: palette.surfaceRaised,
                    shape: appleSquircleBorder(
                      BorderRadius.circular(10),
                      platform: platform,
                      side: BorderSide(
                        color: palette.line.withValues(
                          alpha: palette.isDark ? 0.65 : 0.80,
                        ),
                        width: appleHairlineWidth(context),
                      ),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: contentColumn,
                  ),
                )
              : contentColumn,
        ),
      ),
      actions: [
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
