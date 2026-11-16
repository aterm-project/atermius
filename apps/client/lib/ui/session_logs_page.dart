import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../terminal/session_log.dart';
import 'app_theme.dart';
import 'ios_native/ios_native.dart';

enum _LogFilter { all, active, failed, closed }

String sessionLogFailureLabel(AppLocalizations l10n, SessionLogFailure f) =>
    switch (f) {
      SessionLogFailure.hostKeyRejected => l10n.r7NavLogFailureHostKeyRejected,
      SessionLogFailure.hostKeyChanged => l10n.r7NavLogFailureHostKeyChanged,
      SessionLogFailure.authentication => l10n.r7NavLogFailureAuthentication,
      SessionLogFailure.credential => l10n.r7NavLogFailureCredential,
      SessionLogFailure.network => l10n.r7NavLogFailureNetwork,
      SessionLogFailure.timeout => l10n.r7NavLogFailureTimeout,
      SessionLogFailure.cancelled => l10n.r7NavLogFailureCancelled,
      SessionLogFailure.unsupported => l10n.r7NavLogFailureUnsupported,
      SessionLogFailure.other => l10n.r7NavLogFailureOther,
    };

String sessionLogStatusLabel(AppLocalizations l10n, SessionLogEntry entry) =>
    switch (entry.status) {
      SessionLogStatus.connecting => l10n.r7NavLogStatusConnecting,
      SessionLogStatus.connected => l10n.r7NavLogStatusConnected,
      SessionLogStatus.failed => l10n.r7NavLogStatusFailed,
      SessionLogStatus.closed => switch (entry.endReason) {
        SessionLogEndReason.remote => l10n.r7NavLogStatusEndedByRemote,
        SessionLogEndReason.error => l10n.r7NavLogStatusLost,
        _ => l10n.r7NavLogStatusClosed,
      },
    };

final _timeFormat = DateFormat('yyyy-MM-dd HH:mm:ss');
String _time(DateTime value) => _timeFormat.format(value.toLocal());

String _duration(Duration value) {
  final h = value.inHours, m = value.inMinutes % 60, s = value.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// Home "Logs" destination: connection journal + optional transcripts.
/// Viewing never connects or runs anything on a remote host.
class SessionLogsPage extends StatefulWidget {
  const SessionLogsPage({super.key, required this.book, this.backLabel});

  final SessionLogBook book;
  final String? backLabel;

  @override
  State<SessionLogsPage> createState() => _SessionLogsPageState();
}

class _SessionLogsPageState extends State<SessionLogsPage> {
  final _search = TextEditingController();
  _LogFilter _filter = _LogFilter.all;

  @override
  void initState() {
    super.initState();
    // Picks up rows other windows of the same Profile wrote meanwhile.
    // Read-only: viewing never connects or runs anything remotely.
    widget.book.load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(SessionLogEntry entry) {
    final ok = switch (_filter) {
      _LogFilter.all => true,
      _LogFilter.active =>
        entry.status == SessionLogStatus.connected ||
            entry.status == SessionLogStatus.connecting,
      _LogFilter.failed => entry.status == SessionLogStatus.failed,
      _LogFilter.closed => entry.status == SessionLogStatus.closed,
    };
    if (!ok) return false;
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return entry.hostName.toLowerCase().contains(query) ||
        entry.endpoint.toLowerCase().contains(query);
  }

  Future<void> _confirmClear() async {
    final l10n = context.l10n;
    if (isIosPhone(context)) {
      final confirmed = await showIosDestructiveConfirm(
        context,
        title: l10n.r7NavLogClearTitle,
        message: l10n.r7NavLogClearBody,
        action: l10n.delete,
        cancel: l10n.cancel,
        actionKey: const ValueKey('session_logs_clear_confirm'),
      );
      if (confirmed) await widget.book.clear();
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.r7NavLogClearTitle),
        content: Text(l10n.r7NavLogClearBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('session_logs_clear_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (ok == true) await widget.book.clear();
  }

  void _openIosLogDetail(
    BuildContext context,
    SessionLogBook book,
    SessionLogEntry entry,
  ) {
    showIosFormSheet<void>(
      context,
      builder: (_) => _IosSessionLogDetailSheet(book: book, entry: entry),
    );
  }

  Widget _buildIosPhone(
    BuildContext context,
    SessionLogBook book,
    List<SessionLogEntry> rows,
  ) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final hasClearable = book.entries.any((e) => !book.isActive(e.id));

    final slivers = <Widget>[
      // 首组：会话输出记录开关与策略说明
      SliverToBoxAdapter(
        child: IosListSection(
          separatorIndent: IosListSection.indentForIcon(),
          footer:
              '${book.persistent ? l10n.r7NavLogStorageLocal : l10n.r7NavLogStorageMemory}\n${l10n.r7NavLogRecordPolicy(book.maxTranscripts, book.maxTranscriptBytes ~/ 1024)}',
          children: [
            IosSwitchRow(
              switchKey: const ValueKey('session_logs_record_toggle'),
              leading: IosIconTile(
                icon: Icons.history_edu_rounded,
                color: c.orange,
              ),
              label: l10n.r7NavLogRecordTranscripts,
              value: book.recordTranscripts,
              onChanged: (value) => book.setRecordTranscripts(value),
            ),
            if (book.storageFailed)
              IosListRow(
                leading: IosIconTile(icon: IosIcons.warning, color: c.red),
                title: Text(
                  l10n.r7NavLogStorageFailed,
                  key: const ValueKey('session_logs_storage_failed'),
                ),
                destructive: true,
              ),
          ],
        ),
      ),
      // 搜索槽 + 状态分段
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            IosMetrics.sectionMargin,
            0,
            IosMetrics.sectionMargin,
            10,
          ),
          child: buildIosSearchTextField(
            context,
            key: const ValueKey('session_logs_search'),
            controller: _search,
            placeholder: l10n.r7NavLogSearchHint,
            onChanged: (_) => setState(() {}),
            onSuffixTap: () => setState(() {}),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            IosMetrics.sectionMargin,
            0,
            IosMetrics.sectionMargin,
            18,
          ),
          child: SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<_LogFilter>(
              groupValue: _filter,
              backgroundColor: c.fill,
              thumbColor: c.isDark ? const Color(0xFF636366) : Colors.white,
              onValueChanged: (next) {
                if (next == null) return;
                HapticFeedback.selectionClick().catchError((Object _) {});
                setState(() => _filter = next);
              },
              children: {
                for (final filter in _LogFilter.values)
                  filter: Padding(
                    key: ValueKey('session_logs_filter_${filter.name}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 6,
                    ),
                    child: Text(
                      switch (filter) {
                        _LogFilter.all => l10n.r7NavLogFilterAll,
                        _LogFilter.active => l10n.r7NavLogFilterActive,
                        _LogFilter.failed => l10n.r7NavLogFilterFailed,
                        _LogFilter.closed => l10n.r7NavLogFilterClosed,
                      },
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: IosType.footnote.copyWith(
                        color: c.label,
                        fontWeight: _filter == filter
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
              },
            ),
          ),
        ),
      ),
    ];

    if (!book.loaded && book.persistent && !book.storageFailed) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CupertinoActivityIndicator(radius: 14)),
        ),
      );
    } else if (rows.isEmpty) {
      slivers.add(
        SliverIosEmptyState(
          child: IosEmptyState(
            key: const ValueKey('session_logs_empty'),
            icon: Icons.article_rounded,
            title: book.entries.isEmpty
                ? l10n.r7NavLogEmpty
                : l10n.r7NavLogNoMatches,
          ),
        ),
      );
    } else {
      slivers.add(
        SliverToBoxAdapter(
          child: IosListSection(
            separatorIndent: IosListSection.indentForIcon(),
            children: [
              for (final entry in rows)
                _IosSessionLogRow(
                  entry: entry,
                  live: book.isActive(entry.id),
                  onOpen: () => _openIosLogDetail(context, book, entry),
                  onDelete: book.isActive(entry.id)
                      ? null
                      : () => book.delete(entry.id),
                ),
            ],
          ),
        ),
      );
    }

    return KeyedSubtree(
      key: const ValueKey('session_logs_page'),
      child: IosLargeTitlePage(
        title: l10n.r7NavLogs,
        largeTitle: false,
        showBackButton: true,
        backLabel: widget.backLabel ?? (canPop ? l10n.settings : null),
        trailing: IosBarButton(
          key: const ValueKey('session_logs_clear'),
          icon: IosIcons.delete,
          semanticLabel: l10n.r7NavLogClearTitle,
          color: hasClearable ? c.destructive : c.tertiaryLabel,
          onPressed: hasClearable ? _confirmClear : null,
        ),
        slivers: slivers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AnimatedBuilder(
      animation: widget.book,
      builder: (context, _) {
        final book = widget.book;
        final rows = book.entries.where(_matches).toList();
        if (isIosPhone(context)) {
          return _buildIosPhone(context, book, rows);
        }
        return ListView(
          key: const ValueKey('session_logs_page'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.r7NavLogs,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  key: const ValueKey('session_logs_clear'),
                  tooltip: l10n.r7NavLogClearTitle,
                  onPressed: book.entries.any((e) => !book.isActive(e.id))
                      ? _confirmClear
                      : null,
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              book.persistent
                  ? l10n.r7NavLogStorageLocal
                  : l10n.r7NavLogStorageMemory,
              style: TextStyle(fontSize: 12, color: context.palette.muted),
            ),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: SwitchListTile(
                key: const ValueKey('session_logs_record_toggle'),
                dense: true,
                value: book.recordTranscripts,
                onChanged: (value) => book.setRecordTranscripts(value),
                title: Text(l10n.r7NavLogRecordTranscripts),
                subtitle: Text(
                  l10n.r7NavLogRecordPolicy(
                    book.maxTranscripts,
                    book.maxTranscriptBytes ~/ 1024,
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
            if (book.storageFailed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.r7NavLogStorageFailed,
                  key: const ValueKey('session_logs_storage_failed'),
                  style: TextStyle(color: context.palette.red, fontSize: 12),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('session_logs_search'),
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: l10n.r7NavLogSearchHint,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final filter in _LogFilter.values)
                  ChoiceChip(
                    key: ValueKey('session_logs_filter_${filter.name}'),
                    label: Text(switch (filter) {
                      _LogFilter.all => l10n.r7NavLogFilterAll,
                      _LogFilter.active => l10n.r7NavLogFilterActive,
                      _LogFilter.failed => l10n.r7NavLogFilterFailed,
                      _LogFilter.closed => l10n.r7NavLogFilterClosed,
                    }),
                    selected: _filter == filter,
                    onSelected: (_) => setState(() => _filter = filter),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (!book.loaded && book.persistent && !book.storageFailed)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(
                    book.entries.isEmpty
                        ? l10n.r7NavLogEmpty
                        : l10n.r7NavLogNoMatches,
                    key: const ValueKey('session_logs_empty'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.palette.muted),
                  ),
                ),
              )
            else
              for (final entry in rows)
                _SessionLogRow(
                  key: ValueKey('session_log_${entry.id}'),
                  entry: entry,
                  live: book.isActive(entry.id),
                  onOpen: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        _SessionLogDetailDialog(book: book, entry: entry),
                  ),
                ),
          ],
        );
      },
    );
  }
}

class _SessionLogRow extends StatelessWidget {
  const _SessionLogRow({
    super.key,
    required this.entry,
    required this.live,
    required this.onOpen,
  });

  final SessionLogEntry entry;
  final bool live;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (icon, color) = switch (entry.status) {
      SessionLogStatus.connecting => (Icons.sync, context.palette.orange),
      SessionLogStatus.connected => (Icons.link, context.palette.accentText),
      SessionLogStatus.failed => (Icons.error_outline, context.palette.red),
      SessionLogStatus.closed => (Icons.link_off, context.palette.muted),
    };
    final duration = entry.duration;
    final details = [
      _time(entry.startedAt),
      sessionLogStatusLabel(l10n, entry),
      if (entry.failure != null) sessionLogFailureLabel(l10n, entry.failure!),
      if (duration != null) _duration(duration),
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        onTap: onOpen,
        leading: Icon(icon, color: color, size: 20),
        title: Text(
          '${entry.hostName} — ${entry.endpoint}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          details,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        trailing: entry.hasTranscript || (live && entry.status ==
                    SessionLogStatus.connected)
            ? Tooltip(
                message: l10n.r7NavLogTranscript,
                child: const Icon(Icons.article_outlined, size: 18),
              )
            : null,
      ),
    );
  }
}

class _SessionLogDetailDialog extends StatefulWidget {
  const _SessionLogDetailDialog({required this.book, required this.entry});

  final SessionLogBook book;
  final SessionLogEntry entry;

  @override
  State<_SessionLogDetailDialog> createState() =>
      _SessionLogDetailDialogState();
}

class _SessionLogDetailDialogState extends State<_SessionLogDetailDialog> {
  late final Future<String?> _transcript = widget.book.transcript(
    widget.entry.id,
  );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entry = widget.entry;
    final live = widget.book.isActive(entry.id);
    final facts = <(String, String)>[
      (l10n.r7NavLogHost, entry.hostName),
      (l10n.r7NavLogEndpoint, entry.endpoint),
      (l10n.r7NavLogProtocol, entry.protocol.toUpperCase()),
      (l10n.r7NavLogStatus, sessionLogStatusLabel(l10n, entry)),
      if (entry.failure != null)
        (l10n.r7NavLogReason, sessionLogFailureLabel(l10n, entry.failure!)),
      (l10n.r7NavLogStarted, _time(entry.startedAt)),
      if (entry.connectedAt != null)
        (l10n.r7NavLogConnectedAt, _time(entry.connectedAt!)),
      if (entry.endedAt != null) (l10n.r7NavLogEnded, _time(entry.endedAt!)),
      if (entry.duration != null)
        (l10n.r7NavLogDuration, _duration(entry.duration!)),
      if (entry.viaJump) (l10n.r7NavLogRoute, l10n.r7NavLogRouteJump),
    ];
    return AlertDialog(
      key: const ValueKey('session_log_detail'),
      title: Text(entry.hostName, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (label, value) in facts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 120,
                        child: Text(
                          label,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.palette.muted,
                          ),
                        ),
                      ),
                      Expanded(
                        child: SelectableText(
                          value,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              Text(
                l10n.r7NavLogTranscript,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              FutureBuilder<String?>(
                future: _transcript,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const LinearProgressIndicator();
                  }
                  final text = snapshot.data;
                  if (text == null || text.isEmpty) {
                    return Text(
                      live
                          ? l10n.r7NavLogTranscriptLiveNotRecorded
                          : l10n.r7NavLogTranscriptNone,
                      key: const ValueKey('session_log_no_transcript'),
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.muted,
                      ),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (entry.transcriptTruncated)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            l10n.r7NavLogTranscriptTruncated,
                            style: TextStyle(
                              fontSize: 11,
                              color: context.palette.orange,
                            ),
                          ),
                        ),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 320),
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: context.palette.background,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: context.palette.line),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            text,
                            key: const ValueKey('session_log_transcript'),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: TextButton.icon(
                          onPressed: () =>
                              Clipboard.setData(ClipboardData(text: text)),
                          icon: const Icon(Icons.copy, size: 16),
                          label: Text(l10n.r7NavLogCopyTranscript),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (!live)
          TextButton(
            key: const ValueKey('session_log_delete'),
            onPressed: () async {
              await widget.book.delete(entry.id);
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(l10n.delete),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
      ],
    );
  }
}

class _IosSessionLogRow extends StatelessWidget {
  const _IosSessionLogRow({
    required this.entry,
    required this.live,
    required this.onOpen,
    this.onDelete,
  });

  final SessionLogEntry entry;
  final bool live;
  final VoidCallback onOpen;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final (IconData icon, Color tileColor) = switch (entry.status) {
      SessionLogStatus.connecting => (Icons.sync_rounded, c.orange),
      SessionLogStatus.connected => (Icons.link_rounded, c.green),
      SessionLogStatus.failed => (IosIcons.warning, c.red),
      SessionLogStatus.closed => (Icons.link_off_rounded, c.gray),
    };
    final duration = entry.duration;
    final details = [
      _time(entry.startedAt),
      sessionLogStatusLabel(l10n, entry),
      if (entry.failure != null) sessionLogFailureLabel(l10n, entry.failure!),
      if (duration != null) _duration(duration),
    ].join(' · ');

    final hasTranscript =
        entry.hasTranscript ||
        (live && entry.status == SessionLogStatus.connected);

    final row = IosListRow(
      key: ValueKey('session_log_${entry.id}'),
      minHeight: IosMetrics.hostRowHeight,
      leading: IosIconTile(icon: icon, color: tileColor),
      title: Text('${entry.hostName} — ${entry.endpoint}'),
      subtitle: Text(details),
      trailing: hasTranscript
          ? Icon(Icons.article_rounded, size: 18, color: c.secondaryLabel)
          : null,
      accessory: IosRowAccessory.chevron,
      onTap: onOpen,
    );

    if (onDelete == null) return row;
    return IosSwipeActionCell(
      trailing: [
        IosSwipeAction(
          key: ValueKey('ios_session_log_swipe_delete_${entry.id}'),
          label: l10n.delete,
          icon: IosIcons.delete,
          color: c.destructive,
          destructive: true,
          onTap: onDelete!,
        ),
      ],
      child: row,
    );
  }
}

class _IosSessionLogDetailSheet extends StatefulWidget {
  const _IosSessionLogDetailSheet({
    required this.book,
    required this.entry,
  });

  final SessionLogBook book;
  final SessionLogEntry entry;

  @override
  State<_IosSessionLogDetailSheet> createState() =>
      _IosSessionLogDetailSheetState();
}

class _IosSessionLogDetailSheetState extends State<_IosSessionLogDetailSheet> {
  late final Future<String?> _transcript = widget.book.transcript(
    widget.entry.id,
  );

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final entry = widget.entry;
    final live = widget.book.isActive(entry.id);
    final facts = <(String, String)>[
      (l10n.r7NavLogHost, entry.hostName),
      (l10n.r7NavLogEndpoint, entry.endpoint),
      (l10n.r7NavLogProtocol, entry.protocol.toUpperCase()),
      (l10n.r7NavLogStatus, sessionLogStatusLabel(l10n, entry)),
      if (entry.failure != null)
        (l10n.r7NavLogReason, sessionLogFailureLabel(l10n, entry.failure!)),
      (l10n.r7NavLogStarted, _time(entry.startedAt)),
      if (entry.connectedAt != null)
        (l10n.r7NavLogConnectedAt, _time(entry.connectedAt!)),
      if (entry.endedAt != null) (l10n.r7NavLogEnded, _time(entry.endedAt!)),
      if (entry.duration != null)
        (l10n.r7NavLogDuration, _duration(entry.duration!)),
      if (entry.viaJump) (l10n.r7NavLogRoute, l10n.r7NavLogRouteJump),
    ];

    return IosSheetScaffold(
      key: const ValueKey('session_log_detail'),
      title: entry.hostName,
      cancelLabel: l10n.close,
      children: [
        IosListSection(
          children: [
            for (final (label, value) in facts)
              IosListRow(title: Text(label), value: value),
          ],
        ),
        FutureBuilder<String?>(
          future: _transcript,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CupertinoActivityIndicator()),
              );
            }
            final text = snapshot.data;
            if (text == null || text.isEmpty) {
              return IosListSection(
                header: l10n.r7NavLogTranscript,
                children: [
                  IosListRow(
                    title: Text(
                      live
                          ? l10n.r7NavLogTranscriptLiveNotRecorded
                          : l10n.r7NavLogTranscriptNone,
                      key: const ValueKey('session_log_no_transcript'),
                      style: IosType.subheadline.copyWith(
                        color: c.secondaryLabel,
                      ),
                    ),
                  ),
                ],
              );
            }
            return IosListSection(
              header: l10n.r7NavLogTranscript,
              footer: entry.transcriptTruncated
                  ? l10n.r7NavLogTranscriptTruncated
                  : null,
              children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        text,
                        key: const ValueKey('session_log_transcript'),
                        style: IosType.mono.copyWith(color: c.label),
                      ),
                    ),
                  ),
                ),
                IosListActionRow(
                  icon: IosIcons.copy,
                  label: l10n.r7NavLogCopyTranscript,
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: text));
                    IosToast.show(
                      context,
                      l10n.r7NavLogCopyTranscript,
                      kind: IosToastKind.success,
                    );
                  },
                ),
              ],
            );
          },
        ),
        if (!live)
          IosListSection(
            children: [
              IosListActionRow(
                key: const ValueKey('session_log_delete'),
                icon: IosIcons.delete,
                label: l10n.delete,
                destructive: true,
                onTap: () async {
                  await widget.book.delete(entry.id);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
      ],
    );
  }
}
