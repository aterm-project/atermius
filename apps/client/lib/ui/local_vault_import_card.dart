import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../storage/local_host_repository.dart';
import '../sync/local_vault_import.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'insecure_server_widgets.dart';
import 'page_kit.dart';
import 'password_field.dart';

/// Settings › Sync and conflicts › "Local-only profiles": the whole UI of
/// importing a LocalVault into the server. The import runs in
/// [LocalVaultImport], so it goes on (and its progress keeps updating) when
/// Settings is closed.
class LocalVaultImportCard extends StatefulWidget {
  const LocalVaultImportCard({
    required this.import,
    this.insecureServerOrigin,
    super.key,
  });

  final LocalVaultImport import;

  /// The records go to the signed-in server: its development-only insecure
  /// state stays in view here too.
  final String? insecureServerOrigin;

  @override
  State<LocalVaultImportCard> createState() => _LocalVaultImportCardState();
}

class _LocalVaultImportCardState extends State<LocalVaultImportCard> {
  @override
  void initState() {
    super.initState();
    widget.import.addListener(_changed);
    unawaited(widget.import.refresh());
  }

  @override
  void didUpdateWidget(LocalVaultImportCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.import, widget.import)) {
      oldWidget.import.removeListener(_changed);
      widget.import.addListener(_changed);
      unawaited(widget.import.refresh());
    }
  }

  @override
  void dispose() {
    widget.import.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  LocalVaultImport get _import => widget.import;

  /// Runs [action] with the stored key, asking for the profile's password
  /// (again, after a wrong one) when that is needed.
  Future<void> _withPassword(
    Future<LocalImportAccess> Function(String? password) action,
  ) async {
    var access = await action(null);
    while (mounted &&
        (access == LocalImportAccess.passwordRequired ||
            access == LocalImportAccess.passwordRejected)) {
      final password = await _askPassword(
        rejected: access == LocalImportAccess.passwordRejected,
      );
      if (password == null || !mounted) return;
      access = await action(password);
    }
  }

  Future<String?> _askPassword({required bool rejected}) =>
      showAppDialog<String>(
        context: context,
        builder: (_) => _PasswordDialog(rejected: rejected),
      );

  Future<void> _startImport(LocalImportProfile profile) => _withPassword(
    (password) => _import.importProfile(profile.profileId, password: password),
  );

  Future<void> _resume(
    LocalImportProfile profile,
    LocalMigrationJournalSummary journal,
  ) => _withPassword(
    (password) => _import.resume(
      profile.profileId,
      journal.migrationId,
      password: password,
    ),
  );

  Future<void> _cancel(
    LocalImportProfile profile,
    LocalMigrationJournalSummary journal,
  ) => _withPassword(
    (password) => _import.cancelPreparation(
      profile.profileId,
      journal.migrationId,
      password: password,
    ),
  );

  Future<void> _abandon(
    LocalImportProfile profile,
    LocalMigrationJournalSummary journal,
  ) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.localImportAbandonTitle),
        content: Text(context.l10n.theLocalSourceWillBecomeWritable),
        actions: [
          TextButton(
            key: const ValueKey('migration_abandon_cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('migration_abandon_confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.localImportAbandonConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _withPassword(
      (password) => _import.abandon(
        profile.profileId,
        journal.migrationId,
        password: password,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PagePanel(
    key: const ValueKey('local_vault_import_card'),
    icon: Icons.upload_rounded,
    title: context.l10n.localOnlyProfiles,
    subtitle: context.l10n.moveEncryptedLocalHostsCredentialsGroups,
    children: _body(context),
  );

  List<Widget> _body(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    if (_import.storageRecoveryRequired) {
      return [
        _Line(
          key: const ValueKey('migration_storage_recovery_message'),
          icon: Icons.storage_rounded,
          tone: palette.orange,
          text: l10n.aLocalStorageWriteWasInterrupted,
        ),
        const SizedBox(height: 10),
        _Actions(
          children: [
            OutlinedButton.icon(
              key: const ValueKey('migration_storage_reload'),
              onPressed: _import.reloadPage,
              icon: const Icon(Icons.refresh),
              label: Text(l10n.reloadPage),
            ),
          ],
        ),
      ];
    }
    final children = <Widget>[
      if (widget.insecureServerOrigin case final origin?) ...[
        InsecureServerIndicator(
          key: const ValueKey('insecure_server_indicator'),
          origin: origin,
        ),
        const SizedBox(height: 12),
      ],
    ];
    final progress = _import.progress;
    final profiles = _import.profiles;
    if (progress == null && profiles.isEmpty) {
      if (!_import.loaded) {
        children.add(const LinearProgressIndicator(minHeight: 2));
      } else if (_import.listFailed) {
        children
          ..add(
            _Line(
              icon: Icons.error_outline_rounded,
              tone: palette.red,
              text: l10n.localImportProfilesUnreadable,
            ),
          )
          ..add(const SizedBox(height: 10))
          ..add(
            _Actions(
              children: [
                OutlinedButton.icon(
                  onPressed: _import.loading ? null : _import.refresh,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.retry),
                ),
              ],
            ),
          );
      } else {
        children.add(
          Text(
            l10n.localImportNoProfiles,
            key: const ValueKey('local_import_no_profiles'),
            style: TextStyle(color: palette.muted, fontSize: 13, height: 1.45),
          ),
        );
      }
      return children;
    }

    final busy = _import.busy;
    if (profiles.length > 1) {
      children
        ..add(
          // A new field when the selection changes from elsewhere (an
          // automatic resume selects its profile).
          KeyedSubtree(
            key: ValueKey('migration_profile_${_import.selectedProfileId}'),
            child: DropdownButtonFormField<String>(
              key: const ValueKey('migration_profile_select'),
              initialValue: _import.selectedProfileId,
              decoration: InputDecoration(labelText: l10n.localProfile),
              items: [
                for (final profile in profiles)
                  DropdownMenuItem(
                    value: profile.profileId,
                    child: Text(
                      l10n.localProfileSubstring(
                        profile.createdAt.toLocal().toIso8601String().substring(
                          0,
                          10,
                        ),
                      ),
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (id) {
                      if (id != null) _import.selectProfile(id);
                    },
            ),
          ),
        )
        ..add(const SizedBox(height: 12));
    }

    if (progress != null &&
        (progress.profileId == _import.selectedProfileId ||
            _import.selectedProfile == null)) {
      children.add(_progress(context, progress));
      return children;
    }
    final profile = _import.selectedProfile;
    if (profile == null) return children;
    children.addAll(_status(context, profile, busy: busy));
    return children;
  }

  Widget _progress(BuildContext context, LocalImportProgress progress) {
    final l10n = context.l10n;
    final palette = context.palette;
    final text = switch (progress.phase) {
      LocalImportPhase.preparing => l10n.localImportPreparing,
      LocalImportPhase.encrypting => l10n.localImportEncrypting(
        progress.done,
        progress.total,
      ),
      LocalImportPhase.uploading => l10n.localImportUploading(
        progress.done,
        progress.total,
      ),
      LocalImportPhase.verifying => l10n.localImportVerifying,
    };
    final measured =
        progress.total > 0 &&
        (progress.phase == LocalImportPhase.encrypting ||
            progress.phase == LocalImportPhase.uploading);
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            text,
            key: const ValueKey('local_import_progress'),
            style: TextStyle(
              color: palette.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            key: const ValueKey('local_import_progress_bar'),
            minHeight: 3,
            value: measured
                ? (progress.done / progress.total).clamp(0, 1).toDouble()
                : null,
          ),
          const SizedBox(height: 8),
          Text(
            progress.waitingForServer
                ? l10n.localImportWaitingForServer
                : l10n.localImportRunningNote,
            style: TextStyle(color: palette.muted, fontSize: 12, height: 1.45),
          ),
        ],
      ),
    );
  }

  List<Widget> _status(
    BuildContext context,
    LocalImportProfile profile, {
    required bool busy,
  }) {
    final l10n = context.l10n;
    final palette = context.palette;
    final result = _import.resultFor(profile.profileId);
    final journal = profile.interrupted.firstOrNull;
    final instanceId = _import.destination.instanceId;
    final lines = <Widget>[];
    final actions = <Widget>[];

    switch (result?.outcome) {
      case LocalImportOutcome.completed:
        lines.add(
          _Line(
            key: const ValueKey('local_import_done'),
            icon: Icons.cloud_done_outlined,
            tone: palette.teal,
            text: l10n.localImportCompleted(
              result!.recordCount,
              result.vaultName ?? '',
            ),
          ),
        );
      case LocalImportOutcome.failed:
        lines.add(
          _Line(
            key: const ValueKey('local_import_error'),
            icon: Icons.error_outline_rounded,
            tone: palette.red,
            text: result!.message ?? '',
          ),
        );
      case LocalImportOutcome.paused:
        lines.add(
          _Line(
            key: const ValueKey('local_import_paused'),
            icon: Icons.pause_circle_outline_rounded,
            tone: palette.orange,
            text: result!.message ?? '',
          ),
        );
      case LocalImportOutcome.stopped:
        lines.add(
          _Line(
            key: const ValueKey('local_import_stopped'),
            icon: Icons.info_outline_rounded,
            tone: palette.teal,
            text: result!.message ?? '',
          ),
        );
      case null:
        break;
    }

    if (journal != null) {
      final empty = profile.cancelableIds.contains(journal.migrationId);
      final here = empty || journal.targetInstanceId == instanceId;
      if (result == null) {
        lines.add(
          _Line(
            key: ValueKey('migration_interrupted_${journal.migrationId}'),
            icon: Icons.pause_circle_outline_rounded,
            tone: palette.orange,
            text: empty
                ? l10n.localImportInterruptedEmpty
                : here
                ? l10n.localImportInterrupted(
                    journal.stagedItemCount,
                    journal.itemCount,
                  )
                : l10n.localImportInterruptedOtherServer,
          ),
        );
      }
      if (here) {
        actions.add(
          FilledButton.icon(
            key: ValueKey('migration_resume_${journal.migrationId}'),
            onPressed: busy ? null : () => _resume(profile, journal),
            icon: const Icon(Icons.replay_rounded),
            label: Text(
              result?.outcome == LocalImportOutcome.failed
                  ? l10n.retry
                  : l10n.localImportResume,
            ),
          ),
        );
      }
      actions.add(
        empty
            ? TextButton(
                key: ValueKey('migration_cancel_${journal.migrationId}'),
                onPressed: busy ? null : () => _cancel(profile, journal),
                child: Text(l10n.localImportCancelPreparation),
              )
            : TextButton(
                key: ValueKey('migration_abandon_${journal.migrationId}'),
                onPressed: busy ? null : () => _abandon(profile, journal),
                child: Text(l10n.localImportAbandon),
              ),
      );
    } else {
      final completed = profile.lastCompleted;
      if (result == null &&
          completed != null &&
          completed.targetInstanceId == instanceId) {
        lines.add(
          _Line(
            key: const ValueKey('local_import_done'),
            icon: Icons.cloud_done_outlined,
            tone: palette.teal,
            text: l10n.localImportCompleted(
              completed.itemCount,
              _import.destination.vaultName(completed.targetVaultId),
            ),
          ),
        );
      }
      if (result?.outcome == LocalImportOutcome.failed) {
        actions.add(
          FilledButton.icon(
            key: const ValueKey('local_import_retry'),
            onPressed: busy ? null : () => _startImport(profile),
            icon: const Icon(Icons.replay_rounded),
            label: Text(l10n.retry),
          ),
        );
      } else {
        actions.add(
          OutlinedButton.icon(
            key: const ValueKey('local_to_sync_migration_open'),
            onPressed: busy ? null : () => _startImport(profile),
            icon: const Icon(Icons.upload_rounded),
            label: Text(l10n.localImportButton),
          ),
        );
      }
    }

    return [
      for (final line in lines) ...[line, const SizedBox(height: 10)],
      _Actions(children: actions),
    ];
  }
}

/// Asks for a local profile's password; pops it, or null when cancelled.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.rejected});

  /// The previous password did not unlock the profile.
  final bool rejected;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  // Owned by the dialog: it is still drawn while the route animates out.
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    if (_password.text.isEmpty) return;
    Navigator.of(context).pop(_password.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.localImportPasswordTitle),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.localImportPasswordBody,
            style: TextStyle(color: context.palette.muted, height: 1.45),
          ),
          const SizedBox(height: 14),
          PasswordField(
            fieldKey: const ValueKey('migration_profile_password'),
            controller: _password,
            autofocus: true,
            decoration: InputDecoration(
              labelText: context.l10n.localProfilePassword,
              errorText: widget.rejected
                  ? context.l10n.couldntUnlockOrVerifyThisLocal
                  : null,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(context.l10n.cancel),
      ),
      FilledButton(
        key: const ValueKey('migration_password_submit'),
        onPressed: _submit,
        child: Text(context.l10n.localImportUnlock),
      ),
    ],
  );
}

class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.tone,
    required this.text,
    super.key,
  });

  final IconData icon;
  final Color tone;
  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 18, color: tone),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: context.palette.text,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Actions extends StatelessWidget {
  const _Actions({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Wrap(spacing: 8, runSpacing: 8, children: children),
  );
}

/// Shows a SnackBar when an import finishes in the background, wherever the
/// user is in the workspace.
class LocalVaultImportNotices extends StatefulWidget {
  const LocalVaultImportNotices({
    required this.import,
    required this.child,
    super.key,
  });

  final LocalVaultImport? import;
  final Widget child;

  @override
  State<LocalVaultImportNotices> createState() =>
      _LocalVaultImportNoticesState();
}

class _LocalVaultImportNoticesState extends State<LocalVaultImportNotices> {
  @override
  void initState() {
    super.initState();
    widget.import?.addListener(_changed);
    // A notice of an import that finished while the workspace was locked.
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  @override
  void didUpdateWidget(LocalVaultImportNotices oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.import, widget.import)) {
      oldWidget.import?.removeListener(_changed);
      widget.import?.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.import?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final notice = widget.import?.takeNotice();
    if (notice == null) return;
    messenger.showSnackBar(
      SnackBar(
        key: const ValueKey('local_import_notice'),
        content: Text(notice),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
