import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../workspace_controls.dart' show WorkspaceAction;
import 'ios_icons.dart';
import 'ios_large_title_page.dart';
import 'ios_list.dart';
import 'ios_pull_down_menu.dart';
import 'ios_tokens.dart';

/// 表单行：左标签（17pt，固定 96pt 宽）+ 右侧无边框输入（右对齐）。
///
/// 不提供标签时为全宽占位符行。严禁 clearButtonMode（默认图标字体会显示方块）。
class IosTextFieldRow extends StatelessWidget {
  const IosTextFieldRow({
    super.key,
    this.label,
    required this.controller,
    this.placeholder,
    this.fieldKey,
    this.keyboardType,
    this.obscureText = false,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.autofillHints,
    this.textInputAction,
    this.labelWidth = IosMetrics.formLabelWidth,
    this.mono = false,
    this.maxLines = 1,
    this.minLines,
    this.focusNode,
    this.inputFormatters,
    this.autofocus = false,
    this.textAlign,
    this.errorText,
  });

  final String? label;
  final TextEditingController controller;
  final String? placeholder;
  final Key? fieldKey;
  final TextInputType? keyboardType;
  final bool obscureText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final Iterable<String>? autofillHints;
  final TextInputAction? textInputAction;
  final double labelWidth;
  final bool mono;
  final int? maxLines;
  final int? minLines;
  final FocusNode? focusNode;
  final List<TextInputFormatter>? inputFormatters;
  final bool autofocus;
  final TextAlign? textAlign;

  /// 校验错误：在行下方以 footnote 红字显示。
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final multiline = (maxLines ?? 2) > 1;
    final style = (mono ? IosType.mono.copyWith(fontSize: 16) : IosType.body)
        .copyWith(color: enabled ? c.label : c.secondaryLabel);
    final field = CupertinoTextField(
      key: fieldKey,
      controller: controller,
      placeholder: placeholder,
      placeholderStyle: IosType.body.copyWith(color: c.tertiaryLabel),
      style: style,
      decoration: null,
      padding: EdgeInsets.zero,
      keyboardType: keyboardType,
      obscureText: obscureText,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      enabled: enabled,
      autofillHints: autofillHints,
      textInputAction: textInputAction,
      maxLines: obscureText ? 1 : maxLines,
      minLines: minLines,
      focusNode: focusNode,
      inputFormatters: inputFormatters,
      autofocus: autofocus,
      autocorrect: false,
      enableSuggestions: !obscureText && !mono,
      cursorColor: c.tint,
      textAlign:
          textAlign ??
          (label == null || multiline ? TextAlign.start : TextAlign.end),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: IosMetrics.rowMinHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: IosMetrics.rowPaddingH,
              vertical: 11,
            ),
            child: label == null
                ? field
                : multiline
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label!,
                        style: IosType.footnote.copyWith(
                          color: c.secondaryLabel,
                        ),
                      ),
                      const SizedBox(height: 4),
                      field,
                    ],
                  )
                : Row(
                    children: [
                      SizedBox(
                        width: labelWidth,
                        child: Text(
                          label!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: IosType.body.copyWith(color: c.label),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: field),
                    ],
                  ),
          ),
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              IosMetrics.rowPaddingH,
              0,
              IosMetrics.rowPaddingH,
              10,
            ),
            child: Text(
              errorText!,
              style: IosType.footnote.copyWith(color: c.destructive),
            ),
          ),
      ],
    );
  }
}

/// Picker 选项。
@immutable
class IosPickerOption<T> {
  const IosPickerOption({
    required this.value,
    required this.label,
    this.icon,
    this.subtitle,
  });

  final T value;
  final String label;
  final IconData? icon;
  final String? subtitle;
}

/// 枚举选择行：左标签 + 右侧当前值 + `⌃⌄`（≤ 6 项弹下拉菜单）或 `›`（> 6 项 push 勾选列表）。
class IosPickerRow<T> extends StatelessWidget {
  const IosPickerRow({
    super.key,
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
    this.rowKey,
    this.enabled = true,
    this.leading,
    this.forcePush = false,
    this.pageTitle,
    this.placeholder,
  });

  final String label;
  final List<IosPickerOption<T>> options;
  final T? value;
  final ValueChanged<T>? onChanged;

  /// 落在可点击行上的 key（沿用旧 Dropdown 的 key 便于测试）。
  final Key? rowKey;
  final bool enabled;
  final Widget? leading;

  /// 强制以 push 勾选列表页呈现。
  final bool forcePush;
  final String? pageTitle;

  /// 未选择时右侧显示的文字。
  final String? placeholder;

  bool get _usePush => forcePush || options.length > 6;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final current = options.where((o) => o.value == value).firstOrNull;
    final active = enabled && onChanged != null;
    return Builder(
      builder: (rowContext) => IosListRow(
        key: rowKey,
        leading: leading,
        title: Text(label),
        value: current?.label ?? placeholder,
        enabled: active,
        accessory: _usePush ? IosRowAccessory.chevron : IosRowAccessory.none,
        trailing: _usePush
            ? null
            : Padding(
                padding: const EdgeInsetsDirectional.only(start: 2),
                child: IosUpDownChevron(color: c.secondaryLabel),
              ),
        onTap: !active
            ? null
            : () async {
                if (_usePush) {
                  final picked = await Navigator.of(rowContext).push<T>(
                    CupertinoPageRoute<T>(
                      builder: (_) => IosSelectionPage<T>(
                        title: pageTitle ?? label,
                        options: options,
                        value: value,
                      ),
                    ),
                  );
                  if (picked != null) onChanged!(picked);
                  return;
                }
                await showIosPullDownMenu(
                  rowContext,
                  anchor: iosWidgetRect(rowContext),
                  sections: [
                    [
                      for (final option in options)
                        WorkspaceAction(
                          'picker_${option.value}',
                          option.label,
                          option.value == value
                              ? IosIcons.check
                              : (option.icon ?? kIosMenuNoIcon),
                          () => onChanged!(option.value),
                        ),
                    ],
                  ],
                );
              },
      ),
    );
  }
}

/// 单选勾选列表页（Settings 式，选中后自动返回并带回结果）。
class IosSelectionPage<T> extends StatelessWidget {
  const IosSelectionPage({
    super.key,
    required this.title,
    required this.options,
    required this.value,
    this.backLabel,
  });

  final String title;
  final List<IosPickerOption<T>> options;
  final T? value;
  final String? backLabel;

  @override
  Widget build(BuildContext context) => IosLargeTitlePage(
    title: title,
    largeTitle: false,
    showBackButton: true,
    backLabel: backLabel,
    slivers: [
      SliverToBoxAdapter(
        child: IosListSection(
          children: [
            for (final option in options)
              IosListRow(
                key: ValueKey('ios_selection_${option.value}'),
                title: Text(option.label),
                subtitle: option.subtitle == null ? null : Text(option.subtitle!),
                minHeight: option.subtitle == null ? null : 56,
                accessory: option.value == value
                    ? IosRowAccessory.checkmark
                    : IosRowAccessory.none,
                onTap: () => Navigator.of(context).pop(option.value),
              ),
          ],
        ),
      ),
    ],
  );
}

/// 开关行：标签 + `CupertinoSwitch`（tint 色）。
class IosSwitchRow extends StatelessWidget {
  const IosSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.leading,
    this.switchKey,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? subtitle;
  final Widget? leading;
  final Key? switchKey;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    return IosListRow(
      leading: leading,
      title: Text(label),
      subtitle: subtitle == null ? null : Text(subtitle!),
      minHeight: subtitle == null ? null : 56,
      trailing: CupertinoSwitch(
        key: switchKey,
        value: value,
        onChanged: onChanged,
        activeTrackColor: c.tint,
      ),
    );
  }
}

/// 分段选择行：可选标签 + `CupertinoSlidingSegmentedControl`。
class IosSegmentedRow<T extends Object> extends StatelessWidget {
  const IosSegmentedRow({
    super.key,
    this.label,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.controlKey,
  });

  final String? label;
  final Map<T, String> segments;
  final T value;
  final ValueChanged<T>? onChanged;
  final Key? controlKey;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final control = CupertinoSlidingSegmentedControl<T>(
      key: controlKey,
      groupValue: value,
      backgroundColor: c.fill,
      thumbColor: c.isDark ? const Color(0xFF636366) : Colors.white,
      onValueChanged: (next) {
        if (next != null && onChanged != null) onChanged!(next);
      },
      children: {
        for (final entry in segments.entries)
          entry.key: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Text(
              entry.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: IosType.footnote.copyWith(
                color: c.label,
                fontWeight: entry.key == value
                    ? FontWeight.w600
                    : FontWeight.w500,
              ),
            ),
          ),
      },
    );
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: IosMetrics.rowPaddingH,
        vertical: 8,
      ),
      child: label == null
          ? SizedBox(width: double.infinity, child: control)
          : Row(
              children: [
                Text(label!, style: IosType.body.copyWith(color: c.label)),
                const SizedBox(width: 12),
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: control,
                  ),
                ),
              ],
            ),
    );
  }
}
