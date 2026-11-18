import 'dart:async';

import 'package:flutter/material.dart';

import 'app_motion.dart';

/// Android fullscreen "peek": tapping the white pane handle temporarily drops
/// the workspace tab strip down as an overlay above the selected pane.
///
/// The strip is painted in the route's [Overlay], so the workspace layout is
/// untouched: terminal grids and RDP resolutions keep their size and no pane
/// is remounted or reconnected. The peek hides itself after [autoHide] of
/// inactivity, but never while a finger is down on it (tab drags, long-press)
/// or while a menu/dialog route covers the workspace.
///
/// Desktop fullscreen reveals the same strip with the mouse instead: resting
/// the pointer on the top screen edge slides it down ([hoverEnter]) and it
/// retracts [hoverLinger] after the pointer has left it ([hoverExit]).
class FullscreenTabsPeek extends ChangeNotifier {
  FullscreenTabsPeek({
    this.autoHide = const Duration(seconds: 4),
    this.hoverLinger = const Duration(milliseconds: 350),
  });

  static FullscreenTabsPeek? _instance;
  static FullscreenTabsPeek get instance => _instance ??= FullscreenTabsPeek();
  @visibleForTesting
  static set debugInstance(FullscreenTabsPeek? value) => _instance = value;

  /// [TapRegion] group shared by the dropped strip and the pane handle, so a
  /// tap on either is "inside" and anything else dismisses the peek.
  static const Object tapGroup = #atermiusFullscreenTabsPeek;

  final Duration autoHide, hoverLinger;
  bool _visible = false, _disposed = false, _hover = false;
  static const Object _hoverToken = #atermiusFullscreenTabsHover;
  final _pointers = <int>{};
  final _blockers = <Object>{};
  Timer? _timer;

  bool get visible => _visible;

  /// True while an interaction must keep the strip on screen.
  bool get held => _pointers.isNotEmpty || _blockers.isNotEmpty;

  @visibleForTesting
  bool get debugTimerActive => _timer?.isActive ?? false;

  void show() {
    if (_disposed) return;
    _arm();
    if (_visible) return;
    _visible = true;
    notifyListeners();
  }

  void hide() {
    _timer?.cancel();
    _timer = null;
    _pointers.clear();
    _blockers.remove(_hoverToken);
    _hover = false;
    if (_disposed || !_visible) return;
    _visible = false;
    notifyListeners();
  }

  void toggle() => _visible ? hide() : show();

  /// Restarts the auto-hide countdown after an interaction.
  void keepAlive() {
    if (_visible && !_disposed) _arm();
  }

  void pointerDown(int pointer) {
    if (!_visible || _disposed) return;
    _pointers.add(pointer);
    _timer?.cancel();
    _timer = null;
  }

  void pointerUp(int pointer) {
    if (_pointers.remove(pointer)) keepAlive();
  }

  /// A menu or dialog route above the workspace pauses the countdown; its
  /// result must still reach the strip that opened it.
  void block(Object token) {
    if (!_blockers.add(token)) return;
    _timer?.cancel();
    _timer = null;
  }

  void unblock(Object token) {
    if (_blockers.remove(token)) keepAlive();
  }

  /// The mouse is on the top edge or on the dropped strip.
  void hoverEnter() {
    if (_disposed) return;
    _hover = true;
    _blockers.add(_hoverToken);
    show();
  }

  /// The mouse left the strip; a press or an open menu still holds it.
  void hoverExit() {
    if (_blockers.remove(_hoverToken)) keepAlive();
  }

  void _arm() {
    _timer?.cancel();
    _timer = held
        ? null
        : Timer(_hover ? hoverLinger : autoHide, () {
            _timer = null;
            if (!held) hide();
          });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Layout-free host for the workspace tab strip in Android fullscreen.
///
/// Occupies no space in the workspace column; while the peek is visible the
/// strip built by [builder] is painted at the top of the route's overlay.
class FullscreenTabsOverlay extends StatefulWidget {
  const FullscreenTabsOverlay({
    super.key,
    required this.builder,
    this.hover = false,
  });
  final WidgetBuilder builder;

  /// Desktop: the mouse on the top edge reveals the strip, and leaving the
  /// strip retracts it. Clicks elsewhere reach the pane underneath.
  final bool hover;

  /// Height of the invisible reveal zone along the top edge.
  static const hoverEdge = 3.0;

  /// The pointer must rest on the edge this long, so sweeping the mouse past
  /// the top of a terminal does not flash the strip.
  static const hoverDwell = Duration(milliseconds: 120);
  @override
  State<FullscreenTabsOverlay> createState() => _FullscreenTabsOverlayState();
}

class _FullscreenTabsOverlayState extends State<FullscreenTabsOverlay> {
  final _portal = OverlayPortalController();
  final _routeToken = Object();
  late final FullscreenTabsPeek _peek = FullscreenTabsPeek.instance;
  Timer? _dwell;

  void _edgeEnter() {
    _dwell?.cancel();
    _dwell = Timer(FullscreenTabsOverlay.hoverDwell, () {
      if (mounted && _routeCurrent) _peek.hoverEnter();
    });
  }

  void _edgeExit() {
    _dwell?.cancel();
    _dwell = null;
  }

  @override
  void initState() {
    super.initState();
    _portal.show();
  }

  bool get _routeCurrent => ModalRoute.isCurrentOf(context) ?? true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routeCurrent ? _peek.unblock(_routeToken) : _peek.block(_routeToken);
  }

  @override
  void dispose() {
    final peek = _peek;
    _dwell?.cancel();
    peek.unblock(_routeToken);
    // Leaving fullscreen or selecting Home retires the strip; notify only
    // after the current frame has finished unmounting.
    scheduleMicrotask(peek.hide);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Overlay.maybeOf(context) == null) return const SizedBox.shrink();
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (_) => ListenableBuilder(
        listenable: _peek,
        builder: (overlayContext, _) => Stack(
          children: [
            if (_peek.visible)
              Positioned(
                key: const ValueKey('fullscreen_tabs_overlay'),
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: TapRegion(
                    groupId: FullscreenTabsPeek.tapGroup,
                    // The dismissing tap stops here: gesture handlers outside
                    // the strip/handle (terminal, desktop, dock) never see
                    // it. Raw pointer input on the pane is blocked by the
                    // pane's barrier. Disabled by TapRegion itself while a
                    // menu/dialog route is on top; tab drags start inside.
                    consumeOutsideTaps: !widget.hover,
                    onTapOutside: (_) {
                      // A tap inside an open menu/dialog is not "outside".
                      if (mounted && _routeCurrent) _peek.hide();
                    },
                    child: MouseRegion(
                      onEnter: widget.hover ? (_) => _peek.hoverEnter() : null,
                      onExit: widget.hover ? (_) => _peek.hoverExit() : null,
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (event) =>
                            _peek.pointerDown(event.pointer),
                        onPointerUp: (event) => _peek.pointerUp(event.pointer),
                        onPointerCancel: (event) =>
                            _peek.pointerUp(event.pointer),
                        child: MotionEntrance(
                          trigger: null,
                          animateOnFirstBuild: true,
                          duration: MotionDurations.quick,
                          offset: const Offset(0, -8),
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0x55000000),
                                  blurRadius: 6,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            child: widget.builder(overlayContext),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (widget.hover)
              Positioned(
                key: const ValueKey('fullscreen_tabs_hover_edge'),
                top: 0,
                left: 0,
                right: 0,
                height: FullscreenTabsOverlay.hoverEdge,
                // Translucent and childless: it only observes the hover, so
                // clicks and wheel input on the edge still reach the pane.
                child: MouseRegion(
                  hitTestBehavior: HitTestBehavior.translucent,
                  onEnter: (_) => _edgeEnter(),
                  onExit: (_) => _edgeExit(),
                ),
              ),
          ],
        ),
      ),
      child: const SizedBox.shrink(),
    );
  }
}
