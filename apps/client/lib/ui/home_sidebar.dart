import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'app_theme.dart';
import 'apple_hig.dart';

/// Home destinations shown in the Home LEFT sidebar. The sidebar exists only
/// on the Home surface; terminal/file panes never show it.
enum HomeDestination { hosts, groups, logs, forwarding, snippets, keychain, settings }

/// One footer action (for example an Import / Export menu entry).
@immutable
class HomeSidebarAction {
  const HomeSidebarAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.onSelected,
    this.enabled = true,
  });

  final String id;
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
  final bool enabled;
}

enum HomeSidebarLayout { labelled, rail, phoneRail }

/// Layout chosen from the Home surface width. Always a LEFT column: there is
/// no horizontal strip / second topbar variant.
HomeSidebarLayout homeSidebarLayoutFor(double width) => width >= 1000
    ? HomeSidebarLayout.labelled
    : width >= 600
    ? HomeSidebarLayout.rail
    : HomeSidebarLayout.phoneRail;

IconData homeDestinationIcon(HomeDestination destination) =>
    switch (destination) {
      HomeDestination.hosts => Icons.dns_outlined,
      HomeDestination.groups => Icons.folder_copy_outlined,
      HomeDestination.logs => Icons.receipt_long_outlined,
      HomeDestination.forwarding => Icons.hub_outlined,
      HomeDestination.snippets => Icons.code_rounded,
      HomeDestination.keychain => Icons.key_outlined,
      HomeDestination.settings => Icons.settings_outlined,
    };

String homeDestinationLabel(AppLocalizations l10n, HomeDestination destination) {
  return switch (destination) {
    HomeDestination.hosts => l10n.hosts,
    HomeDestination.groups => l10n.groups,
    HomeDestination.logs => l10n.r7NavLogs,
    HomeDestination.forwarding => l10n.r7NavPortForwarding,
    HomeDestination.snippets => l10n.r7NavSnippets,
    HomeDestination.keychain => l10n.r7NavKeychain,
    HomeDestination.settings => l10n.settings,
  };
}

/// Responsive Home navigation column.
///
/// * labelled (>= 1000 px): 200 px column with icon + label.
/// * rail (600–999 px): 72 px rail with icon + short label + tooltip.
/// * phoneRail (< 600 px): 52 px icon rail; each item keeps a 48 dp hit target,
///   tooltip and semantics label.
class HomeSidebar extends StatelessWidget {
  const HomeSidebar({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.destinations,
    this.layout,
    this.footerActions = const [],
    this.footerLabel,
    this.badges = const {},
  });

  final HomeDestination selected;
  final ValueChanged<HomeDestination> onSelect;

  /// Visible destinations in order. A destination whose page is not wired
  /// (for example forwarding before integration) is simply omitted.
  final List<HomeDestination> destinations;

  /// Forces a layout (tests); otherwise derived from the incoming width.
  final HomeSidebarLayout? layout;
  final List<HomeSidebarAction> footerActions;
  final String? footerLabel;
  final Map<HomeDestination, int> badges;

  static double widthFor(HomeSidebarLayout layout) => switch (layout) {
    HomeSidebarLayout.labelled => 200,
    HomeSidebarLayout.rail => 72,
    HomeSidebarLayout.phoneRail => 52,
  };

  @override
  Widget build(BuildContext context) {
    final mode =
        layout ?? homeSidebarLayoutFor(MediaQuery.sizeOf(context).width);
    final platform = Theme.of(context).platform;
    final apple = isAppleContext(context);
    final hairline = apple ? appleHairlineWidth(context) : 1.0;
    final dividerColor = apple
        ? context.palette.line.withValues(
            alpha: context.palette.isDark ? 0.55 : 0.68,
          )
        : context.palette.line.withValues(alpha: .8);
    final touch = switch (platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final itemHeight = mode == HomeSidebarLayout.rail
        ? 56.0
        : touch
        ? 48.0
        : 38.0;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: context.l10n.r7NavHomeNavigation,
      child: SizedBox(
        key: const ValueKey('home_sidebar'),
        width: widthFor(mode),
        child: AppleGlassBar(
          fallbackColor: context.palette.rail,
          sigma: 22,
          border: Border(
            right: BorderSide(
              color: apple ? appleGlassRimColor(context) : dividerColor,
              width: hairline,
            ),
          ),
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  children: [
                    for (final destination in destinations)
                      _HomeSidebarItem(
                        key: ValueKey('home_nav_${destination.name}'),
                        icon: homeDestinationIcon(destination),
                        label: homeDestinationLabel(context.l10n, destination),
                        selected: destination == selected,
                        layout: mode,
                        height: itemHeight,
                        badge: badges[destination] ?? 0,
                        onTap: () {
                          AppleHaptics.selection(context);
                          onSelect(destination);
                        },
                      ),
                  ],
                ),
              ),
              if (footerActions.isNotEmpty) ...[
                Divider(
                  height: 1,
                  thickness: hairline,
                  color: apple ? appleGlassRimColor(context) : context.palette.line,
                ),
                _HomeSidebarFooterMenu(
                  actions: footerActions,
                  label: footerLabel ?? context.l10n.r7NavImportExport,
                  layout: mode,
                  height: itemHeight,
                ),
                const SizedBox(height: 6),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeSidebarItem extends StatelessWidget {
  const _HomeSidebarItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.layout,
    required this.height,
    required this.badge,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final HomeSidebarLayout layout;
  final double height;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final apple = isAppleContext(context);
    final palette = context.palette;
    final color = selected ? palette.accentText : palette.muted;
    final iconWidget = Badge(
      isLabelVisible: badge > 0,
      label: Text('$badge'),
      child: Icon(icon, size: 18, color: color),
    );
    final Widget content = switch (layout) {
      HomeSidebarLayout.labelled => Row(
        children: [
          const SizedBox(width: 12),
          iconWidget,
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: selected ? palette.text : palette.muted,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
      HomeSidebarLayout.rail => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          iconWidget,
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10, color: color),
            ),
          ),
        ],
      ),
      HomeSidebarLayout.phoneRail => Center(child: iconWidget),
    };
    final itemRadius = BorderRadius.circular(apple ? 10 : 8);
    final borderSide = selected
        ? BorderSide(
            color: palette.accentText.withValues(
              alpha: apple ? (palette.isDark ? 0.24 : 0.20) : 0.28,
            ),
            width: apple ? appleHairlineWidth(context) : 1.0,
          )
        : BorderSide.none;
    final pillShape = appleSquircleBorder(
      itemRadius,
      platform: platform,
      side: borderSide,
    );
    final hitShape = appleSquircleBorder(
      itemRadius,
      platform: platform,
    );
    final pillColor = selected
        ? (palette.isDark
              ? palette.accent.withValues(alpha: apple ? 0.24 : 0.22)
              : palette.accentContainer.withValues(
                  alpha: apple ? 0.82 : 0.75,
                ))
        : Colors.transparent;
    final tile = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: layout == HomeSidebarLayout.labelled ? 8 : 4,
        vertical: 1.5,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: pillColor,
          shape: pillShape,
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: hitShape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: hitShape,
            hoverColor: palette.text.withValues(alpha: apple ? 0.05 : 0.06),
            highlightColor: apple
                ? palette.text.withValues(alpha: 0.08)
                : null,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: height),
              child: content,
            ),
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: layout == HomeSidebarLayout.labelled
          ? tile
          : Tooltip(message: label, child: tile),
    );
  }
}

class _HomeSidebarFooterMenu extends StatelessWidget {
  const _HomeSidebarFooterMenu({
    required this.actions,
    required this.label,
    required this.layout,
    required this.height,
  });

  final List<HomeSidebarAction> actions;
  final String label;
  final HomeSidebarLayout layout;
  final double height;

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final apple = isAppleContext(context);
    final footerShape = appleSquircleBorder(
      BorderRadius.circular(apple ? 10 : 8),
      platform: platform,
    );
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: layout == HomeSidebarLayout.labelled ? 8 : 4,
        vertical: 4,
      ),
      child: MenuAnchor(
        menuChildren: [
          for (final action in actions)
            MenuItemButton(
              key: ValueKey('home_nav_action_${action.id}'),
              leadingIcon: Icon(action.icon, size: 18),
              onPressed: action.enabled
                  ? () {
                      AppleHaptics.light(context);
                      action.onSelected();
                    }
                  : null,
              child: Text(action.label),
            ),
        ],
        builder: (context, controller, _) {
          void toggle() {
            AppleHaptics.selection(context);
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          }

          final icon = Icon(
            Icons.import_export_rounded,
            size: 18,
            color: context.palette.muted,
          );
          return Semantics(
            button: true,
            label: label,
            excludeSemantics: true,
            onTap: toggle,
            child: Tooltip(
              message: label,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: apple && controller.isOpen
                      ? context.palette.text.withValues(alpha: 0.06)
                      : Colors.transparent,
                  shape: footerShape,
                ),
                child: Material(
                  type: MaterialType.transparency,
                  shape: footerShape,
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const ValueKey('home_nav_import_export'),
                    customBorder: footerShape,
                    hoverColor: context.palette.text.withValues(
                      alpha: apple ? 0.05 : 0.06,
                    ),
                    onTap: toggle,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: height),
                      child: layout == HomeSidebarLayout.labelled
                          ? Row(
                              children: [
                                const SizedBox(width: 12),
                                icon,
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: context.palette.muted,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Center(child: icon),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
