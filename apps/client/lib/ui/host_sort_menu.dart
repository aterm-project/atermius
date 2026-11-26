import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/host_sort.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';

String hostSortLabel(AppLocalizations l10n, HostSortOrder order) =>
    switch (order) {
      HostSortOrder.recentRequested => l10n.hostSortRecentRequested,
      HostSortOrder.nameAscending => l10n.hostSortNameAscending,
      HostSortOrder.nameDescending => l10n.hostSortNameDescending,
      HostSortOrder.address => l10n.hostSortAddress,
      HostSortOrder.protocol => l10n.hostSortProtocol,
      HostSortOrder.favoritesFirst => l10n.hostSortFavoritesFirst,
    };

class HostSortMenu extends StatelessWidget {
  const HostSortMenu({super.key, this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final controller = HostSortController.instance;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final label = hostSortLabel(context.l10n, controller.order);
        return PopupMenuButton<HostSortOrder>(
          key: const ValueKey('home_host_sort'),
          tooltip: context.l10n.hostSortCurrent(label),
          initialValue: controller.order,
          // Hover/press ink takes the control radius.
          borderRadius: BorderRadius.circular(AppDensity.of(context).radiusMd),
          onSelected: (order) => unawaited(controller.select(order)),
          itemBuilder: (context) => [
            for (final order in HostSortOrder.values)
              CheckedPopupMenuItem(
                value: order,
                checked: controller.order == order,
                child: Text(hostSortLabel(context.l10n, order)),
              ),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.sort_rounded, size: 22),
                if (!compact) ...[const SizedBox(width: 8), Text(label)],
              ],
            ),
          ),
        );
      },
    );
  }
}
