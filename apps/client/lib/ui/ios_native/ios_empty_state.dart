import 'package:flutter/material.dart';

import 'ios_tokens.dart';

/// `ContentUnavailableView` 范式空状态：56pt 图标 → title2 22pt → 15pt 说明 → tint 文字按钮。
class IosEmptyState extends StatelessWidget {
  const IosEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.actionKey,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: c.secondaryLabel),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: IosType.title2.copyWith(color: c.label),
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: IosType.subheadline.copyWith(color: c.secondaryLabel),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              GestureDetector(
                key: actionKey,
                behavior: HitTestBehavior.opaque,
                onTap: onAction,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Text(
                    actionLabel!,
                    style: IosType.body.copyWith(color: c.tint),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 以 Sliver 形式填满剩余空间的空状态（用于 `IosLargeTitlePage.slivers`）。
class SliverIosEmptyState extends StatelessWidget {
  const SliverIosEmptyState({super.key, required this.child});

  final IosEmptyState child;

  @override
  Widget build(BuildContext context) =>
      SliverFillRemaining(hasScrollBody: false, child: child);
}
