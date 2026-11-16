import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import 'ios_empty_state.dart';
import 'ios_icons.dart';
import 'ios_large_title_page.dart';
import 'ios_list.dart';
import 'ios_swipe_actions.dart';
import 'ios_toast.dart';
import 'ios_tokens.dart';
import 'ios_workspace_scope.dart';

/// iPhone 纯血「片段」一级 Tab 页面。
///
/// 通过 [IosWorkspaceScope.of] 读取片段数据与新建/编辑/删除回调。
class IosSnippetsTab extends StatefulWidget {
  const IosSnippetsTab({super.key});

  @override
  State<IosSnippetsTab> createState() => _IosSnippetsTabState();
}

class _IosSnippetsTabState extends State<IosSnippetsTab> {
  final TextEditingController _search = TextEditingController();
  String? _selectedTag;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(IosSnippetItem item) {
    if (_selectedTag != null && !item.tags.contains(_selectedTag)) {
      return false;
    }
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return item.title.toLowerCase().contains(q) ||
        item.preview.toLowerCase().contains(q) ||
        item.tags.any((tag) => tag.toLowerCase().contains(q));
  }

  void _copyPreview(BuildContext context, IosSnippetItem item) {
    if (item.preview.trim().isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: item.preview)));
    final isZh = Localizations.localeOf(
      context,
    ).languageCode.toLowerCase().startsWith('zh');
    IosToast.show(
      context,
      isZh ? '已复制命令预览' : 'Copied snippet preview',
      kind: IosToastKind.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = IosWorkspaceScope.of(context);
    final l10n = context.l10n;

    final allTags = <String>{
      for (final item in scope.snippets) ...item.tags,
    }.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (_selectedTag != null && !allTags.contains(_selectedTag)) {
      _selectedTag = null;
    }

    final filtered = scope.snippets.where(_matches).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

    final trailing = scope.addSnippet == null
        ? null
        : IosBarButton(
            key: const ValueKey('local_snippet_add'),
            icon: IosIcons.add,
            semanticLabel: l10n.addSnippet,
            onPressed: scope.busy ? null : scope.addSnippet,
          );

    final searchField = buildIosSearchTextField(
      context,
      key: const ValueKey('ios_snippets_search'),
      controller: _search,
      placeholder: l10n.snippets,
      onChanged: (_) => setState(() {}),
      onSuffixTap: () => setState(() {}),
    );

    final slivers = <Widget>[];

    // 可选标签胶囊筛选栏（存在标签时展示）
    if (allTags.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: IosMetrics.sectionMargin,
              ),
              children: [
                _TagFilterPill(
                  label: l10n.r7NavLogFilterAll,
                  selected: _selectedTag == null,
                  onTap: () => setState(() => _selectedTag = null),
                ),
                for (final tag in allTags)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 8),
                    child: _TagFilterPill(
                      label: tag,
                      selected: _selectedTag == tag,
                      onTap: () => setState(
                        () => _selectedTag = _selectedTag == tag ? null : tag,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 12)));
    }

    if (scope.snippets.isEmpty) {
      slivers.add(
        SliverIosEmptyState(
          child: IosEmptyState(
            icon: IosIcons.snippets,
            title: l10n.noSnippetsYet,
            message: l10n.addAScriptOrAStructured,
            actionLabel: scope.addSnippet != null ? l10n.addSnippet : null,
            onAction: scope.busy ? null : scope.addSnippet,
          ),
        ),
      );
    } else if (filtered.isEmpty) {
      slivers.add(
        SliverIosEmptyState(
          child: IosEmptyState(
            icon: IosIcons.search,
            title: l10n.r7NavLogNoMatches,
          ),
        ),
      );
    } else {
      slivers.add(
        SliverToBoxAdapter(
          child: IosListSection(
            key: const ValueKey('local_snippet_list'),
            footer: l10n.localModeOnlyManagesEncryptedSnippets,
            separatorIndent: IosListSection.indentForIcon(),
            children: [
              for (final item in filtered)
                _IosSnippetRow(
                  item: item,
                  scope: scope,
                  onCopyPreview: () => _copyPreview(context, item),
                ),
            ],
          ),
        ),
      );
    }

    return IosLargeTitlePage(
      key: const ValueKey('ios_snippets_tab'),
      title: l10n.snippets,
      trailing: trailing,
      searchField: searchField,
      onRefresh: scope.refresh,
      slivers: slivers,
    );
  }
}

class _IosSnippetRow extends StatelessWidget {
  const _IosSnippetRow({
    required this.item,
    required this.scope,
    required this.onCopyPreview,
  });

  final IosSnippetItem item;
  final IosWorkspaceData scope;
  final VoidCallback onCopyPreview;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final cleanPreview = item.preview
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final previewText = cleanPreview.isEmpty ? '—' : cleanPreview;
    final primaryAction = scope.runSnippet ?? scope.editSnippet;

    final tagBadge = item.tags.isEmpty
        ? null
        : DecoratedBox(
            decoration: ShapeDecoration(
              color: c.fill,
              shape: const StadiumBorder(),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              child: Text(
                item.tags.length == 1
                    ? item.tags.single
                    : '${item.tags.first} +${item.tags.length - 1}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: IosType.caption1.copyWith(color: c.secondaryLabel),
              ),
            ),
          );

    Widget buildRow({required bool inPreview}) => IosListRow(
      key: inPreview ? null : ValueKey('local_snippet_${item.id}'),
      minHeight: IosMetrics.hostRowHeight,
      leading: IosIconTile(icon: IosIcons.snippets, color: c.indigo),
      title: Text(item.title),
      titleTrailing: tagBadge,
      subtitle: Text(previewText),
      monoSubtitle: true,
      accessory: scope.editSnippet != null
          ? IosRowAccessory.info
          : IosRowAccessory.none,
      infoKey: inPreview ? null : ValueKey('ios_snippet_info_${item.id}'),
      infoSemanticLabel: l10n.editSnippet,
      onInfo: scope.busy || scope.editSnippet == null
          ? null
          : () => scope.editSnippet!(item.id),
      enabled: !scope.busy,
      onTap: inPreview || scope.busy || primaryAction == null
          ? null
          : () {
              HapticFeedback.selectionClick().catchError((Object _) {});
              primaryAction(item.id);
            },
    );

    final contextActions = <Widget>[
      if (scope.runSnippet != null)
        Builder(
          builder: (menuCtx) => CupertinoContextMenuAction(
            trailingIcon: IosIcons.connect,
            onPressed: () {
              Navigator.of(menuCtx).pop();
              scope.runSnippet!(item.id);
            },
            child: Text(l10n.terminal),
          ),
        ),
      if (scope.editSnippet != null)
        Builder(
          builder: (menuCtx) => CupertinoContextMenuAction(
            trailingIcon: IosIcons.edit,
            onPressed: () {
              Navigator.of(menuCtx).pop();
              scope.editSnippet!(item.id);
            },
            child: Text(l10n.editSnippet),
          ),
        ),
      if (cleanPreview.isNotEmpty)
        Builder(
          builder: (menuCtx) => CupertinoContextMenuAction(
            trailingIcon: IosIcons.copy,
            onPressed: () {
              Navigator.of(menuCtx).pop();
              onCopyPreview();
            },
            child: Text(l10n.copy),
          ),
        ),
      if (scope.deleteSnippet != null)
        Builder(
          builder: (menuCtx) => CupertinoContextMenuAction(
            isDestructiveAction: true,
            trailingIcon: IosIcons.delete,
            onPressed: () {
              Navigator.of(menuCtx).pop();
              scope.deleteSnippet!(item.id);
            },
            child: Text(l10n.deleteSnippet),
          ),
        ),
    ];

    final Widget withContextMenu = contextActions.isEmpty
        ? buildRow(inPreview: false)
        : CupertinoContextMenu.builder(
            actions: contextActions,
            builder: (ctx, animation) {
              if (animation.value < CupertinoContextMenu.animationOpensAt) {
                return buildRow(inPreview: false);
              }
              final maxW =
                  (MediaQuery.sizeOf(ctx).width - 40).clamp(240.0, 360.0);
              return Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: ClipRSuperellipse(
                    borderRadius: BorderRadius.circular(IosMetrics.groupRadius),
                    child: Material(
                      color: c.cell,
                      child: SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: buildRow(inPreview: true),
                      ),
                    ),
                  ),
                ),
              );
            },
          );

    return IosSwipeActionCell(
      enabled: !scope.busy,
      trailing: [
        if (scope.deleteSnippet != null)
          IosSwipeAction(
            key: ValueKey('ios_snippet_swipe_delete_${item.id}'),
            label: l10n.delete,
            icon: IosIcons.delete,
            color: c.destructive,
            destructive: true,
            onTap: () => scope.deleteSnippet!(item.id),
          ),
        if (scope.editSnippet != null)
          IosSwipeAction(
            key: ValueKey('ios_snippet_swipe_edit_${item.id}'),
            label: l10n.edit,
            icon: IosIcons.edit,
            color: c.gray,
            onTap: () => scope.editSnippet!(item.id),
          ),
      ],
      child: withContextMenu,
    );
  }
}

class _TagFilterPill extends StatelessWidget {
  const _TagFilterPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick().catchError((Object _) {});
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: ShapeDecoration(
          color: selected ? c.tint : c.fill,
          shape: const StadiumBorder(),
        ),
        child: Text(
          label,
          style: IosType.footnote.copyWith(
            color: selected ? c.onTint : c.label,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
