import 'dart:ui';

/// Momentary wheel bits of a remote-desktop mouse packet, above the button
/// bits 1/2/4. They match RFB buttons 4-7 (bits 3-6), so VNC forwards the
/// mask unchanged; the RDP engine turns them into PTR_FLAGS_WHEEL and
/// PTR_FLAGS_HWHEEL notches.
abstract final class DesktopWheel {
  static const up = 8, down = 16, left = 32, right = 64;

  /// Every wheel bit; none of them is ever held down.
  static const mask = up | down | left | right;

  /// The single notch for a physical wheel or touchpad scroll signal, in
  /// Flutter's convention (positive dy scrolls down, positive dx right).
  /// The dominant axis wins, so a tilt wheel scrolls sideways instead of
  /// down. Returns null for an empty delta.
  static int? forScrollDelta(Offset delta) {
    if (delta.dx == 0 && delta.dy == 0) return null;
    if (delta.dx.abs() > delta.dy.abs()) return delta.dx < 0 ? left : right;
    return delta.dy < 0 ? up : down;
  }
}

/// Two-finger touch scrolling for the touchpad (mouse) mode and the direct
/// touch fallback. Content follows the fingers, like scrolling any Android
/// list or a Windows touch screen: moving the fingers down scrolls up, moving
/// them right scrolls left. A gesture locks to the axis it first moves along,
/// so a slightly diagonal swipe never also scrolls sideways.
///
/// Physical mice and touchpads never pass through here; their scroll signals
/// use [DesktopWheel.forScrollDelta] and keep the OS direction.
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
            ? (positive ? DesktopWheel.left : DesktopWheel.right)
            : (positive ? DesktopWheel.up : DesktopWheel.down),
      );
      travel += positive ? -step : step;
    }
    // Movement along the other axis is dropped while the axis is locked.
    _pending = horizontal ? Offset(travel, 0) : Offset(0, travel);
    return notches;
  }
}
