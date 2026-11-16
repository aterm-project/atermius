import 'package:flutter/material.dart';

import 'ios_icons.dart';
import 'ios_tokens.dart';

/// 按压高亮容器：按下瞬间背景变 `cellPressed`，抬起 150ms 渐隐，无水波纹。
class IosPressable extends StatefulWidget {
  const IosPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.color,
    this.pressedColor,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 常态背景（默认透明，交给所在 section 容器）。
  final Color? color;
  final Color? pressedColor;
  final bool enabled;

  @override
  State<IosPressable> createState() => _IosPressableState();
}

class _IosPressableState extends State<IosPressable> {
  bool _pressed = false;

  void _set(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final active =
        widget.enabled && (widget.onTap != null || widget.onLongPress != null);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: active ? (_) => _set(true) : null,
      onTapUp: active ? (_) => _set(false) : null,
      onTapCancel: active ? () => _set(false) : null,
      onTap: active ? widget.onTap : null,
      onLongPress: active ? widget.onLongPress : null,
      child: AnimatedContainer(
        duration: _pressed ? Duration.zero : const Duration(milliseconds: 150),
        color: _pressed
            ? (widget.pressedColor ?? c.cellPressed)
            : (widget.color ?? Colors.transparent),
        child: widget.child,
      ),
    );
  }
}

/// Section 页眉文字（footnote 13pt、secondaryLabel、左缩进 36pt）。
class IosSectionHeader extends StatelessWidget {
  const IosSectionHeader(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(
        IosMetrics.sectionHeaderInset,
        0,
        IosMetrics.sectionHeaderInset,
        7,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: IosType.footnote.copyWith(color: c.secondaryLabel),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Files 侧栏式醒目可折叠页眉（title3 20pt + 旋转 chevron）。
class IosProminentHeader extends StatelessWidget {
  const IosProminentHeader({
    super.key,
    required this.title,
    this.collapsed = false,
    this.onToggle,
    this.trailing,
  });

  final String title;
  final bool collapsed;
  final VoidCallback? onToggle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    return Semantics(
      button: onToggle != null,
      expanded: onToggle == null ? null : !collapsed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(
            IosMetrics.sectionMargin + 4,
            6,
            IosMetrics.sectionMargin + 4,
            8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: IosType.title3.copyWith(color: c.label),
                ),
              ),
              ?trailing,
              if (onToggle != null) ...[
                const SizedBox(width: 8),
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  child: IosChevron(
                    direction: IosChevronDirection.down,
                    size: 13,
                    strokeWidth: 2.2,
                    color: c.tint,
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

/// Inset Grouped 分组容器：26pt 连续曲率圆角、发丝分割线自动插入（起点对齐文字）。
class IosListSection extends StatelessWidget {
  const IosListSection({
    super.key,
    required this.children,
    this.header,
    this.headerWidget,
    this.footer,
    this.separatorIndent = IosMetrics.rowPaddingH,
    this.margin = const EdgeInsets.fromLTRB(
      IosMetrics.sectionMargin,
      0,
      IosMetrics.sectionMargin,
      IosMetrics.sectionSpacing,
    ),
    this.backgroundColor,
  });

  final List<Widget> children;
  final String? header;

  /// 自定义页眉（例如 [IosProminentHeader]）；优先于 [header]。
  final Widget? headerWidget;
  final String? footer;

  /// 分割线左缩进；行带 29pt 图标块时用 `IosMetrics.textInsetFor(29)`。
  final double separatorIndent;
  final EdgeInsets margin;
  final Color? backgroundColor;

  /// 行含图标块时的分割线缩进便捷值。
  static double indentForIcon([double iconSize = IosMetrics.iconTile]) =>
      IosMetrics.textInsetFor(iconSize);

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final hairline = IosMetrics.hairline(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) {
        rows.add(
          Padding(
            padding: EdgeInsetsDirectional.only(start: separatorIndent),
            child: SizedBox(
              height: hairline,
              child: ColoredBox(color: c.separator),
            ),
          ),
        );
      }
    }
    return Padding(
      padding: margin.copyWith(left: 0, right: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (headerWidget != null)
            headerWidget!
          else if (header != null)
            IosSectionHeader(header!),
          if (rows.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(left: margin.left, right: margin.right),
              child: ClipRSuperellipse(
                borderRadius: BorderRadius.circular(IosMetrics.groupRadius),
                child: ColoredBox(
                  color: backgroundColor ?? c.cell,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: rows,
                  ),
                ),
              ),
            ),
          if (footer != null)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                IosMetrics.sectionHeaderInset,
                7,
                IosMetrics.sectionHeaderInset,
                0,
              ),
              child: Text(
                footer!,
                style: IosType.footnote.copyWith(color: c.secondaryLabel),
              ),
            ),
        ],
      ),
    );
  }
}

/// 行尾附件。
enum IosRowAccessory {
  none,

  /// `›`：点按会 push 到下一级。
  chevron,

  /// `ⓘ`：Wi-Fi 范式详情按钮（需提供 `onInfo`）。
  info,

  /// `✓`：单选列表选中项。
  checkmark,
}

/// iOS 列表行：图标块 + 主标题(17) + 副标题(15/13 mono) + 右侧值 + 附件。
///
/// `title` / `subtitle` 传 `Text` 即可，样式由行内 DefaultTextStyle 统一提供。
class IosListRow extends StatelessWidget {
  const IosListRow({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.value,
    this.trailing,
    this.accessory = IosRowAccessory.none,
    this.onTap,
    this.onLongPress,
    this.onInfo,
    this.infoKey,
    this.infoSemanticLabel,
    this.minHeight,
    this.destructive = false,
    this.tinted = false,
    this.monoSubtitle = false,
    this.enabled = true,
    this.titleTrailing,
  });

  final Widget title;
  final Widget? leading;
  final Widget? subtitle;

  /// 右侧灰色当前值（设置行）。
  final String? value;

  /// 自定义尾部控件（如 `CupertinoSwitch`），位于 [value] 之后、附件之前。
  final Widget? trailing;
  final IosRowAccessory accessory;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onInfo;
  final Key? infoKey;
  final String? infoSemanticLabel;

  /// 默认：有副标题 60pt，否则 44pt。
  final double? minHeight;
  final bool destructive;

  /// 主标题用 tint 色（“添加分组”这类动作行）。
  final bool tinted;
  final bool monoSubtitle;
  final bool enabled;

  /// 紧跟主标题的小部件（例如在线圆点）。
  final Widget? titleTrailing;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final titleColor = destructive
        ? c.destructive
        : tinted
        ? c.tint
        : c.label;
    final height =
        minHeight ??
        (subtitle != null ? IosMetrics.hostRowHeight : IosMetrics.rowMinHeight);
    final titleWidget = DefaultTextStyle.merge(
      style: IosType.body.copyWith(color: titleColor),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      child: title,
    );
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (titleTrailing == null)
          titleWidget
        else
          Row(
            children: [
              Flexible(child: titleWidget),
              const SizedBox(width: 6),
              titleTrailing!,
            ],
          ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          DefaultTextStyle.merge(
            style: (monoSubtitle ? IosType.mono : IosType.subheadline).copyWith(
              color: c.secondaryLabel,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: subtitle!,
          ),
        ],
      ],
    );
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: height),
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          start: IosMetrics.rowPaddingH,
          end: accessory == IosRowAccessory.info ? 4 : IosMetrics.rowPaddingH,
          top: 8,
          bottom: 8,
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: IosMetrics.iconTextGap),
            ],
            Expanded(child: content),
            if (value != null) ...[
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  value!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: IosType.body.copyWith(color: c.secondaryLabel),
                ),
              ),
            ],
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            switch (accessory) {
              IosRowAccessory.none => const SizedBox.shrink(),
              IosRowAccessory.chevron => const Padding(
                padding: EdgeInsetsDirectional.only(start: 10),
                child: IosChevron(),
              ),
              IosRowAccessory.checkmark => const Padding(
                padding: EdgeInsetsDirectional.only(start: 10),
                child: IosCheckmark(),
              ),
              IosRowAccessory.info => Semantics(
                button: true,
                label: infoSemanticLabel,
                child: GestureDetector(
                  key: infoKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: enabled ? onInfo : null,
                  child: SizedBox.square(
                    dimension: 44,
                    child: Icon(IosIcons.info, size: 22, color: c.tint),
                  ),
                ),
              ),
            },
          ],
        ),
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: IosPressable(
        enabled: enabled,
        onTap: onTap,
        onLongPress: onLongPress,
        child: row,
      ),
    );
  }
}

/// tint 色动作行（例如“＋ 添加分组”）。
class IosListActionRow extends StatelessWidget {
  const IosListActionRow({
    super.key,
    required this.label,
    this.icon = Icons.add_circle_rounded,
    this.onTap,
    this.destructive = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    return IosListRow(
      title: Text(label),
      tinted: !destructive,
      destructive: destructive,
      enabled: onTap != null,
      leading: icon == null
          ? null
          : Icon(icon, size: 22, color: destructive ? c.destructive : c.tint),
      onTap: onTap,
    );
  }
}

/// iOS 页面底色容器（暗 `#000` / 亮 `#F2F2F7`）。
class IosGroupedBackground extends StatelessWidget {
  const IosGroupedBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: IosColors.of(context).groupedBackground, child: child);
}
