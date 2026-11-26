import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'ios_glass.dart';
import 'ios_icons.dart';
import 'ios_tab_scaffold.dart' show IosChromeInsets;
import 'ios_tokens.dart';

/// 合规的 iOS 胶囊灰槽搜索框：显式传入 Material 图标，规避 SDK 默认图标字体。
class IosSearchField extends StatelessWidget {
  const IosSearchField({
    super.key,
    this.controller,
    this.placeholder,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.autofocus = false,
    this.fieldKey,
    this.keyboardType = TextInputType.text,
    this.onSuffixTap,
  });

  final TextEditingController? controller;
  final String? placeholder;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final bool autofocus;

  /// 落在内部 `CupertinoSearchTextField` 上的 key（测试 finder 用）。
  final Key? fieldKey;
  final TextInputType keyboardType;
  final VoidCallback? onSuffixTap;

  @override
  Widget build(BuildContext context) => buildIosSearchTextField(
    context,
    key: fieldKey,
    controller: controller,
    placeholder: placeholder,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    focusNode: focusNode,
    autofocus: autofocus,
    keyboardType: keyboardType,
    onSuffixTap: onSuffixTap,
  );
}

/// 直接返回 `CupertinoSearchTextField`（供 `CupertinoSliverNavigationBar.search` 使用）。
CupertinoSearchTextField buildIosSearchTextField(
  BuildContext context, {
  Key? key,
  TextEditingController? controller,
  String? placeholder,
  ValueChanged<String>? onChanged,
  ValueChanged<String>? onSubmitted,
  FocusNode? focusNode,
  bool autofocus = false,
  TextInputType keyboardType = TextInputType.text,
  VoidCallback? onSuffixTap,
}) {
  final c = IosColors.of(context);
  return CupertinoSearchTextField(
    key: key,
    controller: controller,
    placeholder: placeholder,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    focusNode: focusNode,
    autofocus: autofocus,
    keyboardType: keyboardType,
    autocorrect: false,
    style: IosType.body.copyWith(color: c.label),
    placeholderStyle: IosType.body.copyWith(color: c.secondaryLabel),
    backgroundColor: c.fill,
    borderRadius: BorderRadius.circular(IosMetrics.searchHeight / 2),
    itemColor: c.secondaryLabel,
    prefixIcon: const Icon(IosIcons.search),
    suffixIcon: const Icon(IosIcons.clear),
    onSuffixTap: onSuffixTap == null
        ? null
        : () {
            controller?.clear();
            onChanged?.call('');
            onSuffixTap();
          },
    cursorColor: c.tint,
  );
}

/// iOS 26 导航栏玻璃圆钮（44pt，图标 20pt、label 色）。
class IosBarButton extends StatelessWidget {
  const IosBarButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.semanticLabel,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? semanticLabel;
  final Color? color;

  @override
  Widget build(BuildContext context) => IosGlassCircle(
    onPressed: onPressed,
    semanticLabel: semanticLabel,
    child: Icon(
      icon,
      size: 21,
      color: color ?? IosColors.of(context).label,
    ),
  );
}

/// 一个导航栏按钮组内的条目。
@immutable
class IosBarButtonItem {
  const IosBarButtonItem({
    required this.icon,
    required this.onPressed,
    this.semanticLabel,
    this.key,
    this.color,
    this.badge,
  });

  final IconData icon;

  /// 带锚点矩形的回调（用于弹出下拉菜单）；不需要时忽略参数。
  final void Function(Rect anchor)? onPressed;
  final String? semanticLabel;
  final Key? key;
  final Color? color;

  /// 叠加在图标外的小部件（如进度环）。
  final Widget? badge;
}

/// 多个导航栏按钮合并成一颗玻璃胶囊（高 44，每格 44 宽）。
class IosBarButtonGroup extends StatelessWidget {
  const IosBarButtonGroup({super.key, required this.items});

  final List<IosBarButtonItem> items;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    return SizedBox(
      height: IosMetrics.glassButton,
      child: IosGlassSurface(
        shadow: false,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in items)
              Builder(
                builder: (itemContext) => Semantics(
                  button: true,
                  enabled: item.onPressed != null,
                  label: item.semanticLabel,
                  child: IosGlassTapScale(
                    key: item.key,
                    onTap: item.onPressed == null
                        ? null
                        : () => item.onPressed!(iosWidgetRect(itemContext)),
                    child: SizedBox(
                      width: IosMetrics.glassButton,
                      height: IosMetrics.glassButton,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Icon(item.icon, size: 21, color: item.color ?? c.label),
                          ?item.badge,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 计算 widget 在全局坐标中的矩形（锚定下拉菜单）。
Rect iosWidgetRect(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Rect.zero;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// 自绘返回键：细 chevron + 上一页标题（17pt tint），44pt 热区。
class IosBackButton extends StatelessWidget {
  const IosBackButton({super.key, this.label, this.onPressed});

  final String? label;

  /// 默认 `Navigator.maybePop`。
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    return Semantics(
      button: true,
      label: label ?? MaterialLocalizations.of(context).backButtonTooltip,
      excludeSemantics: true,
      child: IosGlassTapScale(
        pressedScale: 1,
        onTap: onPressed ?? () => Navigator.maybePop(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 2),
              IosBackChevron(color: c.tint),
              if (label != null) ...[
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(
                    label!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: IosType.body.copyWith(color: c.tint),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 大标题页骨架：`CupertinoSliverNavigationBar`（34pt→17pt 折叠、滚动后毛玻璃）
/// + 可选搜索槽 + 下拉刷新 + 自动底部留白（读取 MediaQuery 与 [IosChromeInsets]）。
///
/// 返回键一律自绘：传 [backLabel] 或 [showBackButton] 即显示 [IosBackButton]。
class IosLargeTitlePage extends StatelessWidget {
  const IosLargeTitlePage({
    super.key,
    required this.title,
    required this.slivers,
    this.trailing,
    this.leading,
    this.searchField,
    this.onRefresh,
    this.showBackButton = false,
    this.backLabel,
    this.onBack,
    this.scrollController,
    this.largeTitle = true,
    this.heroTag,
    this.transitionBetweenRoutes = true,
  });

  final String title;
  final List<Widget> slivers;

  /// 右上角（通常是 [IosBarButtonGroup] 或 [IosBarButton]）。
  final Widget? trailing;
  final Widget? leading;

  /// 搜索槽（用 [buildIosSearchTextField] 构建）；提供时使用 `.search` 导航栏。
  final Widget? searchField;
  final Future<void> Function()? onRefresh;
  final bool showBackButton;
  final String? backLabel;
  final VoidCallback? onBack;
  final ScrollController? scrollController;

  /// false 时为普通 44pt 居中标题页（二级详情页）。
  final bool largeTitle;
  final Object? heroTag;
  final bool transitionBetweenRoutes;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final media = MediaQuery.of(context);
    final compact = media.size.height < 500;
    final effectiveLeading =
        leading ??
        (showBackButton || backLabel != null
            ? IosBackButton(label: backLabel, onPressed: onBack)
            : null);
    // No hairline under the bar (the Cupertino default): content scrolling
    // under the frosted bar is told apart by the blur alone, as in iOS 26.
    const Border? border = null;
    final titleText = Text(title);
    final bottom = iosScrollBottomPadding(context);

    // 二级详情页（largeTitle: false）或横屏紧凑高度：使用固定 44pt CupertinoNavigationBar，
    // 内容从毛玻璃顶栏下方折射滚过，并规避 CupertinoSliverNavigationBar 对 largeTitle 非空的断言。
    if (!largeTitle || compact) {
      final topObstruction =
          media.padding.top + kMinInteractiveDimensionCupertino;
      // 注意：Flutter SDK 的 CupertinoNavigationBar 存在断言
      // `!transitionBetweenRoutes || identical(heroTag, _defaultHeroTag)`，
      // 因此开启路由过渡时不覆写 heroTag（SDK 默认按当前 Navigator 作用域自动匹配）。
      final staticBar = (heroTag != null && !transitionBetweenRoutes)
          ? CupertinoNavigationBar(
              automaticallyImplyLeading: false,
              automaticallyImplyMiddle: false,
              middle: titleText,
              leading: effectiveLeading,
              trailing: trailing,
              backgroundColor: c.barFill,
              border: border,
              heroTag: heroTag!,
              transitionBetweenRoutes: false,
              padding: const EdgeInsetsDirectional.only(start: 8, end: 12),
            )
          : CupertinoNavigationBar(
              automaticallyImplyLeading: false,
              automaticallyImplyMiddle: false,
              middle: titleText,
              leading: effectiveLeading,
              trailing: trailing,
              backgroundColor: c.barFill,
              border: border,
              transitionBetweenRoutes: transitionBetweenRoutes,
              padding: const EdgeInsetsDirectional.only(start: 8, end: 12),
            );
      return IosGroupedPageBackground(
        child: ScrollNotificationObserver(
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomScrollView(
                controller: scrollController,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                slivers: [
                  SliverToBoxAdapter(child: SizedBox(height: topObstruction)),
                  if (onRefresh != null)
                    CupertinoSliverRefreshControl(onRefresh: onRefresh),
                  if (searchField != null)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        media.padding.left + IosMetrics.sectionMargin,
                        10,
                        media.padding.right + IosMetrics.sectionMargin,
                        0,
                      ),
                      sliver: SliverToBoxAdapter(child: searchField),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                  for (final sliver in slivers)
                    SliverSafeArea(top: false, bottom: false, sliver: sliver),
                  SliverToBoxAdapter(child: SizedBox(height: bottom)),
                ],
              ),
              Positioned(top: 0, left: 0, right: 0, child: staticBar),
            ],
          ),
        ),
      );
    }

    final Widget navBar;
    if (searchField != null) {
      navBar = heroTag == null
          ? CupertinoSliverNavigationBar.search(
              automaticallyImplyLeading: false,
              automaticallyImplyTitle: false,
              searchField: searchField!,
              largeTitle: titleText,
              alwaysShowMiddle: false,
              leading: effectiveLeading,
              trailing: trailing,
              backgroundColor: c.barFill,
              border: border,
              transitionBetweenRoutes: transitionBetweenRoutes,
              padding: const EdgeInsetsDirectional.only(start: 8, end: 12),
            )
          : CupertinoSliverNavigationBar.search(
              automaticallyImplyLeading: false,
              automaticallyImplyTitle: false,
              searchField: searchField!,
              largeTitle: titleText,
              alwaysShowMiddle: false,
              leading: effectiveLeading,
              trailing: trailing,
              backgroundColor: c.barFill,
              border: border,
              heroTag: heroTag!,
              transitionBetweenRoutes: transitionBetweenRoutes,
              padding: const EdgeInsetsDirectional.only(start: 8, end: 12),
            );
    } else {
      navBar = heroTag == null
          ? CupertinoSliverNavigationBar(
              automaticallyImplyLeading: false,
              automaticallyImplyTitle: false,
              largeTitle: titleText,
              alwaysShowMiddle: false,
              leading: effectiveLeading,
              trailing: trailing,
              backgroundColor: c.barFill,
              border: border,
              transitionBetweenRoutes: transitionBetweenRoutes,
              padding: const EdgeInsetsDirectional.only(start: 8, end: 12),
            )
          : CupertinoSliverNavigationBar(
              automaticallyImplyLeading: false,
              automaticallyImplyTitle: false,
              largeTitle: titleText,
              alwaysShowMiddle: false,
              leading: effectiveLeading,
              trailing: trailing,
              backgroundColor: c.barFill,
              border: border,
              heroTag: heroTag!,
              transitionBetweenRoutes: transitionBetweenRoutes,
              padding: const EdgeInsetsDirectional.only(start: 8, end: 12),
            );
    }
    return IosGroupedPageBackground(
      child: ScrollNotificationObserver(
        child: CustomScrollView(
          controller: scrollController,
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          slivers: [
            navBar,
            if (onRefresh != null)
              CupertinoSliverRefreshControl(onRefresh: onRefresh),
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
            for (final sliver in slivers)
              SliverSafeArea(top: false, bottom: false, sliver: sliver),
            SliverToBoxAdapter(child: SizedBox(height: bottom)),
          ],
        ),
      ),
    );
  }
}

/// 页面末尾统一留白：`paddingOf.bottom + accessory + 16`（键盘升起时取 viewInsets）。
double iosScrollBottomPadding(BuildContext context) {
  final media = MediaQuery.of(context);
  final chrome = IosChromeInsets.of(context);
  final keyboard = media.viewInsets.bottom;
  if (keyboard > 0) return keyboard + 16;
  return media.padding.bottom + chrome.accessory + 16;
}

/// 页面底色（`groupedBackground`），同时把 Material 默认文字样式切到 iOS body。
class IosGroupedPageBackground extends StatelessWidget {
  const IosGroupedPageBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    return Material(
      type: MaterialType.canvas,
      color: c.groupedBackground,
      child: DefaultTextStyle.merge(
        style: IosType.body.copyWith(color: c.label),
        child: child,
      ),
    );
  }
}
