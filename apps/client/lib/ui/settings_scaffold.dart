import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'app_density.dart';
import 'app_theme.dart';
import 'apple_hig.dart';
import 'ios_native/ios_native.dart';
import 'ios_native/ios_settings_navigator.dart';
import 'responsive_layout.dart';

AppPalette _settingsPaletteOf(BuildContext context) {
  final theme = Theme.of(context);
  return theme.extension<AppPalette>() ??
      (theme.brightness == Brightness.dark
          ? AppPalette.dark
          : AppPalette.light);
}

/// 标记子组件在 iOS Phone 模式下自行管理分组卡片内边距（如通栏行与左缩进分割线），
/// 使 [SettingsCard] 在 iOS Phone 下不额外包裹四周内边距，保持非 iOS 平台不变。
mixin IosFlushSettingsChild on Widget {}

@immutable
class SettingsSection {
  const SettingsSection({
    required this.id,
    required this.title,
    required this.icon,
    required this.description,
    required this.builder,
    this.iosValue,
    this.iosTint,
    this.iosFullPage = false,
    this.iosOnTap,
    this.iosDestructive = false,
  });

  final String id;
  final String title;
  final IconData icon;
  final String description;
  final WidgetBuilder builder;

  /// iOS Phone 一级设置列表右侧展示的当前状态灰字（可选）。
  final String Function(BuildContext)? iosValue;

  /// iOS Phone 一级设置列表左侧 29pt 圆角图标块色（可选，缺省按 [id] 自动匹配系统色）。
  final Color? iosTint;

  /// 当 [builder] 自身已经是完整的 `IosLargeTitlePage`（如 `SessionLogsPage`）时设为 true，
  /// 二级页直接渲染 [builder] 产物而不重复包裹导航栏与滚动容器。
  final bool iosFullPage;

  /// iOS Phone 一级行点击动作覆盖（例如“锁定配置库”直接执行动作而不 push 二级页）。
  final VoidCallback? iosOnTap;

  /// iOS Phone 一级行标题使用破坏性红色样式。
  final bool iosDestructive;
}

/// Categories are built on first visit. Visited forms keep their drafts and
/// scroll positions while navigating within settings.
class SettingsScaffold extends StatefulWidget {
  const SettingsScaffold({required this.sections, super.key});

  final List<SettingsSection> sections;

  /// Selects another category of the enclosing settings page, for example a
  /// cross-link from Account to Account security. Returns false when
  /// [context] is not inside a settings page or the category is not offered.
  static bool selectSection(BuildContext context, String id) {
    final state = context.findAncestorStateOfType<_SettingsScaffoldState>();
    if (state == null || !state.widget.sections.any((s) => s.id == id)) {
      return false;
    }
    state._select(id);
    return true;
  }

  @override
  State<SettingsScaffold> createState() => _SettingsScaffoldState();
}

class _SettingsScaffoldState extends State<SettingsScaffold> {
  final _contentKey = GlobalKey();
  final _visited = <String>{};
  String? _selectedId;
  String? _iosOpenId;

  void _select(String id) {
    final iosPhone = isIosPhone(context);
    if (!iosPhone && _selectedId == id) return;
    if (iosPhone && _iosOpenId == id) return;
    AppleHaptics.selection(context);
    FocusScope.of(context).unfocus();
    setState(() {
      _selectedId = id;
      _visited.add(id);
      if (iosPhone) _iosOpenId = id;
    });
  }

  void _onIosOpenChanged(String? nextId) {
    if (nextId != null) {
      AppleHaptics.selection(context);
      FocusScope.of(context).unfocus();
    }
    if (_iosOpenId == nextId) return;
    setState(() {
      _iosOpenId = nextId;
      if (nextId != null) {
        _selectedId = nextId;
        _visited.add(nextId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sections = widget.sections;
    if (sections.isEmpty) return const SizedBox.shrink();
    final ids = sections.map((section) => section.id).toSet();
    if (isIosPhone(context)) {
      if (_iosOpenId != null && !ids.contains(_iosOpenId)) {
        _iosOpenId = null;
      }
      return IosSettingsNavigator(
        sections: sections,
        openSectionId: _iosOpenId,
        onOpenSectionChanged: _onIosOpenChanged,
      );
    }

    _visited.removeWhere((id) => !ids.contains(id));
    if (!ids.contains(_selectedId)) _selectedId = sections.first.id;
    _visited.add(_selectedId!);
    final selected = sections.indexWhere((s) => s.id == _selectedId);
    final activeSection = sections[selected];
    final density = AppDensity.of(context);
    final platform = Theme.of(context).platform;
    final touch = isTouchPlatform(platform);
    final apple = isAppleContext(context);
    final palette = _settingsPaletteOf(context);
    final hairline = appleHairlineWidth(context);
    // Padding follows the width this scaffold actually gets (not the window),
    // so it always agrees with the picker/navigation choice below, e.g. on a
    // tablet beside the Home rail or in Android split-screen.
    Widget content(bool narrow) => KeyedSubtree(
      key: _contentKey,
      child: IndexedStack(
        index: selected,
        sizing: StackFit.expand,
        children: [
          for (final section in sections)
            TickerMode(
              key: ValueKey('settings_page_${section.id}'),
              enabled: section.id == _selectedId,
              child: !_visited.contains(section.id)
                  ? const SizedBox.shrink()
                  : SingleChildScrollView(
                      key: PageStorageKey('settings_scroll_${section.id}'),
                      primary: false,
                      // Touch: dragging the page hides the soft keyboard, as
                      // Android users expect, instead of leaving it covering
                      // the form.
                      // Desktop keeps the inherited scroll behaviour.
                      keyboardDismissBehavior: touch
                          ? ScrollViewKeyboardDismissBehavior.onDrag
                          : null,
                      padding: narrow
                          ? const EdgeInsets.all(12)
                          : density.pagePadding,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: density.dialogXl,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                section.title,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                              SizedBox(height: density.space3),
                              Text(
                                section.description,
                                style: TextStyle(
                                  color: palette.muted,
                                  height: 1.5,
                                ),
                              ),
                              SizedBox(height: density.space7),
                              section.builder(context),
                            ],
                          ),
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < AppBreakpoints.settingsNavigation) {
          final pickerField = DropdownButtonFormField<String>(
            key: ValueKey('settings_category_picker_$_selectedId'),
            initialValue: _selectedId,
            isExpanded: true,
            dropdownColor: apple ? palette.surfaceRaised : null,
            borderRadius: apple
                ? BorderRadius.circular(density.radiusMd)
                : null,
            icon: apple
                ? Icon(
                    Icons.expand_more_rounded,
                    size: 20,
                    color: palette.muted,
                  )
                : null,
            decoration: apple
                ? InputDecoration(
                    labelText: context.l10n.settingsCategories,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.fromLTRB(0, 10, 12, 10),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 50,
                      minHeight: 44,
                    ),
                    prefixIcon: Padding(
                      padding: const EdgeInsets.only(left: 12, right: 10),
                      child: _SettingsCategoryIconBadge(
                        icon: activeSection.icon,
                        selected: true,
                      ),
                    ),
                  )
                : InputDecoration(
                    labelText: context.l10n.settingsCategories,
                  ),
            items: [
              for (final section in sections)
                DropdownMenuItem(
                  value: section.id,
                  child: Text(section.title),
                ),
            ],
            onChanged: (id) {
              if (id != null) _select(id);
            },
          );
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: apple
                    ? DecoratedBox(
                        decoration: ShapeDecoration(
                          color: palette.isDark
                              ? palette.surfaceRaised
                              : palette.surface,
                          shape: appleSquircleBorder(
                            BorderRadius.circular(density.radiusLg),
                            platform: platform,
                            side: BorderSide(
                              color: palette.line.withValues(
                                alpha: palette.isDark ? 0.80 : 0.86,
                              ),
                              width: hairline,
                            ),
                          ),
                          shadows: [
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: palette.isDark ? 0.16 : 0.04,
                              ),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: pickerField,
                      )
                    : pickerField,
              ),
              Expanded(child: content(true)),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: density.isCompact ? 200 : 220,
              child: Material(
                color: palette.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        density.space7,
                        density.space7,
                        density.space7,
                        density.space5,
                      ),
                      child: Text(
                        context.l10n.settings,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        key: const ValueKey('settings_category_navigation'),
                        padding: EdgeInsets.fromLTRB(
                          density.space4,
                          0,
                          density.space4,
                          density.space7,
                        ),
                        children: [
                          for (final section in sections)
                            Padding(
                              padding: EdgeInsets.only(bottom: density.space1),
                              child: ListTile(
                                key: ValueKey(
                                  'settings_category_${section.id}',
                                ),
                                selected: section.id == _selectedId,
                                selectedColor: palette.lime,
                                selectedTileColor: palette.lime.withValues(
                                  alpha: apple
                                      ? (palette.isDark ? 0.12 : 0.10)
                                      : .09,
                                ),
                                shape: appleSquircleBorder(
                                  BorderRadius.circular(density.radiusMd),
                                  platform: platform,
                                  side: apple && section.id == _selectedId
                                      ? BorderSide(
                                          color: palette.lime.withValues(
                                            alpha: palette.isDark ? 0.24 : 0.20,
                                          ),
                                          width: hairline,
                                        )
                                      : BorderSide.none,
                                ),
                                leading: apple
                                    ? _SettingsCategoryIconBadge(
                                        icon: section.icon,
                                        selected: section.id == _selectedId,
                                      )
                                    : Icon(
                                        section.icon,
                                        size: density.iconMd,
                                      ),
                                minLeadingWidth: apple ? 28 : density.iconMd,
                                horizontalTitleGap: apple
                                    ? density.space4
                                    : null,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: apple
                                      ? density.space4
                                      : density.space5,
                                ),
                                title: Text(
                                  section.title,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight:
                                        apple && section.id == _selectedId
                                        ? FontWeight.w600
                                        : null,
                                  ),
                                ),
                                onTap: () => _select(section.id),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            VerticalDivider(
              width: apple ? hairline : 1,
              thickness: apple ? hairline : 1,
              color: apple
                  ? palette.line.withValues(alpha: palette.isDark ? 0.80 : 0.86)
                  : palette.line,
            ),
            Expanded(child: content(false)),
          ],
        );
      },
    );
  }
}

/// System-Settings style 28x28 continuous-squircle tinted icon badge.
class _SettingsCategoryIconBadge extends StatelessWidget {
  const _SettingsCategoryIconBadge({
    required this.icon,
    required this.selected,
  });

  final IconData icon;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final palette = _settingsPaletteOf(context);
    final fillColor = palette.isDark
        ? palette.accent.withValues(alpha: selected ? 0.28 : 0.16)
        : palette.accentContainer.withValues(alpha: selected ? 0.95 : 0.60);
    final borderColor = palette.isDark
        ? (selected
              ? palette.lime.withValues(alpha: 0.34)
              : palette.line.withValues(alpha: 0.72))
        : palette.accent.withValues(alpha: selected ? 0.28 : 0.16);
    final iconColor = palette.isDark
        ? palette.lime.withValues(alpha: selected ? 1.0 : 0.88)
        : palette.accentText;
    return Center(
      widthFactor: 1,
      heightFactor: 1,
      child: SizedBox.square(
        dimension: 28,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: fillColor,
            shape: appleSquircleBorder(
              BorderRadius.circular(7),
              platform: Theme.of(context).platform,
              side: BorderSide(
                color: borderColor,
                width: appleHairlineWidth(context),
              ),
            ),
          ),
          child: Center(
            child: Icon(icon, size: 16, color: iconColor),
          ),
        ),
      ),
    );
  }
}

/// Keeps individual settings visually separate without nesting scroll views.
class SettingsCards extends StatelessWidget {
  const SettingsCards({required this.children, super.key});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final gap = isIosPhone(context) ? 20.0 : AppDensity.of(context).space5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(height: gap),
          children[i],
        ],
      ],
    );
  }
}

class SettingsCard extends StatelessWidget {
  const SettingsCard({
    required this.child,
    this.semanticContainer = true,
    this.iosPadding,
    super.key,
  });
  final Widget child;

  /// Passed to [Card.semanticContainer]. Keep the default for read-only cards
  /// (they are announced as one block). Pass false for cards that hold
  /// interactive controls such as text fields: otherwise a field that does not
  /// form its own semantics boundary is merged into the card node, so Android
  /// accessibility and UI automation report the field with the whole card's
  /// bounds and all of the card's text as its label.
  final bool semanticContainer;

  /// iOS Phone 模式下的显式内边距覆盖；缺省在 [child] 实现 [IosFlushSettingsChild]
  /// 时为 `EdgeInsets.zero`，否则为 16pt。
  final EdgeInsetsGeometry? iosPadding;

  @override
  Widget build(BuildContext context) {
    if (isIosPhone(context)) {
      final colors = IosColors.of(context);
      final effectivePadding =
          iosPadding ??
          (child is IosFlushSettingsChild
              ? EdgeInsets.zero
              : const EdgeInsets.all(IosMetrics.rowPaddingH));
      final body = ClipRSuperellipse(
        borderRadius: BorderRadius.circular(IosMetrics.groupRadius),
        child: ColoredBox(
          color: colors.cell,
          child: effectivePadding == EdgeInsets.zero
              ? child
              : Padding(padding: effectivePadding, child: child),
        ),
      );
      return semanticContainer ? Semantics(container: true, child: body) : body;
    }

    final density = AppDensity.of(context);
    final apple = isAppleContext(context);
    final palette = _settingsPaletteOf(context);
    return Card(
      margin: EdgeInsets.zero,
      semanticContainer: semanticContainer,
      elevation: apple ? 0 : null,
      surfaceTintColor: apple ? Colors.transparent : null,
      clipBehavior: apple ? Clip.antiAlias : null,
      shape: apple
          ? appleSquircleBorder(
              BorderRadius.circular(density.radiusLg),
              platform: Theme.of(context).platform,
              side: BorderSide(
                color: palette.line.withValues(
                  alpha: palette.isDark ? 0.80 : 0.86,
                ),
                width: appleHairlineWidth(context),
              ),
            )
          : null,
      child: Padding(
        padding: EdgeInsets.all(density.space6),
        child: child,
      ),
    );
  }
}
