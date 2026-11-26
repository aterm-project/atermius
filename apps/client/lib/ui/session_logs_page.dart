import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../terminal/session_log.dart';
import 'app_density.dart';
import 'app_theme.dart';
import 'ios_native/ios_native.dart';
import 'page_kit.dart';
import 'surfaces.dart';
import 'app_motion.dart';

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

  static bool _inFilter(SessionLogEntry entry, _LogFilter filter) =>
      switch (filter) {
        _LogFilter.all => true,
        _LogFilter.active =>
          entry.status == SessionLogStatus.connected ||
              entry.status == SessionLogStatus.connecting,
        _LogFilter.failed => entry.status == SessionLogStatus.failed,
        _LogFilter.closed => entry.status == SessionLogStatus.closed,
      };

  /// [query] is trimmed and lower-cased.
  static bool _hasQuery(SessionLogEntry entry, String query) =>
      query.isEmpty ||
      entry.hostName.toLowerCase().contains(query) ||
      entry.endpoint.toLowerCase().contains(query);

  bool _matches(SessionLogEntry entry) =>
      _inFilter(entry, _filter) &&
      _hasQuery(entry, _search.text.trim().toLowerCase());

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
    final ok = await showAppDialog<bool>(
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
    return AnimatedBuilder(
      animation: widget.book,
      builder: (context, _) {
        final book = widget.book;
        final rows = book.entries.where(_matches).toList();
        if (isIosPhone(context)) {
          return _buildIosPhone(context, book, rows);
        }
        return _buildPage(context, book, rows);
      },
    );
  }

  Widget _buildPage(
    BuildContext context,
    SessionLogBook book,
    List<SessionLogEntry> rows,
  ) {
    final l10n = context.l10n;
    final palette = context.palette;
    final loading = !book.loaded && book.persistent && !book.storageFailed;
    return ListView(
      key: const ValueKey('session_logs_page'),
      padding: AppDensity.of(context).pagePadding,
      children: [
        PageHeader(
          title: l10n.r7NavLogs,
          subtitle: book.persistent
              ? l10n.r7NavLogStorageLocal
              : l10n.r7NavLogStorageMemory,
          actions: [
            OutlinedButton.icon(
              key: const ValueKey('session_logs_clear'),
              onPressed: book.entries.any((e) => !book.isActive(e.id))
                  ? _confirmClear
                  : null,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: Text(l10n.r7NavLogClearTitle),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _RecordingPanel(book: book),
        if (book.storageFailed) ...[
          const SizedBox(height: 10),
          PageNotice(
            key: const ValueKey('session_logs_storage_failed'),
            icon: Icons.error_outline_rounded,
            tone: palette.red,
            message: l10n.r7NavLogStorageFailed,
          ),
        ],
        const SizedBox(height: 22),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (book.entries.isEmpty)
          const _LogsEmptyState()
        else ...[
          _toolbar(context, book),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            _LogsNoMatches(
              onReset: () => setState(() {
                _search.clear();
                _filter = _LogFilter.all;
              }),
            )
          else
            _SessionLogList(
              children: [
                for (final entry in rows)
                  _SessionLogRow(
                    key: ValueKey('session_log_${entry.id}'),
                    entry: entry,
                    live: book.isActive(entry.id),
                    onOpen: () => showAppDialog<void>(
                      context: context,
                      builder: (_) =>
                          _SessionLogDetailDialog(book: book, entry: entry),
                    ),
                  ),
              ],
            ),
        ],
      ],
    );
  }

  /// Search field and the status filters, each with the number of rows it
  /// would show for the current search.
  Widget _toolbar(BuildContext context, SessionLogBook book) {
    final l10n = context.l10n;
    final palette = context.palette;
    final search = TextField(
      key: const ValueKey('session_logs_search'),
      controller: _search,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 18),
        hintText: l10n.r7NavLogSearchHint,
      ),
    );
    final query = _search.text.trim().toLowerCase();
    final filters = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final filter in _LogFilter.values)
          _FilterPill(
            key: ValueKey('session_logs_filter_${filter.name}'),
            label: switch (filter) {
              _LogFilter.all => l10n.r7NavLogFilterAll,
              _LogFilter.active => l10n.r7NavLogFilterActive,
              _LogFilter.failed => l10n.r7NavLogFilterFailed,
              _LogFilter.closed => l10n.r7NavLogFilterClosed,
            },
            tone: switch (filter) {
              _LogFilter.all => null,
              _LogFilter.active => palette.teal,
              _LogFilter.failed => palette.red,
              _LogFilter.closed => palette.muted,
            },
            count: book.entries
                .where(
                  (entry) =>
                      _inFilter(entry, filter) && _hasQuery(entry, query),
                )
                .length,
            selected: _filter == filter,
            onSelected: () => setState(() => _filter = filter),
          ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [search, const SizedBox(height: 10), filters],
          );
        }
        return Row(
          children: [
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: search,
                ),
              ),
            ),
            const SizedBox(width: 16),
            filters,
          ],
        );
      },
    );
  }
}

/// The transcript setting: what it records, its limits and the switch.
class _RecordingPanel extends StatelessWidget {
  const _RecordingPanel({required this.book});

  final SessionLogBook book;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final limits = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _LimitChip(
          icon: Icons.inventory_2_outlined,
          label: l10n.logsRecordKeepCount(book.maxTranscripts),
        ),
        _LimitChip(
          icon: Icons.data_usage_rounded,
          label: l10n.logsRecordSizeLimit(book.maxTranscriptBytes ~/ 1024),
        ),
        _LimitChip(
          icon: Icons.visibility_off_outlined,
          label: l10n.logsRecordSecretsHint,
          tone: palette.orange,
        ),
      ],
    );
    final toggle = Switch(
      key: const ValueKey('session_logs_record_toggle'),
      value: book.recordTranscripts,
      onChanged: (value) => book.setRecordTranscripts(value),
    );
    return LayoutBuilder(
      builder: (context, box) {
        // On a phone the explanation takes the panel's full width instead
        // of the narrow column beside the switch.
        final narrow = box.maxWidth < 480;
        return PagePanel(
          icon: Icons.history_edu_outlined,
          title: l10n.r7NavLogRecordTranscripts,
          subtitle: narrow ? null : l10n.logsRecordSubtitle,
          trailing: toggle,
          children: [
            if (narrow) ...[
              Text(
                l10n.logsRecordSubtitle,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: palette.muted,
                ),
              ),
              const SizedBox(height: 10),
            ],
            limits,
          ],
        );
      },
    );
  }
}

class _LimitChip extends StatelessWidget {
  const _LimitChip({required this.icon, required this.label, this.tone});

  final IconData icon;
  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = tone ?? palette.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: tone == null ? palette.fill : tone!.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(AppDensity.of(context).radiusMd),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: tone ?? palette.text.withValues(alpha: .86),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One status filter: its name, a colour dot for its status and the number
/// of rows it would show.
class _FilterPill extends StatelessWidget {
  const _FilterPill({
    required this.label,
    required this.count,
    required this.selected,
    required this.onSelected,
    this.tone,
    super.key,
  });

  final String label;
  final int count;
  final bool selected;
  final Color? tone;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final foreground = selected ? palette.onAccentContainer : palette.text;
    const shape = StadiumBorder();
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? palette.accentContainer : palette.fill,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onSelected,
          customBorder: shape,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 5, 6, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tone != null) ...[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: tone,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 7),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.3,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: foreground,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Container(
                  constraints: const BoxConstraints(minWidth: 22),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? palette.onAccentContainer.withValues(alpha: .14)
                        : palette.text.withValues(alpha: .07),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$count',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: foreground.withValues(alpha: .8),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the list while nothing was logged at all.
class _LogsEmptyState extends StatelessWidget {
  const _LogsEmptyState();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 12),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: palette.teal.withValues(alpha: .14),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.receipt_long_outlined,
              size: 24,
              color: palette.teal,
            ),
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              context.l10n.r7NavLogEmpty,
              key: const ValueKey('session_logs_empty'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                fontWeight: FontWeight.w500,
                color: palette.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One-line "nothing matches" row with a way back to every row.
class _LogsNoMatches extends StatelessWidget {
  const _LogsNoMatches({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.blockFill(SurfaceScope.depthOf(context) + 1),
        borderRadius: BorderRadius.circular(
          SurfaceScope.concentric(
            context,
            fallback: AppDensity.of(context).radiusLg,
            floor: AppDensity.of(context).radiusMd,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_off_rounded, size: 18, color: palette.muted),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    context.l10n.r7NavLogNoMatches,
                    key: const ValueKey('session_logs_empty'),
                    style: TextStyle(fontSize: 13, color: palette.muted),
                  ),
                ),
              ],
            ),
            TextButton(
              onPressed: onReset,
              child: Text(context.l10n.logsClearFilters),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rows of the journal in one filled block; soft separators inset from
/// its edges tell the rows apart.
class _SessionLogList extends StatelessWidget {
  const _SessionLogList({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final density = AppDensity.of(context);
    return Material(
      color: palette.blockFill(SurfaceScope.depthOf(context) + 1),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          SurfaceScope.concentric(
            context,
            fallback: density.radiusLg,
            floor: density.radiusMd,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 14, endIndent: 12),
            children[i],
          ],
        ],
      ),
    );
  }
}

(IconData, Color) _statusVisual(BuildContext context, SessionLogEntry entry) {
  final palette = context.palette;
  return switch (entry.status) {
    SessionLogStatus.connecting => (Icons.sync_rounded, palette.orange),
    SessionLogStatus.connected => (Icons.link_rounded, palette.teal),
    SessionLogStatus.failed => (Icons.error_outline_rounded, palette.red),
    SessionLogStatus.closed => switch (entry.endReason) {
      SessionLogEndReason.error => (Icons.link_off_rounded, palette.orange),
      SessionLogEndReason.remote => (Icons.logout_rounded, palette.muted),
      _ => (Icons.link_off_rounded, palette.muted),
    },
  };
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
    final palette = context.palette;
    final (icon, tone) = _statusVisual(context, entry);
    final duration = entry.duration;
    final hasTranscript =
        entry.hasTranscript ||
        (live && entry.status == SessionLogStatus.connected);
    final failure = entry.failure == null
        ? null
        : sessionLogFailureLabel(l10n, entry.failure!);
    final metaStyle = TextStyle(
      fontSize: 12,
      height: 1.35,
      color: palette.muted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    final badge = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(AppDensity.of(context).radiusMd),
      ),
      child: Icon(icon, size: 18, color: tone),
    );
    final name = Text(
      entry.hostName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13.5,
        fontWeight: FontWeight.w600,
        color: palette.text,
      ),
    );
    final protocol = _Tag(label: entry.protocol.toUpperCase());
    final jump = entry.viaJump
        ? _Tag(label: l10n.r7NavLogRouteJump, icon: Icons.alt_route_rounded)
        : null;
    final endpoint = Text(
      entry.endpoint,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11.5,
        height: 1.4,
        fontFamily: 'monospace',
        color: palette.muted,
      ),
    );
    final started = _Meta(
      icon: Icons.schedule_rounded,
      child: Text(_time(entry.startedAt), style: metaStyle),
    );
    final length = duration == null
        ? null
        : _Meta(
            icon: Icons.timer_outlined,
            child: Text(_duration(duration), style: metaStyle),
          );
    final chip = _StatusPill(
      label: sessionLogStatusLabel(l10n, entry),
      tone: tone,
    );
    final failureText = failure == null
        ? null
        : Text(
            failure,
            style: TextStyle(fontSize: 12, height: 1.35, color: palette.red),
          );
    final transcript = hasTranscript
        ? Tooltip(
            message: l10n.r7NavLogTranscript,
            child: Icon(Icons.article_outlined, size: 17, color: palette.muted),
          )
        : null;

    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
        child: LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth >= 720) {
              return Row(
                children: [
                  badge,
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(child: name),
                            const SizedBox(width: 6),
                            protocol,
                            if (jump != null) ...[
                              const SizedBox(width: 6),
                              Flexible(child: jump),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        endpoint,
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 170,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [started, ?length],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        chip,
                        if (failureText != null) ...[
                          const SizedBox(height: 3),
                          failureText,
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: 26, child: transcript),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: palette.hint,
                  ),
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                badge,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [name, protocol],
                            ),
                          ),
                          if (transcript != null) ...[
                            const SizedBox(width: 8),
                            transcript,
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      endpoint,
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [chip, started, ?length, ?jump],
                      ),
                      if (failureText != null) ...[
                        const SizedBox(height: 4),
                        failureText,
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// An icon and a value on the meta line of a row.
class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.child});

  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: context.palette.hint),
      const SizedBox(width: 5),
      Flexible(child: child),
    ],
  );
}

/// A small neutral label (protocol, route).
class _Tag extends StatelessWidget {
  const _Tag({required this.label, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.fill,
        borderRadius: BorderRadius.circular(AppDensity.of(context).radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: palette.muted),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: .2,
                color: palette.muted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The kit's status chip, except that a long label wraps instead of running
/// out of a narrow row.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: .12),
      // Round as a pill on one line; a wrapped label keeps soft corners.
      borderRadius: BorderRadius.circular(AppDensity.of(context).radiusMd),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: tone,
            ),
          ),
        ),
      ],
    ),
  );
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
                        // A sunken well in the dialog; no outline.
                        decoration: BoxDecoration(
                          color: context.palette.background,
                          borderRadius: BorderRadius.circular(
                            SurfaceScope.concentric(
                              context,
                              fallback: AppDensity.of(context).radiusMd,
                              floor: AppDensity.of(context).radiusMd,
                            ),
                          ),
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
  const _IosSessionLogDetailSheet({required this.book, required this.entry});

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
