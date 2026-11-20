import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';
import 'app_motion.dart';
import 'host_search_palette.dart' show hostSearchGroupLabels;
import 'ios_native/ios_native.dart';

/// A null result dismisses the picker. A choice with a null ID selects the
/// direct connection (in the editor) or the saved route (on a retry).
typedef JumpHostChoice = ({String? jumpHostId});

/// An eligible SSH chain reaches a direct host within the hop limit and
/// never revisits the target or another host along the way.
List<HostRecord> jumpHostCandidates(
  Iterable<HostRecord> hosts, {
  String? targetId,
}) {
  final byId = {for (final host in hosts) host.id: host};
  bool eligible(HostRecord host) {
    final seen = <String>{?targetId};
    for (var hop = 0; hop < maxJumpHostHops; hop++) {
      if (host.protocol != HostProtocol.ssh || !seen.add(host.id)) return false;
      if (host.jumpHostId == null) return true;
      final next = byId[host.jumpHostId];
      if (next == null) return false;
      host = next;
    }
    return false;
  }

  return hosts.where(eligible).toList(growable: false);
}

Future<JumpHostChoice?> showJumpHostPicker(
  BuildContext context, {
  required List<HostRecord> candidates,
  required String keyPrefix,
  String? selectedId,
  Iterable<GroupRecord> groups = const [],
  HostRecord? retryTarget,
}) {
  final ios = isIosPhone(context);
  final groupLabels = hostSearchGroupLabels(groups);
  final picker = _JumpHostPicker(
    keyPrefix: keyPrefix,
    ios: ios,
    selectedId: selectedId,
    retryTarget: retryTarget,
    candidates: [
      for (final host in candidates)
        (
          host: host,
          keywords: [
            host.name,
            '${host.username}@${host.endpoint}',
            ...host.tags,
            ?groupLabels[host.groupId],
          ].join(' ').toLowerCase(),
        ),
    ],
  );
  if (ios) {
    return Navigator.of(context)
        .push<JumpHostChoice>(CupertinoPageRoute(builder: (_) => picker));
  }
  return showAppDialog<JumpHostChoice>(
    context: context,
    builder: (_) => picker,
  );
}

class _JumpHostPicker extends StatefulWidget {
  const _JumpHostPicker({
    required this.keyPrefix,
    required this.ios,
    required this.selectedId,
    required this.retryTarget,
    required this.candidates,
  });

  final String keyPrefix;
  final bool ios;
  final String? selectedId;
  final HostRecord? retryTarget;
  final List<({HostRecord host, String keywords})> candidates;

  @override
  State<_JumpHostPicker> createState() => _JumpHostPickerState();
}

class _JumpHostPickerState extends State<_JumpHostPicker> {
  final _search = TextEditingController();
  static final _whitespace = RegExp(r'\s+');

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _pick(String? id) =>
      Navigator.pop<JumpHostChoice>(context, (jumpHostId: id));

  Iterable<HostRecord> _matches(String input) {
    final query = input.trim().toLowerCase();
    final terms = query.isEmpty ? const <String>[] : query.split(_whitespace);
    return widget.candidates
        .where((entry) => terms.every(entry.keywords.contains))
        .map((entry) => entry.host);
  }

  void _submit(String input) {
    if (input.trim().isEmpty) return;
    final results = _matches(input).take(2).toList();
    if (results.length == 1) _pick(results.single.id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final prefix = widget.keyPrefix;
    final target = widget.retryTarget;
    final title = target == null
        ? l10n.jumpHost
        : l10n.temporaryJumpPickerTitle;
    final matches = _matches(_search.text).toList(growable: false);
    final defaultRoute = target == null
        ? l10n.directConnection
        : l10n.temporaryJumpPickerSavedRoute;
    final search = widget.ios
        ? buildIosSearchTextField(
            context,
            key: ValueKey('${prefix}_search'),
            controller: _search,
            placeholder: l10n.temporaryJumpPickerSearch,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: _submit,
          )
        : TextField(
            key: ValueKey('${prefix}_search'),
            controller: _search,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            onSubmitted: _submit,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: l10n.temporaryJumpPickerSearch,
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: l10n.clearSearch,
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(_search.clear),
                    ),
            ),
          );
    final slivers = <Widget>[
      if (target != null)
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          sliver: SliverToBoxAdapter(
            child: Text(l10n.temporaryJumpPickerHint(target.name)),
          ),
        ),
      if (target == null || widget.selectedId != null)
        SliverToBoxAdapter(
          child: widget.ios
              ? IosListRow(
                  key: ValueKey('${prefix}_saved_route'),
                  title: Text(defaultRoute),
                  accessory: widget.selectedId == null
                      ? IosRowAccessory.checkmark
                      : IosRowAccessory.none,
                  onTap: () => _pick(null),
                )
              : ListTile(
                  key: ValueKey('${prefix}_saved_route'),
                  leading: const Icon(Icons.alt_route_rounded),
                  title: Text(defaultRoute),
                  trailing: widget.selectedId == null
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => _pick(null),
                ),
        ),
      if (matches.isEmpty)
        SliverPadding(
          padding: const EdgeInsets.all(20),
          sliver: SliverToBoxAdapter(
            child: Text(
              widget.candidates.isEmpty
                  ? l10n.temporaryJumpPickerEmpty
                  : l10n.noMatchingHosts,
              key: ValueKey('${prefix}_empty'),
            ),
          ),
        )
      else
        SliverList.builder(
          itemCount: matches.length,
          itemBuilder: (context, index) {
            final host = matches[index];
            final selected = host.id == widget.selectedId;
            final key = ValueKey('${prefix}_option_${host.id}');
            final endpoint = host.username.isEmpty
                ? host.endpoint
                : '${host.username}@${host.endpoint}';
            return Semantics(
              identifier: 'ssh-jump-host-option-${host.id}',
              selected: selected,
              child: widget.ios
                  ? IosListRow(
                      key: key,
                      title: Text(host.name),
                      subtitle: Text(endpoint),
                      accessory: selected
                          ? IosRowAccessory.checkmark
                          : IosRowAccessory.none,
                      onTap: () => _pick(host.id),
                    )
                  : ListTile(
                      key: key,
                      title: Text(
                        target == null
                            ? '${host.name} · ${host.endpoint}'
                            : host.name,
                      ),
                      subtitle: Text(target == null ? host.username : endpoint),
                      trailing: selected ? const Icon(Icons.check) : null,
                      onTap: () => _pick(host.id),
                    ),
            );
          },
        ),
    ];
    if (widget.ios) {
      return Material(
        child: IosLargeTitlePage(
          title: title,
          largeTitle: false,
          showBackButton: true,
          searchField: search,
          slivers: slivers,
        ),
      );
    }
    return Dialog(
      key: ValueKey('${prefix}_picker'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: SizedBox(
        width: appDialogWidth(context, 440),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: CustomScrollView(
            shrinkWrap: true,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        key: ValueKey('${prefix}_cancel'),
                        tooltip: l10n.cancel,
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                sliver: SliverToBoxAdapter(child: search),
              ),
              ...slivers,
            ],
          ),
        ),
      ),
    );
  }
}
