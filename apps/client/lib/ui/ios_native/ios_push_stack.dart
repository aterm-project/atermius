import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

/// 模拟 iOS 原生 push 转场的双层常驻容器（视觉附录 §9.1 / 蓝图 §1.5）。
///
/// 两个子树始终挂载在同一个 Stack 下（配合 GlobalKey），切换时不卸载终端视图，
/// 不丢失回滚缓冲区、GlobalKey 状态与软键盘 IME 连接。
///
/// - 进入终端（`showDetail: true`）：终端层自右滑入 `100% → 0`，主机层视差左移 `0 → -30%`，
///   左缘附带 8pt 渐变阴影；亮色模式下主机层叠 6% 暗色遮罩。
/// - 左缘 20pt 跟手右滑返回：位移 > 50% 或速度 > 1000 px/s 完成返回并触发 [onPopGesture]，
///   否则弹簧回弹。
/// - 完全遮挡后：底层设 `Offstage` + `TickerMode(false)` + `ExcludeSemantics` + `IgnorePointer`，
///   省电且测试 finder（默认 `skipOffstage`）不会误命中被盖住的一层。
class IosPushStack extends StatefulWidget {
  const IosPushStack({
    super.key,
    required this.home,
    required this.detail,
    required this.showDetail,
    required this.onPopGesture,
    this.onShown,
    this.homeStatusBarStyle,
    this.detailStatusBarStyle,
  });

  final Widget home;
  final Widget detail;
  final bool showDetail;

  /// 左缘右滑返回完成时触发（通常切回 `'hosts'`）。
  final VoidCallback onPopGesture;

  /// 终端层滑入动画完全结束时触发（用于延后请求终端焦点，避免转场中键盘抖动）。
  final VoidCallback? onShown;

  final SystemUiOverlayStyle? homeStatusBarStyle;
  final SystemUiOverlayStyle? detailStatusBarStyle;

  @override
  State<IosPushStack> createState() => _IosPushStackState();
}

class _IosPushStackState extends State<IosPushStack>
    with SingleTickerProviderStateMixin {
  static const double _edgeGestureWidth = 20;
  static const Duration _pushDuration = Duration(milliseconds: 350);
  static const Duration _popDuration = Duration(milliseconds: 300);

  final GlobalKey _homeSubtreeKey = GlobalKey(debugLabel: 'ios_push_home');
  final GlobalKey _detailSubtreeKey = GlobalKey(debugLabel: 'ios_push_detail');

  late final AnimationController _controller = AnimationController(
    vsync: this,
    value: widget.showDetail ? 1.0 : 0.0,
    duration: _pushDuration,
    reverseDuration: _popDuration,
  )..addStatusListener(_handleStatus);

  bool _dragging = false;
  double _width = 1;
  bool _notifiedShown = false;

  @override
  void initState() {
    super.initState();
    if (widget.showDetail) {
      _notifiedShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.showDetail) {
          widget.onShown?.call();
        }
      });
    }
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && widget.showDetail && !_notifiedShown) {
      _notifiedShown = true;
      widget.onShown?.call();
    } else if (status == AnimationStatus.dismissed) {
      _notifiedShown = false;
    }
  }

  @override
  void didUpdateWidget(IosPushStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.showDetail == oldWidget.showDetail) return;
    if (widget.showDetail) {
      _notifiedShown = false;
      _controller.animateTo(
        1.0,
        duration: _pushDuration,
        curve: Curves.fastEaseInToSlowEaseOut,
      );
    } else {
      _notifiedShown = false;
      _controller.animateTo(
        0.0,
        duration: _popDuration,
        curve: Curves.fastEaseInToSlowEaseOut,
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onEdgeDragStart(DragStartDetails _) {
    if (!widget.showDetail) return;
    _dragging = true;
    _controller.stop();
  }

  void _onEdgeDragUpdate(DragUpdateDetails details) {
    if (!_dragging || _width <= 0) return;
    final delta = details.primaryDelta ?? 0;
    _controller.value = (_controller.value - delta / _width).clamp(0.0, 1.0);
  }

  void _onEdgeDragEnd(DragEndDetails details) {
    if (!_dragging) return;
    _dragging = false;
    final velocity = details.primaryVelocity ?? 0;
    final displaced = 1.0 - _controller.value;
    if (displaced > 0.5 || velocity > 1000) {
      _notifiedShown = false;
      _controller.animateTo(
        0.0,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
      widget.onPopGesture();
    } else {
      _controller.animateTo(
        1.0,
        duration: _popDuration,
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _onEdgeDragCancel() {
    if (!_dragging) return;
    _dragging = false;
    _controller.animateTo(
      widget.showDetail ? 1.0 : 0.0,
      duration: _popDuration,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final defaultOverlay = isDark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;
    return TooltipVisibility(
      visible: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _width = constraints.maxWidth <= 0 ? 1 : constraints.maxWidth;
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.value;
              final homeHidden = t >= 1.0;
              final detailHidden = t <= 0.0;
              final overlayStyle = t > 0.5
                  ? (widget.detailStatusBarStyle ?? SystemUiOverlayStyle.light)
                  : (widget.homeStatusBarStyle ?? defaultOverlay);

              return AnnotatedRegion<SystemUiOverlayStyle>(
                value: overlayStyle,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 底层 Home：完全被覆盖时设为 Offstage 并暂停 Ticker。
                    Offstage(
                      offstage: homeHidden,
                      child: TickerMode(
                        enabled: !homeHidden,
                        child: ExcludeSemantics(
                          excluding: homeHidden || t > 0.0,
                          child: IgnorePointer(
                            ignoring: t > 0.0,
                            child: ExcludeFocus(
                              excluding: t > 0.0,
                              child: Transform.translate(
                                offset: Offset(-0.30 * t * _width, 0),
                                child: KeyedSubtree(
                                  key: _homeSubtreeKey,
                                  child: widget.home,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 亮色模式转场期间给底层加轻微暗角遮罩。
                    if (!isDark && t > 0.0 && t < 1.0)
                      IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.06 * t),
                        ),
                      ),
                    // 顶层 Detail（终端 / 文件会话）：常驻挂载，完全收起时设为 Offstage。
                    Offstage(
                      offstage: detailHidden,
                      child: TickerMode(
                        enabled: !detailHidden,
                        child: ExcludeSemantics(
                          excluding: detailHidden,
                          child: IgnorePointer(
                            ignoring: !widget.showDetail || _dragging,
                            child: ExcludeFocus(
                              excluding: !widget.showDetail,
                              child: Transform.translate(
                                offset: Offset((1.0 - t) * _width, 0),
                                child: DecoratedBox(
                                  decoration: t > 0.0 && t < 1.0
                                      ? BoxDecoration(
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(
                                                alpha: 0.20 * t,
                                              ),
                                              blurRadius: 12,
                                              offset: const Offset(-4, 0),
                                            ),
                                          ],
                                        )
                                      : const BoxDecoration(),
                                  child: KeyedSubtree(
                                    key: _detailSubtreeKey,
                                    child: widget.detail,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 左边缘 20pt 返回手势热区。
                    if (widget.showDetail && !detailHidden)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        width: _edgeGestureWidth,
                        child: GestureDetector(
                          key: const ValueKey('ios_push_stack_back_edge'),
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragStart: _onEdgeDragStart,
                          onHorizontalDragUpdate: _onEdgeDragUpdate,
                          onHorizontalDragEnd: _onEdgeDragEnd,
                          onHorizontalDragCancel: _onEdgeDragCancel,
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
