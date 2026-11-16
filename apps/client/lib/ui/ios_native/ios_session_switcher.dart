import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../l10n/l10n.dart';
import '../workspace_tab_bar.dart' show WorkspaceTab;
import 'ios_icons.dart';
import 'ios_list.dart';
import 'ios_sheet.dart';
import 'ios_swipe_actions.dart';
import 'ios_tokens.dart';

/// 弹出 iOS 底部活跃会话切换器 Sheet（视觉附录 §9.4 / 蓝图 §3）。
Future<void> showIosSessionSwitcher(
  BuildContext context, {
  required List<WorkspaceTab> sessions,
  String? selectedId,
  required ValueChanged<String> onSelect,
  required ValueChanged<String> onClose,
  VoidCallback? onNewConnection,
  Map<String, String> subtitles = const {},
}) {
  final live = sessions.where((tab) => !tab.isHome).toList();
  if (live.isEmpty && onNewConnection == null) return Future<void>.value();
  return showIosDetentSheet<void>(
    context,
    detents: const [0.52, 0.92],
    builder: (sheetContext, scrollController) => IosSessionSwitcherSheet(
      sessions: live,
      selectedId: selectedId,
      onSelect: onSelect,
      onClose: onClose,
      onNewConnection: onNewConnection,
      subtitles: subtitles,
      scrollController: scrollController,
    ),
  );
}

/// 活跃会话切换面板主体（左滑关闭会话、点按切换、底部新建连接）。
class IosSessionSwitcherSheet extends StatefulWidget {
  const IosSessionSwitcherSheet({
    super.key,
    required this.sessions,
    this.selectedId,
    required this.onSelect,
    required this.onClose,
    this.onNewConnection,
    this.subtitles = const {},
    this.scrollController,
  });

  final List<WorkspaceTab> sessions;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final VoidCallback? onNewConnection;
  final Map<String, String> subtitles;
  final ScrollController? scrollController;

  @override
  State<IosSessionSwitcherSheet> createState() =>
      _IosSessionSwitcherSheetState();
}

class _IosSessionSwitcherSheetState extends State<IosSessionSwitcherSheet> {
  late final List<WorkspaceTab> _items = [
    for (final tab in widget.sessions)
      if (!tab.isHome) tab,
  ];

  void _closeTab(WorkspaceTab tab) {
    HapticFeedback.mediumImpact().catchError((Object _) {});
    setState(() => _items.removeWhere((item) => item.id == tab.id));
    widget.onClose(tab.id);
    if (_items.isEmpty && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final title = isZh ? '活跃会话' : 'Active Sessions';
    final doneLabel = isZh ? '完成' : 'Done';
    final newConnectionLabel = isZh ? '新建连接' : 'New Connection';

    return DefaultTextStyle.merge(
      style: IosType.body.copyWith(color: c.label),
      child: Column(
        children: [
          SizedBox(
            height: 44,
            child: NavigationToolbar(
              middleSpacing: 8,
              middle: Text(
                title,
                style: IosType.headline.copyWith(color: c.label),
              ),
              trailing: GestureDetector(
                key: const ValueKey('ios_session_switcher_done'),
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).maybePop(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Text(
                    doneLabel,
                    style: IosType.headline.copyWith(color: c.tint),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView(
              controller: widget.scrollController,
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              padding: EdgeInsets.only(
                top: 8,
                bottom: MediaQuery.paddingOf(context).bottom + 24,
              ),
              children: [
                if (_items.isNotEmpty)
                  IosListSection(
                    separatorIndent: IosListSection.indentForIcon(
                      IosMetrics.hostIconTile,
                    ),
                    children: [
                      for (final tab in _items)
                        IosSwipeActionCell(
                          key: ValueKey('ios_switcher_swipe_${tab.id}'),
                          trailing: [
                            IosSwipeAction(
                              key: ValueKey('ios_switcher_close_${tab.id}'),
                              label: l10n.closeTab,
                              icon: IosIcons.close,
                              color: c.destructive,
                              destructive: true,
                              onTap: () => _closeTab(tab),
                            ),
                          ],
                          child: IosListRow(
                            key: ValueKey('ios_switcher_item_${tab.id}'),
                            minHeight: IosMetrics.hostRowHeight,
                            leading: IosIconTile(
                              size: IosMetrics.hostIconTile,
                              radius: IosMetrics.hostIconTileRadius,
                              color: c.fill,
                              glyphColor: tab.isFile ? c.blue : c.tint,
                              icon:
                                  tab.icon ??
                                  (tab.isFile
                                      ? IosIcons.folder
                                      : IosIcons.terminal),
                            ),
                            title: Text(tab.title),
                            subtitle: Text(_subtitleFor(tab, l10n)),
                            monoSubtitle: widget.subtitles.containsKey(tab.id),
                            trailing: IosStatusDot(
                              color: tab.isConnected
                                  ? c.online
                                  : c.tertiaryLabel,
                            ),
                            accessory: tab.id == widget.selectedId
                                ? IosRowAccessory.checkmark
                                : IosRowAccessory.none,
                            onTap: () {
                              HapticFeedback.selectionClick().catchError(
                                (Object _) {},
                              );
                              Navigator.of(context).pop();
                              widget.onSelect(tab.id);
                            },
                          ),
                        ),
                    ],
                  ),
                if (widget.onNewConnection != null)
                  IosListSection(
                    children: [
                      IosListActionRow(
                        key: const ValueKey('ios_switcher_new_connection'),
                        label: newConnectionLabel,
                        icon: Icons.add_circle_rounded,
                        onTap: () {
                          Navigator.of(context).pop();
                          widget.onNewConnection!();
                        },
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _subtitleFor(WorkspaceTab tab, AppLocalizations l10n) {
    final custom = widget.subtitles[tab.id] ?? tab.status;
    if (custom != null && custom.isNotEmpty) return custom;
    if (tab.isFile) return l10n.fileManager;
    return tab.isConnected ? l10n.connected : l10n.notConnected;
  }
}
