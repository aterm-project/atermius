import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'ios_glass.dart';
import 'ios_icons.dart';
import 'ios_tokens.dart';

/// Toast 语义类型。
enum IosToastKind { info, success, warning, error }

/// 顶部灵动胶囊 Toast（替代 SnackBar）：从灵动岛下方 spring 下落，
/// 48pt 玻璃胶囊、2.6s 自动收回、上滑立即收回、同时最多一条（新消息替换）。
abstract final class IosToast {
  static _ToastHandle? _current;

  static void show(
    BuildContext context,
    String message, {
    IosToastKind kind = IosToastKind.info,
    Duration duration = const Duration(milliseconds: 2600),
  }) {
    if (!context.mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _current?.dismiss(immediate: true);
    switch (kind) {
      case IosToastKind.success:
        HapticFeedback.lightImpact().catchError((Object _) {});
      case IosToastKind.warning || IosToastKind.error:
        HapticFeedback.mediumImpact().catchError((Object _) {});
      case IosToastKind.info:
        break;
    }
    final handle = _ToastHandle();
    final themes = InheritedTheme.capture(from: context, to: overlay.context);
    handle.entry = OverlayEntry(
      builder: (_) => themes.wrap(
        Stack(
          children: [
            _IosToastView(
              message: message,
              kind: kind,
              duration: duration,
              handle: handle,
            ),
          ],
        ),
      ),
    );
    _current = handle;
    overlay.insert(handle.entry!);
  }

  /// 立即收起当前 Toast（测试或页面切换时使用）。
  static void dismiss() => _current?.dismiss(immediate: true);
}

class _ToastHandle {
  OverlayEntry? entry;
  VoidCallback? _animateOut;
  bool _removed = false;

  void dismiss({bool immediate = false}) {
    if (_removed) return;
    if (!immediate && _animateOut != null) {
      _animateOut!();
      return;
    }
    remove();
  }

  void remove() {
    if (_removed) return;
    _removed = true;
    entry?.remove();
    entry = null;
    if (IosToast._current == this) IosToast._current = null;
  }
}

class _IosToastView extends StatefulWidget {
  const _IosToastView({
    required this.message,
    required this.kind,
    required this.duration,
    required this.handle,
  });

  final String message;
  final IosToastKind kind;
  final Duration duration;
  final _ToastHandle handle;

  @override
  State<_IosToastView> createState() => _IosToastViewState();
}

class _IosToastViewState extends State<_IosToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    reverseDuration: const Duration(milliseconds: 220),
  );
  Timer? _timer;
  double _drag = 0;

  @override
  void initState() {
    super.initState();
    widget.handle._animateOut = _out;
    _controller.forward();
    _timer = Timer(widget.duration, _out);
  }

  Future<void> _out() async {
    _timer?.cancel();
    if (!mounted) return;
    await _controller.reverse();
    widget.handle.remove();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final media = MediaQuery.of(context);
    final (icon, color) = switch (widget.kind) {
      IosToastKind.success => (IosIcons.success, c.online),
      IosToastKind.warning => (IosIcons.warning, c.warning),
      IosToastKind.error => (IosIcons.warning, c.destructive),
      IosToastKind.info => (Icons.info_rounded, c.tint),
    };
    final curved = CurvedAnimation(
      parent: _controller,
      curve: const Cubic(0.18, 1.0, 0.3, 1.12),
      reverseCurve: Curves.easeIn,
    );
    return Positioned(
      top: media.padding.top + 6,
      left: media.padding.left + 16,
      right: media.padding.right + 16,
      child: Center(
        child: AnimatedBuilder(
          animation: curved,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, (curved.value - 1) * 80 + _drag.clamp(-80.0, 8.0)),
            child: Opacity(opacity: _controller.value.clamp(0.0, 1.0), child: child),
          ),
          child: GestureDetector(
            onVerticalDragUpdate: (d) => setState(() => _drag += d.delta.dy),
            onVerticalDragEnd: (d) {
              if (_drag < -12 || (d.primaryVelocity ?? 0) < -200) {
                _out();
              } else {
                setState(() => _drag = 0);
              }
            },
            onTap: _out,
            child: Semantics(
              liveRegion: true,
              container: true,
              label: widget.message,
              excludeSemantics: true,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360, minHeight: 48),
                child: IosGlassSurface(
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 12, 20, 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 20, color: color),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.message,
                          key: const ValueKey('ios_toast_message'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: IosType.subheadline.copyWith(
                            color: c.label,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
