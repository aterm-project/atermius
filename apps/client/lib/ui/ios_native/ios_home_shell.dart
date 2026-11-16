import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../home_sidebar.dart' show HomeDestination, homeDestinationLabel;
import 'ios_icons.dart';
import 'ios_tab_scaffold.dart';

/// iPhone 一级导航壳（蓝图 §3 / 视觉附录 §1.1–§1.3）：
///
/// - 默认承载 5 个一级 Tab：**主机 / 片段 / 转发 / 钥匙串 / 设置**。
/// - 封装 [IosTabScaffold]（悬浮胶囊玻璃 TabBar + 每 Tab 独立 Navigator + 底部占位下发）。
/// - 统一包裹 `TooltipVisibility(visible: false)`，抑制长按黑框 Tooltip。
/// - 支持底部 [accessory]（`IosLiveSessionPill`）弹簧入场。
class IosHomeShell extends StatefulWidget {
  const IosHomeShell({
    super.key,
    this.destinations = defaultDestinations,
    required this.selected,
    required this.onSelect,
    required this.tabBuilder,
    this.accessory,
    this.badges = const {},
  });

  static const List<HomeDestination> defaultDestinations = <HomeDestination>[
    HomeDestination.hosts,
    HomeDestination.snippets,
    HomeDestination.forwarding,
    HomeDestination.keychain,
    HomeDestination.settings,
  ];

  final List<HomeDestination> destinations;
  final HomeDestination selected;
  final ValueChanged<HomeDestination> onSelect;
  final Widget Function(BuildContext context, HomeDestination destination)
  tabBuilder;

  /// 底部 TabBar 上方 8pt 的实时会话胶囊（无活跃会话时传 `null`）。
  final Widget? accessory;
  final Map<HomeDestination, int> badges;

  @override
  State<IosHomeShell> createState() => IosHomeShellState();
}

class IosHomeShellState extends State<IosHomeShell> {
  final GlobalKey<IosTabScaffoldState> _scaffoldKey =
      GlobalKey<IosTabScaffoldState>();

  /// 访问指定目的地对应的嵌套 Navigator。
  NavigatorState? navigatorFor(HomeDestination destination) {
    final index = widget.destinations.indexOf(destination);
    if (index < 0) return null;
    return _scaffoldKey.currentState?.navigatorOf(index);
  }

  int _resolveIndex() {
    final direct = widget.destinations.indexOf(widget.selected);
    if (direct >= 0) return direct;
    // 分组已合并入主机 Tab，会话日志已迁入设置 Tab；若旧默认工作区落在其上则平滑映射。
    if (widget.selected == HomeDestination.groups) {
      final hostsIdx = widget.destinations.indexOf(HomeDestination.hosts);
      if (hostsIdx >= 0) return hostsIdx;
    }
    if (widget.selected == HomeDestination.logs) {
      final settingsIdx = widget.destinations.indexOf(HomeDestination.settings);
      if (settingsIdx >= 0) return settingsIdx;
    }
    return 0;
  }

  static IconData _iconFor(HomeDestination destination) => switch (destination) {
    HomeDestination.hosts => IosIcons.hosts,
    HomeDestination.groups => IosIcons.folder,
    HomeDestination.logs => Icons.receipt_long_rounded,
    HomeDestination.forwarding => IosIcons.forwarding,
    HomeDestination.snippets => IosIcons.snippets,
    HomeDestination.keychain => IosIcons.keychain,
    HomeDestination.settings => IosIcons.settings,
  };

  static String _shortLabelFor(BuildContext context, HomeDestination dest) {
    final lang = Localizations.localeOf(context).languageCode;
    final l10n = context.l10n;
    return switch (dest) {
      HomeDestination.hosts => l10n.hosts,
      HomeDestination.snippets => switch (lang) {
        'zh' => '片段',
        'en' => 'Snippets',
        _ => l10n.snippets,
      },
      HomeDestination.forwarding => switch (lang) {
        'zh' => '转发',
        'en' => 'Forwards',
        _ => l10n.r7NavPortForwarding,
      },
      HomeDestination.keychain => l10n.r7NavKeychain,
      HomeDestination.settings => l10n.settings,
      _ => homeDestinationLabel(l10n, dest),
    };
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = _resolveIndex();
    final items = [
      for (final dest in widget.destinations)
        IosTabItem(
          id: dest.name,
          icon: _iconFor(dest),
          label: _shortLabelFor(context, dest),
          badge: widget.badges[dest] ?? 0,
        ),
    ];

    return TooltipVisibility(
      visible: false,
      child: IosTabScaffold(
        key: _scaffoldKey,
        items: items,
        currentIndex: currentIndex,
        onTabSelected: (index) {
          if (index >= 0 && index < widget.destinations.length) {
            widget.onSelect(widget.destinations[index]);
          }
        },
        accessory: widget.accessory == null
            ? null
            : _AccessoryEntrance(child: widget.accessory!),
        tabBuilder: (tabContext, index) =>
            widget.tabBuilder(tabContext, widget.destinations[index]),
      ),
    );
  }
}

class _AccessoryEntrance extends StatelessWidget {
  const _AccessoryEntrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: const Duration(milliseconds: 380),
    curve: const Cubic(0.18, 1.0, 0.3, 1.08),
    builder: (context, value, content) => Transform.translate(
      offset: Offset(0, (1 - value) * 16),
      child: Opacity(opacity: value.clamp(0.0, 1.0), child: content),
    ),
    child: child,
  );
}
