import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'ios_tokens.dart';

/// Sheet 顶部拖拽横条（36×5、圆角、tertiaryLabel）。
class IosSheetGrabber extends StatelessWidget {
  const IosSheetGrabber({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 4),
    child: Center(
      child: SizedBox(
        width: 36,
        height: 5,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: const StadiumBorder(),
            color: IosColors.of(context).tertiaryLabel,
          ),
        ),
      ),
    ),
  );
}

/// iOS 表单 Sheet 骨架：Grabber + 顶栏（取消 / 居中标题 / **保存**）+ 分组底色滚动体。
///
/// [isDirty] 返回 true 时，下拉或点“取消”关闭前弹出“放弃更改”确认。
class IosSheetScaffold extends StatelessWidget {
  const IosSheetScaffold({
    super.key,
    required this.title,
    required this.children,
    this.onCancel,
    this.cancelLabel,
    this.cancelKey,
    this.actionLabel,
    this.onAction,
    this.actionEnabled = true,
    this.actionKey,
    this.actionBusy = false,
    this.isDirty,
    this.discardLabel,
    this.scrollController,
  });

  final String title;

  /// 表单内容（一般为若干 `IosListSection`）。
  final List<Widget> children;
  final VoidCallback? onCancel;
  final String? cancelLabel;
  final Key? cancelKey;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool actionEnabled;
  final Key? actionKey;
  final bool actionBusy;
  final bool Function()? isDirty;

  /// “放弃更改”按钮文案；默认中英文自适应。
  final String? discardLabel;
  final ScrollController? scrollController;

  Future<void> _attemptCancel(BuildContext context) async {
    if (isDirty?.call() ?? false) {
      final discard = await showIosDestructiveConfirm(
        context,
        action: discardLabel ?? _discardText(context),
      );
      if (!discard || !context.mounted) return;
    }
    if (onCancel != null) {
      onCancel!();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final l10n = MaterialLocalizations.of(context);
    final canAct = actionEnabled && onAction != null && !actionBusy;
    return PopScope(
      canPop: !(isDirty?.call() ?? false),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _attemptCancel(context);
      },
      child: Material(
        color: c.groupedBackground,
        child: DefaultTextStyle.merge(
          style: IosType.body.copyWith(color: c.label),
          child: Column(
            children: [
              const IosSheetGrabber(),
              SizedBox(
                height: 48,
                child: NavigationToolbar(
                  middleSpacing: 8,
                  leading: _SheetTextButton(
                    key: cancelKey,
                    label: cancelLabel ?? l10n.cancelButtonLabel,
                    onTap: () => _attemptCancel(context),
                  ),
                  middle: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: IosType.headline.copyWith(color: c.label),
                  ),
                  trailing: actionLabel == null
                      ? null
                      : actionBusy
                      ? const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 20),
                          child: CupertinoActivityIndicator(),
                        )
                      : _SheetTextButton(
                          key: actionKey,
                          label: actionLabel!,
                          bold: true,
                          onTap: canAct ? onAction : null,
                        ),
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics(),
                  ),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.only(
                    top: 16,
                    bottom:
                        MediaQuery.viewInsetsOf(context).bottom +
                        MediaQuery.paddingOf(context).bottom +
                        24,
                  ),
                  children: children,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _discardText(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh' ? '放弃更改' : 'Discard Changes';

class _SheetTextButton extends StatelessWidget {
  const _SheetTextButton({
    super.key,
    required this.label,
    required this.onTap,
    this.bold = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Text(
            label,
            style: (bold ? IosType.headline : IosType.body).copyWith(
              color: onTap == null ? c.tertiaryLabel : c.tint,
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹出 iOS 全高表单 Sheet（`showCupertinoSheet`，下层页面缩放后退）。
///
/// [builder] 通常返回 [IosSheetScaffold]；在内部 `Navigator.pop(context, value)` 返回结果。
Future<T?> showIosFormSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool enableDrag = true,
}) => showCupertinoSheet<T>(
  context: context,
  enableDrag: enableDrag,
  scrollableBuilder: (sheetContext, _) => Builder(builder: builder),
);

/// 带两档 detent（默认 50% / 94%）的底部玻璃 Sheet，用于会话切换器、终端工具抽屉等。
Future<T?> showIosDetentSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, ScrollController controller)
  builder,
  List<double> detents = const [0.5, 0.94],
  double? initial,
}) {
  final sorted = [...detents]..sort();
  final start = initial ?? sorted.first;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.25),
    elevation: 0,
    builder: (sheetContext) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: start,
      minChildSize: sorted.first * 0.6,
      maxChildSize: sorted.last,
      snap: true,
      snapSizes: sorted,
      builder: (context, controller) {
        final c = IosColors.of(context);
        return ClipRSuperellipse(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          child: Material(
            color: c.groupedBackground,
            child: Column(
              children: [
                const IosSheetGrabber(),
                Expanded(child: builder(context, controller)),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// 破坏性二次确认（`CupertinoActionSheet`）：返回用户是否确认。
Future<bool> showIosDestructiveConfirm(
  BuildContext context, {
  String? title,
  String? message,
  required String action,
  String? cancel,
  Key? actionKey,
}) async {
  final result = await showCupertinoModalPopup<bool>(
    context: context,
    builder: (popupContext) => CupertinoActionSheet(
      title: title == null ? null : Text(title),
      message: message == null ? null : Text(message),
      actions: [
        CupertinoActionSheetAction(
          key: actionKey,
          isDestructiveAction: true,
          onPressed: () => Navigator.of(popupContext).pop(true),
          child: Text(action),
        ),
      ],
      cancelButton: CupertinoActionSheetAction(
        isDefaultAction: true,
        onPressed: () => Navigator.of(popupContext).pop(false),
        child: Text(cancel ?? MaterialLocalizations.of(context).cancelButtonLabel),
      ),
    ),
  );
  return result ?? false;
}

/// 简单确认弹窗（`CupertinoAlertDialog`）：返回是否确认。
Future<bool> showIosConfirmAlert(
  BuildContext context, {
  required String title,
  String? message,
  required String confirm,
  String? cancel,
  bool destructive = false,
  Key? confirmKey,
}) async {
  final result = await showCupertinoDialog<bool>(
    context: context,
    builder: (dialogContext) => CupertinoAlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        CupertinoDialogAction(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancel ?? MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        CupertinoDialogAction(
          key: confirmKey,
          isDefaultAction: !destructive,
          isDestructiveAction: destructive,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return result ?? false;
}
