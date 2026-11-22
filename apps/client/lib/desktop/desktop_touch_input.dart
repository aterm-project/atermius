import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'desktop_wheel.dart';

/// Converts touchpad gestures to the same pointer packets as a real mouse.
/// Physical mice are handled by DesktopView and never pass through this class.
class DesktopTouchInput {
  DesktopTouchInput({
    required this.pointer,
    required this.send,
    required this.scroll,
  });

  final Offset Function() pointer;
  final void Function(Offset point, int buttons) send;
  final void Function(Offset point, int dx, int dy) scroll;
  static const _tapDragTimeout = Duration(milliseconds: 500);
  static const _scrollStep = 20.0;
  bool trackpad = false;
  final _points = <int, Offset>{};
  Offset _start = Offset.zero, _scrollTravel = Offset.zero;
  Duration _started = Duration.zero;
  Duration? _lastTapTime;
  double _travel = 0;
  int _fingerCount = 0;
  bool? _horizontalScroll;
  bool _dragArmed = false, _dragging = false, _longClicked = false;
  Timer? _hold;
  Rect _bounds = Rect.zero;

  void _mouse(Offset point, int buttons) {
    if (_bounds.isEmpty) return;
    send(
      Offset(
        point.dx.clamp(_bounds.left, _bounds.right - 1),
        point.dy.clamp(_bounds.top, _bounds.bottom - 1),
      ),
      buttons,
    );
  }

  void _click(int button) {
    _mouse(pointer(), button);
    _mouse(pointer(), 0);
  }

  void _scroll(Offset delta) {
    _scrollTravel += delta / 2;
    if (_horizontalScroll == null) {
      final x = _scrollTravel.dx.abs(), y = _scrollTravel.dy.abs();
      if (x < _scrollStep && y < _scrollStep) return;
      _horizontalScroll = x > y;
    }
    final horizontal = _horizontalScroll!;
    final travel = horizontal ? _scrollTravel.dx : _scrollTravel.dy;
    final steps = (travel / _scrollStep).truncate();
    final remainder = travel - steps * _scrollStep;
    _scrollTravel = horizontal ? Offset(remainder, 0) : Offset(0, remainder);
    if (steps == 0) return;
    final units = (steps * DesktopWheelUnits.notch).clamp(
      -DesktopWheelUnits.maxPerCommand,
      DesktopWheelUnits.maxPerCommand,
    );
    // Content follows the fingers, with one axis per gesture.
    scroll(pointer(), horizontal ? -units : 0, horizontal ? 0 : units);
  }

  void handle(
    PointerEvent event, {
    required Rect bounds,
    required double scale,
  }) {
    if (!trackpad || bounds.isEmpty || !scale.isFinite || scale <= 0) {
      reset();
      return;
    }
    _bounds = bounds;
    if (event is PointerDownEvent) {
      _points[event.pointer] = event.position;
      if (_points.length == 1) {
        _start = event.position;
        _started = event.timeStamp;
        _travel = 0;
        _fingerCount = 1;
        _scrollTravel = Offset.zero;
        _horizontalScroll = null;
        _longClicked = false;
        final lastTap = _lastTapTime;
        // In relative mode the remote target is the cursor. The second
        // contact can land elsewhere on the screen and wait before moving.
        _dragArmed =
            lastTap != null &&
            _started >= lastTap &&
            _started - lastTap <= _tapDragTimeout;
        _lastTapTime = null;
        if (!_dragArmed) {
          _hold = Timer(kLongPressTimeout, () {
            _longClicked = true;
            _click(4);
          });
        }
      } else {
        if (_points.length > _fingerCount) _fingerCount = _points.length;
        _hold?.cancel();
        if (_dragging) _mouse(pointer(), 0);
        _dragArmed = _dragging = false;
      }
    } else if (event is PointerMoveEvent &&
        _points.containsKey(event.pointer)) {
      final previous = _points[event.pointer]!;
      final delta = event.position - previous;
      _points[event.pointer] = event.position;
      _travel += delta.distance;
      if (_travel >= kTouchSlop) _hold?.cancel();
      if (_fingerCount == 2 && _points.length == 2) {
        _scroll(delta);
      } else if (_dragArmed) {
        final travel = event.position - _start;
        if (travel.distance < kPrecisePointerPanSlop) return;
        _dragArmed = false;
        _dragging = true;
        final point = pointer();
        _mouse(point, 1);
        _mouse(point + travel / scale, 1);
      } else if (_fingerCount == 1 && !_longClicked) {
        _mouse(pointer() + delta / scale, _dragging ? 1 : 0);
      }
    } else if (event is PointerUpEvent &&
        _points.remove(event.pointer) != null) {
      if (_points.isNotEmpty) return;
      _hold?.cancel();
      if (_dragging) {
        _mouse(pointer(), 0);
      } else if (_fingerCount <= 2 &&
          !_longClicked &&
          _travel < kTouchSlop &&
          event.timeStamp - _started < kLongPressTimeout) {
        _click(_fingerCount == 2 ? 4 : 1);
        if (_fingerCount == 1) _lastTapTime = event.timeStamp;
      }
      _dragArmed = _dragging = false;
    } else if (event is PointerCancelEvent) {
      reset();
    }
  }

  void reset({bool release = true}) {
    _hold?.cancel();
    if (release && _dragging) _mouse(pointer(), 0);
    _points.clear();
    _dragArmed = _dragging = _longClicked = false;
    _lastTapTime = null;
  }

  void dispose() => reset();
}
