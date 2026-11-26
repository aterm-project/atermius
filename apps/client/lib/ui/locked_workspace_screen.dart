import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';
import 'surfaces.dart';
import 'app_theme.dart';
import 'apple_hig.dart';
import 'insecure_server_widgets.dart';
import 'ios_native/ios_native.dart';
import 'ios_native/ios_unlock_view.dart';
import 'password_field.dart';

AppPalette _lockedPaletteOf(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<AppPalette>() ?? AppPalette.fallback(theme.brightness);
}

class LockedWorkspaceScreen extends StatefulWidget {
  const LockedWorkspaceScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<LockedWorkspaceScreen> createState() => _LockedWorkspaceScreenState();
}

class _LockedWorkspaceScreenState extends State<LockedWorkspaceScreen> {
  final _password = TextEditingController();

  AppController get app => widget.controller;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    AppleHaptics.light(context);
    try {
      await app.unlockLockedWorkspace(password: _password.text);
      _password.clear();
    } catch (_) {
      // AppController retains the safe, user-facing error.
    }
  }

  Future<void> _receiveNow() async {
    try {
      await app.synchronize(background: false, suppressSuccessNotice: true);
    } catch (_) {
      // AppController retains the safe, user-facing error.
    }
  }

  Future<void> _signOut() async {
    try {
      await app.logout();
    } catch (_) {
      // AppController clears local credentials even if the server is offline.
    }
  }

  String get _statusLabel => switch (app.syncStatus) {
    'locked_receiving' => context.l10n.receivingSignedEncryptedChanges,
    'locked_ready' => context.l10n.encryptedChangesAreUpToDate,
    'locked_no_vault' => context.l10n.noVaultIsCurrentlyAvailable,
    'unlock_required' => context.l10n.unlockToVerifyTheLatestVault,
    'auth_required' => context.l10n.accountSessionExpiredSignInAgain,
    'revoked' => context.l10n.thisDeviceOrVaultAccessWas,
    'retry_wait' => context.l10n.encryptedSyncWillRetryWhenThe,
    // Other states (idle, syncing, ...) describe the unlocked workspace and
    // have no meaning here; never show the internal state name.
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    if (isIosPhone(context)) {
      final vaultId = app.activeVault?.id;
      final shortVault = vaultId != null && vaultId.isNotEmpty
          ? (vaultId.length > 8 ? vaultId.substring(0, 8) : vaultId)
          : null;
      return IosUnlockView(
        wrapInScaffold: true,
        title: context.l10n.workspaceLocked,
        vaultName: shortVault,
        subtitle: context.l10n.yourAccountStaysSignedInWhile,
        statusLabel: _statusLabel,
        statusBusy: app.syncStatus == 'locked_receiving',
        errorText: app.errorMessage,
        passwordController: _password,
        passwordPlaceholder: context.l10n.accountPassword,
        unlockLabel: context.l10n.unlockWorkspace,
        busy: app.busy,
        onUnlock: _unlock,
        secondaryActions: [
          if (app.activeVault != null &&
              app.syncStatus != 'unlock_required' &&
              app.syncStatus != 'revoked')
            IosUnlockAction(
              label: context.l10n.receiveEncryptedChangesNow,
              icon: Icons.sync_rounded,
              onPressed: app.syncing ? null : _receiveNow,
            ),
          IosUnlockAction(
            label: context.l10n.signOut,
            icon: Icons.logout_rounded,
            destructive: true,
            onPressed: app.busy ? null : _signOut,
          ),
        ],
      );
    }
    final theme = Theme.of(context);
    final density = AppDensity.of(context);
    final palette = _lockedPaletteOf(context);
    final panelRadius = BorderRadius.circular(density.radiusDialog);

    final unlockCard = Card(
      // A Card merges its content into one accessibility node by default.
      // That turned the password field into a card-sized field announced as
      // "Workspace locked. Your account stays signed in…", with the status
      // line lying on top of it.
      semanticContainer: false,
      margin: EdgeInsets.zero,
      elevation: 0,
      color: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: SizedBox.square(
                dimension: 56,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: palette.isDark
                        ? palette.accent.withValues(alpha: 0.2)
                        : palette.accentContainer.withValues(alpha: 0.8),
                    shape: appleSquircleBorder(
                      BorderRadius.circular(density.radiusLg),
                      platform: theme.platform,
                    ),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.lock_outline,
                      size: 28,
                      color: palette.accentText,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              context.l10n.workspaceLocked,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            Text(
              context.l10n.yourAccountStaysSignedInWhile,
              textAlign: TextAlign.center,
            ),
            if (app.insecureServerOrigin case final insecureOrigin?) ...[
              const SizedBox(height: 14),
              InsecureServerIndicator(
                key: const ValueKey('insecure_server_indicator'),
                origin: insecureOrigin,
              ),
            ],
            if (_statusLabel.isNotEmpty) ...[
              const SizedBox(height: 18),
              Semantics(
                container: true,
                liveRegion: true,
                label: _statusLabel,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (app.syncStatus == 'locked_receiving') ...[
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 9),
                    ],
                    Flexible(child: Text(_statusLabel)),
                  ],
                ),
              ),
            ],
            if (app.errorMessage != null) ...[
              const SizedBox(height: 14),
              Text(
                app.errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 22),
            PasswordField(
              fieldKey: const ValueKey('locked_workspace_password'),
              controller: _password,
              enabled: !app.busy,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _unlock(),
              decoration: InputDecoration(
                labelText: context.l10n.accountPassword,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: app.busy ? null : _unlock,
              icon: const Icon(Icons.lock_open),
              label: Text(context.l10n.unlockWorkspace),
            ),
            if (app.activeVault != null &&
                app.syncStatus != 'unlock_required' &&
                app.syncStatus != 'revoked') ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: app.syncing ? null : _receiveNow,
                icon: const Icon(Icons.sync),
                label: Text(context.l10n.receiveEncryptedChangesNow),
              ),
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: app.busy ? null : _signOut,
              icon: const Icon(Icons.logout),
              label: Text(context.l10n.signOut),
            ),
          ],
        ),
      ),
    );

    return Scaffold(
      body: AmbientCanvas(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 24).clamp(
                    0,
                    double.infinity,
                  ),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: appDialogWidth(context, 460),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: GlassSurface(
                        borderRadius: panelRadius,
                        tint: palette.surface,
                        sigma: 26,
                        elevated: true,
                        child: unlockCard,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
