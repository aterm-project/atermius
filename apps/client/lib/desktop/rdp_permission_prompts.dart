import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../ui/app_density.dart';
import 'rdp_permissions.dart';

/// Shown when the user starts an RDP connection on Android that maps local
/// storage while All files access is off, before Android's own screen opens
/// (a Settings page on Android 11+, which would otherwise appear without
/// context). Pops with the [RdpStorageChoice]; there is no barrier dismissal
/// so every outcome is a deliberate choice.
class RdpStorageExplanationDialog extends StatelessWidget {
  const RdpStorageExplanationDialog({
    super.key,
    required this.hostName,
    required this.offerDontMap,
  });

  final String hostName;

  /// Adds "Don't map disks for this host" (turns the device-local switch
  /// off); only while that switch is on.
  final bool offerDontMap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    void choose(RdpStorageChoice choice) => Navigator.of(context).pop(choice);
    return AlertDialog(
      key: const ValueKey('rdp_storage_explanation'),
      icon: const Icon(Icons.sd_storage_outlined),
      title: Text(l10n.rdpStorageAccessTitle),
      content: SizedBox(
        width: appDialogWidth(context, 480),
        child: SingleChildScrollView(
          child: Text(l10n.rdpStorageAccessBody(hostName)),
        ),
      ),
      actions: [
        if (offerDontMap)
          TextButton(
            key: const ValueKey('rdp_storage_dont_map'),
            onPressed: () => choose(RdpStorageChoice.dontMap),
            child: Text(l10n.rdpStorageAccessDontMap),
          ),
        TextButton(
          key: const ValueKey('rdp_storage_not_now'),
          onPressed: () => choose(RdpStorageChoice.notNow),
          child: Text(l10n.rdpStorageAccessNotNow),
        ),
        FilledButton(
          key: const ValueKey('rdp_storage_grant'),
          onPressed: () => choose(RdpStorageChoice.grant),
          child: Text(l10n.rdpStorageAccessGrant),
        ),
      ],
    );
  }
}
