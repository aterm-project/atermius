import 'package:flutter/material.dart';

import '../../domain/models.dart' show GroupRecord, HostRecord;
import '../../domain/quick_connect.dart' show QuickConnectRequest;
import '../workspace_controls.dart' show WorkspaceAction;

/// 片段列表条目（local / cloud 共用的展示快照）。
@immutable
class IosSnippetItem {
  const IosSnippetItem({
    required this.id,
    required this.title,
    required this.preview,
    this.tags = const [],
  });

  final String id;
  final String title;

  /// 命令预览（单行等宽显示）。
  final String preview;
  final List<String> tags;
}

/// iOS Phone 各 Tab 页面共享的数据快照 + 回调（flow 每次 build 重新下发）。
///
/// 被 push 的页面**只能**通过 [IosWorkspaceScope.of] 读取，禁止在路由 builder
/// 闭包里捕获 flow 状态（否则 push 出去的页面不会随 flow 的 setState 刷新）。
@immutable
class IosWorkspaceData {
  const IosWorkspaceData({
    required this.hosts,
    this.hostSortScope,
    required this.groups,
    required this.search,
    required this.connect,
    required this.edit,
    required this.delete,
    required this.hostActions,
    this.liveHostIds = const {},
    this.snippets = const [],
    this.busy = false,
    this.groupConnecting = false,
    this.hostListError,
    this.openFiles,
    this.addMenu = const [],
    this.moreMenu = const [],
    this.connectGroup,
    this.editGroup,
    this.deleteGroup,
    this.addGroup,
    this.quickConnect,
    this.refresh,
    this.retryHosts,
    this.addSnippet,
    this.editSnippet,
    this.deleteSnippet,
    this.runSnippet,
    this.copyAddress,
  });

  final List<HostRecord> hosts;
  final String? hostSortScope;

  /// 分组（local 由 `LocalGroupRecord.group` 映射）。
  final List<GroupRecord> groups;

  /// 有活跃会话的主机 → 行内显示在线绿点。
  final Set<String> liveHostIds;
  final List<IosSnippetItem> snippets;
  final bool busy;
  final bool groupConnecting;
  final String? hostListError;

  /// 复用 flow 的首页搜索控制器（`_homeSearch`）。
  final TextEditingController search;

  final void Function(HostRecord host) connect;
  final void Function(HostRecord host) edit;
  final void Function(HostRecord host) delete;
  final void Function(HostRecord host)? openFiles;
  final void Function(HostRecord host)? copyAddress;

  /// 长按上下文菜单 / 下拉菜单的完整操作（复用 `_hostActions`）。
  final List<WorkspaceAction> Function(HostRecord host) hostActions;

  /// 主机页 `+` 与 `…` 下拉菜单（按分组传入，空列表自动忽略）。
  final List<List<WorkspaceAction>> addMenu;
  final List<List<WorkspaceAction>> moreMenu;

  final void Function(GroupRecord group)? connectGroup;
  final void Function(GroupRecord group)? editGroup;
  final void Function(GroupRecord group)? deleteGroup;
  final VoidCallback? addGroup;
  final void Function(QuickConnectRequest request)? quickConnect;
  final Future<void> Function()? refresh;
  final VoidCallback? retryHosts;

  final VoidCallback? addSnippet;
  final void Function(String snippetId)? editSnippet;
  final void Function(String snippetId)? deleteSnippet;
  final void Function(String snippetId)? runSnippet;

  /// 指定分组下的直接主机。
  List<HostRecord> hostsInGroup(String? groupId) =>
      hosts.where((host) => host.groupId == groupId).toList();

  /// 指定分组的直接子分组。
  List<GroupRecord> childGroups(String? parentId) =>
      groups.where((group) => group.parentId == parentId).toList();

  GroupRecord? groupById(String id) =>
      groups.where((group) => group.id == id).firstOrNull;
}

/// 下发 [IosWorkspaceData] 的 InheritedWidget。
class IosWorkspaceScope extends InheritedWidget {
  const IosWorkspaceScope({
    super.key,
    required this.data,
    required super.child,
  });

  final IosWorkspaceData data;

  static IosWorkspaceData of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<IosWorkspaceScope>();
    assert(scope != null, 'IosWorkspaceScope 未在祖先中提供');
    return scope!.data;
  }

  static IosWorkspaceData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IosWorkspaceScope>()?.data;

  @override
  bool updateShouldNotify(IosWorkspaceScope oldWidget) =>
      !identical(data, oldWidget.data);
}
