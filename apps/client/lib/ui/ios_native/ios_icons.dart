import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ios_tokens.dart';

/// iOS Phone 模式统一图标表：只用 Material `*_rounded` 字形 + CustomPaint，
/// 严禁 Cupertino 图标字体（工程未打包时真机显示方块）。
abstract final class IosIcons {
  static const hosts = Icons.dns_rounded;
  static const snippets = Icons.code_rounded;
  static const forwarding = Icons.swap_horiz_rounded;
  static const keychain = Icons.key_rounded;
  static const settings = Icons.settings_rounded;
  static const add = Icons.add_rounded;
  static const more = Icons.more_horiz_rounded;
  static const search = Icons.search_rounded;
  static const clear = Icons.cancel_rounded;
  static const info = Icons.info_outline_rounded;
  static const folder = Icons.folder_rounded;
  static const terminal = Icons.terminal_rounded;
  static const edit = Icons.edit_rounded;
  static const delete = Icons.delete_rounded;
  static const sftp = Icons.folder_open_rounded;
  static const connect = Icons.play_arrow_rounded;
  static const lock = Icons.lock_rounded;
  static const copy = Icons.content_copy_rounded;
  static const check = Icons.check_rounded;
  static const success = Icons.check_circle_rounded;
  static const warning = Icons.error_rounded;
  static const bolt = Icons.bolt_rounded;
  static const verified = Icons.verified_user_rounded;
  static const close = Icons.close_rounded;
}

/// chevron 方向。
enum IosChevronDirection { right, left, up, down }

/// iOS 细线 chevron（`› ‹ ⌃ ⌄`），圆头圆角折线。
class IosChevron extends StatelessWidget {
  const IosChevron({
    super.key,
    this.direction = IosChevronDirection.right,
    this.size = 12,
    this.color,
    this.strokeWidth = 2,
  });

  /// chevron 的长边（右/左为高度，上/下为宽度）。
  final double size;
  final IosChevronDirection direction;
  final Color? color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final horizontal = direction == IosChevronDirection.right ||
        direction == IosChevronDirection.left;
    final long = size;
    final short = size * 0.58;
    return ExcludeSemantics(
      child: CustomPaint(
        size: horizontal ? Size(short, long) : Size(long, short),
        painter: _ChevronPainter(
          direction: direction,
          color: color ?? IosColors.of(context).tertiaryLabel,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _ChevronPainter extends CustomPainter {
  const _ChevronPainter({
    required this.direction,
    required this.color,
    required this.strokeWidth,
  });

  final IosChevronDirection direction;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2;
    final w = size.width - inset * 2;
    final h = size.height - inset * 2;
    final path = Path();
    switch (direction) {
      case IosChevronDirection.right:
        path
          ..moveTo(inset, inset)
          ..lineTo(inset + w, inset + h / 2)
          ..lineTo(inset, inset + h);
      case IosChevronDirection.left:
        path
          ..moveTo(inset + w, inset)
          ..lineTo(inset, inset + h / 2)
          ..lineTo(inset + w, inset + h);
      case IosChevronDirection.down:
        path
          ..moveTo(inset, inset)
          ..lineTo(inset + w / 2, inset + h)
          ..lineTo(inset + w, inset);
      case IosChevronDirection.up:
        path
          ..moveTo(inset, inset + h)
          ..lineTo(inset + w / 2, inset)
          ..lineTo(inset + w, inset + h);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ChevronPainter old) =>
      old.direction != direction ||
      old.color != color ||
      old.strokeWidth != strokeWidth;
}

/// 导航栏返回 chevron（高 17pt、线宽 2.4）。
class IosBackChevron extends StatelessWidget {
  const IosBackChevron({super.key, this.color, this.size = 17});

  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => IosChevron(
    direction: IosChevronDirection.left,
    size: size,
    strokeWidth: 2.4,
    color: color ?? IosColors.of(context).tint,
  );
}

/// 上下双箭头（Picker 行右侧的 `⌃⌄`）。
class IosUpDownChevron extends StatelessWidget {
  const IosUpDownChevron({super.key, this.color, this.size = 9});

  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = color ?? IosColors.of(context).tertiaryLabel;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IosChevron(
          direction: IosChevronDirection.up,
          size: size,
          strokeWidth: 1.8,
          color: c,
        ),
        SizedBox(height: size * 0.22),
        IosChevron(
          direction: IosChevronDirection.down,
          size: size,
          strokeWidth: 1.8,
          color: c,
        ),
      ],
    );
  }
}

/// iOS 勾选标记（列表单选）。
class IosCheckmark extends StatelessWidget {
  const IosCheckmark({super.key, this.color, this.size = 14});

  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size(size, size * 0.8),
      painter: _CheckPainter(color ?? IosColors.of(context).tint),
    ),
  );
}

class _CheckPainter extends CustomPainter {
  const _CheckPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = math.max(2.0, size.width * 0.16);
    final path = Path()
      ..moveTo(stroke / 2, size.height * 0.55)
      ..lineTo(size.width * 0.38, size.height - stroke / 2)
      ..lineTo(size.width - stroke / 2, stroke / 2);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.color != color;
}

/// 在线 / 连接中 / 断开 状态圆点；[pulsing] 为连接中呼吸动画（1.2s）。
class IosStatusDot extends StatefulWidget {
  const IosStatusDot({
    super.key,
    required this.color,
    this.size = 8,
    this.pulsing = false,
  });

  final Color color;
  final double size;
  final bool pulsing;

  @override
  State<IosStatusDot> createState() => _IosStatusDotState();
}

class _IosStatusDotState extends State<IosStatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _controller.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(IosStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulsing && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulsing && _controller.isAnimating) {
      _controller
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dot = SizedBox.square(
      dimension: widget.size,
      child: DecoratedBox(
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
    if (!widget.pulsing) return dot;
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.35).animate(_controller),
      child: dot,
    );
  }
}

/// 设置式圆角彩色图标块（默认 29pt、7pt 连续曲率、白色 17pt 字形）。
class IosIconTile extends StatelessWidget {
  const IosIconTile({
    super.key,
    this.icon,
    required this.color,
    this.size = IosMetrics.iconTile,
    this.radius,
    this.glyphColor = Colors.white,
    this.glyphSize,
    this.child,
  });

  final IconData? icon;
  final Color color;
  final double size;
  final double? radius;
  final Color glyphColor;
  final double? glyphSize;

  /// 自定义内容（例如主机 OS 图标）；提供时忽略 [icon]。
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final r = radius ?? size * (IosMetrics.iconTileRadius / IosMetrics.iconTile);
    return SizedBox.square(
      dimension: size,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: color,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(r),
          ),
        ),
        child: Center(
          child:
              child ??
              Icon(icon, size: glyphSize ?? size * 0.6, color: glyphColor),
        ),
      ),
    );
  }
}
