import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show TargetPlatform;

/// High-resolution wheel input of a remote-desktop session.
///
/// Wire command: `['wheel', x, y, dx, dy]`, all integers. `x`/`y` is the
/// remote pointer position the wheel turns at. `dx`/`dy` are signed wheel
/// units in the Windows convention (WM_MOUSEWHEEL / WM_MOUSEHWHEEL), where
/// [notch] (120) is one detent of an ordinary wheel:
///
///  * `dy > 0` turns the wheel away from the user and scrolls **up**,
///    `dy < 0` scrolls down;
///  * `dx > 0` scrolls **right**, `dx < 0` scrolls left.
///
/// A command whose `dx` and `dy` are both 0 ends a scroll gesture: transports
/// that only know whole notches forget what they had counted towards the next
/// one. Each delta is at most [maxPerCommand] in magnitude.
///
/// The direct RDP engine sends the units as they are (`aterm_rdp_wheel`).
/// Every other transport counts them into whole notches with
/// [DesktopWheelNotches] and sends those as the momentary wheel bits of a
/// `['mouse', x, y, buttons]` command.
abstract final class DesktopWheelUnits {
  /// One detent of an ordinary mouse wheel (WHEEL_DELTA).
  static const notch = 120;

  /// Largest magnitude of `dx` or `dy` in one command (32 notches).
  static const maxPerCommand = notch * 32;

  /// Momentary wheel bits of a `mouse` command, above the buttons 1/2/4: one
  /// notch each. They equal RFB buttons 4-7, and the horizontal pair is the
  /// encoding Android two-finger scrolling uses.
  static const notchUp = 8, notchDown = 16, notchLeft = 32, notchRight = 64;

  /// Whether [dx] and [dy] are the deltas of a well-formed wheel command.
  static bool valid(Object? dx, Object? dy) =>
      dx is int &&
      dy is int &&
      dx.abs() <= maxPerCommand &&
      dy.abs() <= maxPerCommand;
}

/// How far the local device scrolls for one wheel notch, in logical pixels,
/// so local scroll amounts can be turned into wheel units.
class DesktopWheelScale {
  const DesktopWheelScale({
    required this.wheelNotch,
    required this.panNotch,
    this.clickIsNotch = false,
  });

  /// What each embedder reports for one notch, and how far a touchpad moves
  /// content that a notch would move.
  ///
  /// Windows reports `lines × 100 / 3` physical pixels per notch, where
  /// `lines` is the system's "lines to scroll" setting ([windowsScrollLines],
  /// 3 when unknown), and touchpad pans in physical pixels. Linux (GTK)
  /// reports 53 logical pixels per notch or per touchpad scroll unit. macOS
  /// reports 40 per wheel line, but its acceleration makes a slow click a
  /// fraction of a line, and browsers report about 100 per notch, depending
  /// on the browser: there a wheel click is never less than a notch
  /// ([clickIsNotch]).
  factory DesktopWheelScale.of({
    required TargetPlatform platform,
    required bool web,
    required double devicePixelRatio,
    int? windowsScrollLines,
  }) {
    final ratio = devicePixelRatio.isFinite && devicePixelRatio > 0
        ? devicePixelRatio
        : 1.0;
    if (web) {
      return const DesktopWheelScale(
        wheelNotch: 100,
        panNotch: 100,
        clickIsNotch: true,
      );
    }
    switch (platform) {
      case TargetPlatform.windows:
        final lines = windowsScrollLines == null || windowsScrollLines <= 0
            ? 3
            : windowsScrollLines;
        return DesktopWheelScale(
          wheelNotch: lines * 100 / 3 / ratio,
          panNotch: 100 / ratio,
        );
      case TargetPlatform.linux:
        return const DesktopWheelScale(wheelNotch: 53, panNotch: 53);
      case TargetPlatform.macOS:
      case TargetPlatform.iOS:
        return const DesktopWheelScale(
          wheelNotch: 40,
          panNotch: 100,
          clickIsNotch: true,
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
        return const DesktopWheelScale(wheelNotch: 100, panNotch: 100);
    }
  }

  /// Logical pixels of a scroll signal's `scrollDelta` for one notch.
  final double wheelNotch;

  /// Logical pixels of touchpad pan for one notch.
  final double panNotch;

  /// Where the local amount of one click of an ordinary wheel cannot be
  /// relied on: such a click counts as one notch at least, as it did before
  /// wheel amounts were forwarded.
  final bool clickIsNotch;

  /// Wheel units (x, y) of a scroll signal. Flutter's `scrollDelta` is
  /// positive downwards and to the right; the direction the local system
  /// chose (natural scrolling or not) is already in it. [wheelClick] says
  /// the signal comes from a mouse wheel rather than a touchpad.
  (double, double) ofScroll(Offset scrollDelta, {bool wheelClick = false}) {
    const notch = DesktopWheelUnits.notch;
    var x = scrollDelta.dx / wheelNotch * notch;
    var y = -scrollDelta.dy / wheelNotch * notch;
    if (wheelClick && clickIsNotch) {
      // Only the axis the wheel turned on is raised to a notch.
      if (y.abs() >= x.abs()) {
        if (y != 0 && y.abs() < notch) y = y.sign * notch;
      } else if (x.abs() < notch) {
        x = x.sign * notch;
      }
    }
    return (x, y);
  }

  /// Wheel units (x, y) of a touchpad pan. Content follows the pan like a
  /// dragged page: panning down scrolls up, panning right scrolls left. The
  /// local system's scroll direction setting is already in the pan.
  (double, double) ofPan(Offset pan) => (
    -pan.dx / panNotch * DesktopWheelUnits.notch,
    pan.dy / panNotch * DesktopWheelUnits.notch,
  );
}

/// Turns fractional wheel units into the whole units of wheel commands and
/// carries what is left over to the next event.
class DesktopWheelAccumulator {
  double _x = 0, _y = 0;

  /// Forgets the remainder (the gesture ended or the pointer left).
  void reset() => _x = _y = 0;

  /// Adds [dx]/[dy] units and returns the whole units due now, or null while
  /// they amount to less than one unit on both axes.
  (int, int)? add(double dx, double dy) {
    if (!dx.isFinite || !dy.isFinite) return null;
    final x = _take(_x + dx), y = _take(_y + dy);
    _x = x.$2;
    _y = y.$2;
    return x.$1 == 0 && y.$1 == 0 ? null : (x.$1, y.$1);
  }

  static (int, double) _take(double total) {
    const limit = DesktopWheelUnits.maxPerCommand;
    // More than one command may carry is dropped, never replayed later.
    if (total.abs() > limit) return (total > 0 ? limit : -limit, 0);
    final whole = total.round();
    return (whole, total - whole);
  }
}

/// Counts wheel units into whole notches for transports without a
/// high-resolution wheel: VNC, the Guacamole gateway and RDP engines older
/// than `aterm_rdp_wheel`.
class DesktopWheelNotches {
  DesktopWheelNotches({this.horizontal = true});

  /// False where the transport has no horizontal wheel: sideways units are
  /// dropped instead of scrolling the wrong way.
  final bool horizontal;
  int _x = 0, _y = 0;

  /// Adds the deltas of one wheel command and returns the wheel bits
  /// ([DesktopWheelUnits.notchUp] ...) to send, one per notch, in order. A
  /// command with both deltas 0 ends the gesture and clears the count.
  List<int> add(int dx, int dy) {
    if (dx == 0 && dy == 0) {
      _x = _y = 0;
      return const [];
    }
    const notch = DesktopWheelUnits.notch;
    final bits = <int>[];
    _y += dy;
    for (; _y >= notch; _y -= notch) {
      bits.add(DesktopWheelUnits.notchUp);
    }
    for (; _y <= -notch; _y += notch) {
      bits.add(DesktopWheelUnits.notchDown);
    }
    if (!horizontal) return bits;
    _x += dx;
    for (; _x >= notch; _x -= notch) {
      bits.add(DesktopWheelUnits.notchRight);
    }
    for (; _x <= -notch; _x += notch) {
      bits.add(DesktopWheelUnits.notchLeft);
    }
    return bits;
  }
}

/// What one touchpad update asks for: [pan] logical pixels to scroll by, or
/// [zoom] whole zoom steps (positive zooms in).
typedef DesktopTouchpadStep = ({Offset pan, int zoom});

/// Tells a two-finger scroll from a pinch within one touchpad gesture
/// (`PointerPanZoomStart` to `PointerPanZoomEnd`).
///
/// A gesture is a pinch once its scale has changed by [zoomSlop], and a
/// scroll once it has panned [panSlop] by more than its scale change can
/// account for, whichever comes first. It stays that for its whole length:
/// the small scale changes of two fingers that scroll never zoom, and a pinch
/// never scrolls.
///
/// A system that zooms about a point reports a pinch as a scale together
/// with the pan that keeps that point in place, which is at most the scale
/// change times the distance of the point from the window's corner. Pan
/// within that bound says nothing about scrolling.
class DesktopTouchpadGesture {
  /// Pan, in logical pixels, that makes the gesture a scroll. What was panned
  /// before is scrolled at that moment, so nothing is lost.
  static const panSlop = 6.0;

  /// Scale change (as |ln scale|, about 3%) that makes the gesture a pinch.
  static const zoomSlop = 0.03;

  /// Margin on the pan a scale change may account for.
  static const _reachMargin = 1.5;

  /// Scale factor of one zoom step: one Ctrl+wheel notch per 15%.
  static const zoomStep = 1.15;

  bool _active = false;
  bool? _zooming;
  Offset _pan = Offset.zero;
  int _zoomSteps = 0;
  double _signal = 0;

  /// True from the moment the gesture became a scroll until it ends.
  bool get scrolling => _active && _zooming == false;

  /// A gesture begins.
  void start() {
    _active = true;
    _zooming = null;
    _pan = Offset.zero;
    _zoomSteps = 0;
  }

  /// The gesture ended or was cancelled; later updates of it do nothing.
  void end() {
    _active = false;
    _zooming = null;
    _signal = 0;
  }

  /// [pan] and [scale] are the totals since [start], as a
  /// `PointerPanZoomUpdateEvent` reports them. [reach] is the diagonal of the
  /// window in logical pixels: the farthest a zoom's fixed point can be.
  DesktopTouchpadStep update(Offset pan, double scale, {double reach = 0}) {
    const none = (pan: Offset.zero, zoom: 0);
    if (!_active || !pan.isFinite || !scale.isFinite || scale <= 0) {
      return none;
    }
    final zoom = math.log(scale);
    if (_zooming == null) {
      final panned = pan.distance;
      if (zoom.abs() >= zoomSlop) {
        _zooming = true;
      } else if (panned >= panSlop &&
          panned > zoom.abs() * reach * _reachMargin) {
        _zooming = false;
      } else {
        return none;
      }
    }
    if (_zooming!) {
      // Counted from the start of the pinch and truncated, so a scale that
      // wavers around a step neither repeats nor undoes it.
      final steps = (zoom / math.log(zoomStep) - _zoomSteps).truncate();
      _zoomSteps += steps;
      return (pan: Offset.zero, zoom: steps);
    }
    final delta = pan - _pan;
    _pan = pan;
    return (pan: delta, zoom: 0);
  }

  /// Zoom steps of a `PointerScaleEvent` (a browser's pinch), whose [scale]
  /// is relative to the previous event.
  int scaleSignal(double scale) {
    if (!scale.isFinite || scale <= 0) return 0;
    _signal += math.log(scale) / math.log(zoomStep);
    final steps = _signal.truncate();
    _signal -= steps;
    return steps;
  }
}
