import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'ios_glass.dart';
import 'ios_mode.dart';
import 'ios_tokens.dart';

/// Shell 下发的底部浮层占位：`tabBar` 为玻璃 TabBar 占用的总高度（含悬浮底距），
/// `accessory` 为 Live Session Pill 占用（高度 + 8pt 间距，无 Pill 时为 0）。
///
/// 页面末尾统一 `SliverPadding(bottom: paddingOf.bottom + accessory + 16)`，
/// 其中 `paddingOf.bottom` 已被 shell 覆写为 `tabBar`。
class IosChromeInsets extends InheritedWidget {
  const IosChromeInsets({
    super.key,
    required this.tabBar,
    required this.accessory,
    required super.child,
  });

  final double tabBar;
  final double accessory;

  static const _zero = _IosChromeInsetsValue(0, 0);

  /// 没有 shell 时返回全 0。
  static ({double tabBar, double accessory}) of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<IosChromeInsets>();
    if (w == null) return (tabBar: _zero.tabBar, accessory: _zero.accessory);
    return (tabBar: w.tabBar, accessory: w.accessory);
  }

  @override
  bool updateShouldNotify(IosChromeInsets oldWidget) =>
      tabBar != oldWidget.tabBar || accessory != oldWidget.accessory;
}

class _IosChromeInsetsValue {
  const _IosChromeInsetsValue(this.tabBar, this.accessory);

  final double tabBar;
  final double accessory;
}

/// TabBar 条目。
@immutable
class IosTabItem {
  const IosTabItem({
    required this.id,
    required this.icon,
    required this.label,
    this.badge = 0,
  });

  /// 稳定 id，生成 `ValueKey('ios_tab_$id')`。
  final String id;
  final IconData icon;
  final String label;
  final int badge;
}

/// iOS 26/27 Liquid Glass 悬浮胶囊 TabBar（视觉附录 §1.2）。
class IosGlassTabBar extends StatelessWidget {
  const IosGlassTabBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  final List<IosTabItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final compact = isIosCompactHeight(context);
    final height = compact
        ? IosMetrics.tabBarHeightCompact
        : IosMetrics.tabBarHeight;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: SizedBox(
        key: const ValueKey('ios_glass_tab_bar'),
        height: height,
        child: IosGlassCapsule(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final itemWidth = constraints.maxWidth / items.length;
              return Stack(
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 360),
                    curve: const Cubic(0.2, 0.9, 0.25, 1.05),
                    left: itemWidth * currentIndex + 4,
                    top: 4,
                    bottom: 4,
                    width: itemWidth - 8,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: const StadiumBorder(),
                        color: Color.alphaBlend(
                          Colors.white.withValues(alpha: c.isDark ? 0.06 : 0.25),
                          c.tint.withValues(alpha: 0.16),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < items.length; i++)
                        Expanded(
                          child: _TabBarItem(
                            item: items[i],
                            selected: i == currentIndex,
                            compact: compact,
                            onTap: () {
                              HapticFeedback.selectionClick().catchError(
                                (Object _) {},
                              );
                              onTap(i);
                            },
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TabBarItem extends StatelessWidget {
  const _TabBarItem({
    required this.item,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final IosTabItem item;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final color = selected ? c.tint : c.label;
    final icon = Icon(item.icon, size: compact ? 22 : 24, color: color);
    final iconWithBadge = item.badge <= 0
        ? icon
        : Stack(
            clipBehavior: Clip.none,
            children: [
              icon,
              PositionedDirectional(
                top: -4,
                end: -10,
                child: IosCountBadge(count: item.badge),
              ),
            ],
          );
    final label = Text(
      item.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: IosType.caption2.copyWith(color: color),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey('ios_tab_${item.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: compact
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [iconWithBadge, const SizedBox(width: 6), label],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [iconWithBadge, const SizedBox(height: 2), label],
                ),
        ),
      ),
    );
  }
}

/// iOS 红色计数胶囊（13pt w600 白字，最小 18×18）。
class IosCountBadge extends StatelessWidget {
  const IosCountBadge({super.key, required this.count, this.color});

  final int count;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
    padding: const EdgeInsets.symmetric(horizontal: 5),
    alignment: Alignment.center,
    decoration: ShapeDecoration(
      shape: const StadiumBorder(),
      color: color ?? IosColors.of(context).red,
    ),
    child: Text(
      count > 99 ? '99+' : '$count',
      style: IosType.footnote.copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w600,
        height: 1.1,
      ),
    ),
  );
}

/// 每个 Tab 根页面构建器。
typedef IosTabBuilder = Widget Function(BuildContext context, int index);

/// 悬浮玻璃 TabBar + 每 Tab 独立 Navigator（保留各自导航栈）+ 底部浮层占位下发。
///
/// - Tab 根页面每次 shell 重建都会重新执行 [tabBuilder]（不会闭包过期）；
///   被 push 的页面必须通过 InheritedWidget（如 `IosWorkspaceScope`）读数据。
/// - 再次点按当前 Tab：弹回该 Tab 根页面。
/// - 键盘升起时 TabBar 与 [accessory] 淡出隐藏，不随键盘上浮。
class IosTabScaffold extends StatefulWidget {
  const IosTabScaffold({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTabSelected,
    required this.tabBuilder,
    this.accessory,
  });

  final List<IosTabItem> items;
  final int currentIndex;
  final ValueChanged<int> onTabSelected;
  final IosTabBuilder tabBuilder;

  /// TabBar 上方 8pt 的附件（Live Session Pill）；null 时不占位。
  final Widget? accessory;

  @override
  State<IosTabScaffold> createState() => IosTabScaffoldState();
}

class IosTabScaffoldState extends State<IosTabScaffold> {
  final Map<int, GlobalKey<NavigatorState>> _navigatorKeys = {};
  final Map<int, HeroController> _heroControllers = {};
  final Set<int> _visited = {};

  /// 指定 Tab 的嵌套 Navigator（用于在该 Tab 内 push 页面）。
  NavigatorState? navigatorOf(int index) => _navigatorKeys[index]?.currentState;

  GlobalKey<NavigatorState> _keyFor(int index) =>
      _navigatorKeys.putIfAbsent(index, GlobalKey<NavigatorState>.new);

  @override
  void dispose() {
    for (final controller in _heroControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _handleTap(int index) {
    if (index == widget.currentIndex) {
      _navigatorKeys[index]?.currentState?.popUntil((route) => route.isFirst);
      return;
    }
    widget.onTabSelected(index);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final compact = isIosCompactHeight(context);
    final tabHeight = compact
        ? IosMetrics.tabBarHeightCompact
        : IosMetrics.tabBarHeight;
    final accessoryHeight = compact
        ? IosMetrics.accessoryHeightCompact
        : IosMetrics.accessoryHeight;
    final tabBottom = IosMetrics.tabBarBottom(media.padding.bottom);
    final tabTotal = tabBottom + tabHeight;
    final accessoryTotal = widget.accessory == null
        ? 0.0
        : accessoryHeight + IosMetrics.accessoryGap;
    final keyboardUp = media.viewInsets.bottom > 0;
    final current = widget.currentIndex.clamp(0, widget.items.length - 1);
    _visited.add(current);

    final content = MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(bottom: tabTotal),
        viewPadding: media.viewPadding.copyWith(
          bottom: tabTotal > media.viewPadding.bottom
              ? tabTotal
              : media.viewPadding.bottom,
        ),
      ),
      child: IosChromeInsets(
        tabBar: tabTotal,
        accessory: accessoryTotal,
        child: _IosTabBuilderScope(
          builder: widget.tabBuilder,
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (final index in _visited.toList()..sort())
                Offstage(
                  offstage: index != current,
                  child: TickerMode(
                    enabled: index == current,
                    child: ExcludeFocus(
                      excluding: index != current,
                      child: HeroControllerScope(
                        controller: _heroControllers.putIfAbsent(
                          index,
                          CupertinoApp.createCupertinoHeroController,
                        ),
                        child: Navigator(
                          key: _keyFor(index),
                          onGenerateRoute: (settings) => CupertinoPageRoute<void>(
                            settings: settings,
                            builder: (_) => _IosTabRoot(index: index),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return BackdropGroup(
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          if (widget.accessory != null)
            Positioned(
              left: media.padding.left + IosMetrics.tabBarMargin,
              right: media.padding.right + IosMetrics.tabBarMargin,
              bottom: tabTotal + IosMetrics.accessoryGap,
              height: accessoryHeight,
              child: _KeyboardHide(hidden: keyboardUp, child: widget.accessory!),
            ),
          Positioned(
            left: media.padding.left + IosMetrics.tabBarMargin,
            right: media.padding.right + IosMetrics.tabBarMargin,
            bottom: tabBottom,
            height: tabHeight,
            child: _KeyboardHide(
              hidden: keyboardUp,
              child: IosGlassTabBar(
                items: widget.items,
                currentIndex: current,
                onTap: _handleTap,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyboardHide extends StatelessWidget {
  const _KeyboardHide({required this.hidden, required this.child});

  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: hidden,
    child: AnimatedOpacity(
      opacity: hidden ? 0 : 1,
      duration: const Duration(milliseconds: 180),
      child: AnimatedSlide(
        offset: hidden ? const Offset(0, 0.4) : Offset.zero,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        child: child,
      ),
    ),
  );
}

class _IosTabBuilderScope extends InheritedWidget {
  const _IosTabBuilderScope({required this.builder, required super.child});

  final IosTabBuilder builder;

  static IosTabBuilder of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_IosTabBuilderScope>()!
      .builder;

  @override
  bool updateShouldNotify(_IosTabBuilderScope oldWidget) => true;
}

class _IosTabRoot extends StatelessWidget {
  const _IosTabRoot({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) =>
      _IosTabBuilderScope.of(context)(context, index);
}
