import 'app_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../domain/quick_connect.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'host_search_field.dart';
import '../l10n/l10n.dart';
import '../telnet/telnet_ui.dart';

/// Keep duplicate leaf names distinguishable in nested group filters.
Map<String, String> hostSearchGroupLabels(Iterable<GroupRecord> groups) {
  final byId = {for (final group in groups) group.id: group};
  return {
    for (final group in byId.values)
      group.id: (() {
        final path = <String>[group.name];
        final seen = <String>{group.id};
        var parent = group.parentId;
        while (parent != null && seen.add(parent)) {
          final node = byId[parent];
          if (node == null) break;
          path.insert(0, node.name);
          parent = node.parentId;
        }
        return path.join(' / ');
      })(),
  };
}

/// 按运维人员高频直连习惯对搜索命中结果智能排序：
/// 1. 名称精确匹配 / 名称前缀匹配 / 地址前缀匹配（仅当 [query] 非空时）；
/// 2. 最近连接时间（`lastConnected` 降序）；
/// 3. 收藏星标主机（`isFavorite`）；
/// 4. 名称字母序。
List<HostRecord> rankHostSearchMatches(
  List<HostRecord> matches,
  String query,
) {
  if (matches.length <= 1) return matches;
  final normalized = query.trim().toLowerCase();
  int relevance(HostRecord host) {
    if (normalized.isEmpty) return 0;
    final name = host.name.toLowerCase();
    if (name == normalized) return 3;
    if (name.startsWith(normalized)) return 2;
    if (host.address.toLowerCase().startsWith(normalized)) return 1;
    return 0;
  }

  final ranked = List<HostRecord>.of(matches);
  ranked.sort((a, b) {
    final relCmp = relevance(b).compareTo(relevance(a));
    if (relCmp != 0) return relCmp;
    final aRecent = a.lastConnected;
    final bRecent = b.lastConnected;
    if (aRecent != null && bRecent != null) {
      final recentCmp = bRecent.compareTo(aRecent);
      if (recentCmp != 0) return recentCmp;
    } else if (aRecent != null) {
      return -1;
    } else if (bRecent != null) {
      return 1;
    }
    if (a.isFavorite != b.isFavorite) {
      return a.isFavorite ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return ranked;
}

class HostSearchSelection {
  const HostSearchSelection.host(this.hostId) : command = null;
  const HostSearchSelection.command(this.command) : hostId = null;
  final String? hostId;
  final QuickConnectRequest? command;
}

Future<HostSearchSelection?> showHostSearchPalette(
  BuildContext context, {
  required List<HostRecord> Function() hosts,
  required Map<String, String> groups,
  required Key fieldKey,
  required bool Function() isCurrent,
  Listenable? changes,
  void Function(VoidCallback?)? onDismissChanged,
}) async {
  final navigator = Navigator.of(context);
  late final DialogRoute<HostSearchSelection> route;
  void dismiss() {
    if (route.isActive) navigator.removeRoute(route);
  }

  route = AppDialogRoute<HostSearchSelection>(
    context: context,
    motion: AppDialogMotion.palette,
    builder: (_) => _HostSearchPalette(
      hosts: hosts,
      groups: groups,
      fieldKey: fieldKey,
      isCurrent: isCurrent,
      changes: changes,
      onInvalidated: dismiss,
    ),
  );
  final result = navigator.push(route);
  onDismissChanged?.call(dismiss);
  try {
    return await result;
  } finally {
    onDismissChanged?.call(null);
  }
}

class _HostSearchPalette extends StatefulWidget {
  const _HostSearchPalette({
    required this.hosts,
    required this.groups,
    required this.fieldKey,
    required this.isCurrent,
    required this.onInvalidated,
    this.changes,
  });
  final List<HostRecord> Function() hosts;
  final Map<String, String> groups;
  final Key fieldKey;
  final bool Function() isCurrent;
  final VoidCallback onInvalidated;
  final Listenable? changes;
  @override
  State<_HostSearchPalette> createState() => _HostSearchPaletteState();
}

class _HostSearchPaletteState extends State<_HostSearchPalette> {
  final _search = TextEditingController();
  final _scrollController = ScrollController();
  HostProtocol? _protocol;
  String? _group;
  bool _favorites = false;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    if (!widget.isCurrent()) {
      widget.onInvalidated();
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_changed);
    _search.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _select(HostSearchSelection selection) {
    if (widget.isCurrent()) Navigator.of(context).pop(selection);
  }

  void _moveSelection(int delta, int count) {
    if (count <= 0) return;
    final next = (_selectedIndex + delta) % count;
    final resolved = next < 0 ? next + count : next;
    setState(() => _selectedIndex = resolved);
    if (_scrollController.hasClients) {
      const estimatedItemExtent = 56.0;
      final target = (resolved * estimatedItemExtent).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.jumpTo(target);
    }
  }

  KeyEventResult _handleKeyEvent(
    KeyEvent event,
    List<HostRecord> matches,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown ||
        (ctrl && key == LogicalKeyboardKey.keyN)) {
      _moveSelection(1, matches.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        (ctrl && key == LogicalKeyboardKey.keyP)) {
      _moveSelection(-1, matches.length);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static String _keyboardHint(BuildContext context) =>
      switch (Localizations.localeOf(context).languageCode) {
        'zh' => '↑↓ 切换主机 · ⏎ 直连 · Esc 关闭',
        'ja' => '↑↓ 選択 · ⏎ 接続 · Esc 閉じる',
        'ru' => '↑↓ выбор · ⏎ подключиться · Esc закрыть',
        _ => '↑↓ Navigate · ⏎ Connect · Esc Close',
      };

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    QuickConnectRequest? command;
    try {
      command = QuickConnectRequest.parse(_search.text);
    } on FormatException {
      // The search field shows bounded syntax guidance while typing.
    }
    final filtered = widget.hosts().where((host) {
      if (_protocol != null && host.protocol != _protocol) return false;
      if (_group != null && host.groupId != _group) return false;
      if (_favorites && !host.isFavorite) return false;
      if (command != null) return command.matches(host);
      return query.isEmpty ||
          '${host.name} ${host.address} ${host.username} ${host.tags.join(' ')} ${widget.groups[host.groupId] ?? ''}'
              .toLowerCase()
              .contains(query);
    }).toList();
    final matches = rankHostSearchMatches(filtered, query);
    final activeIndex = matches.isEmpty
        ? -1
        : _selectedIndex.clamp(0, matches.length - 1);
    final palette = context.palette;

    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) => _handleKeyEvent(event, matches),
      child: Dialog(
        key: const ValueKey('host_search_palette'),
        alignment: Alignment.topCenter,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 56),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 660, maxHeight: 560),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.searchAndQuickConnect,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: context.l10n.closeSearch,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                HostSearchField(
                  fieldKey: widget.fieldKey,
                  controller: _search,
                  autofocus: true,
                  onChanged: (_) => setState(() => _selectedIndex = 0),
                  onConnect: (request) =>
                      _select(HostSearchSelection.command(request)),
                  onSearchSubmitted: activeIndex < 0
                      ? null
                      : () => _select(
                          HostSearchSelection.host(matches[activeIndex].id),
                        ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  key: const ValueKey('host_search_filters'),
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ChoiceChip(
                      label: Text(context.l10n.all),
                      selected: _protocol == null,
                      onSelected: (_) => setState(() {
                        _protocol = null;
                        _selectedIndex = 0;
                      }),
                    ),
                    for (final protocol in HostProtocol.values)
                      ChoiceChip(
                        label: Text(protocol.name.toUpperCase()),
                        selected: _protocol == protocol,
                        onSelected: (_) => setState(() {
                          _protocol = protocol;
                          _selectedIndex = 0;
                        }),
                      ),
                    FilterChip(
                      label: Text(context.l10n.favorites),
                      selected: _favorites,
                      onSelected: (value) => setState(() {
                        _favorites = value;
                        _selectedIndex = 0;
                      }),
                    ),
                    if (widget.groups.isNotEmpty)
                      PopupMenuButton<String>(
                        popUpAnimationStyle: AppMotion.menuStyle(context),
                        tooltip: context.l10n.filterByGroup,
                        initialValue: _group ?? '',
                        onSelected: (value) => setState(() {
                          _group = value.isEmpty ? null : value;
                          _selectedIndex = 0;
                        }),
                        itemBuilder: (_) => [
                          appMenuItem(
                            context,
                            value: '',
                            child: Text(context.l10n.allGroups),
                          ),
                          for (final entry in widget.groups.entries)
                            appMenuItem(
                              context,
                              value: entry.key,
                              child: Text(entry.value),
                            ),
                        ],
                        child: Chip(
                          label: Text(
                            widget.groups[_group] ?? context.l10n.groups,
                          ),
                          avatar: const Icon(Icons.folder_outlined, size: 16),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.countHosts2(matches.length),
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                    ),
                    if (MediaQuery.sizeOf(context).width >= 480)
                      Text(
                        _keyboardHint(context),
                        key: const ValueKey('host_search_keyboard_hint'),
                        style: TextStyle(fontSize: 11, color: palette.muted),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: matches.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(context.l10n.noMatchingHostsTypeAnSsh),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          shrinkWrap: true,
                          itemCount: matches.length,
                          itemBuilder: (_, index) {
                            final host = matches[index];
                            final selected = index == activeIndex;
                            return ListTile(
                              key: ValueKey('host-search-result-${host.id}'),
                              dense: true,
                              selected: selected,
                              selectedTileColor: Theme.of(context)
                                  .colorScheme
                                  .primaryContainer
                                  .withValues(alpha: 0.45),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: selected
                                    ? BorderSide(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: 0.45),
                                      )
                                    : BorderSide.none,
                              ),
                              leading: Icon(
                                hostProtocolIcon(host.protocol),
                                size: 20,
                              ),
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      host.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (host.isFavorite) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.star_rounded,
                                      size: 14,
                                      color: palette.orange,
                                    ),
                                  ],
                                ],
                              ),
                              subtitle: Text(
                                '${host.protocol.name.toUpperCase()} · ${host.username.isEmpty ? '' : '${host.username}@'}${host.endpoint}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Icon(
                                selected
                                    ? Icons.keyboard_return_rounded
                                    : Icons.north_east,
                                size: 16,
                              ),
                              onTap: () =>
                                  _select(HostSearchSelection.host(host.id)),
                            );
                          },
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
