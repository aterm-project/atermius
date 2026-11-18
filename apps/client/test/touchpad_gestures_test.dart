import 'package:aterm_client/desktop/keyboard_capture.dart';
import 'package:aterm_client/desktop/touchpad_gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _shift = 0xffe1, _control = 0xffe3, _alt = 0xffe9, _meta = 0xffeb;
const _tab = 0xff09, _left = 0xff51, _right = 0xff53;

/// [count] fingers side by side, moved by ([dx], [dy]) from their start.
List<TouchpadContact> fingers(int count, [double dx = 0, double dy = 0]) => [
  for (var i = 0; i < count; i++)
    TouchpadContact(i, .3 + i * .1 + dx, .3 + dy),
];

/// Feeds a movement in small frames, 8 ms apart, and collects the events.
class Pad {
  final recognizer = MultiFingerGestureRecognizer();
  final events = <String>[];
  int time = 1000;

  void frame(List<TouchpadContact> contacts, {int after = 8}) {
    time += after;
    events.addAll(recognizer.add(contacts, time).map((e) => '$e'));
  }

  void slide(int count, double dx, double dy, {int frames = 20}) {
    for (var i = 0; i <= frames; i++) {
      frame(fingers(count, dx * i / frames, dy * i / frames));
    }
  }

  void lift() => frame(const []);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('recognizer', () {
    test('three fingers in each direction, once per gesture', () {
      for (final (dx, dy, name) in [
        (0.0, -.3, 'up'),
        (0.0, .3, 'down'),
        (-.09, 0.0, 'left'),
        (.09, 0.0, 'right'),
      ]) {
        final pad = Pad()
          ..slide(3, dx, dy)
          ..lift();
        expect(pad.events, ['swipe 3 $name', 'end 3'], reason: name);
      }
    });

    test('a short movement is no swipe, and too slow or far no tap', () {
      final still = Pad()
        ..frame(fingers(3))
        ..frame(fingers(3, .01, .01))
        ..lift();
      expect(still.events, ['tap 3']);
      final held = Pad()
        ..frame(fingers(4))
        ..frame(fingers(4), after: 600)
        ..lift();
      expect(held.events, isEmpty);
      final nudged = Pad()
        ..slide(3, .05, 0)
        ..lift();
      expect(nudged.events, isEmpty);
    });

    test('sideways steps follow the fingers forth and back', () {
      final pad = Pad()..slide(3, .40, 0, frames: 80);
      expect(pad.events, [
        'swipe 3 right',
        'step 3 forward',
        'step 3 forward',
        'step 3 forward',
      ]);
      pad.events.clear();
      for (var i = 0; i <= 40; i++) {
        pad.frame(fingers(3, .40 - .25 * i / 40));
      }
      expect(pad.events, ['step 3 back', 'step 3 back']);
      pad
        ..events.clear()
        ..lift();
      expect(pad.events, ['end 3']);
    });

    test('a fourth finger landing late makes it a four-finger gesture', () {
      final pad = Pad()
        ..frame(fingers(3))
        ..frame(fingers(4))
        ..slide(4, -.2, 0)
        ..lift();
      expect(pad.events.first, 'swipe 4 left');
      expect(pad.events.last, 'end 4');
      final tap = Pad()
        ..frame(fingers(3))
        ..frame(fingers(4))
        ..frame(fingers(2))
        ..lift();
      expect(tap.events, ['tap 4']);
    });

    test('fingers landing or lifting are not movement', () {
      final pad = Pad()..frame(fingers(3));
      // One finger is replaced by another far away: no common movement.
      pad.frame(const [
        TouchpadContact(0, .3, .3),
        TouchpadContact(1, .4, .3),
        TouchpadContact(7, .9, .9),
      ]);
      pad.lift();
      expect(pad.events, ['tap 3']);
    });

    test('five fingers are ignored, and a new gesture needs a full lift', () {
      final five = Pad()
        ..frame(fingers(5))
        ..slide(5, .3, 0)
        ..lift();
      expect(five.events, isEmpty);
      final pad = Pad()
        ..slide(3, 0, -.2)
        ..frame(fingers(2, 0, -.2));
      expect(pad.events, ['swipe 3 up', 'end 3']);
      pad.events.clear();
      // Back to three without lifting everything: still the old gesture.
      pad.slide(3, 0, .3);
      expect(pad.events, isEmpty);
      pad
        ..lift()
        ..slide(3, 0, .3)
        ..lift();
      expect(pad.events, ['swipe 3 down', 'end 3']);
    });

    test('cancel ends a swipe in progress', () {
      final pad = Pad()..slide(3, .2, 0);
      expect(pad.recognizer.swiping, isTrue);
      expect(pad.recognizer.cancel().map((e) => '$e'), ['end 3']);
      expect(pad.recognizer.cancel(), isEmpty);
    });
  });

  group('mapper', () {
    late List<(int, bool)> keys;
    late TouchpadGestureMapper mapper;
    setUp(() {
      keys = [];
      mapper = TouchpadGestureMapper((sym, down) => keys.add((sym, down)));
    });
    List<(int, bool)> chord(int key, List<int> modifiers) => [
      for (final m in modifiers) (m, true),
      (key, true),
      (key, false),
      for (final m in modifiers.reversed) (m, false),
    ];
    const free = TouchpadGestureSettings.allFree;

    test('up, down and taps are single shortcuts', () {
      for (final (event, expected) in <(TouchpadGestureEvent, List<(int, bool)>)>[
        (const TouchpadSwipeStarted(3, TouchpadSwipe.up), chord(_tab, [_meta])),
        (const TouchpadSwipeStarted(4, TouchpadSwipe.up), chord(_tab, [_meta])),
        (
          const TouchpadSwipeStarted(3, TouchpadSwipe.down),
          chord(0x64, [_meta]),
        ),
        (const TouchpadTap(3), chord(0x73, [_meta])),
        (const TouchpadTap(4), chord(0x61, [_meta])),
        (
          const TouchpadSwipeStarted(4, TouchpadSwipe.left),
          chord(_right, [_control, _meta]),
        ),
        (
          const TouchpadSwipeStarted(4, TouchpadSwipe.right),
          chord(_left, [_control, _meta]),
        ),
      ]) {
        keys.clear();
        mapper.handle(event, free);
        mapper.handle(TouchpadSwipeEnded(event.fingers), free);
        expect(keys, expected, reason: '$event');
      }
    });

    test('three fingers sideways hold Alt until the fingers lift', () {
      mapper.handle(const TouchpadSwipeStarted(3, TouchpadSwipe.right), free);
      expect(keys, [(_alt, true), (_tab, true), (_tab, false)]);
      keys.clear();
      mapper.handle(const TouchpadSwipeStep(3, forward: true), free);
      expect(keys, chord(_tab, []));
      keys.clear();
      mapper.handle(const TouchpadSwipeStep(3, forward: false), free);
      expect(keys, chord(_tab, [_shift]));
      keys.clear();
      mapper.handle(const TouchpadSwipeEnded(3), free);
      expect(keys, [(_alt, false)]);
      keys.clear();
      // To the left the first step goes backwards through the switcher.
      mapper.handle(const TouchpadSwipeStarted(3, TouchpadSwipe.left), free);
      expect(keys, [(_alt, true), ...chord(_tab, [_shift])]);
      keys.clear();
      mapper.handle(const TouchpadSwipeStep(3, forward: true), free);
      expect(keys, chord(_tab, [_shift]));
      mapper.release();
      mapper.release();
      expect(keys.where((k) => k == (_alt, false)), hasLength(1));
    });

    test('a gesture this computer uses is left to it', () {
      const local = TouchpadGestureSettings(
        threeFingerSlide: 1,
        threeFingerTap: 1,
        fourFingerSlide: 0,
        fourFingerTap: 0,
      );
      mapper
        ..handle(const TouchpadSwipeStarted(3, TouchpadSwipe.right), local)
        ..handle(const TouchpadSwipeStep(3, forward: true), local)
        ..handle(const TouchpadSwipeEnded(3), local)
        ..handle(const TouchpadTap(3), local);
      expect(keys, isEmpty);
      mapper.handle(const TouchpadTap(4), local);
      expect(keys, chord(0x61, [_meta]));
      keys.clear();
      // Unknown settings count as used locally.
      mapper.handle(const TouchpadTap(4), const TouchpadGestureSettings());
      mapper.handle(
        const TouchpadSwipeStarted(4, TouchpadSwipe.up),
        TouchpadGestureSettings.fromNative({'fourFingerSlide': -1}),
      );
      expect(keys, isEmpty);
    });
  });

  group('controller', () {
    const gestures = MethodChannel('test/touchpad_gestures');
    const capture = MethodChannel('test/keyboard_capture');
    late List<MethodCall> calls;
    late KeyboardCaptureController targets;
    late TouchpadGestureController controller;
    late Map<String, Object> state;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      calls = [];
      state = {
        'supported': true,
        'threeFingerSlide': 0,
        'threeFingerTap': 0,
        'fourFingerSlide': 1,
        'fourFingerTap': -1,
      };
      messenger.setMockMethodCallHandler(gestures, (call) async {
        calls.add(call);
        return state;
      });
      messenger.setMockMethodCallHandler(capture, (call) async => null);
      targets = KeyboardCaptureController(channel: capture);
      controller = TouchpadGestureController(
        channel: gestures,
        targets: targets,
      );
    });
    tearDown(() {
      controller.dispose();
      targets.dispose();
      messenger.setMockMethodCallHandler(gestures, null);
      messenger.setMockMethodCallHandler(capture, null);
      debugDefaultTargetPlatformOverride = null;
    });

    Future<void> frame(List<TouchpadContact> contacts, int time) =>
        messenger.handlePlatformMessage(
          gestures.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('frame', {
              'contacts': [
                for (final c in contacts) ...[c.id.toDouble(), c.x, c.y],
              ],
              'time': time,
            }),
          ),
          (_) {},
        );

    test('arms for the desktop under the pointer and sends it the keys', () async {
      final keys = <(int, bool)>[];
      controller.attach();
      final target = targets.register((sym, down) => keys.add((sym, down)));
      await pumpEventQueue();
      expect(calls, isEmpty);
      target.update(focused: true, hovered: true);
      await pumpEventQueue();
      expect(calls.single.method, 'configure');
      expect(calls.single.arguments, {'armed': true});
      expect(controller.settings.threeFingerSlide, 0);
      expect(controller.settings.fourFingerTap, isNull);

      // Three fingers up: Win+Tab on the remote computer.
      var time = 0;
      for (var i = 0; i <= 10; i++) {
        await frame(fingers(3, 0, -.02 * i), time += 8);
      }
      await frame(const [], time += 8);
      expect(keys, [
        (_meta, true),
        (_tab, true),
        (_tab, false),
        (_meta, false),
      ]);

      // Four-finger slides belong to this computer here.
      keys.clear();
      for (var i = 0; i <= 10; i++) {
        await frame(fingers(4, .03 * i, 0), time += 8);
      }
      await frame(const [], time += 8);
      expect(keys, isEmpty);

      // Leaving the desktop mid-swipe releases Alt and disarms.
      for (var i = 0; i <= 10; i++) {
        await frame(fingers(3, .02 * i, 0), time += 8);
      }
      expect(keys.first, (_alt, true));
      expect(keys.contains((_alt, false)), isFalse);
      target.update(hovered: false);
      await pumpEventQueue();
      expect(keys.last, (_alt, false));
      expect(calls.last.arguments, {'armed': false});
      keys.clear();
      await frame(fingers(3), time += 8);
      await frame(const [], time += 8);
      expect(keys, isEmpty);
      target.unregister();
    });

    test('settings follow the runner, malformed frames are dropped', () async {
      final keys = <(int, bool)>[];
      controller.attach();
      targets.register((sym, down) => keys.add((sym, down)))
        .update(focused: true, hovered: true);
      await pumpEventQueue();
      await messenger.handlePlatformMessage(
        gestures.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('stateChanged', {'threeFingerTap': 4}),
        ),
        (_) {},
      );
      expect(controller.settings.threeFingerTap, 4);
      await frame(fingers(3), 8);
      await frame(const [], 16);
      expect(keys, isEmpty);
      for (final bad in <Object?>[
        null,
        {'contacts': 'x', 'time': 1},
        {
          'contacts': [1.0, 2.0],
          'time': 1,
        },
        {
          'contacts': [1.0, double.nan, 0.0],
          'time': 1,
        },
        {
          'contacts': [1.0, 0.0, 0.0],
        },
      ]) {
        await messenger.handlePlatformMessage(
          gestures.name,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('frame', bad),
          ),
          (_) {},
        );
      }
      expect(keys, isEmpty);
    });

    test('other platforms never attach', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      controller.attach();
      targets.register((_, _) {}).update(focused: true, hovered: true);
      await pumpEventQueue();
      expect(calls, isEmpty);
    });
  });
}
