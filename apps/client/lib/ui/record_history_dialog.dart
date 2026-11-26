// Version history of one Vault record: the versions the server keeps, who
// made each one, what changed, and "Restore this version".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../crypto/jcs.dart';
import '../desktop/desktop_resolution.dart' show vncSettingsManifestKey;
import '../desktop/rdp_settings.dart' show rdpSettingsManifestKey;
import '../domain/ansible_inventory_metadata.dart'
    show ansibleInventoryManifestKey;
import '../domain/host_operating_system.dart'
    show hostOperatingSystemManifestKey;
import '../l10n/l10n.dart';
import '../sync/sync_repository.dart';
import 'app_density.dart';
import 'app_motion.dart';
import 'app_theme.dart';

/// Plaintext keys of the fields that differ between two versions of one
/// record, sorted.
///
/// The manifest holds unrelated settings side by side (attachments, RDP and
/// VNC settings, legacy SSH, the detected operating system), so a manifest
/// change is reported per entry as `_manifest.<entry>`; a manifest that is
/// not a map on either side is reported as `_manifest`.
///
/// Only keys are returned, never values: a record may hold a password or a
/// private key. [recordHistoryFieldLabel] turns a key into what is shown.
List<String> recordHistoryChangedFields({
  required Map<String, dynamic> newer,
  required Map<String, dynamic> older,
}) {
  final names = <String>[];
  final keys = <String>{...older.keys, ...newer.keys}.toList()..sort();
  for (final key in keys) {
    if (key == 'id' || key == 'type' || key == 'deleted') continue;
    if (canonicalJson(newer[key]) == canonicalJson(older[key])) continue;
    final newerValue = newer[key];
    final olderValue = older[key];
    if (key == _manifestKey &&
        (newerValue == null || newerValue is Map) &&
        (olderValue == null || olderValue is Map)) {
      final newerManifest = (newerValue as Map?) ?? const {};
      final olderManifest = (olderValue as Map?) ?? const {};
      final entries = <String>{
        for (final entry in [...olderManifest.keys, ...newerManifest.keys])
          '$entry',
      }.toList()..sort();
      for (final entry in entries) {
        if (canonicalJson(newerManifest[entry]) ==
            canonicalJson(olderManifest[entry])) {
          continue;
        }
        names.add('$_manifestKey.$entry');
      }
      continue;
    }
    names.add(key);
  }
  return names;
}

const _manifestKey = '_manifest';

/// The label the editor of a [recordType] record shows for the plaintext
/// field [field], in the language of [l10n]. A field without an editor label
/// (one a newer client added, say) falls back to its key with underscores
/// turned into spaces. The label never includes the field's value.
String recordHistoryFieldLabel(
  AppLocalizations l10n,
  Object? recordType,
  String field,
) {
  if (field == _manifestKey) return l10n.attachments;
  if (field.startsWith('$_manifestKey.')) {
    final entry = field.substring(_manifestKey.length + 1);
    return switch (entry) {
      'attachments' || 'object_refs' => l10n.attachments,
      rdpSettingsManifestKey => l10n.rdpOptions,
      vncSettingsManifestKey => l10n.vncDisplay,
      'ssh_legacy_algorithms' => l10n.legacySshCompatibility,
      hostOperatingSystemManifestKey => l10n.recordHistoryFieldDetectedOs,
      ansibleInventoryManifestKey => l10n.recordHistoryFieldAnsibleImport,
      _ => entry.replaceAll('_', ' ').trim(),
    };
  }
  final label = switch (recordType) {
    'host' => switch (field) {
      'name' => l10n.displayName,
      'address' => l10n.hostnameOrIp,
      'port' => l10n.port2,
      'protocol' => l10n.protocol,
      'rdp_cert_sha256' => l10n.rdpCertificateSha256Optional,
      'username' => l10n.username,
      'group_id' => l10n.group,
      'credential_id' => l10n.r7NavKeychain,
      'login' => l10n.r7NavSignInOwn,
      'jump_host_id' => l10n.jumpHost,
      'auth_kind' => l10n.authentication,
      'color' => l10n.color2,
      'tags' => l10n.tags,
      'port_forward_profiles' => l10n.r7NavPortForwarding,
      'is_favorite' => l10n.favorite,
      _ => null,
    },
    'credential' => switch (field) {
      'name' => l10n.credentialName2,
      'username' => l10n.sshUsername,
      'kind' => l10n.authenticationType,
      'secret' => l10n.password,
      'private_key' => l10n.pemPrivateKey,
      'passphrase' => l10n.keyPassphraseOptional,
      'fingerprint' => l10n.recordHistoryFieldKeyFingerprint,
      'certificate' => l10n.r7NavCertificateOptional,
      _ => null,
    },
    'group' => switch (field) {
      'name' => l10n.groupName3,
      'color' => l10n.color2,
      'parent_id' => l10n.parentGroup2,
      'default_credential_id' => l10n.defaultSshCredential,
      _ => null,
    },
    'snippet' => switch (field) {
      'title' => l10n.title,
      'body' => l10n.scriptBody2,
      'shell_kind' => l10n.shellLabel2,
      'execution_mode' => l10n.executionMode,
      'program' => l10n.program2,
      'arguments' => l10n.argumentsJsonArray2,
      'parameters' => l10n.parameterDefinitionsJsonArray2,
      // The editor's own label ("Tags, separated by commas") would read as
      // two entries of this comma-separated list.
      'tags' => l10n.tags,
      _ => null,
    },
    _ => null,
  };
  return label ?? field.replaceAll('_', ' ').trim();
}

Future<void> showRecordHistoryDialog(
  BuildContext context, {
  required AppController app,
  required String recordId,
  required String recordName,
}) => showAppDialog<void>(
  context: context,
  builder: (_) =>
      RecordHistoryDialog(app: app, recordId: recordId, recordName: recordName),
);

class RecordHistoryDialog extends StatefulWidget {
  const RecordHistoryDialog({
    required this.app,
    required this.recordId,
    required this.recordName,
    this.loadHistoryForTesting,
    this.planRestoreForTesting,
    this.restoreVersionForTesting,
    super.key,
  });

  final AppController app;
  final String recordId;
  final String recordName;
  final Future<RecordHistory> Function()? loadHistoryForTesting;

  /// Stands in for the attachment check of a restore; its answer is also
  /// taken as the outcome when [restoreVersionForTesting] is set.
  final Future<RecordRestoreOutcome> Function(RecordHistoryEntry version)?
  planRestoreForTesting;
  final Future<void> Function(RecordHistoryEntry version)?
  restoreVersionForTesting;

  @override
  State<RecordHistoryDialog> createState() => _RecordHistoryDialogState();
}

class _RecordHistoryDialogState extends State<RecordHistoryDialog> {
  AppController get app => widget.app;
  late Future<RecordHistory> _history;
  bool _restoring = false;
  String? _restoreError;
  String? _restoreNotice;

  @override
  void initState() {
    super.initState();
    _history = _load();
  }

  Future<RecordHistory> _load() =>
      widget.loadHistoryForTesting?.call() ??
      app.loadRecordHistory(widget.recordId);

  void _reload() {
    setState(() {
      _restoreError = null;
      _history = _load();
    });
  }

  bool get _canRestore =>
      app.activeVault?.canWrite == true && app.activeVault?.status == 'active';

  String _deviceLabel(BuildContext context, String deviceId) {
    if (deviceId == app.identity?.deviceId) {
      return context.l10n.recordHistoryThisDevice;
    }
    final name = app.deviceDisplayName(deviceId);
    if (name != null) return name;
    return context.l10n.recordHistoryNode(
      deviceId.length > 8 ? deviceId.substring(0, 8) : deviceId,
    );
  }

  String _operationLabel(BuildContext context, String? operation) =>
      switch (operation) {
        'create' => context.l10n.recordHistoryOpCreated,
        'delete' => context.l10n.recordHistoryOpDeleted,
        'restore' => context.l10n.recordHistoryOpRestored,
        _ => context.l10n.recordHistoryOpUpdated,
      };

  /// What changed against the next older listed version.
  String? _changeSummary(
    BuildContext context,
    RecordHistoryEntry entry,
    RecordHistoryEntry? previous,
  ) {
    final content = entry.plaintext;
    if (!entry.verified || content == null || entry.deleted) return null;
    if (previous == null) {
      return entry.operation == 'create'
          ? null
          : context.l10n.recordHistoryEarliestKept;
    }
    final previousContent = previous.plaintext;
    if (!previous.verified || previousContent == null || previous.deleted) {
      return null;
    }
    final fields = recordHistoryChangedFields(
      newer: content,
      older: previousContent,
    );
    if (fields.isEmpty) return context.l10n.recordHistoryNoFieldChanges;
    final l10n = context.l10n;
    final labels = <String>{
      for (final field in fields)
        recordHistoryFieldLabel(l10n, content['type'], field),
    };
    return l10n.recordHistoryChangedFields(labels.join(', '));
  }

  String _formatTime(DateTime time) =>
      DateFormat.yMMMd().add_jms().format(time.toLocal());

  String? _nothingToRestoreNotice(RecordRestoreOutcome outcome) =>
      switch (outcome) {
        RecordRestoreOutcome.nothingToRestore =>
          context.l10n.recordHistoryNothingToRestore,
        RecordRestoreOutcome.nothingToRestoreAttachmentsGone =>
          context.l10n.recordHistoryNothingToRestoreAttachmentsGone,
        _ => null,
      };

  bool get _testing =>
      widget.planRestoreForTesting != null ||
      widget.restoreVersionForTesting != null;

  Future<void> _restore(RecordHistoryEntry entry) async {
    if (_restoring) return;
    // Ask the server about the version's attachment objects first, so the
    // confirmation can say what will happen to the attachments.
    setState(() {
      _restoring = true;
      _restoreError = null;
      _restoreNotice = null;
    });
    late final RecordRestoreOutcome planned;
    try {
      planned = _testing
          ? await widget.planRestoreForTesting?.call(entry) ??
                RecordRestoreOutcome.unchanged
          : await app.planRecordVersionRestore(
              recordId: widget.recordId,
              version: entry,
            );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _restoring = false;
        _restoreError = app.friendlyError(error);
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _restoring = false;
      // Nothing to confirm when the restore would write nothing.
      _restoreNotice = _nothingToRestoreNotice(planned);
    });
    if (_restoreNotice != null) return;
    final isHost = entry.plaintext?['type'] == 'host';
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.recordHistoryRestoreConfirmTitle),
        // One plain text, so the iPhone alert adaptation still applies.
        content: Text(
          [
            context.l10n.recordHistoryRestoreConfirmBody(
              _formatTime(entry.createdAt),
            ),
            switch (planned) {
              RecordRestoreOutcome.restored =>
                context.l10n.recordHistoryRestoreAttachmentsRestored,
              RecordRestoreOutcome.keptCurrent =>
                context.l10n.recordHistoryRestoreAttachmentsKept,
              RecordRestoreOutcome.unchanged when isHost =>
                context.l10n.recordHistoryRestoreAttachmentsUnchanged,
              RecordRestoreOutcome.unchanged ||
              RecordRestoreOutcome.nothingToRestore ||
              RecordRestoreOutcome.nothingToRestoreAttachmentsGone => null,
            },
          ].nonNulls.join('\n\n'),
          key: const ValueKey('record_history_restore_confirm_body'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('record_history_restore_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.recordHistoryRestoreThis),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _restoring = true;
      _restoreError = null;
      _restoreNotice = null;
    });
    try {
      // The outcome is the one of the restore itself: the server may have
      // dropped an object since the confirmation was shown.
      var outcome = planned;
      if (_testing) {
        await widget.restoreVersionForTesting?.call(entry);
      } else {
        outcome = await app.restoreRecordVersion(
          recordId: widget.recordId,
          version: entry,
        );
      }
      if (!mounted) return;
      setState(() {
        _restoreNotice =
            _nothingToRestoreNotice(outcome) ??
            switch (outcome) {
              RecordRestoreOutcome.restored =>
                context.l10n.recordHistoryRestoredWithAttachments,
              RecordRestoreOutcome.keptCurrent =>
                context.l10n.recordHistoryRestoredKeptAttachments,
              _ => context.l10n.recordHistoryRestored,
            };
        _history = _load();
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _restoreError = app.friendlyError(error));
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.l10n.recordHistoryTitleFor(widget.recordName)),
    content: SizedBox(
      width: appDialogWidth(context, 620),
      child: FutureBuilder<RecordHistory>(
        future: _history,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 150,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.error is RecordHistoryUnavailableException) {
            return SizedBox(
              height: 150,
              child: Center(
                child: Text(
                  context.l10n.recordHistoryNotAvailable,
                  key: const ValueKey('record_history_unavailable'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.palette.muted),
                ),
              ),
            );
          }
          if (snapshot.hasError) {
            return SizedBox(
              height: 150,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    app.friendlyError(snapshot.error!),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.palette.red),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const ValueKey('record_history_retry'),
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(context.l10n.retry2),
                  ),
                ],
              ),
            );
          }
          final history = snapshot.data!;
          final entries = history.entries;
          final limit = history.historyLimit ?? app.recordHistoryLimit;
          final canRestore = _canRestore;
          final muted = TextStyle(fontSize: 12, color: context.palette.muted);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (limit != null)
                Text(context.l10n.recordHistoryKeepsLimit(limit), style: muted),
              if (!canRestore) ...[
                const SizedBox(height: 4),
                Text(
                  context.l10n.recordHistoryReadOnly,
                  key: const ValueKey('record_history_read_only'),
                  style: muted,
                ),
              ],
              if (_restoreNotice case final notice?) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    notice,
                    style: TextStyle(color: context.palette.lime),
                  ),
                ),
              ],
              if (_restoreError case final error?) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    style: TextStyle(color: context.palette.red),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              if (entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 30),
                  child: Center(
                    child: Text(
                      context.l10n.recordHistoryEmpty,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: context.palette.muted),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return _RecordHistoryRow(
                        entry: entry,
                        time: _formatTime(entry.createdAt),
                        headline: entry.verified
                            ? '${_operationLabel(context, entry.operation)} · '
                                  '${_deviceLabel(context, entry.deviceId ?? '')}'
                            : null,
                        summary: _changeSummary(
                          context,
                          entry,
                          index + 1 < entries.length
                              ? entries[index + 1]
                              : null,
                        ),
                        onRestore:
                            canRestore &&
                                !_restoring &&
                                entry.verified &&
                                !entry.deleted &&
                                !entry.isCurrent &&
                                entry.plaintext != null
                            ? () => unawaited(_restore(entry))
                            : null,
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.close),
      ),
    ],
  );
}

class _RecordHistoryRow extends StatelessWidget {
  const _RecordHistoryRow({
    required this.entry,
    required this.time,
    required this.headline,
    required this.summary,
    required this.onRestore,
  });

  final RecordHistoryEntry entry;
  final String time;

  /// Operation and device; null for an entry that could not be verified.
  final String? headline;
  final String? summary;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(fontSize: 12, color: context.palette.muted);
    return Card(
      key: ValueKey('record_history_entry_${entry.revisionId}'),
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(13, 10, 9, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  !entry.verified
                      ? Icons.lock_outline_rounded
                      : entry.deleted
                      ? Icons.delete_outline
                      : Icons.history_rounded,
                  size: 17,
                  color: entry.verified
                      ? context.palette.teal
                      : context.palette.orange,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    time,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (entry.isCurrent)
                  Container(
                    key: ValueKey('record_history_current_${entry.revisionId}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: context.palette.teal.withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(
                        AppDensity.of(context).radiusSm,
                      ),
                    ),
                    child: Text(
                      context.l10n.recordHistoryCurrent,
                      style: TextStyle(
                        fontSize: 11,
                        color: context.palette.teal,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (headline case final text?)
              Text(text, style: muted)
            else
              Text(
                context.l10n.recordHistoryUnreadable,
                key: ValueKey('record_history_unreadable_${entry.revisionId}'),
                style: muted.copyWith(color: context.palette.orange),
              ),
            if (summary case final text?) ...[
              const SizedBox(height: 2),
              Text(text, style: muted),
            ],
            if (onRestore != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: ValueKey('record_history_restore_${entry.revisionId}'),
                  onPressed: onRestore,
                  icon: const Icon(Icons.restore_rounded, size: 17),
                  label: Text(context.l10n.recordHistoryRestoreThis),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
