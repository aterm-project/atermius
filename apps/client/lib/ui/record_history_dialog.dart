// Version history of one Vault record: the versions the server keeps, who
// made each one, what changed, and "Restore this version".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_controller.dart';
import '../crypto/jcs.dart';
import '../l10n/l10n.dart';
import '../sync/sync_repository.dart';
import 'app_density.dart';
import 'app_motion.dart';
import 'app_theme.dart';

/// Names of the fields that differ between two versions of one record.
///
/// Only names are returned, never values: a record may hold a password or a
/// private key, and this list is rendered as is.
List<String> recordHistoryChangedFields({
  required Map<String, dynamic> newer,
  required Map<String, dynamic> older,
}) {
  final names = <String>[];
  final keys = <String>{...older.keys, ...newer.keys}.toList()..sort();
  for (final key in keys) {
    if (key == 'id' || key == 'type' || key == 'deleted') continue;
    if (canonicalJson(newer[key]) == canonicalJson(older[key])) continue;
    names.add(
      key == '_manifest' ? 'attachments' : key.replaceAll('_', ' ').trim(),
    );
  }
  return names;
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
    this.restoreVersionForTesting,
    super.key,
  });

  final AppController app;
  final String recordId;
  final String recordName;
  final Future<RecordHistory> Function()? loadHistoryForTesting;
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
    return fields.isEmpty
        ? context.l10n.recordHistoryNoFieldChanges
        : context.l10n.recordHistoryChangedFields(fields.join(', '));
  }

  String _formatTime(DateTime time) =>
      DateFormat.yMMMd().add_jms().format(time.toLocal());

  Future<void> _restore(RecordHistoryEntry entry) async {
    if (_restoring) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.recordHistoryRestoreConfirmTitle),
        content: Text(
          context.l10n.recordHistoryRestoreConfirmBody(
            _formatTime(entry.createdAt),
          ),
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
      final restore = widget.restoreVersionForTesting;
      if (restore != null) {
        await restore(entry);
      } else {
        await app.restoreRecordVersion(
          recordId: widget.recordId,
          version: entry,
        );
      }
      if (!mounted) return;
      setState(() {
        _restoreNotice = context.l10n.recordHistoryRestored;
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
                      borderRadius: BorderRadius.circular(7),
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
