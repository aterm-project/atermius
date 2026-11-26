import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import '../ui/app_density.dart';
import '../ui/atermius_icons.dart';
import '../ui/surfaces.dart';

/// Icon used for a Host protocol in menus, search results and lists. RDP has
/// the app's own mark so it is never mistaken for VNC's plain monitor.
IconData hostProtocolIcon(HostProtocol protocol) => switch (protocol) {
  HostProtocol.ssh => Icons.terminal,
  HostProtocol.telnet => Icons.settings_ethernet,
  HostProtocol.rdp => AtermiusIcons.remoteDesktop,
  HostProtocol.vnc => Icons.desktop_windows_outlined,
};

/// Icon of an open session (workspace tabs, connect actions): every text
/// terminal shows the terminal glyph, a remote desktop its protocol's icon.
IconData hostSessionIcon(HostProtocol protocol) =>
    protocol.isTerminal ? Icons.terminal : hostProtocolIcon(protocol);

/// Honest plaintext warning shown in Telnet host editors and before a Telnet
/// connection. It makes no TLS or security claim for the connection; the
/// saved Host metadata itself stays encrypted in the Vault/profile.
class TelnetPlaintextNotice extends StatelessWidget {
  const TelnetPlaintextNotice({super.key, this.dense = false});

  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;
    return Semantics(
      container: true,
      label: l10n.telnetPlaintextWarningTitle,
      child: Container(
        key: const ValueKey('telnet_plaintext_notice'),
        width: double.infinity,
        padding: EdgeInsets.all(dense ? 8 : 12),
        // A tinted status block; its corners follow the block it sits in.
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(
            SurfaceScope.concentric(
              context,
              fallback: AppDensity.of(context).radiusLg,
              floor: AppDensity.of(context).radiusMd,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.no_encryption_gmailerrorred_outlined,
              size: 20,
              color: scheme.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.telnetPlaintextWarningTitle,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.telnetPlaintextWarningBody,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
