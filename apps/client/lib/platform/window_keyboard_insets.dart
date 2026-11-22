import 'dart:async';

import 'package:flutter/widgets.dart';

/// The IME overlap before any Scaffold or remote desktop consumes it.
class WindowKeyboardInsets extends InheritedWidget {
  const WindowKeyboardInsets._({required this.bottom, required super.child});

  final double bottom;

  static WindowKeyboardInsets? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowKeyboardInsets>();

  @override
  bool updateShouldNotify(WindowKeyboardInsets oldWidget) =>
      bottom != oldWidget.bottom;
}

/// Android can deliver IME metrics even while an overlapping window has
/// input focus. Keep the last inset from our own window while it is inactive.
class AndroidKeyboardViewport extends StatefulWidget {
  const AndroidKeyboardViewport({required this.child, super.key});

  final Widget child;

  @override
  State<AndroidKeyboardViewport> createState() =>
      _AndroidKeyboardViewportState();
}

class _AndroidKeyboardViewportState extends State<AndroidKeyboardViewport>
    with WidgetsBindingObserver {
  double _bottom = 0;
  Timer? _imeHandoff;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _imeHandoff?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _imeHandoff?.cancel();
    // Android can return window focus before delivering the last insets of
    // the previous editor. Give the IME time to finish the handoff.
    _imeHandoff = state == AppLifecycleState.resumed
        ? Timer(const Duration(milliseconds: 650), () {
            setState(() => _imeHandoff = null);
          })
        : null;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    var media = MediaQuery.of(context);
    final rawBottom = media.viewInsets.bottom;
    if (_imeHandoff != null && _bottom == 0 && rawBottom == 0) {
      _imeHandoff?.cancel();
      _imeHandoff = null;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_imeHandoff == null &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed)) {
      _bottom = rawBottom;
    } else if (rawBottom != _bottom) {
      media = media.copyWith(
        viewInsets: media.viewInsets.copyWith(bottom: _bottom),
        padding: media.padding.copyWith(
          bottom: (media.viewPadding.bottom - _bottom).clamp(
            0.0,
            double.infinity,
          ),
        ),
      );
    }
    return WindowKeyboardInsets._(
      bottom: _bottom,
      child: MediaQuery(data: media, child: widget.child),
    );
  }
}
