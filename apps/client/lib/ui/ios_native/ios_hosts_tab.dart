import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models.dart';
import '../../domain/quick_connect.dart';
import '../../l10n/l10n.dart';
import '../host_search_palette.dart' show hostSearchGroupLabels;
import '../host_system_icon.dart';
import '../workspace_controls.dart' show WorkspaceAction;
import 'ios_empty_state.dart';
import 'ios_group_detail_page.dart';
import 'ios_icons.dart';
import 'ios_large_title_page.dart';
import 'ios_list.dart';
import 'ios_pull_down_menu.dart';
import 'ios_swipe_actions.dart';
import 'ios_toast.dart';
import 'ios_tokens.dart';
import 'ios_workspace_scope.dart';

/// 主机列表排序方式。
enum IosHostSortOrder { name, recent }

/// 解析分组整数颜色到 iOS 语义色。
Color resolveIosGroupColor(IosColors c, int rawColor) {
  if (rawColor <= 0) return c.blue;
  // 兼容小索引号（如 demo 数据 1..7）与 24 位 RGB 颜色值。
  return switch (rawColor) {
    1 => c.green,
    2 => c.orange,
    3 => c.purple,
    4 => c.pink,
    5 => c.indigo,
    6 => c.teal,
    7 => c.yellow,
    _ => Color(0xFF000000 | (rawColor & 0x00FFFFFF)),
  };
}

/// 递归统计某分组及其全部子分组下的主机总数。
int countIosGroupHosts(IosWorkspaceData scope, String groupId) {
  final visited = <String>{};
  var total = 0;
  void walk(String id) {
    if (!visited.add(id)) return;
    total += scope.hosts.where((host) => host.groupId == id).length;
    for (final child in scope.groups) {
      if (child.parentId == id) walk(child.id);
    }
  }

  walk(groupId);
  return total;
}

/// 生成主机副标题等宽地址文案（`user@host:port` 或 `host:port`）。
String formatIosHostEndpoint(HostRecord host) => host.username.trim().isEmpty
    ? '${host.address}:${host.port}'
    : '${host.username}@${host.address}:${host.port}';

/// 将任意 WorkspaceAction 图标规范化为圆润 Material rounded 字形。
IconData normalizeIosRoundedIcon(IconData icon) {
  if (icon == Icons.terminal || icon == Icons.terminal_outlined) {
    return IosIcons.terminal;
  }
  if (icon == Icons.folder_open_outlined || icon == Icons.folder_outlined) {
    return IosIcons.sftp;
  }
  if (icon == Icons.upload_file_outlined || icon == Icons.file_upload_outlined) {
    return Icons.upload_file_rounded;
  }
  if (icon == Icons.hub_outlined || icon == Icons.swap_horiz) {
    return IosIcons.forwarding;
  }
  if (icon == Icons.edit_outlined || icon == Icons.edit) {
    return IosIcons.edit;
  }
  if (icon == Icons.info_outline || icon == Icons.info) {
    return IosIcons.info;
  }
  if (icon == Icons.delete_outline || icon == Icons.delete) {
    return IosIcons.delete;
  }
  if (icon == Icons.content_copy || icon == Icons.copy) {
    return IosIcons.copy;
  }
  if (icon == Icons.create_new_folder_outlined) {
    return Icons.create_new_folder_rounded;
  }
  if (icon == Icons.verified_user_outlined) {
    return IosIcons.verified;
  }
  if (icon == Icons.lock_outline) {
    return IosIcons.lock;
  }
  return icon;
}

/// 按所选排序方式排列主机列表。
List<HostRecord> sortIosHosts(List<HostRecord> source, IosHostSortOrder order) {
  final sorted = [...source];
  sorted.sort((a, b) {
    if (order == IosHostSortOrder.recent) {
      final aTime = a.lastConnected;
      final bTime = b.lastConnected;
      if (aTime != null && bTime != null) {
        final cmp = bTime.compareTo(aTime);
        if (cmp != 0) return cmp;
      } else if (aTime != null) {
        return -1;
      } else if (bTime != null) {
        return 1;
      }
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return sorted;
}

/// iPhone 纯血「主机」一级 Tab 页面。
///
/// 严格只通过 [IosWorkspaceScope.of] 读取数据快照与交互回调。
class IosHostsTab extends StatefulWidget {
  const IosHostsTab({super.key});

  @override
  State<IosHostsTab> createState() => _IosHostsTabState();
}

class _IosHostsTabState extends State<IosHostsTab> {
  bool _groupsCollapsed = false;
  bool _sectionByGroup = false;
  IosHostSortOrder _sortOrder = IosHostSortOrder.name;

  bool get _isZh =>
      Localizations.localeOf(context).languageCode.toLowerCase().startsWith('zh');

  String get _quickConnectTitle => _isZh ? '快速连接' : 'Quick Connect';
  String get _allHostsTitle => _isZh ? '全部主机' : context.l10n.hosts;
  String get _ungroupedTitle => _isZh ? '未分组' : 'Ungrouped';
  String get _sortByNameLabel => _isZh ? '按名称' : 'By Name';
  String get _sortByRecentLabel => _isZh ? '最近连接' : 'Recent';
  String get _groupBySectionLabel => _isZh ? '按分组分区显示' : 'Group by Folder';

  List<GroupRecord> _topLevelGroups(IosWorkspaceData scope) {
    final knownIds = {for (final g in scope.groups) g.id};
    final result = <GroupRecord>[
      for (final g in scope.groups)
        if (g.parentId == null || !knownIds.contains(g.parentId)) g,
    ];
    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  List<List<WorkspaceAction>> _buildMoreSections(IosWorkspaceData scope) {
    final viewSection = <WorkspaceAction>[
      WorkspaceAction(
        'ios_hosts_toggle_group_sections',
        _groupBySectionLabel,
        _sectionByGroup ? IosIcons.check : kIosMenuNoIcon,
        () => setState(() => _sectionByGroup = !_sectionByGroup),
      ),
      WorkspaceAction(
        'ios_hosts_sort_name',
        _sortByNameLabel,
        _sortOrder == IosHostSortOrder.name ? IosIcons.check : kIosMenuNoIcon,
        () => setState(() => _sortOrder = IosHostSortOrder.name),
      ),
      WorkspaceAction(
        'ios_hosts_sort_recent',
        _sortByRecentLabel,
        _sortOrder == IosHostSortOrder.recent ? IosIcons.check : kIosMenuNoIcon,
        () => setState(() => _sortOrder = IosHostSortOrder.recent),
      ),
    ];
    return [viewSection, ...scope.moreMenu];
  }

  List<List<WorkspaceAction>> _buildSortMenu() => [
    [
      WorkspaceAction(
        'ios_sort_name',
        _sortByNameLabel,
        _sortOrder == IosHostSortOrder.name ? IosIcons.check : kIosMenuNoIcon,
        () => setState(() => _sortOrder = IosHostSortOrder.name),
      ),
      WorkspaceAction(
        'ios_sort_recent',
        _sortByRecentLabel,
        _sortOrder == IosHostSortOrder.recent ? IosIcons.check : kIosMenuNoIcon,
        () => setState(() => _sortOrder = IosHostSortOrder.recent),
      ),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final scope = IosWorkspaceScope.of(context);
    return ListenableBuilder(
      listenable: scope.search,
      builder: (context, _) => _buildPage(context, scope),
    );
  }

  Widget _buildPage(BuildContext context, IosWorkspaceData scope) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final rawSearch = scope.search.text;
    final query = rawSearch.trim().toLowerCase();
    final groupLabels = hostSearchGroupLabels(scope.groups);

    QuickConnectRequest? quickCommand;
    String? quickSyntaxError;
    if (rawSearch.trim().isNotEmpty) {
      try {
        quickCommand = QuickConnectRequest.parse(rawSearch);
      } on FormatException catch (error) {
        quickSyntaxError = error.message;
      }
    }

    final filteredHosts = sortIosHosts(
      scope.hosts.where((host) {
        if (quickCommand != null) return quickCommand.matches(host);
        if (query.isEmpty) return true;
        final haystack =
            '${host.name} ${host.address} ${host.username} ${host.tags.join(' ')} ${groupLabels[host.groupId] ?? ''}'
                .toLowerCase();
        return haystack.contains(query);
      }).toList(),
      _sortOrder,
    );

    final visibleGroups = query.isEmpty
        ? _topLevelGroups(scope)
        : (scope.groups
              .where((g) => g.name.toLowerCase().contains(query))
              .toList()
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            ));

    final hasAddMenu = scope.addMenu.any((s) => s.isNotEmpty);
    final trailingItems = <IosBarButtonItem>[
      if (hasAddMenu)
        IosBarButtonItem(
          key: const ValueKey('ios_hosts_add_button'),
          icon: IosIcons.add,
          semanticLabel: l10n.r7NavAdd,
          onPressed: scope.busy
              ? null
              : (anchor) => showIosPullDownMenu(
                  context,
                  anchor: anchor,
                  sections: scope.addMenu,
                ),
        ),
      IosBarButtonItem(
        key: const ValueKey('ios_hosts_more_button'),
        icon: IosIcons.more,
        semanticLabel: l10n.more,
        badge: scope.busy
            ? const Positioned.fill(
                child: IgnorePointer(
                  child: Center(child: CupertinoActivityIndicator(radius: 8)),
                ),
              )
            : null,
        onPressed: (anchor) => showIosPullDownMenu(
          context,
          anchor: anchor,
          sections: _buildMoreSections(scope),
        ),
      ),
    ];

    final searchField = buildIosSearchTextField(
      context,
      key: const ValueKey('local_home_search'),
      controller: scope.search,
      placeholder: l10n.searchHostsOrTypeAnSsh,
      onChanged: (_) => setState(() {}),
      onSuffixTap: () => setState(() {}),
      onSubmitted: (_) {
        if (scope.busy || quickSyntaxError != null) return;
        if (quickCommand != null && scope.quickConnect != null) {
          HapticFeedback.lightImpact().catchError((Object _) {});
          scope.quickConnect!(quickCommand);
          return;
        }
        if (filteredHosts.isNotEmpty && !kIsWeb) {
          HapticFeedback.lightImpact().catchError((Object _) {});
          scope.connect(filteredHosts.first);
        }
      },
    );

    final slivers = <Widget>[];

    // 语法提示（如 ssh 命令未输完）
    if (quickSyntaxError != null) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              IosMetrics.sectionHeaderInset,
              0,
              IosMetrics.sectionHeaderInset,
              14,
            ),
            child: Text(
              quickSyntaxError,
              style: IosType.footnote.copyWith(color: c.secondaryLabel),
            ),
          ),
        ),
      );
    }

    // 快速连接智能分组（无右箭头，点按立即连接）
    if (quickCommand != null) {
      final cmd = quickCommand;
      slivers.add(
        SliverToBoxAdapter(
          child: IosListSection(
            header: _quickConnectTitle,
            separatorIndent: IosListSection.indentForIcon(),
            children: [
              IosListRow(
                key: const ValueKey('quick_connect_action'),
                leading: IosIconTile(icon: IosIcons.bolt, color: c.tint),
                title: Text(cmd.label),
                subtitle: Text(l10n.connectDirectFromThisDevice),
                accessory: IosRowAccessory.none,
                enabled: !scope.busy && scope.quickConnect != null,
                onTap: scope.busy || scope.quickConnect == null
                    ? null
                    : () {
                        HapticFeedback.lightImpact().catchError((Object _) {});
                        scope.quickConnect!(cmd);
                      },
              ),
            ],
          ),
        ),
      );
    }

    // 主机列表读取错误卡片
    if (scope.hostListError != null) {
      slivers.add(
        SliverToBoxAdapter(
          child: IosListSection(
            separatorIndent: IosListSection.indentForIcon(),
            children: [
              IosListRow(
                leading: IosIconTile(icon: IosIcons.warning, color: c.warning),
                title: Text(
                  scope.hostListError!,
                  key: const ValueKey('local_host_list_error'),
                ),
              ),
              if (scope.retryHosts != null)
                IosListActionRow(
                  key: const ValueKey('local_host_list_retry'),
                  icon: Icons.refresh_rounded,
                  label: l10n.retryRefresh,
                  onTap: scope.busy ? null : scope.retryHosts,
                ),
            ],
          ),
        ),
      );
    }

    // 空状态判断
    if (scope.hosts.isEmpty && scope.groups.isEmpty && quickCommand == null) {
      final primaryAdd = scope.addMenu
          .expand((s) => s)
          .where((a) => a.enabled)
          .firstOrNull;
      slivers.add(
        SliverIosEmptyState(
          child: IosEmptyState(
            icon: IosIcons.hosts,
            title: l10n.noHostsYet,
            message: l10n.addHostDetailsToStoreThem,
            actionLabel: primaryAdd?.label,
            onAction: primaryAdd == null ? null : () => primaryAdd.run(),
          ),
        ),
      );
    } else if (filteredHosts.isEmpty &&
        visibleGroups.isEmpty &&
        quickCommand == null) {
      slivers.add(
        SliverIosEmptyState(
          child: IosEmptyState(
            icon: IosIcons.search,
            title: l10n.noMatchingHosts,
          ),
        ),
      );
    } else {
      // 1. Files 侧栏式可折叠「分组」区域
      if (visibleGroups.isNotEmpty && !_sectionByGroup) {
        slivers.add(
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                IosProminentHeader(
                  key: const ValueKey('ios_hosts_groups_header'),
                  title: l10n.groups,
                  collapsed: _groupsCollapsed && query.isEmpty,
                  onToggle: query.isEmpty
                      ? () =>
                            setState(() => _groupsCollapsed = !_groupsCollapsed)
                      : null,
                ),
                if (!_groupsCollapsed || query.isNotEmpty)
                  IosListSection(
                    separatorIndent: IosListSection.indentForIcon(),
                    children: [
                      for (final group in visibleGroups)
                        IosGroupFolderRow(
                          group: group,
                          backLabel: l10n.hosts,
                        ),
                    ],
                  )
                else
                  const SizedBox(height: 16),
              ],
            ),
          ),
        );
      }

      // 2. 主机列表区（支持合并全部主机 或 按分组切分 Section）
      if (filteredHosts.isNotEmpty) {
        if (_sectionByGroup && query.isEmpty) {
          slivers.addAll(_buildGroupedHostSections(context, scope, filteredHosts));
        } else {
          final currentSortLabel = _sortOrder == IosHostSortOrder.recent
              ? _sortByRecentLabel
              : _sortByNameLabel;
          slivers.add(
            SliverToBoxAdapter(
              child: IosListSection(
                key: const ValueKey('local_host_list'),
                headerWidget: IosSectionHeader(
                  _allHostsTitle,
                  trailing: IosPullDownButton(
                    key: const ValueKey('ios_hosts_sort_button'),
                    sections: _buildSortMenu,
                    semanticLabel: currentSortLabel,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currentSortLabel,
                          style: IosType.footnote.copyWith(color: c.tint),
                        ),
                        const SizedBox(width: 4),
                        IosChevron(
                          direction: IosChevronDirection.down,
                          size: 10,
                          strokeWidth: 1.8,
                          color: c.tint,
                        ),
                      ],
                    ),
                  ),
                ),
                separatorIndent: IosListSection.indentForIcon(
                  IosMetrics.hostIconTile,
                ),
                children: [
                  for (final host in filteredHosts) IosHostRow(host: host),
                ],
              ),
            ),
          );
        }
      }
    }

    return IosLargeTitlePage(
      key: const ValueKey('ios_hosts_tab'),
      title: l10n.hosts,
      trailing: IosBarButtonGroup(items: trailingItems),
      searchField: searchField,
      onRefresh: scope.refresh,
      slivers: slivers,
    );
  }

  List<Widget> _buildGroupedHostSections(
    BuildContext context,
    IosWorkspaceData scope,
    List<HostRecord> hosts,
  ) {
    final groupLabels = hostSearchGroupLabels(scope.groups);
    final byGroup = <String?, List<HostRecord>>{};
    for (final host in hosts) {
      byGroup.putIfAbsent(host.groupId, () => []).add(host);
    }
    final groupIds = byGroup.keys.toList()
      ..sort((a, b) {
        if (a == null) return 1;
        if (b == null) return -1;
        final labelA = groupLabels[a] ?? '';
        final labelB = groupLabels[b] ?? '';
        return labelA.toLowerCase().compareTo(labelB.toLowerCase());
      });

    return [
      SliverToBoxAdapter(
        key: const ValueKey('local_host_list'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final groupId in groupIds)
              IosListSection(
                header: groupId == null
                    ? _ungroupedTitle
                    : (groupLabels[groupId] ?? _ungroupedTitle),
                separatorIndent: IosListSection.indentForIcon(
                  IosMetrics.hostIconTile,
                ),
                children: [
                  for (final host in byGroup[groupId]!) IosHostRow(host: host),
                ],
              ),
          ],
        ),
      ),
    ];
  }
}

/// Files 式分组文件夹行：点按 push `IosGroupDetailPage`，支持左右滑动与长按菜单。
class IosGroupFolderRow extends StatelessWidget {
  const IosGroupFolderRow({
    super.key,
    required this.group,
    required this.backLabel,
  });

  final GroupRecord group;
  final String backLabel;

  @override
  Widget build(BuildContext context) {
    final scope = IosWorkspaceScope.of(context);
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final count = countIosGroupHosts(scope, group.id);
    final folderColor = resolveIosGroupColor(c, group.color);

    void openDetail() {
      final groupId = group.id;
      final parentTitle = backLabel;
      Navigator.of(context).push(
        CupertinoPageRoute<void>(
          builder: (_) =>
              IosGroupDetailPage(groupId: groupId, backLabel: parentTitle),
        ),
      );
    }

    Widget buildRow({required bool inPreview}) => IosListRow(
      key: inPreview ? null : ValueKey('local_host_group_${group.id}'),
      leading: IosIconTile(icon: IosIcons.folder, color: folderColor),
      title: Text(group.name),
      value: '$count',
      accessory: IosRowAccessory.chevron,
      onTap: inPreview ? null : openDetail,
    );

    final contextActions = <Widget>[
      if (scope.connectGroup != null && count > 0 && !kIsWeb)
        Builder(
          builder: (menuCtx) => CupertinoContextMenuAction(
            trailingIcon: IosIcons.connect,
            onPressed: () {
              Navigator.of(menuCtx).pop();
              scope.connectGroup!(group);
            },
            child: Text(l10n.connectGroup),
          ),
        ),
      if (scope.editGroup != null)
        Builder(
          builder: (menuCtx) => CupertinoContextMenuAction(
            trailingIcon: IosIcons.edit,
            onPressed: () {
              Navigator.of(menuCtx).pop();
              scope.editGroup!(group);
            },
            child: Text(l10n.edit),
          ),
        ),
      if (scope.deleteGroup != null)
        Builder(
          builder: (menuCtx) => CupertinoContextMenuAction(
            isDestructiveAction: true,
            trailingIcon: IosIcons.delete,
            onPressed: () {
              Navigator.of(menuCtx).pop();
              scope.deleteGroup!(group);
            },
            child: Text(l10n.delete),
          ),
        ),
    ];

    final Widget interactiveRow = contextActions.isEmpty
        ? buildRow(inPreview: false)
        : CupertinoContextMenu.builder(
            actions: contextActions,
            builder: (ctx, animation) {
              if (animation.value < CupertinoContextMenu.animationOpensAt) {
                return buildRow(inPreview: false);
              }
              return _IosContextPreviewShell(child: buildRow(inPreview: true));
            },
          );

    return IosSwipeActionCell(
      enabled: !scope.busy,
      leading: [
        if (scope.connectGroup != null && count > 0 && !kIsWeb)
          IosSwipeAction(
            label: l10n.connectGroup,
            icon: IosIcons.connect,
            color: c.tint,
            onTap: () => scope.connectGroup!(group),
          ),
      ],
      trailing: [
        if (scope.deleteGroup != null)
          IosSwipeAction(
            key: ValueKey('ios_group_swipe_delete_${group.id}'),
            label: l10n.delete,
            icon: IosIcons.delete,
            color: c.destructive,
            destructive: true,
            onTap: () => scope.deleteGroup!(group),
          ),
        if (scope.editGroup != null)
          IosSwipeAction(
            key: ValueKey('ios_group_swipe_edit_${group.id}'),
            label: l10n.edit,
            icon: IosIcons.edit,
            color: c.gray,
            onTap: () => scope.editGroup!(group),
          ),
      ],
      child: interactiveRow,
    );
  }
}

/// Wi-Fi 设置范式主机行：
/// - 60pt 行高，36pt 连续曲率 OS 图标块，17pt 主机名 + 13pt mono `user@host:port`
/// - 活跃会话显示 8pt 在线绿点
/// - 点按行 = 直接连接；右侧 `ⓘ` = 打开编辑 Sheet；不显示 `›`
/// - 左滑 删除/编辑，右滑 SFTP，长按 `CupertinoContextMenu`
/// - 保留 `ValueKey('local_host_${host.id}')`
class IosHostRow extends StatelessWidget {
  const IosHostRow({super.key, required this.host});

  final HostRecord host;

  void _copyEndpoint(BuildContext context, IosWorkspaceData scope) {
    if (scope.copyAddress != null) {
      scope.copyAddress!(host);
      return;
    }
    final endpoint = formatIosHostEndpoint(host);
    unawaited(Clipboard.setData(ClipboardData(text: endpoint)));
    final isZh = Localizations.localeOf(
      context,
    ).languageCode.toLowerCase().startsWith('zh');
    IosToast.show(
      context,
      isZh ? '已复制 $endpoint' : 'Copied $endpoint',
      kind: IosToastKind.success,
    );
  }

  List<Widget> _buildContextActions(
    BuildContext outerContext,
    IosWorkspaceData scope,
  ) {
    final actions = scope.hostActions(host);
    final widgets = <Widget>[];
    var insertedCopy = false;

    void appendCopyAction() {
      if (insertedCopy) return;
      insertedCopy = true;
      final isZh = Localizations.localeOf(
        outerContext,
      ).languageCode.toLowerCase().startsWith('zh');
      widgets.add(
        Builder(
          builder: (menuCtx) => CupertinoContextMenuAction(
            trailingIcon: IosIcons.copy,
            onPressed: () {
              Navigator.of(menuCtx).pop();
              if (outerContext.mounted) {
                _copyEndpoint(outerContext, scope);
              }
            },
            child: Text(isZh ? '复制地址' : outerContext.l10n.copy),
          ),
        ),
      );
    }

    for (final action in actions) {
      if (!action.enabled) continue;
      if (action.destructive) {
        appendCopyAction();
      }
      widgets.add(
        Builder(
          builder: (menuCtx) => CupertinoContextMenuAction(
            isDestructiveAction: action.destructive,
            trailingIcon: normalizeIosRoundedIcon(action.icon),
            onPressed: () {
              Navigator.of(menuCtx).pop();
              unawaited(Future<void>.sync(action.run));
            },
            child: Text(action.label),
          ),
        ),
      );
    }
    appendCopyAction();
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final scope = IosWorkspaceScope.of(context);
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final isOnline = scope.liveHostIds.contains(host.id) || host.online;
    final endpoint = formatIosHostEndpoint(host);
    final canConnect = !scope.busy && !kIsWeb;
    final canSftp =
        !scope.busy &&
        !kIsWeb &&
        host.protocol == HostProtocol.ssh &&
        scope.openFiles != null;

    final rowWidget = IosListRow(
      key: ValueKey('local_host_${host.id}'),
      minHeight: IosMetrics.hostRowHeight,
      leading: IosIconTile(
        size: IosMetrics.hostIconTile,
        radius: IosMetrics.hostIconTileRadius,
        color: c.fill,
        child: ExcludeSemantics(child: HostSystemIcon(host: host, size: 22)),
      ),
      title: Text(host.name),
      titleTrailing: isOnline
          ? IosStatusDot(
              key: ValueKey('ios_host_online_${host.id}'),
              color: c.online,
              size: 8,
            )
          : null,
      subtitle: Text(endpoint),
      monoSubtitle: true,
      accessory: IosRowAccessory.info,
      infoKey: ValueKey('ios_host_info_${host.id}'),
      infoSemanticLabel: l10n.edit,
      onInfo: scope.busy ? null : () => scope.edit(host),
      enabled: !scope.busy,
      onTap: canConnect
          ? () {
              HapticFeedback.lightImpact().catchError((Object _) {});
              scope.connect(host);
            }
          : null,
    );

    final contextActions = _buildContextActions(context, scope);
    final Widget withContextMenu = contextActions.isEmpty
        ? rowWidget
        : CupertinoContextMenu.builder(
            actions: contextActions,
            builder: (ctx, animation) {
              if (animation.value < CupertinoContextMenu.animationOpensAt) {
                return rowWidget;
              }
              return _IosHostPreviewCard(
                host: host,
                endpoint: endpoint,
                isOnline: isOnline,
              );
            },
          );

    return IosSwipeActionCell(
      enabled: !scope.busy,
      leading: [
        if (canSftp)
          IosSwipeAction(
            key: ValueKey('ios_host_swipe_sftp_${host.id}'),
            label: 'SFTP',
            icon: IosIcons.sftp,
            color: c.tint,
            onTap: () => scope.openFiles!(host),
          ),
      ],
      trailing: [
        IosSwipeAction(
          key: ValueKey('ios_host_swipe_delete_${host.id}'),
          label: l10n.delete,
          icon: IosIcons.delete,
          color: c.destructive,
          destructive: true,
          onTap: () => scope.delete(host),
        ),
        IosSwipeAction(
          key: ValueKey('ios_host_swipe_edit_${host.id}'),
          label: l10n.edit,
          icon: IosIcons.edit,
          color: c.gray,
          onTap: () => scope.edit(host),
        ),
      ],
      child: withContextMenu,
    );
  }
}

/// 长按上下文菜单展开时的放大主机预览卡片。
class _IosHostPreviewCard extends StatelessWidget {
  const _IosHostPreviewCard({
    required this.host,
    required this.endpoint,
    required this.isOnline,
  });

  final HostRecord host;
  final String endpoint;
  final bool isOnline;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    return _IosContextPreviewShell(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IosIconTile(
              size: 44,
              radius: 11,
              color: c.fill,
              child: ExcludeSemantics(
                child: HostSystemIcon(host: host, size: 26),
              ),
            ),
            const SizedBox(width: 14),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          host.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: IosType.headline.copyWith(color: c.label),
                        ),
                      ),
                      if (isOnline) ...[
                        const SizedBox(width: 6),
                        IosStatusDot(color: c.online, size: 8),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    endpoint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: IosType.mono.copyWith(color: c.secondaryLabel),
                  ),
                  if (host.tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      host.tags.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: IosType.caption1.copyWith(color: c.tertiaryLabel),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 为 `CupertinoContextMenu` 展开态提供有界尺寸与 26pt 连续曲率圆角背景。
class _IosContextPreviewShell extends StatelessWidget {
  const _IosContextPreviewShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final maxWidth = (MediaQuery.sizeOf(context).width - 40).clamp(240.0, 360.0);
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(IosMetrics.groupRadius),
          child: Material(
            color: c.cell,
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
