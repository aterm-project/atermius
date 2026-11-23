import 'dart:ui';

import 'desktop_wheel.dart';

/// Two-finger scrolling of the direct touch fallback (servers without
/// RDPEI, including standard VNC), as momentary wheel bits of a `mouse`
/// command ([DesktopWheelUnits.notchUp] and its siblings). Content follows
/// the fingers, like scrolling any Android list or a Windows touch screen:
/// moving the fingers down scrolls up, moving them right scrolls left. A gesture locks to the axis it first moves along,
/// so a slightly diagonal swipe never also scrolls sideways.
///
/// The touchpad (mouse) mode and physical wheels never pass through here;
/// they send high-resolution `wheel` commands (see desktop_wheel.dart).
class DesktopTouchScroll {
  /// Finger travel, in logical pixels, for one wheel notch.
  static const step = 20.0;

  Offset _pending = Offset.zero;
  bool? _horizontal;

  /// Starts a new gesture (first finger down).
  void reset() {
    _pending = Offset.zero;
    _horizontal = null;
  }

  /// Adds one finger's movement while [fingers] touch the screen (the
  /// gesture moves by the average of all fingers) and returns the wheel
  /// notches to send, in order.
  List<int> move(Offset delta, int fingers) {
    if (fingers < 1) return const [];
    _pending += delta / fingers.toDouble();
    if (_horizontal == null) {
      if (_pending.dx.abs() < step && _pending.dy.abs() < step) {
        return const [];
      }
      _horizontal = _pending.dx.abs() > _pending.dy.abs();
    }
    final horizontal = _horizontal!;
    var travel = horizontal ? _pending.dx : _pending.dy;
    final notches = <int>[];
    while (travel.abs() >= step) {
      final positive = travel > 0;
      notches.add(
        horizontal
            ? (positive ? DesktopWheelUnits.notchLeft : DesktopWheelUnits.notchRight)
            : (positive ? DesktopWheelUnits.notchUp : DesktopWheelUnits.notchDown),
      );
      travel += positive ? -step : step;
    }
    // Movement along the other axis is dropped while the axis is locked.
    _pending = horizontal ? Offset(travel, 0) : Offset(0, travel);
    return notches;
  }
}
