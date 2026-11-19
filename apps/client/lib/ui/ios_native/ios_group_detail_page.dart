import '../../domain/host_sort.dart';
import '../host_sort_menu.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../domain/models.dart';
import '../../l10n/l10n.dart';
import '../workspace_controls.dart' show WorkspaceAction;
import 'ios_empty_state.dart';
import 'ios_hosts_tab.dart';
import 'ios_icons.dart';
import 'ios_large_title_page.dart';
import 'ios_list.dart';
import 'ios_pull_down_menu.dart';
import 'ios_tokens.dart';
import 'ios_workspace_scope.dart';

/// iPhone 分组详情独立导航页（由主机 Tab 点击分组文件夹 push 进入）。
///
/// 严禁在构造闭包中捕获分组或主机列表快照；每次构建均通过
/// [IosWorkspaceScope.of] 按 [groupId] 动态读取最新分组、子分组与组内主机。
class IosGroupDetailPage extends StatefulWidget {
  const IosGroupDetailPage({super.key, required this.groupId, this.backLabel});

  final String groupId;
  final String? backLabel;

  @override
  State<IosGroupDetailPage> createState() => _IosGroupDetailPageState();
}

class _IosGroupDetailPageState extends State<IosGroupDetailPage> {
  final TextEditingController _search = TextEditingController();
  bool _popScheduled = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _isZh =>
      Localizations.localeOf(context).languageCode
          .toLowerCase()
          .startsWith('zh');

  String get _subgroupsHeader => _isZh ? '子分组' : 'Subgroups';

  List<List<WorkspaceAction>> _buildGroupMoreMenu(
    IosWorkspaceData scope,
    GroupRecord group,
    int totalHosts,
  ) {
    final l10n = context.l10n;
    final primary = <WorkspaceAction>[
      if (scope.connectGroup != null)
        WorkspaceAction(
          'ios_group_menu_connect_all',
          l10n.connectGroup,
          IosIcons.connect,
          () => scope.connectGroup!(group),
          enabled:
              !scope.busy &&
              !scope.groupConnecting &&
              totalHosts > 0 &&
              !kIsWeb,
        ),
      if (scope.editGroup != null)
        WorkspaceAction(
          'ios_group_menu_edit',
          l10n.edit,
          IosIcons.edit,
          () => scope.editGroup!(group),
          enabled: !scope.busy,
        ),
    ];
    final destructive = <WorkspaceAction>[
      if (scope.deleteGroup != null)
        WorkspaceAction(
          'ios_group_menu_delete',
          l10n.delete,
          IosIcons.delete,
          () => scope.deleteGroup!(group),
          enabled: !scope.busy,
          destructive: true,
        ),
    ];
    return [
      primary,
      [
        for (final order in HostSortOrder.values)
          WorkspaceAction(
            'ios_group_sort_${order.name}',
            hostSortLabel(l10n, order),
            HostSortController.instance.order == order
                ? IosIcons.check
                : kIosMenuNoIcon,
            () {
              HostSortController.instance.select(order);
            },
          ),
      ],
      destructive,
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: HostSortController.instance,
    builder: (context, _) => _buildPage(context),
  );

  Widget _buildPage(BuildContext context) {
    final scope = IosWorkspaceScope.of(context);
    final l10n = context.l10n;
    final group = scope.groupById(widget.groupId);

    // 若分组已被删除，帧后安全自动返回上一页，避免悬空路由。
    if (group == null) {
      if (!_popScheduled) {
        _popScheduled = true;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).maybePop();
        });
      }
      return IosLargeTitlePage(
        key: ValueKey('ios_group_detail_${widget.groupId}'),
        title: '',
        showBackButton: true,
        backLabel: widget.backLabel ?? l10n.hosts,
        largeTitle: false,
        slivers: const [],
      );
    }

    final query = _search.text.trim().toLowerCase();
    final subGroups =
        scope
            .childGroups(group.id)
            .where((g) => query.isEmpty || g.name.toLowerCase().contains(query))
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );

    final directHosts = HostSortController.instance.sorted(
      scope
          .hostsInGroup(group.id)
          .where(
            (host) =>
                query.isEmpty ||
                '${host.name} ${host.address} ${host.username} ${host.tags.join(' ')}'
                    .toLowerCase()
                    .contains(query),
          )
          .toList(),
      scope: scope.hostSortScope,
    );

    final totalInSubtree = countIosGroupHosts(scope, group.id);
    final canConnectAll =
        !scope.busy &&
        !scope.groupConnecting &&
        !kIsWeb &&
        totalInSubtree > 0 &&
        scope.connectGroup != null;

    final trailing = IosBarButtonGroup(
      items: [
        if (scope.connectGroup != null)
          IosBarButtonItem(
            key: ValueKey('ios_group_connect_all_${group.id}'),
            icon: IosIcons.connect,
            semanticLabel: l10n.connectGroup,
            onPressed: canConnectAll
                ? (_) {
                    HapticFeedback.lightImpact().catchError((Object _) {});
                    scope.connectGroup!(group);
                  }
                : null,
          ),
        IosBarButtonItem(
          key: ValueKey('ios_group_more_${group.id}'),
          icon: IosIcons.more,
          semanticLabel: l10n.more,
          onPressed: (anchor) => showIosPullDownMenu(
            context,
            anchor: anchor,
            sections: _buildGroupMoreMenu(scope, group, totalInSubtree),
          ),
        ),
      ],
    );

    final hasAnyContent =
        scope.childGroups(group.id).isNotEmpty ||
        scope.hostsInGroup(group.id).isNotEmpty;

    final searchField = hasAnyContent
        ? buildIosSearchTextField(
            context,
            key: ValueKey('ios_group_search_${group.id}'),
            controller: _search,
            placeholder: l10n.searchHostsOrTypeAnSsh,
            onChanged: (_) => setState(() {}),
            onSuffixTap: () => setState(() {}),
          )
        : null;

    final slivers = <Widget>[];
    if (!hasAnyContent) {
      slivers.add(
        SliverIosEmptyState(
          child: IosEmptyState(
            icon: IosIcons.folder,
            title: l10n.noHostsYet,
            message: l10n.addHostDetailsToStoreThem,
            actionLabel: scope.editGroup != null ? l10n.edit : null,
            onAction: scope.busy || scope.editGroup == null
                ? null
                : () => scope.editGroup!(group),
          ),
        ),
      );
    } else if (subGroups.isEmpty && directHosts.isEmpty) {
      slivers.add(
        SliverIosEmptyState(
          child: IosEmptyState(
            icon: IosIcons.search,
            title: l10n.noMatchingHosts,
          ),
        ),
      );
    } else {
      if (subGroups.isNotEmpty) {
        slivers.add(
          SliverToBoxAdapter(
            child: IosListSection(
              header: _subgroupsHeader,
              separatorIndent: IosListSection.indentForIcon(),
              children: [
                for (final sub in subGroups)
                  IosGroupFolderRow(group: sub, backLabel: group.name),
              ],
            ),
          ),
        );
      }
      if (directHosts.isNotEmpty) {
        slivers.add(
          SliverToBoxAdapter(
            child: IosListSection(
              header: l10n.hosts,
              separatorIndent: IosListSection.indentForIcon(
                IosMetrics.hostIconTile,
              ),
              children: [
                for (final host in directHosts) IosHostRow(host: host),
              ],
            ),
          ),
        );
      }
    }

    return IosLargeTitlePage(
      key: ValueKey('ios_group_detail_${group.id}'),
      title: group.name,
      showBackButton: true,
      backLabel: widget.backLabel ?? l10n.hosts,
      trailing: trailing,
      searchField: searchField,
      onRefresh: scope.refresh,
      slivers: slivers,
    );
  }
}
