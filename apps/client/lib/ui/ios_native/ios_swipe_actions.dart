import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'ios_tokens.dart';

/// 单个滑动操作按钮。
@immutable
class IosSwipeAction {
  const IosSwipeAction({
    required this.label,
    required this.color,
    required this.onTap,
    this.icon,
    this.key,
    this.destructive = false,
  });

  final String label;
  final IconData? icon;
  final Color color;
  final VoidCallback onTap;
  final Key? key;
  final bool destructive;
}

/// 同一时刻只允许一个行处于展开状态。
final ValueNotifier<Object?> _openSwipeCell = ValueNotifier<Object?>(null);

/// iOS 列表行左右滑动操作（trailing：左滑露出；leading：右滑露出）。
///
/// [fullSwipe] 为 true 时，滑过 60% 宽度直接触发最外侧（第一个）操作。
class IosSwipeActionCell extends StatefulWidget {
  const IosSwipeActionCell({
    super.key,
    required this.child,
    this.leading = const [],
    this.trailing = const [],
    this.fullSwipe = true,
    this.enabled = true,
  });

  final Widget child;
  final List<IosSwipeAction> leading;
  final List<IosSwipeAction> trailing;
  final bool fullSwipe;
  final bool enabled;

  @override
  State<IosSwipeActionCell> createState() => _IosSwipeActionCellState();
}

class _IosSwipeActionCellState extends State<IosSwipeActionCell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController.unbounded(
    vsync: this,
  );
  final Object _token = Object();
  double _width = 0;
  bool _pastThreshold = false;

  double get _leadingExtent =>
      widget.leading.length * IosMetrics.swipeActionWidth;
  double get _trailingExtent =>
      widget.trailing.length * IosMetrics.swipeActionWidth;

  @override
  void initState() {
    super.initState();
    _openSwipeCell.addListener(_onOtherOpened);
  }

  void _onOtherOpened() {
    if (_openSwipeCell.value != _token && _controller.value != 0) _animateTo(0);
  }

  @override
  void dispose() {
    _openSwipeCell.removeListener(_onOtherOpened);
    if (_openSwipeCell.value == _token) _openSwipeCell.value = null;
    _controller.dispose();
    super.dispose();
  }

  void _animateTo(double target) {
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _onDragStart(DragStartDetails _) {
    _controller.stop();
    _openSwipeCell.value = _token;
  }

  void _onDragUpdate(DragUpdateDetails details) {
    var next = _controller.value + details.delta.dx;
    final maxRight = widget.leading.isEmpty
        ? 0.0
        : (widget.fullSwipe ? _width : _leadingExtent * 1.3);
    final maxLeft = widget.trailing.isEmpty
        ? 0.0
        : (widget.fullSwipe ? _width : _trailingExtent * 1.3);
    next = next.clamp(-maxLeft, maxRight);
    _controller.value = next;
    final past = widget.fullSwipe && next.abs() > _width * 0.6;
    if (past != _pastThreshold) {
      _pastThreshold = past;
      HapticFeedback.mediumImpact().catchError((Object _) {});
    }
  }

  void _onDragEnd(DragEndDetails details) {
    final v = _controller.value;
    final velocity = details.primaryVelocity ?? 0;
    if (_pastThreshold) {
      _pastThreshold = false;
      final action = v < 0 ? widget.trailing.first : widget.leading.first;
      _animateTo(0);
      action.onTap();
      return;
    }
    if (v < 0) {
      final open = -v > _trailingExtent / 2 || velocity < -600;
      _animateTo(open && velocity <= 600 ? -_trailingExtent : 0);
    } else if (v > 0) {
      final open = v > _leadingExtent / 2 || velocity > 600;
      _animateTo(open && velocity >= -600 ? _leadingExtent : 0);
    }
  }

  void _close() => _animateTo(0);

  Widget _buttons(List<IosSwipeAction> actions, bool trailing, double offset) {
    final total = offset.abs();
    final each = actions.isEmpty ? 0.0 : total / actions.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final action in trailing ? actions.reversed : actions)
          SizedBox(
            width: each,
            child: _SwipeButton(
              action: action,
              onTap: () {
                _close();
                action.onTap();
              },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled || (widget.leading.isEmpty && widget.trailing.isEmpty)) {
      return widget.child;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: _onDragStart,
          onHorizontalDragUpdate: _onDragUpdate,
          onHorizontalDragEnd: _onDragEnd,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final dx = _controller.value;
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  if (dx > 0)
                    Positioned.fill(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: _buttons(widget.leading, false, dx),
                      ),
                    ),
                  if (dx < 0)
                    Positioned.fill(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: _buttons(widget.trailing, true, dx),
                      ),
                    ),
                  Transform.translate(
                    offset: Offset(dx, 0),
                    child: TapRegion(
                      onTapOutside: dx == 0 ? null : (_) => _close(),
                      child: AbsorbPointer(absorbing: dx != 0, child: child),
                    ),
                  ),
                ],
              );
            },
            child: ColoredBox(
              color: IosColors.of(context).cell,
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}

class _SwipeButton extends StatelessWidget {
  const _SwipeButton({required this.action, required this.onTap});

  final IosSwipeAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: action.label,
    child: GestureDetector(
      key: action.key,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ColoredBox(
        color: action.color,
        child: ClipRect(
          child: OverflowBox(
            maxWidth: IosMetrics.swipeActionWidth,
            minWidth: IosMetrics.swipeActionWidth,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (action.icon != null)
                  Icon(action.icon, size: 22, color: Colors.white),
                if (action.icon != null) const SizedBox(height: 3),
                Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: IosType.footnote.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
