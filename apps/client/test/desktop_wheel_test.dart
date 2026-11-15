import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/desktop/desktop_wheel.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/direct/rdp_io.dart';
import 'package:aterm_client/desktop/direct/rfb.dart';
import 'package:aterm_client/desktop/keyboard_capture.dart';
import 'package:aterm_client/desktop/window/desktop_window.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/terminal/live_terminal_window.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';

/// A connected 1000×800 desktop that records what the view sends.
class _Session extends DesktopSession {
  _Session() {
    state = 'connected';
    display.layer(0).resize(1000, 800);
  }
  final sent = <List<Object>>[];
  @override
  void send(List<Object> command) => sent.add(command);
  List<List<Object>> of(String type) =>
      sent.where((e) => e.first == type).toList();

  /// Wheel commands that turn the wheel (the end marker left out).
  List<List<Object>> get turns =>
      of('wheel').where((e) => e[3] != 0 || e[4] != 0).toList();
}

class _Fake implements DirectDesktopConnection {
  final controller = StreamController<DesktopEvent>();
  final sent = <List<Object>>[];
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  void send(List<Object> command) => sent.add(command);
  @override
  void paste(String text) {}
  @override
  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }
}

class _Reader {
  _Reader(Stream<List<int>> stream) : iterator = StreamIterator(stream);
  final StreamIterator<List<int>> iterator;
  final bytes = <int>[];
  Future<List<int>> read(int n) async {
    while (bytes.length < n) {
      if (!await iterator.moveNext()) throw StateError('Client disconnected');
      bytes.addAll(iterator.current);
    }
    final result = bytes.sublist(0, n);
    bytes.removeRange(0, n);
    return result;
  }
}

Future<void> _until(bool Function() condition, {required String what}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Mounts a view that fills an 800×640 window, so a 1000×800 desktop is
/// shown at 0.8 and the window centre is the remote point (500, 400).
Future<_Session> _mount(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.windows,
  double devicePixelRatio = 1,
  Rect? viewport,
}) async {
  tester.view.physicalSize = const Size(800, 640) * devicePixelRatio;
  tester.view.devicePixelRatio = devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final capture = KeyboardCaptureController();
  KeyboardCaptureController.debugInstance = capture;
  final session = _Session();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: Scaffold(
        body: DesktopView(session: session, viewport: viewport),
      ),
    ),
  );
  await tester.pump();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
    KeyboardCaptureController.debugInstance = null;
    capture.dispose();
  });
  session.sent.clear();
  return session;
}

const _centre = Offset(400, 320);

void main() {
  group('wheel units', () {
    test('a local notch is 120 units on every platform', () {
      DesktopWheelScale scale(
        TargetPlatform platform, {
        double ratio = 1,
        int? lines,
        bool web = false,
      }) => DesktopWheelScale.of(
        platform: platform,
        web: web,
        devicePixelRatio: ratio,
        windowsScrollLines: lines,
      );
      // Windows: lines × 100 / 3 physical pixels per notch.
      expect(scale(TargetPlatform.windows).ofScroll(const Offset(0, 100)), (
        0.0,
        -120.0,
      ));
      final scaled = scale(
        TargetPlatform.windows,
        ratio: 1.5,
      ).ofScroll(const Offset(0, 100 / 1.5));
      expect(scaled.$2, closeTo(-120, 1e-9));
      final sixLines = scale(
        TargetPlatform.windows,
        lines: 6,
      ).ofScroll(const Offset(0, -200));
      expect(sixLines.$2, closeTo(120, 1e-9));
      // "One screen at a time" (WHEEL_PAGESCROLL) is still one notch.
      final page = scale(
        TargetPlatform.windows,
        lines: 0xFFFFFFFF,
      ).ofScroll(const Offset(0, 0xFFFFFFFF * 100 / 3));
      expect(page.$2, closeTo(-120, 1e-6));
      expect(scale(TargetPlatform.linux).ofScroll(const Offset(53, 0)), (
        120.0,
        -0.0,
      ));
      expect(
        scale(TargetPlatform.macOS).ofScroll(const Offset(0, -40)).$2,
        120,
      );
      expect(
        scale(
          TargetPlatform.linux,
          web: true,
        ).ofScroll(const Offset(0, 100)).$2,
        -120,
      );
      // macOS acceleration and browsers can report a wheel click as far
      // less than a notch: there a click of a mouse wheel is one notch at
      // least, on the axis it turned on; touchpad amounts stay as they are.
      for (final uncertain in [
        scale(TargetPlatform.macOS),
        scale(TargetPlatform.windows, web: true),
      ]) {
        final click = uncertain.ofScroll(
          const Offset(0.2, 4),
          wheelClick: true,
        );
        expect(click.$2, -120);
        expect(click.$1.abs(), lessThan(1));
        expect(uncertain.ofScroll(const Offset(-4, 0), wheelClick: true), (
          -120.0,
          -0.0,
        ));
        expect(
          uncertain.ofScroll(const Offset(0, -400), wheelClick: true).$2,
          greaterThan(400),
        );
        expect(uncertain.ofScroll(const Offset(0, 4)).$2.abs(), lessThan(20));
        expect(uncertain.ofScroll(Offset.zero, wheelClick: true), (0.0, -0.0));
      }
      // Windows and Linux report exact amounts: part of a notch stays that.
      expect(
        scale(TargetPlatform.windows)
            .ofScroll(const Offset(0, 25), wheelClick: true),
        (0.0, -30.0),
      );
      expect(
        scale(TargetPlatform.linux)
            .ofScroll(const Offset(0, 5.3), wheelClick: true)
            .$2,
        closeTo(-12, 1e-9),
      );
      // A touchpad pans in physical pixels on Windows; content follows the
      // fingers, so panning down scrolls up and panning right scrolls left.
      final pan = scale(
        TargetPlatform.windows,
        ratio: 2,
      ).ofPan(const Offset(50, 25));
      expect(pan.$1, closeTo(-120, 1e-9));
      expect(pan.$2, closeTo(60, 1e-9));
    });

    test('the accumulator sends whole units and carries the rest', () {
      final wheel = DesktopWheelAccumulator();
      expect(wheel.add(0, 0.3), isNull);
      expect(wheel.add(0, 0.3), (0, 1)); // 0.6 rounds up, -0.4 is carried
      expect(wheel.add(0, 0.3), isNull); // -0.1
      expect(wheel.add(0, 0.7), (0, 1)); // 0.6
      var total = 0;
      wheel.reset();
      for (var i = 0; i < 100; i++) {
        total += wheel.add(0, -1.23)?.$2 ?? 0;
      }
      expect(total, -123);
      // Rounding noise of a notch never loses a unit.
      wheel.reset();
      expect(wheel.add(119.99999999, -119.99999999), (120, -120));
      // A reset forgets the remainder.
      expect(wheel.add(0.4, 0), isNull);
      wheel.reset();
      expect(wheel.add(0.4, 0), isNull);
      // One command never carries more than its limit, and the excess is
      // not replayed afterwards.
      expect(wheel.add(1e9, -1e9), (
        DesktopWheelUnits.maxPerCommand,
        -DesktopWheelUnits.maxPerCommand,
      ));
      expect(wheel.add(0, 0), isNull);
      expect(wheel.add(double.nan, 1), isNull);
    });

    test('notch transports send one notch per 120 units', () {
      final notches = DesktopWheelNotches();
      expect(notches.add(0, 60), isEmpty);
      expect(notches.add(0, 59), isEmpty);
      expect(notches.add(0, 1), [DesktopWheelUnits.notchUp]);
      expect(notches.add(0, -360), [
        DesktopWheelUnits.notchDown,
        DesktopWheelUnits.notchDown,
        DesktopWheelUnits.notchDown,
      ]);
      expect(notches.add(120, 0), [DesktopWheelUnits.notchRight]);
      expect(notches.add(-240, 0), [
        DesktopWheelUnits.notchLeft,
        DesktopWheelUnits.notchLeft,
      ]);
      // Both deltas 0 end the gesture: the count starts again.
      expect(notches.add(0, 100), isEmpty);
      expect(notches.add(0, 0), isEmpty);
      expect(notches.add(0, 100), isEmpty);
      expect(notches.add(0, 20), [DesktopWheelUnits.notchUp]);
      // Without a horizontal wheel sideways units are dropped.
      final vertical = DesktopWheelNotches(horizontal: false);
      expect(vertical.add(600, 0), isEmpty);
      expect(vertical.add(600, -120), [DesktopWheelUnits.notchDown]);
      // The bits are RFB buttons 4-7 and clear of the mouse buttons.
      expect(
        [
          DesktopWheelUnits.notchUp,
          DesktopWheelUnits.notchDown,
          DesktopWheelUnits.notchLeft,
          DesktopWheelUnits.notchRight,
        ],
        [1 << 3, 1 << 4, 1 << 5, 1 << 6],
      );
    });

    test('a touchpad gesture is a scroll or a pinch, never both', () {
      final gesture = DesktopTouchpadGesture();
      const none = (pan: Offset.zero, zoom: 0);
      // Not started: nothing.
      expect(gesture.update(const Offset(0, 50), 1), none);
      gesture.start();
      expect(gesture.update(const Offset(0, 3), 1.001), none);
      expect(gesture.scrolling, isFalse);
      // Past the slop everything panned so far is scrolled.
      expect(gesture.update(const Offset(0, 8), 1.002).pan, const Offset(0, 8));
      expect(gesture.scrolling, isTrue);
      // A scroll stays a scroll whatever the scale does afterwards.
      expect(gesture.update(const Offset(2, 9), 1.5), (
        pan: const Offset(2, 1),
        zoom: 0,
      ));
      gesture.end();
      expect(gesture.update(const Offset(2, 90), 3), none);

      gesture.start();
      expect(gesture.update(const Offset(1, 1), 1.05), none);
      expect(gesture.scrolling, isFalse);
      expect(gesture.update(const Offset(30, 30), 1.16), (
        pan: Offset.zero,
        zoom: 1,
      ));
      // Wavering around a step neither repeats nor undoes it.
      expect(gesture.update(Offset.zero, 1.14).zoom, 0);
      expect(gesture.update(Offset.zero, 1.16).zoom, 0);
      expect(gesture.update(Offset.zero, 1.55).zoom, 2);
      expect(gesture.update(Offset.zero, 0.8).zoom, -4);
      // A scale that is no number changes nothing.
      expect(gesture.update(Offset.zero, double.nan), none);
      expect(gesture.update(Offset.zero, 0), none);
      expect(gesture.update(Offset.zero, 1).zoom, 1);
      gesture.end();

      // A zoom about a point far from the window's corner comes with the pan
      // that keeps the point in place (here (700, 500) × (1 - scale)). Within
      // the window's reach that pan is no scroll; the pinch is recognised
      // once the scale has changed enough.
      gesture.start();
      expect(gesture.update(const Offset(-7, -5), 1.01, reach: 1000), none);
      expect(gesture.update(const Offset(-14, -10), 1.02, reach: 1000), none);
      expect(gesture.scrolling, isFalse);
      expect(gesture.update(const Offset(-112, -80), 1.16, reach: 1000), (
        pan: Offset.zero,
        zoom: 1,
      ));
      gesture.end();
      // Pan far beyond what the scale accounts for is a scroll.
      gesture.start();
      expect(gesture.update(const Offset(0, 40), 1.01, reach: 1000), (
        pan: const Offset(0, 40),
        zoom: 0,
      ));
      gesture.end();

      // Scale signals (browser pinch) are relative to the previous event.
      expect(gesture.scaleSignal(1.1), 0);
      expect(gesture.scaleSignal(1.1), 1);
      expect(gesture.scaleSignal(0.5), -4);
      expect(gesture.scaleSignal(0), 0);
    });

    test('wheel command validation', () {
      expect(DesktopWheelUnits.valid(0, 0), isTrue);
      expect(DesktopWheelUnits.valid(-3840, 3840), isTrue);
      expect(DesktopWheelUnits.valid(3841, 0), isFalse);
      expect(DesktopWheelUnits.valid(0, -3841), isFalse);
      expect(DesktopWheelUnits.valid(1.5, 0), isFalse);
      expect(DesktopWheelUnits.valid(null, 0), isFalse);
      expect(DesktopWheelUnits.valid('1', 0), isFalse);
    });
  });

  group('RDP engine', () {
    test('an engine with aterm_rdp_wheel gets the units as they are', () {
      final wheel = <List<int>>[], mouse = <List<int>>[];
      void apply(List<Object> command) => rdpWheel(
        command,
        wheel: (x, y, dx, dy) => wheel.add([x, y, dx, dy]),
        mouse: (x, y, buttons) => mouse.add([x, y, buttons]),
        notches: DesktopWheelNotches(horizontal: false),
        buttons: 1,
      );
      apply(['wheel', 10, 20, 0, 7]);
      apply(['wheel', 10, 20, -300, 0]);
      apply(['wheel', 10, 20, 0, 0]); // end of gesture: nothing to send
      expect(wheel, [
        [10, 20, 0, 7],
        [10, 20, -300, 0],
      ]);
      expect(mouse, isEmpty);
    });

    test('an older engine gets one vertical notch per 120 units', () {
      final mouse = <List<int>>[];
      final notches = DesktopWheelNotches(horizontal: false);
      void apply(List<Object> command, {int buttons = 0}) => rdpWheel(
        command,
        wheel: null,
        mouse: (x, y, mask) => mouse.add([x, y, mask]),
        notches: notches,
        buttons: buttons,
      );
      apply(['wheel', 10, 20, 0, 50]);
      apply(['wheel', 10, 20, 0, 50]);
      expect(mouse, isEmpty);
      apply(['wheel', 11, 21, 0, 50]);
      expect(mouse, [
        [11, 21, 8],
      ]);
      mouse.clear();
      // The held button stays in the packet; sideways units are dropped.
      // 30 units up were left over, so 270 down make two notches.
      apply(['wheel', 12, 22, 500, -270], buttons: 1);
      expect(mouse, [
        [12, 22, 1 | 16],
        [12, 22, 1 | 16],
      ]);
      mouse.clear();
      // The end of the gesture forgets what was counted.
      apply(['wheel', 12, 22, 0, 100]);
      apply(['wheel', 12, 22, 0, 0]);
      apply(['wheel', 12, 22, 0, 100]);
      expect(mouse, isEmpty);
    });
  });

  group('DesktopView', () {
    testWidgets('a two-finger pan scrolls in proportion, on both axes', (
      tester,
    ) async {
      final session = await _mount(tester);
      final touchpad = TestPointer(7, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
      // Below the slop nothing is sent.
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, pan: const Offset(0, 4)),
      );
      expect(session.sent, isEmpty);
      // 10 pixels down are 12 of the 120 units of a notch, upwards: content
      // follows the fingers. The wheel turns under the pointer.
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, pan: const Offset(0, 10)),
      );
      expect(session.sent, [
        ['wheel', 500, 400, 0, 12],
      ]);
      // The fraction of a unit is carried: 0.5 px is 0.6 units.
      session.sent.clear();
      for (var pan = 10.5; pan <= 12.5; pan += 0.5) {
        await tester.sendEventToBinding(
          touchpad.panZoomUpdate(_centre, pan: Offset(0, pan)),
        );
      }
      expect(session.turns.map((e) => e[4]), [1, 1, 1]);
      // Fingers up and to the right scroll down and to the left.
      session.sent.clear();
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, pan: const Offset(25, -37.5)),
      );
      expect(session.sent, [
        ['wheel', 500, 400, -30, -60],
      ]);
      // The end of the gesture tells notch-counting transports to forget
      // what they had counted; nothing is held.
      session.sent.clear();
      await tester.sendEventToBinding(touchpad.panZoomEnd());
      expect(session.sent, [
        ['wheel', 500, 400, 0, 0],
      ]);
      expect(session.of('key'), isEmpty);
      expect(session.of('mouse'), isEmpty);
    });

    testWidgets('a touchpad pans in physical pixels on a scaled display', (
      tester,
    ) async {
      final session = await _mount(tester, devicePixelRatio: 2);
      final touchpad = TestPointer(7, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, pan: const Offset(0, 50)),
      );
      await tester.sendEventToBinding(touchpad.panZoomEnd());
      expect(session.turns, [
        ['wheel', 500, 400, 0, 120],
      ]);
    });

    testWidgets('a mouse wheel turns as far as the device said', (
      tester,
    ) async {
      final session = await _mount(tester);
      final mouse = TestPointer(3, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(_centre));
      session.sent.clear();
      // One notch down, one notch up.
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -100)));
      // A tilt wheel or horizontal wheel, right then left.
      await tester.sendEventToBinding(mouse.scroll(const Offset(100, 0)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(-100, 0)));
      // A free-spinning wheel reports a quarter notch; a fast one three.
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 25)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 300)));
      expect(session.sent, [
        ['wheel', 500, 400, 0, -120],
        ['wheel', 500, 400, 0, 120],
        ['wheel', 500, 400, 120, 0],
        ['wheel', 500, 400, -120, 0],
        ['wheel', 500, 400, 0, -30],
        ['wheel', 500, 400, 0, -360],
      ]);
      // The wheel never touches buttons or keys.
      expect(session.of('mouse'), isEmpty);
      expect(session.of('key'), isEmpty);
    });

    testWidgets('a wheel notch is 120 units on a scaled Windows display', (
      tester,
    ) async {
      final session = await _mount(tester, devicePixelRatio: 1.5);
      final mouse = TestPointer(3, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(_centre));
      session.sent.clear();
      // 100 physical pixels are 66.67 logical ones.
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100 / 1.5)));
      expect(session.sent, [
        ['wheel', 500, 400, 0, -120],
      ]);
    });

    testWidgets('a pinch holds Ctrl and turns the wheel a notch per step', (
      tester,
    ) async {
      final session = await _mount(tester);
      final touchpad = TestPointer(7, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
      // The centre of a pinch wanders a little; that never scrolls.
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, pan: const Offset(1, 2), scale: 1.05),
      );
      expect(session.sent, isEmpty);
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, pan: const Offset(9, 12), scale: 1.2),
      );
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, pan: const Offset(9, 30), scale: 1.6),
      );
      // Back below the start: three steps in undone, one step out.
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, scale: 0.85),
      );
      await tester.sendEventToBinding(touchpad.panZoomEnd());
      expect(session.sent, [
        ['key', 0xffe3, 1],
        ['wheel', 500, 400, 0, 120],
        ['wheel', 500, 400, 0, 240],
        ['wheel', 500, 400, 0, -480],
        ['key', 0xffe3, 0],
      ]);
    });

    testWidgets('the pan that comes with a zoom about a point never scrolls', (
      tester,
    ) async {
      final session = await _mount(tester);
      final touchpad = TestPointer(7, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
      // A zoom that keeps the window point (700, 500) in place.
      for (final scale in [1.005, 1.01, 1.02, 1.1, 1.2]) {
        await tester.sendEventToBinding(
          touchpad.panZoomUpdate(
            _centre,
            pan: const Offset(700, 500) * (1 - scale),
            scale: scale,
          ),
        );
      }
      await tester.sendEventToBinding(touchpad.panZoomEnd());
      expect(session.sent, [
        ['key', 0xffe3, 1],
        ['wheel', 500, 400, 0, 120],
        ['key', 0xffe3, 0],
      ]);
    });

    testWidgets('a slow wheel click on macOS is still one notch', (
      tester,
    ) async {
      final session = await _mount(tester, platform: TargetPlatform.macOS);
      final mouse = TestPointer(3, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(_centre));
      session.sent.clear();
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 4)));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
      expect(session.sent, [
        ['wheel', 500, 400, 0, -120],
        ['wheel', 500, 400, 0, 360],
      ]);
    });

    testWidgets('scale noise of a two-finger scroll never zooms', (
      tester,
    ) async {
      final session = await _mount(tester);
      final touchpad = TestPointer(7, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, pan: const Offset(0, 20), scale: 1.004),
      );
      // Once it scrolls, even a large scale change stays a scroll.
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, pan: const Offset(0, 120), scale: 1.4),
      );
      await tester.sendEventToBinding(touchpad.panZoomEnd());
      expect(session.of('key'), isEmpty);
      expect(session.turns, [
        ['wheel', 500, 400, 0, 24],
        ['wheel', 500, 400, 0, 120],
      ]);
    });

    testWidgets('losing the focus in the middle of a pinch releases Ctrl', (
      tester,
    ) async {
      final session = await _mount(tester);
      final touchpad = TestPointer(7, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, scale: 1.2),
      );
      expect(session.of('key'), [
        ['key', 0xffe3, 1],
      ]);
      FocusManager.instance.primaryFocus!.unfocus();
      await tester.pump();
      expect(session.of('key'), [
        ['key', 0xffe3, 1],
        ['key', 0xffe3, 0],
      ]);
      // The rest of that gesture does nothing: Ctrl is not pressed again.
      session.sent.clear();
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, scale: 2),
      );
      await tester.sendEventToBinding(touchpad.panZoomEnd());
      expect(session.of('key'), isEmpty);
      expect(session.of('wheel'), isEmpty);
    });

    testWidgets('a cancelled pointer or a closed view releases Ctrl', (
      tester,
    ) async {
      final session = await _mount(tester);
      final touchpad = TestPointer(7, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, scale: 1.2),
      );
      // A mouse button of the same view is cancelled (window deactivated).
      final mouse = TestPointer(3, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.down(_centre));
      await tester.sendEventToBinding(mouse.cancel());
      expect(session.of('key'), [
        ['key', 0xffe3, 1],
        ['key', 0xffe3, 0],
      ]);
      await tester.sendEventToBinding(touchpad.panZoomEnd());
      // A new pinch, and the view goes away under it.
      session.sent.clear();
      await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, scale: 0.8),
      );
      expect(session.sent, [
        ['key', 0xffe3, 1],
        ['wheel', 500, 400, 0, -120],
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(session.of('key'), [
        ['key', 0xffe3, 1],
        ['key', 0xffe3, 0],
      ]);
    });

    testWidgets('a pinch that rests lets go of Ctrl until it zooms again', (
      tester,
    ) async {
      final session = await _mount(tester);
      final touchpad = TestPointer(7, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, scale: 1.2),
      );
      await tester.pump(const Duration(milliseconds: 900));
      expect(session.of('key'), [
        ['key', 0xffe3, 1],
      ]);
      // No end of the gesture arrives; a second later Ctrl is up anyway.
      await tester.pump(const Duration(milliseconds: 200));
      expect(session.of('key'), [
        ['key', 0xffe3, 1],
        ['key', 0xffe3, 0],
      ]);
      // The same gesture goes on: Ctrl is pressed for the next step only.
      session.sent.clear();
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, scale: 1.4),
      );
      await tester.sendEventToBinding(touchpad.panZoomEnd());
      expect(session.sent, [
        ['key', 0xffe3, 1],
        ['wheel', 500, 400, 0, 120],
        ['key', 0xffe3, 0],
      ]);
    });

    testWidgets('a Ctrl the user holds is used and left to the user', (
      tester,
    ) async {
      final session = await _mount(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      expect(session.sent, [
        ['key', 0xffe3, 1],
      ]);
      session.sent.clear();
      final touchpad = TestPointer(7, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, scale: 1.2),
      );
      await tester.sendEventToBinding(touchpad.panZoomEnd());
      expect(session.sent, [
        ['wheel', 500, 400, 0, 120],
      ]);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(session.of('key'), [
        ['key', 0xffe3, 0],
      ]);
    });

    testWidgets('a browser pinch (scale signal) is Ctrl+wheel at once', (
      tester,
    ) async {
      final session = await _mount(tester);
      final mouse = TestPointer(3, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(_centre));
      session.sent.clear();
      await tester.sendEventToBinding(mouse.scale(1.05));
      expect(session.sent, isEmpty);
      await tester.sendEventToBinding(mouse.scale(1.12));
      expect(session.sent, [
        ['key', 0xffe3, 1],
        ['wheel', 500, 400, 0, 120],
        ['key', 0xffe3, 0],
      ]);
    });

    testWidgets('leaving the view forgets the fraction of a unit', (
      tester,
    ) async {
      final session = await _mount(tester);
      final mouse = TestPointer(3, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(_centre));
      session.sent.clear();
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -0.3)));
      expect(session.sent, isEmpty);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -50)));
      expect(session.sent, [
        ['wheel', 500, 400, 0, 60],
      ]);
      // Outside: the end marker goes out once; inside again, a new count.
      session.sent.clear();
      await tester.sendEventToBinding(mouse.hover(const Offset(2000, 2000)));
      await tester.pump();
      expect(session.of('wheel'), [
        ['wheel', 500, 400, 0, 0],
      ]);
      await tester.sendEventToBinding(mouse.hover(_centre));
      await tester.pump();
      session.sent.clear();
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -0.3)));
      expect(session.of('wheel'), isEmpty);
    });

    testWidgets('a monitor window sends the wheel at its own remote point', (
      tester,
    ) async {
      final session = await _mount(
        tester,
        viewport: const Rect.fromLTWH(500, 0, 500, 800),
      );
      final touchpad = TestPointer(7, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
      await tester.sendEventToBinding(
        touchpad.panZoomUpdate(_centre, pan: const Offset(0, -100)),
      );
      expect(session.sent, [
        ['wheel', 750, 400, 0, -120],
      ]);
    });

    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('$platform keeps its wheel and ignores touchpad gestures', (
        tester,
      ) async {
        final session = await _mount(tester, platform: platform);
        final mouse = TestPointer(3, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(mouse.hover(_centre));
        session.sent.clear();
        // One vertical notch per event whatever the delta, as before.
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, 300)));
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, -5)));
        await tester.sendEventToBinding(mouse.scale(2));
        expect(session.sent, [
          ['mouse', 500, 400, 16],
          ['mouse', 500, 400, 0],
          ['mouse', 500, 400, 8],
          ['mouse', 500, 400, 0],
        ]);
        session.sent.clear();
        final touchpad = TestPointer(7, PointerDeviceKind.trackpad);
        await tester.sendEventToBinding(touchpad.panZoomStart(_centre));
        await tester.sendEventToBinding(
          touchpad.panZoomUpdate(_centre, pan: const Offset(80, 200), scale: 2),
        );
        await tester.sendEventToBinding(touchpad.panZoomEnd());
        expect(session.sent, isEmpty);
      });
    }
  });

  group('transports', () {
    useAppLocaleFixture('en');
    // The binding mocks HttpClient; these tests need real loopback sockets.
    setUp(() => HttpOverrides.global = null);

    test('VNC presses buttons 4-7 once per notch, with held buttons', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.first;
      final connection = RfbConnection.connect('127.0.0.1', server.port, '');
      // The connection has one listener for its whole life.
      final ready = Completer<void>();
      connection.events.listen((event) {
        if (event is DesktopReady && !ready.isCompleted) ready.complete();
      }, onError: (_) {});
      final socket = await accepted;
      final client = _Reader(socket);
      addTearDown(() async {
        await connection.close();
        socket.destroy();
        await server.close();
      });
      socket.add('RFB 003.008\n'.codeUnits);
      await client.read(12);
      socket.add([1, 1]); // security: None
      expect(await client.read(1), [1]);
      socket.add([0, 0, 0, 0]);
      expect(await client.read(1), [1]);
      socket.add(
        (ByteData(24)
              ..setUint16(0, 640)
              ..setUint16(2, 480))
            .buffer
            .asUint8List(),
      );
      await client.read(20 + 28 + 10); // format, encodings, first request
      await ready.future;
      List<int> pointer(int mask, int x, int y) => [
        5,
        mask,
        x >> 8,
        x & 255,
        y >> 8,
        y & 255,
      ];
      // Less than a notch: nothing. The third command completes it.
      connection.send(['wheel', 300, 200, 0, 50]);
      connection.send(['wheel', 300, 200, 0, 50]);
      connection.send(['wheel', 301, 201, 0, 50]);
      expect(await client.read(12), [
        ...pointer(8, 301, 201),
        ...pointer(0, 301, 201),
      ]);
      // The end of the gesture drops the 30 units left over, so these 100
      // units up are 20 short of a notch.
      connection.send(['wheel', 301, 201, 0, 0]);
      connection.send(['wheel', 301, 201, 0, 100]);
      // A held left button stays down through the notches; horizontal
      // notches are buttons 6 (left) and 7 (right).
      connection.send(['mouse', 10, 20, 1]);
      connection.send(['wheel', 10, 20, -120, -340]);
      connection.send(['wheel', 10, 20, 120, 0]);
      expect(await client.read(6 + 12 * 4), [
        ...pointer(1, 10, 20),
        ...pointer(1 | 16, 10, 20),
        ...pointer(1, 10, 20),
        ...pointer(1 | 16, 10, 20),
        ...pointer(1, 10, 20),
        ...pointer(1 | 32, 10, 20),
        ...pointer(1, 10, 20),
        ...pointer(1 | 64, 10, 20),
        ...pointer(1, 10, 20),
      ]);
    });

    test('the gateway gets Guacamole scroll buttons, vertical only', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = StringBuffer();
      Socket? peer;
      final accepted = server.first.then((socket) {
        peer = socket;
        socket.listen((bytes) => received.write(utf8.decode(bytes)));
      });
      final session = DesktopSession();
      addTearDown(() async {
        // The peer goes first: closing the session waits for its socket.
        peer?.destroy();
        await server.close();
        await session.close();
      });
      await session.connectLocal(
        const HostRecord(
          id: 'v',
          name: 'V',
          address: 'v',
          protocol: HostProtocol.vnc,
        ),
        guacdPort: server.port,
      );
      await accepted;
      await _until(
        () => received.toString().contains('select'),
        what: 'the gateway handshake',
      );
      received.clear();
      session.send(['mouse', 7, 9, 1]); // left button held
      session.send(['wheel', 7, 9, 0, 60]);
      session.send(['wheel', 7, 9, 4000, 60]); // one notch up; sideways dropped
      session.send(['wheel', 7, 9, 0, -100]);
      session.send(['wheel', 7, 9, 0, 0]); // end: the 100 units are dropped
      session.send(['wheel', 7, 9, 0, -240]);
      session.send(['key', 97, 1]);
      await _until(
        () => received.toString().contains('3.key'),
        what: 'the instructions',
      );
      expect(
        received.toString(),
        '5.mouse,1.7,1.9,1.1;'
        '5.mouse,1.7,1.9,1.9;'
        '5.mouse,1.7,1.9,1.1;'
        '5.mouse,1.7,1.9,2.17;'
        '5.mouse,1.7,1.9,1.1;'
        '5.mouse,1.7,1.9,2.17;'
        '5.mouse,1.7,1.9,1.1;'
        '3.key,2.97,1.1;',
      );
      // No instruction the gateway does not know ever leaves the client.
      expect(received.toString(), isNot(contains('wheel')));
    });

    Future<(DesktopSession, _Fake)> connected() async {
      final fake = _Fake();
      final session = DesktopSession(directConnectionForTesting: (_) => fake);
      await session.connectLocal(
        const HostRecord(
          id: 'r',
          name: 'R',
          address: 'r',
          protocol: HostProtocol.rdp,
        ),
      );
      var acked = 0;
      fake.controller.add(
        DesktopFrame(64, 48, Uint8List(64 * 48 * 4), onConsumed: () => acked++),
      );
      await _until(
        () => acked == 1 && session.state == 'connected',
        what: 'the first frame',
      );
      return (session, fake);
    }

    test('a direct session passes wheel commands to its connection', () async {
      final (session, fake) = await connected();
      session.send(['wheel', 3, 4, -7, 9]);
      expect(fake.sent, [
        ['wheel', 3, 4, -7, 9],
      ]);
      await session.close();
    });

    test('a detached window forwards validated wheel commands', () async {
      final (session, fake) = await connected();
      final broker = await DesktopWindowBroker.bind(
        session: session,
        spec: const DesktopWindowSpec(title: 'Win'),
      );
      final child = await connectDesktopWindow(broker.launch);
      child.confirmReady();
      expect(await broker.ready, isTrue);
      child.send(['key', 0xffe3, 1]);
      child.send(['wheel', 10, 12, 0, 120]);
      child.send(['wheel', 64, 48, -3840, 3840]);
      child.send(['wheel', 10, 12, 0, 0]);
      child.send(['key', 0xffe3, 0]);
      await _until(() => fake.sent.length >= 5, what: 'the input');
      expect(fake.sent, [
        ['key', 0xffe3, 1],
        ['wheel', 10, 12, 0, 120],
        ['wheel', 64, 48, -3840, 3840],
        ['wheel', 10, 12, 0, 0],
        ['key', 0xffe3, 0],
      ]);
      await broker.close();
      await session.close();
    });

    for (final (name, message) in <(String, Map<String, Object?>)>[
      ('too many units', {'x': 1, 'y': 1, 'dx': 3841, 'dy': 0}),
      ('too many units down', {'x': 1, 'y': 1, 'dx': 0, 'dy': -3841}),
      ('a fractional delta', {'x': 1, 'y': 1, 'dx': 0, 'dy': 1.5}),
      ('a text delta', {'x': 1, 'y': 1, 'dx': '1', 'dy': 0}),
      ('a missing delta', {'x': 1, 'y': 1, 'dy': 120}),
      ('a point outside the desktop', {'x': 65, 'y': 1, 'dx': 0, 'dy': 120}),
      ('a negative point', {'x': 1, 'y': -1, 'dx': 0, 'dy': 120}),
      ('a missing point', {'dx': 0, 'dy': 120}),
    ]) {
      test('a detached window is closed for $name', () async {
        final (session, fake) = await connected();
        final broker = await DesktopWindowBroker.bind(
          session: session,
          spec: const DesktopWindowSpec(title: 'Win'),
        );
        final launch = broker.launch;
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:${launch.port}/desktop/${launch.sessionId}',
          protocols: const ['atermius-desktop-v1'],
          headers: {
            'Origin': 'atermius://desktop-window',
            'Authorization': 'Bearer ${launch.capability}',
          },
          compression: CompressionOptions.compressionOff,
        );
        socket.listen((_) {}, onError: (_) {});
        socket.add(jsonEncode({'type': 'ready'}));
        expect(await broker.ready, isTrue);
        // A well-formed command of the same raw client is accepted.
        socket.add(
          jsonEncode({'type': 'wheel', 'x': 1, 'y': 1, 'dx': 0, 'dy': 120}),
        );
        await _until(() => fake.sent.isNotEmpty, what: 'the valid command');
        socket.add(jsonEncode({'type': 'wheel', ...message}));
        expect(
          await broker.outcome,
          LiveTerminalWindowCloseReason.transportLost,
        );
        expect(fake.sent, [
          ['wheel', 1, 1, 0, 120],
        ]);
        await socket.close();
        await session.close();
      });
    }

    test(
      'a detached window is closed for a wheel before it is ready',
      () async {
        final (session, fake) = await connected();
        final broker = await DesktopWindowBroker.bind(
          session: session,
          spec: const DesktopWindowSpec(title: 'Win'),
        );
        final launch = broker.launch;
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:${launch.port}/desktop/${launch.sessionId}',
          protocols: const ['atermius-desktop-v1'],
          headers: {
            'Origin': 'atermius://desktop-window',
            'Authorization': 'Bearer ${launch.capability}',
          },
          compression: CompressionOptions.compressionOff,
        );
        socket.listen((_) {}, onError: (_) {});
        socket.add(
          jsonEncode({'type': 'wheel', 'x': 1, 'y': 1, 'dx': 0, 'dy': 120}),
        );
        expect(
          await broker.outcome,
          LiveTerminalWindowCloseReason.transportLost,
        );
        expect(fake.sent, isEmpty);
        await socket.close();
        await session.close();
      },
    );

    test('an unconfirmed mirror keeps wheel commands to itself', () async {
      final (session, fake) = await connected();
      final broker = await DesktopWindowBroker.bind(
        session: session,
        spec: const DesktopWindowSpec(title: 'Win'),
      );
      final child = await connectDesktopWindow(broker.launch);
      // Not confirmed: the mirror keeps the command to itself.
      child.send(['wheel', 10, 12, 0, 120]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(fake.sent, isEmpty);
      await child.close();
      await broker.close();
      await session.close();
    });
  });
}
