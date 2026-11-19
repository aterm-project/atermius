import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'keyboard_capture.dart';

/// Three- and four-finger gestures of a Windows precision touchpad for the
/// remote desktop under the pointer.
///
/// Windows keeps these gestures to itself and Flutter never sees them, so the
/// runner ("atermius/touchpad_gestures") reads the touchpad's contacts and
/// sends the frames of a gesture with three or more fingers here.
/// [MultiFingerGestureRecognizer] turns them into swipes and taps and
/// [TouchpadGestureMapper] into the shortcuts those gestures stand for on
/// Windows, sent to the remote computer.
///
/// An application cannot take the gestures away from the local system, which
/// still performs whatever Settings > Touchpad assigns to them. A gesture is
/// therefore forwarded only when its local setting is "Nothing"
/// ([TouchpadGestureSettings]); otherwise this computer keeps it, as before.

/// One finger on the pad. [x] and [y] are in units of the pad's width.
@immutable
class TouchpadContact {
  const TouchpadContact(this.id, this.x, this.y);
  final int id;
  final double x, y;
}

enum TouchpadSwipe { up, down, left, right }

/// What the recognizer saw. [fingers] is the most fingers the gesture had.
@immutable
sealed class TouchpadGestureEvent {
  const TouchpadGestureEvent(this.fingers);
  final int fingers;
}

/// The fingers moved far enough in [direction]; sent once per gesture.
class TouchpadSwipeStarted extends TouchpadGestureEvent {
  const TouchpadSwipeStarted(super.fingers, this.direction);
  final TouchpadSwipe direction;
  @override
  String toString() => 'swipe $fingers ${direction.name}';
}

/// A sideways swipe went on by another step: forward along its direction, or
/// back when [forward] is false.
class TouchpadSwipeStep extends TouchpadGestureEvent {
  const TouchpadSwipeStep(super.fingers, {required this.forward});
  final bool forward;
  @override
  String toString() => 'step $fingers ${forward ? 'forward' : 'back'}';
}

/// The fingers of a swipe lifted.
class TouchpadSwipeEnded extends TouchpadGestureEvent {
  const TouchpadSwipeEnded(super.fingers);
  @override
  String toString() => 'end $fingers';
}

/// The fingers touched and lifted without moving.
class TouchpadTap extends TouchpadGestureEvent {
  const TouchpadTap(super.fingers);
  @override
  String toString() => 'tap $fingers';
}

/// Recognizes swipes and taps of three or four fingers from contact frames.
/// Distances are in units of the pad's width.
class MultiFingerGestureRecognizer {
  /// Travel of the fingers' common movement that makes a swipe.
  static const swipeDistance = .08;

  /// Further sideways travel for each additional step.
  static const stepDistance = .10;

  /// A tap moves less than this and lasts no longer than [tapTime].
  static const tapSlop = .025;
  static const tapTime = Duration(milliseconds: 350);

  bool _tracking = false, _ignored = false, _waitForLift = false;
  int _fingers = 0, _startMs = 0;
  double _dx = 0, _dy = 0, _travel = 0;
  Map<int, TouchpadContact> _last = const {};
  TouchpadSwipe? _direction;
  int _steps = 0;

  /// Whether a swipe is in progress (its end has not been reported yet).
  bool get swiping => _direction != null;

  /// Feeds one frame taken at [timeMs]; returns what it completed.
  List<TouchpadGestureEvent> add(List<TouchpadContact> contacts, int timeMs) {
    final events = <TouchpadGestureEvent>[];
    if (_waitForLift) {
      // After a gesture every finger has to lift before the next one.
      if (contacts.isEmpty) _waitForLift = false;
      return events;
    }
    if (!_tracking) {
      if (contacts.length < 3) return events;
      _tracking = true;
      _ignored = false;
      _fingers = contacts.length;
      _startMs = timeMs;
      _dx = _dy = _travel = 0;
      _direction = null;
      _steps = 0;
      _last = {for (final c in contacts) c.id: c};
      if (contacts.length > 4) _ignored = true;
      return events;
    }
    if (contacts.length < 3) {
      // The gesture is over as soon as fewer than three fingers remain.
      if (!_ignored) {
        if (_direction != null) {
          events.add(TouchpadSwipeEnded(_fingers));
        } else if (_travel <= tapSlop &&
            timeMs - _startMs <= tapTime.inMilliseconds) {
          events.add(TouchpadTap(_fingers));
        }
      }
      _tracking = false;
      _direction = null;
      _last = const {};
      _waitForLift = contacts.isNotEmpty;
      return events;
    }
    // More fingers than Windows has gestures for: not ours.
    if (contacts.length > 4) {
      // A palm/fifth contact can interrupt an app-switching swipe. Always
      // finish it now, otherwise the remote Alt stays down indefinitely.
      if (_direction != null) events.add(TouchpadSwipeEnded(_fingers));
      _tracking = false;
      _direction = null;
      _last = const {};
      _waitForLift = true;
      return events;
    }
    if (contacts.length > _fingers && _direction == null) {
      // A fourth finger landing late still makes it a four-finger gesture.
      _fingers = contacts.length;
    }
    // The common movement of the fingers present in both frames, so one
    // that lands or lifts does not look like movement.
    var sumX = 0.0, sumY = 0.0, shared = 0;
    for (final contact in contacts) {
      final before = _last[contact.id];
      if (before == null) continue;
      sumX += contact.x - before.x;
      sumY += contact.y - before.y;
      shared++;
    }
    _last = {for (final c in contacts) c.id: c};
    if (shared == 0 || _ignored) return events;
    _dx += sumX / shared;
    _dy += sumY / shared;
    final distance = _dx.abs() > _dy.abs() ? _dx.abs() : _dy.abs();
    if (distance > _travel) _travel = distance;
    final direction = _direction;
    if (direction == null) {
      if (distance < swipeDistance) return events;
      final next = _dx.abs() > _dy.abs()
          ? (_dx > 0 ? TouchpadSwipe.right : TouchpadSwipe.left)
          : (_dy > 0 ? TouchpadSwipe.down : TouchpadSwipe.up);
      _direction = next;
      events.add(TouchpadSwipeStarted(_fingers, next));
      return events;
    }
    if (direction == TouchpadSwipe.left || direction == TouchpadSwipe.right) {
      // Steps counted along the direction the swipe started in.
      final along =
          ((direction == TouchpadSwipe.right ? _dx : -_dx) - swipeDistance) /
          stepDistance;
      while (along >= _steps + 1 && _steps < 64) {
        _steps++;
        events.add(TouchpadSwipeStep(_fingers, forward: true));
      }
      // Half a step of slack, so resting on a boundary does not flicker.
      while (along <= _steps - .5 && _steps > -8) {
        _steps--;
        events.add(TouchpadSwipeStep(_fingers, forward: false));
      }
    }
    return events;
  }

  /// Forgets the gesture in progress; reports the end of a started swipe.
  List<TouchpadGestureEvent> cancel({bool waitForLift = false}) {
    final events = <TouchpadGestureEvent>[
      if (_tracking && !_ignored && _direction != null)
        TouchpadSwipeEnded(_fingers),
    ];
    _waitForLift = waitForLift && (_tracking || _waitForLift);
    _tracking = false;
    _direction = null;
    _last = const {};
    return events;
  }
}

/// What this computer does with the gestures (Settings > Touchpad), as the
/// runner reads it: 0 is "Nothing". Null when the runner could not tell, which
/// is treated like a gesture the local system uses.
@immutable
class TouchpadGestureSettings {
  const TouchpadGestureSettings({
    this.threeFingerSlide,
    this.threeFingerTap,
    this.fourFingerSlide,
    this.fourFingerTap,
  });

  /// Every gesture is free for the remote computer.
  static const allFree = TouchpadGestureSettings(
    threeFingerSlide: 0,
    threeFingerTap: 0,
    fourFingerSlide: 0,
    fourFingerTap: 0,
  );

  final int? threeFingerSlide, threeFingerTap, fourFingerSlide, fourFingerTap;

  static int? _value(Object? value) =>
      value is int && value >= 0 ? value : null;

  static TouchpadGestureSettings fromNative(Object? value) => value is! Map
      ? const TouchpadGestureSettings()
      : TouchpadGestureSettings(
          threeFingerSlide: _value(value['threeFingerSlide']),
          threeFingerTap: _value(value['threeFingerTap']),
          fourFingerSlide: _value(value['fourFingerSlide']),
          fourFingerTap: _value(value['fourFingerTap']),
        );

  /// Whether the local system leaves this gesture alone.
  bool free(int fingers, {required bool tap}) =>
      switch ((fingers, tap)) {
        (3, false) => threeFingerSlide,
        (3, true) => threeFingerTap,
        (4, false) => fourFingerSlide,
        (4, true) => fourFingerTap,
        _ => null,
      } ==
      0;
}

/// X11 keysyms of the shortcuts.
abstract final class _Key {
  static const shift = 0xffe1;
  static const control = 0xffe3;
  static const alt = 0xffe9;
  static const meta = 0xffeb;
  static const tab = 0xff09;
  static const left = 0xff51;
  static const right = 0xff53;
  static const a = 0x61;
  static const d = 0x64;
  static const s = 0x73;
}

/// Sends the shortcut each gesture stands for with Windows' default touchpad
/// settings:
///
/// | Gesture | Windows | Sent |
/// | --- | --- | --- |
/// | three or four fingers up | Task view | Win+Tab |
/// | three or four fingers down | Show desktop | Win+D |
/// | three fingers left/right | Switch apps | Alt held, Tab / Shift+Tab per step |
/// | four fingers left/right | Switch desktops | Ctrl+Win+Right / Left |
/// | three-finger tap | Search | Win+S |
/// | four-finger tap | Notifications / quick settings | Win+A |
class TouchpadGestureMapper {
  TouchpadGestureMapper(this._send);
  final void Function(int keysym, bool down) _send;
  bool _altHeld = false, _forwardIsTab = true;

  void _tap(int keysym, [List<int> modifiers = const []]) {
    for (final modifier in modifiers) {
      _send(modifier, true);
    }
    _send(keysym, true);
    _send(keysym, false);
    for (final modifier in modifiers.reversed) {
      _send(modifier, false);
    }
  }

  void handle(TouchpadGestureEvent event, TouchpadGestureSettings settings) {
    switch (event) {
      case TouchpadTap():
        if (!settings.free(event.fingers, tap: true)) return;
        _tap(event.fingers == 3 ? _Key.s : _Key.a, const [_Key.meta]);
      case TouchpadSwipeStarted():
        if (!settings.free(event.fingers, tap: false)) return;
        switch (event.direction) {
          case TouchpadSwipe.up:
            _tap(_Key.tab, const [_Key.meta]);
          case TouchpadSwipe.down:
            _tap(_Key.d, const [_Key.meta]);
          case TouchpadSwipe.left || TouchpadSwipe.right:
            final right = event.direction == TouchpadSwipe.right;
            if (event.fingers == 3) {
              // Alt stays down while the fingers do: the remote switcher
              // stays open and further steps move through it.
              release();
              _forwardIsTab = right;
              _altHeld = true;
              _send(_Key.alt, true);
              _tap(_Key.tab, right ? const [] : const [_Key.shift]);
            } else {
              // The desktops follow the fingers: sliding left shows the
              // desktop on the right.
              _tap(right ? _Key.left : _Key.right, const [
                _Key.control,
                _Key.meta,
              ]);
            }
        }
      case TouchpadSwipeStep():
        if (!_altHeld) return;
        final tab = event.forward == _forwardIsTab;
        _tap(_Key.tab, tab ? const [] : const [_Key.shift]);
      case TouchpadSwipeEnded():
        release();
    }
  }

  /// Lets go of the Alt of an app-switching swipe.
  void release() {
    if (!_altHeld) return;
    _altHeld = false;
    _send(_Key.alt, false);
  }
}

/// Connects the runner to the remote desktop under the pointer.
class TouchpadGestureController {
  TouchpadGestureController({
    MethodChannel channel = const MethodChannel('atermius/touchpad_gestures'),
    KeyboardCaptureController? targets,
    // Public channel injection keeps native bridge tests isolated.
    // ignore: prefer_initializing_formals
  }) : _channel = channel,
       _targetsOverride = targets;

  static TouchpadGestureController? _instance;
  static TouchpadGestureController get instance =>
      _instance ??= TouchpadGestureController();
  @visibleForTesting
  static set debugInstance(TouchpadGestureController? value) =>
      _instance = value;

  /// Only the Windows runner reads the touchpad.
  static bool get available =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  final MethodChannel _channel;
  final KeyboardCaptureController? _targetsOverride;
  KeyboardCaptureController? _targets;
  final _recognizer = MultiFingerGestureRecognizer();
  TouchpadGestureMapper? _mapper;
  KeyboardCaptureTarget? _target;
  bool _attached = false, _missing = false, _sentArmed = false;
  Timer? _idle;

  /// As last reported by the runner.
  TouchpadGestureSettings settings = const TouchpadGestureSettings();

  /// Counts gestures made over a remote desktop that were not forwarded
  /// because this computer's Windows uses them itself, so the view can tell
  /// the user how to hand them to the remote side.
  final usedLocally = ValueNotifier<int>(0);

  /// Starts following the desktop under the pointer. Called by every remote
  /// desktop view; does nothing off Windows or when called again.
  void attach() {
    if (_attached || !available) return;
    _attached = true;
    _channel.setMethodCallHandler(_handle);
    _targets = (_targetsOverride ?? KeyboardCaptureController.instance)
      ..pointerTarget.addListener(_targetChanged);
    _targetChanged();
  }

  void _targetChanged() {
    final next = _targets?.pointerTarget.value;
    if (identical(next, _target)) return;
    _finish();
    _target = next;
    _mapper = next == null ? null : TouchpadGestureMapper(next.send);
    final armed = next != null;
    if (armed == _sentArmed || _missing) return;
    _sentArmed = armed;
    unawaited(_configure(armed));
  }

  Future<void> _configure(bool armed) async {
    try {
      _accept(
        await _channel.invokeMethod<Object?>('configure', {'armed': armed}),
      );
    } on MissingPluginException {
      // A runner without the reader: these gestures stay with the system.
      _missing = true;
    } on PlatformException {
      // The next focus change tries again.
      _sentArmed = false;
    }
  }

  void _accept(Object? state) {
    if (state is Map) settings = TouchpadGestureSettings.fromNative(state);
  }

  /// Ends the gesture in progress on the current target.
  void _finish() {
    final mapper = _mapper;
    _idle?.cancel();
    _idle = null;
    for (final event in _recognizer.cancel(waitForLift: true)) {
      mapper?.handle(event, settings);
    }
    mapper?.release();
  }

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'stateChanged':
        _finish();
        _accept(call.arguments);
      case 'cancel':
        _finish();
      case 'frame':
        final mapper = _mapper;
        final arguments = call.arguments;
        if (mapper == null || arguments is! Map) return null;
        final raw = arguments['contacts'], time = arguments['time'];
        if (raw is! List ||
            time is! int ||
            raw.length % 3 != 0 ||
            raw.length > 48) {
          _finish();
          return null;
        }
        final contacts = <TouchpadContact>[];
        final ids = <int>{};
        for (var i = 0; i + 2 < raw.length && contacts.length < 16; i += 3) {
          final id = raw[i], x = raw[i + 1], y = raw[i + 2];
          if (id is! num ||
              !id.isFinite ||
              id != id.roundToDouble() ||
              x is! num ||
              y is! num ||
              !x.isFinite ||
              !y.isFinite ||
              !ids.add(id.toInt())) {
            _finish();
            return null;
          }
          contacts.add(TouchpadContact(id.toInt(), x.toDouble(), y.toDouble()));
        }
        for (final event in _recognizer.add(contacts, time)) {
          final blocked = switch (event) {
            TouchpadTap() => !settings.free(event.fingers, tap: true),
            TouchpadSwipeStarted() => !settings.free(event.fingers, tap: false),
            _ => false,
          };
          if (blocked) usedLocally.value++;
          mapper.handle(event, settings);
        }
        _idle?.cancel();
        // Device removal, a lost final HID report, or a suspended window
        // must never leave a modifier held remotely.
        _idle = contacts.isEmpty
            ? null
            : Timer(const Duration(seconds: 1), _finish);
    }
    return null;
  }

  void dispose() {
    if (!_attached) return;
    _finish();
    _targets?.pointerTarget.removeListener(_targetChanged);
    _channel.setMethodCallHandler(null);
    if (_sentArmed && !_missing) {
      _sentArmed = false;
      unawaited(
        _channel
            .invokeMethod<Object?>('configure', {'armed': false})
            .then<void>((_) {}, onError: (Object _) {}),
      );
    }
    _attached = false;
    _target = null;
    _mapper = null;
  }
}
