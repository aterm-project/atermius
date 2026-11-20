import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'connect_progress_view.dart';

/// Result of [showTemporaryJumpHostPicker]: the SSH Host to connect through,
/// or null for the target's saved route.
typedef TemporaryJumpChoice = ({String? jumpHostId});

/// SSH Hosts among [hosts] that [target] can be reached through: not the
/// target itself, and the candidate's own Jump Host chain is complete,
/// acyclic, does not pass through the target and leaves room for one more hop.
List<HostRecord> temporaryJumpHostCandidates(
  HostRecord target,
  Iterable<HostRecord> hosts,
) {
  final hostsById = {for (final host in hosts) host.id: host};
  bool eligible(HostRecord candidate) {
    if (candidate.protocol != HostProtocol.ssh || candidate.id == target.id) {
      return false;
    }
    final seen = <String>{target.id};
    var host = candidate;
    var routeLength = 1;
    while (true) {
      if (host.protocol != HostProtocol.ssh || !seen.add(host.id)) return false;
      final next = host.jumpHostId;
      if (next == null) return true;
      if (routeLength == maxJumpHostHops) return false;
      final nextHost = hostsById[next];
      if (nextHost == null) return false;
      host = nextHost;
      routeLength++;
    }
  }

  return [
    for (final host in hosts)
      if (eligible(host)) host,
  ];
}

/// Lets the user pick the SSH Host a failed tab should be retried through.
/// Returns null when dismissed. [currentJumpHostId] is the tab's present
/// temporary jump host; when set, the saved route is offered as well.
Future<TemporaryJumpChoice?> showTemporaryJumpHostPicker(
  BuildContext context, {
  required HostRecord target,
  required List<HostRecord> candidates,
  String? currentJumpHostId,
}) => showAppDialog<TemporaryJumpChoice>(
  context: context,
  builder: (context) => _TemporaryJumpHostDialog(
    target: target,
    candidates: candidates,
    currentJumpHostId: currentJumpHostId,
  ),
);

class _TemporaryJumpHostDialog extends StatefulWidget {
  const _TemporaryJumpHostDialog({
    required this.target,
    required this.candidates,
    required this.currentJumpHostId,
  });

  final HostRecord target;
  final List<HostRecord> candidates;
  final String? currentJumpHostId;

  @override
  State<_TemporaryJumpHostDialog> createState() =>
      _TemporaryJumpHostDialogState();
}

class _TemporaryJumpHostDialogState extends State<_TemporaryJumpHostDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final query = _query.trim().toLowerCase();
    final matches = [
      for (final host in widget.candidates)
        if (query.isEmpty ||
            host.name.toLowerCase().contains(query) ||
            host.address.toLowerCase().contains(query) ||
            host.username.toLowerCase().contains(query))
          host,
    ];
    return AlertDialog(
      key: const ValueKey('temporary_jump_picker'),
      title: Text(l10n.temporaryJumpPickerTitle),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: appDialogWidth(context, 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                l10n.temporaryJumpPickerHint(widget.target.name),
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ),
            if (widget.candidates.length > 6)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: TextField(
                  key: const ValueKey('temporary_jump_search'),
                  autofocus: true,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: l10n.temporaryJumpPickerSearch,
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
            const SizedBox(height: 8),
            if (widget.currentJumpHostId != null)
              ListTile(
                key: const ValueKey('temporary_jump_saved_route'),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                leading: const Icon(Icons.undo_rounded, size: 20),
                title: Text(l10n.temporaryJumpPickerSavedRoute),
                onTap: () => Navigator.pop<TemporaryJumpChoice>(context, (
                  jumpHostId: null,
                )),
              ),
            if (matches.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                child: Text(
                  widget.candidates.isEmpty
                      ? l10n.temporaryJumpPickerEmpty
                      : l10n.temporaryJumpPickerNoMatch,
                  key: const ValueKey('temporary_jump_empty'),
                  style: TextStyle(color: palette.muted),
                ),
              )
            else
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: matches.length,
                    itemBuilder: (context, index) {
                      final host = matches[index];
                      final selected = host.id == widget.currentJumpHostId;
                      return ListTile(
                        key: ValueKey('temporary_jump_option_${host.id}'),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 24,
                        ),
                        leading: const Icon(Icons.alt_route_rounded, size: 20),
                        title: Text(
                          host.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          connectProgressDetail(host),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: selected
                            ? const Icon(Icons.check_rounded, size: 18)
                            : null,
                        onTap: () => Navigator.pop<TemporaryJumpChoice>(
                          context,
                          (jumpHostId: host.id),
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('temporary_jump_cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}
