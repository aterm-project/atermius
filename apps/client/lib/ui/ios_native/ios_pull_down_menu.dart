import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../workspace_controls.dart' show WorkspaceAction;
import 'ios_glass.dart';
import 'ios_large_title_page.dart' show iosWidgetRect;
import 'ios_tokens.dart';

/// 下拉菜单项“无图标”占位（例如单选菜单中未选中的项）；仅作比较，从不渲染。
const IconData kIosMenuNoIcon = IconData(0xF0000, fontFamily: 'IosMenuNoIcon');

/// iOS 14+ 下拉菜单（玻璃面板 14pt、行高 44、文字左 17pt + 图标右 20pt、
/// 分组间 8pt 粗分隔、destructive 红色），从锚点 scale(0.8→1)+fade 弹出。
///
/// 复用现有 `WorkspaceAction` 数据结构；禁用项置灰不可点。
Future<void> showIosPullDownMenu(
  BuildContext context, {
  required Rect anchor,
  required List<List<WorkspaceAction>> sections,
}) async {
  final visible = [
    for (final section in sections)
      if (section.isNotEmpty) section,
  ];
  if (visible.isEmpty) return;
  HapticFeedback.selectionClick().catchError((Object _) {});
  final selected = await Navigator.of(context, rootNavigator: true).push(
    _PullDownRoute(
      anchor: anchor,
      sections: visible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: Navigator.of(context, rootNavigator: true).context,
      ),
    ),
  );
  if (selected != null && selected.enabled) {
    unawaited(Future<void>.sync(selected.run));
  }
}

/// 包装任意子组件为“点按弹出下拉菜单”的按钮。
class IosPullDownButton extends StatelessWidget {
  const IosPullDownButton({
    super.key,
    required this.sections,
    required this.child,
    this.semanticLabel,
  });

  /// 惰性构建（每次打开时取最新数据）。
  final List<List<WorkspaceAction>> Function() sections;
  final Widget child;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semanticLabel,
    child: IosGlassTapScale(
      onTap: () => showIosPullDownMenu(
        context,
        anchor: iosWidgetRect(context),
        sections: sections(),
      ),
      child: child,
    ),
  );
}

class _PullDownRoute extends PopupRoute<WorkspaceAction> {
  _PullDownRoute({
    required this.anchor,
    required this.sections,
    required this.barrierLabel,
    required this.capturedThemes,
  });

  final Rect anchor;
  final List<List<WorkspaceAction>> sections;
  final CapturedThemes capturedThemes;

  @override
  final String? barrierLabel;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.08);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => capturedThemes.wrap(
    _PullDownLayout(anchor: anchor, sections: sections, animation: animation),
  );
}

class _PullDownLayout extends StatelessWidget {
  const _PullDownLayout({
    required this.anchor,
    required this.sections,
    required this.animation,
  });

  final Rect anchor;
  final List<List<WorkspaceAction>> sections;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    const width = IosMetrics.menuWidth;
    final alignRight = anchor.center.dx > screen.width / 2;
    final left = alignRight
        ? (anchor.right - width).clamp(12.0, screen.width - width - 12)
        : anchor.left.clamp(12.0, screen.width - width - 12);
    final spaceBelow = screen.height - anchor.bottom - media.padding.bottom - 12;
    final spaceAbove = anchor.top - media.padding.top - 12;
    final below = spaceBelow >= 220 || spaceBelow >= spaceAbove;
    final maxHeight = (below ? spaceBelow : spaceAbove).clamp(120.0, 560.0);
    final curved = CurvedAnimation(
      parent: animation,
      curve: const Cubic(0.2, 0.9, 0.3, 1.08),
      reverseCurve: Curves.easeIn,
    );
    final origin = Alignment(
      alignRight ? 1 : -1,
      below ? -1 : 1,
    );
    return Stack(
      children: [
        Positioned(
          left: left,
          width: width,
          top: below ? anchor.bottom + 8 : null,
          bottom: below ? null : screen.height - anchor.top + 8,
          child: FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.8, end: 1).animate(curved),
              alignment: origin,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxHeight),
                child: IosGlassPanel(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.zero,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var s = 0; s < sections.length; s++) ...[
                          if (s > 0)
                            SizedBox(
                              height: 8,
                              child: ColoredBox(
                                color: IosColors.of(context).menuSectionGap,
                              ),
                            ),
                          for (var i = 0; i < sections[s].length; i++) ...[
                            if (i > 0)
                              SizedBox(
                                height: IosMetrics.hairline(context),
                                child: ColoredBox(
                                  color: IosColors.of(
                                    context,
                                  ).separator.withValues(alpha: 0.6),
                                ),
                              ),
                            _PullDownItem(action: sections[s][i]),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PullDownItem extends StatefulWidget {
  const _PullDownItem({required this.action});

  final WorkspaceAction action;

  @override
  State<_PullDownItem> createState() => _PullDownItemState();
}

class _PullDownItemState extends State<_PullDownItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final action = widget.action;
    final color = !action.enabled
        ? c.tertiaryLabel
        : action.destructive
        ? c.destructive
        : c.label;
    return Semantics(
      button: true,
      enabled: action.enabled,
      label: action.label,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey('ios_menu_${action.id}'),
        behavior: HitTestBehavior.opaque,
        onTapDown: action.enabled ? (_) => setState(() => _pressed = true) : null,
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: action.enabled
            ? () {
                HapticFeedback.selectionClick().catchError((Object _) {});
                Navigator.of(context).pop(action);
              }
            : null,
        child: ColoredBox(
          color: _pressed
              ? c.label.withValues(alpha: c.isDark ? 0.12 : 0.08)
              : Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: IosMetrics.menuRowHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      action.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: IosType.body.copyWith(color: color),
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (action.icon == kIosMenuNoIcon)
                    const SizedBox(width: 20)
                  else
                    Icon(action.icon, size: 20, color: color),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
