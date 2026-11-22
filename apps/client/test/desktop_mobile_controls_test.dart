import 'package:aterm_client/desktop/desktop_mobile_controls.dart';
import 'package:aterm_client/desktop/desktop_keyboard_mode.dart';
import 'package:aterm_client/platform/fullscreen.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/desktop_resolution.dart';
import 'package:aterm_client/desktop/desktop_touch_input.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session extends DesktopSession {
  _Session({
    this.protocol = HostProtocol.rdp,
    this.localScaling = DesktopLocalScaling.fit,
  }) {
    state = 'connected';
    display.layer(0).resize(1000, 800);
  }
  @override
  final HostProtocol protocol;
  @override
  final DesktopLocalScaling localScaling;
  final sent = <List<Object>>[];
  @override
  void send(List<Object> command) => sent.add(command);
  List<List<Object>> get keys => sent.where((e) => e.first == 'key').toList();
}

Future<_Session> _mount(
  WidgetTester tester, {
  TargetPlatform platform = TargetPlatform.android,
  HostProtocol protocol = HostProtocol.rdp,
  DesktopLocalScaling scaling = DesktopLocalScaling.fit,
  bool safeArea = false,
  Locale? locale,
}) async {
  final session = _Session(protocol: protocol, localScaling: scaling);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: locale == null
          ? null
          : AppLocalizationSetup.delegates,
      supportedLocales: locale == null
          ? const [Locale('en', 'US')]
          : AppLocalizationSetup.locales,
      theme: ThemeData(platform: platform),
      builder: (context, child) => DesktopKeyboardViewport(child: child!),
      home: Scaffold(
        body: safeArea
            ? SafeArea(child: DesktopView(session: session))
            : DesktopView(session: session),
      ),
    ),
  );
  await tester.pump();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });
  return session;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
  await tester.pump();
  expect(tester.testTextInput.isVisible, isTrue);
  expect(find.byKey(const ValueKey('desktop_special_keybar')), findsOneWidget);
}

const _imeToggle = ValueKey('desktop_ime_mode_toggle');
const _preedit = ValueKey('desktop_ime_preedit');

List<List<Object>> _strokes(Iterable<int> syms) => [
  for (final sym in syms) ...[
    ['key', sym, 1],
    ['key', sym, 0],
  ],
];

/// What the IME reports while [composing] follows the [committed] text.
void _ime(WidgetTester tester, String committed, [String composing = '']) {
  final start = 1 + committed.length;
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: '\u200b$committed$composing',
      selection: TextSelection.collapsed(offset: start + composing.length),
      composing: composing.isEmpty
          ? TextRange.empty
          : TextRange(start: start, end: start + composing.length),
    ),
  );
}

void main() {
  setUp(() {
    DesktopMobileControlsState.imeMode = DesktopImeMode.composed;
    addTearDown(
      () => DesktopMobileControlsState.imeMode = DesktopImeMode.composed,
    );
    final controller = DesktopKeyboardController();
    DesktopKeyboardController.debugInstance = controller;
    addTearDown(() {
      controller.dispose();
      DesktopKeyboardController.debugInstance = null;
    });
  });
  testWidgets('Android three controls share the same draggable edge dock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(tester);
    final dock = find.byKey(const ValueKey('desktop_edge_dock'));
    final menu = find.byTooltip('Remote desktop menu');
    expect(find.descendant(of: dock, matching: menu), findsOneWidget);
    final keyboard = find.byKey(const ValueKey('desktop_keyboard_toggle'));
    final pointer = find.byKey(const ValueKey('desktop_pointer_mode_toggle'));
    expect(tester.getCenter(menu).dx, tester.getCenter(keyboard).dx);
    expect(tester.getCenter(pointer).dx, tester.getCenter(keyboard).dx);
    await tester.drag(dock, const Offset(-340, 170));
    await tester.pumpAndSettle();
    expect(tester.getRect(dock).left, 0);
    expect(tester.getCenter(menu).dx, tester.getCenter(keyboard).dx);
    // Top/bottom edges use a horizontal strip.
    await tester.drag(dock, const Offset(190, -360));
    await tester.pumpAndSettle();
    expect(tester.getRect(dock).top, 0);
    expect(tester.getCenter(menu).dy, tester.getCenter(keyboard).dy);
    expect(tester.getCenter(pointer).dy, tester.getCenter(keyboard).dy);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Send Ctrl+Alt+Delete'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Android dock opens and closes actual IME client plus special keys',
    (tester) async {
      final session = await _mount(tester);
      expect(
        find.byKey(const ValueKey('desktop_special_keybar')),
        findsNothing,
      );
      await _open(tester);
      expect(
        session.sent.where((e) => e.first == 'mouse' && e.last == 1),
        isEmpty,
        reason: 'Dock taps must never click the remote desktop',
      );
      await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('desktop_special_keybar')),
        findsNothing,
      );
      expect(tester.testTextInput.hasAnyClients, isFalse);
    },
  );

  testWidgets(
    'trackpad starts with the same visible local and remote pointer position',
    (tester) async {
      final session = await _mount(tester);
      await tester.tap(
        find.byKey(const ValueKey('desktop_pointer_mode_toggle')),
      );
      await tester.pump();
      expect(session.display.pointer, const Offset(500, 400));
      expect(session.sent.last, ['mouse', 500, 400, 0]);
      expect(
        session.sent.where((p) => p.first == 'mouse' && p.last == 1),
        isEmpty,
      );
    },
  );

  testWidgets('Android RDP taps, holds, then drags from the remote cursor', (
    tester,
  ) async {
    final session = await _mount(tester);
    await tester.tap(find.byKey(const ValueKey('desktop_pointer_mode_toggle')));
    await tester.pump();
    session.sent.clear();
    const start = Offset(300, 300);
    final tap = await tester.startGesture(start);
    await tap.up(timeStamp: const Duration(milliseconds: 40));
    expect(session.sent, [
      ['mouse', 500, 400, 1],
      ['mouse', 500, 400, 0],
    ]);
    session.sent.clear();

    // A second contact lands farther away and the finger rests before dragging.
    final drag = await tester.createGesture();
    await drag.down(
      const Offset(460, 270),
      timeStamp: const Duration(milliseconds: 440),
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(session.sent.where((event) => event.first == 'mouse'), isEmpty);
    await drag.moveBy(
      const Offset(45, 30),
      timeStamp: const Duration(milliseconds: 1140),
    );
    await drag.up(timeStamp: const Duration(milliseconds: 1200));
    expect(session.sent.where((event) => event.first == 'mouse'), [
      ['mouse', 500, 400, 1],
      ['mouse', 560, 440, 1],
      ['mouse', 560, 440, 0],
    ]);
  });

  testWidgets(
    'IME preedit stays local; committed CJK, uppercase and emoji send once',
    (tester) async {
      final session = await _mount(tester);
      await _open(tester);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200bzhong',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 1, end: 6),
        ),
      );
      await tester.pump();
      expect(session.keys, isEmpty);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '\u200b中A😀',
          selection: TextSelection.collapsed(offset: 5),
        ),
      );
      await tester.pump();
      expect(session.keys, [
        ['key', 0x01004e2d, 1],
        ['key', 0x01004e2d, 0],
        ['key', 0x01000041, 1],
        ['key', 0x01000041, 0],
        ['key', 0x0101f600, 1],
        ['key', 0x0101f600, 0],
      ]);
      expect(tester.testTextInput.editingState!['text'], '\u200b');
    },
  );

  testWidgets(
    'VNC preserves standard Latin-1 keysyms and extends only CJK/emoji',
    (tester) async {
      final session = await _mount(tester, protocol: HostProtocol.vnc);
      await _open(tester);
      tester.testTextInput.enterText('aAé中😀');
      await tester.pump();
      expect(session.keys, [
        for (final code in [97, 65, 233, 0x01004e2d, 0x0101f600]) ...[
          ['key', code, 1],
          ['key', code, 0],
        ],
      ]);
    },
  );
  testWidgets('IME Backspace and newline generate real desktop key strokes', (
    tester,
  ) async {
    final session = await _mount(tester);
    await _open(tester);
    tester.testTextInput.updateEditingValue(TextEditingValue.empty);
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();
    expect(session.keys, [
      ['key', 0xff08, 1],
      ['key', 0xff08, 0],
      ['key', 0xff0d, 1],
      ['key', 0xff0d, 0],
    ]);
  });

  testWidgets('soft Ctrl is one-shot, double tap locks, closing releases it', (
    tester,
  ) async {
    final session = await _mount(tester);
    await _open(tester);
    final ctrl = find.byKey(const ValueKey('desktop_key_65507'));
    await tester.tap(ctrl);
    await tester.pump();
    tester.testTextInput.enterText('\u200bc');
    await tester.pump();
    expect(session.keys, [
      ['key', 0xffe3, 1],
      ['key', 99, 1],
      ['key', 99, 0],
      ['key', 0xffe3, 0],
    ]);
    session.sent.clear();
    await tester.tap(ctrl);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(ctrl);
    await tester.pump();
    tester.testTextInput.enterText('\u200bc');
    await tester.pump();
    tester.testTextInput.enterText('\u200bc');
    await tester.pump();
    expect(session.keys.where((e) => e[1] == 0xffe3), [
      ['key', 0xffe3, 1],
    ]);
    await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
    await tester.pump();
    expect(session.keys.last, ['key', 0xffe3, 0]);
  });

  testWidgets('dock stays on edge when dragged, resized and IME opens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(tester);
    final dock = find.byKey(const ValueKey('desktop_edge_dock'));
    expect(tester.getRect(dock).right, 390);
    await tester.drag(dock, const Offset(-300, 200));
    await tester.pump();
    expect(tester.getRect(dock).left, 0);
    await _open(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.pump();
    final rect = tester.getRect(dock);
    expect(rect.left, 0);
    expect(rect.bottom, lessThanOrEqualTo(428));
    expect(
      tester
          .getRect(find.byKey(const ValueKey('desktop_special_keybar')))
          .bottom,
      524,
    );
    expect(tester.takeException(), isNull);
  });

  group('slide handle under the overlaid keyboard', () {
    final handle = find.byKey(const ValueKey('desktop_keyboard_pan'));

    Future<Offset> remoteAt(
      WidgetTester tester,
      _Session session,
      Offset point,
    ) async {
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 400));
      final report = session.sent.lastWhere(
        (e) => e.first == 'mouse' || e.first == 'touch',
      );
      final index = report.first == 'mouse' ? 1 : 3;
      return Offset(
        (report[index] as int).toDouble(),
        (report[index + 1] as int).toDouble(),
      );
    }

    Future<double> remoteY(
      WidgetTester tester,
      _Session session,
      double y,
    ) async => (await remoteAt(tester, session, Offset(195, y))).dy;

    Future<_Session> openOverKeyboard(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await DesktopKeyboardController.instance.select(
        DesktopKeyboardMode.overlay,
      );
      final session = await _mount(tester);
      await tester.pump(const Duration(milliseconds: 300));
      expect(handle, findsNothing, reason: 'nothing is covered yet');
      await _open(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return session;
    }

    testWidgets('appears while the keyboard covers the picture and slides it '
        'without resizing the remote', (tester) async {
      final session = await openOverKeyboard(tester);
      // 1000x800 remote fitted to 390 wide: picture is 390x312 at y 266..578;
      // keyboard (320) and key bar (96) leave y < 428 visible, 150 is hidden.
      expect(handle, findsOneWidget);
      final keybar = tester.getRect(
        find.byKey(const ValueKey('desktop_special_keybar')),
      );
      expect(tester.getRect(handle).bottom, lessThanOrEqualTo(keybar.top));
      session.sent.clear();

      // Before sliding, the last visible row shows remote y of about 410.
      expect(await remoteY(tester, session, 426), closeTo(410, 4));

      // Drag the handle up: the picture follows, up to what was hidden.
      await tester.drag(handle, const Offset(0, -90));
      await tester.pump();
      expect(await remoteY(tester, session, 426), closeTo(410 + 90 / .39, 4));
      await tester.drag(handle, const Offset(0, -500));
      await tester.pump();
      // The bottom edge of the remote screen now sits right above the bar.
      expect(await remoteY(tester, session, 426), closeTo(795, 5));
      // ...and it cannot be pulled further up than that.
      await tester.drag(handle, const Offset(0, -300));
      await tester.pump();
      expect(await remoteY(tester, session, 426), closeTo(795, 5));

      // Dragging down brings the top back.
      await tester.drag(handle, const Offset(0, 500));
      await tester.pump();
      expect(await remoteY(tester, session, 426), closeTo(410, 4));

      expect(
        session.sent.where((e) => e.first == 'size'),
        isEmpty,
        reason: 'sliding never changes the remote resolution',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('works in mouse (touchpad) mode and goes away with the '
        'keyboard', (tester) async {
      final session = await openOverKeyboard(tester);
      await tester.tap(
        find.byKey(const ValueKey('desktop_pointer_mode_toggle')),
      );
      await tester.pump();
      expect(handle, findsOneWidget);
      session.sent.clear();
      await tester.drag(handle, const Offset(0, -120));
      await tester.pump();
      // Sliding is local: no pointer, key or size traffic to the remote.
      expect(session.sent, isEmpty);
      final semantics = tester.getSemantics(handle);
      expect(semantics.label, 'Slide the remote screen');
      expect(semantics.value, '80%');

      // Closing the keyboard uncovers everything: no handle, picture back.
      await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(handle, findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('desktop_pointer_mode_toggle')),
      );
      await tester.pump();
      expect(await remoteY(tester, session, 422), closeTo(400, 4));
    });

    testWidgets(
      'floating Android IME can pan a fitted RDP picture on both axes '
      'even when the keyboard reports zero inset',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final session = await _mount(tester);
        await tester.pump(const Duration(milliseconds: 300));
        await _open(tester);
        await tester.pump();
        expect(
          find.descendant(of: handle, matching: find.byIcon(Icons.open_with)),
          findsOneWidget,
        );
        final bar = find.byKey(const ValueKey('desktop_special_keybar'));
        final keybarRect = tester.getRect(bar);
        const point = Offset(195, 422);
        final before = await remoteAt(tester, session, point);
        _ime(tester, '', 'zhong');
        await tester.pump();
        session.sent.clear();
        await tester.drag(handle, const Offset(39, -39));
        await tester.pump();
        expect(session.sent, isEmpty);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(
          find.descendant(
            of: find.byKey(_preedit),
            matching: find.text('zhong'),
          ),
          findsOneWidget,
        );
        expect(tester.getRect(bar), keybarRect);
        final moved = await remoteAt(tester, session, point);
        expect(moved.dx, closeTo(before.dx - 100, 1));
        expect(moved.dy, closeTo(before.dy + 100, 1));
        await tester.drag(handle, const Offset(-78, 78));
        await tester.pump();
        final reversed = await remoteAt(tester, session, point);
        expect(reversed.dx, closeTo(before.dx + 100, 1));
        expect(reversed.dy, closeTo(before.dy - 100, 1));
        _ime(tester, '中');
        await tester.pump();
        expect(session.keys, _strokes([0x01004e2d]));
        expect(session.sent.where((e) => e.first == 'size'), isEmpty);
        await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
        await tester.pump();
        expect(handle, findsNothing);
        expect(await remoteAt(tester, session, point), before);
      },
    );

    testWidgets('landscape actual-size pan reaches both remote edges and keeps '
        'the grip reachable above a tall Android keyboard', (tester) async {
      tester.view.physicalSize = const Size(800, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = await _mount(
        tester,
        scaling: DesktopLocalScaling.actualSize,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await _open(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 335);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('desktop_special_keybar')),
          matching: handle,
        ),
        findsOneWidget,
      );
      expect(tester.getRect(handle).bottom, lessThanOrEqualTo(85));
      session.sent.clear();
      await tester.drag(handle, const Offset(-1200, -1200));
      await tester.pump();
      expect(session.sent, isEmpty);
      // The 800 x 37 visible area is now at (200, 763) in the 1000 x 800 desktop.
      expect(
        await remoteAt(tester, session, const Offset(300, 20)),
        const Offset(500, 783),
      );
      await tester.drag(handle, const Offset(1200, 1200));
      await tester.pump();
      expect(
        await remoteAt(tester, session, const Offset(300, 20)),
        const Offset(300, 20),
      );
      expect(tester.testTextInput.isVisible, isTrue);
      expect(session.sent.where((e) => e.first == 'size'), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a keyboard that resizes the view covers nothing: no handle', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await DesktopKeyboardController.instance.select(
        DesktopKeyboardMode.resize,
      );
      await _mount(tester);
      await tester.pump(const Duration(milliseconds: 300));
      await _open(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(handle, findsNothing);
    });
  });

  for (final mode in DesktopKeyboardMode.values) {
    testWidgets('Android $mode keyboard viewport and remote size policy', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await DesktopKeyboardController.instance.select(mode);
      final session = await _mount(tester);
      await tester.pump(const Duration(milliseconds: 300));
      final surface = find.byKey(const ValueKey('desktop_remote_surface'));
      final original = tester.getSize(surface);
      session.sent.clear();
      await _open(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final requests = session.sent.where((e) => e.first == 'size').toList();
      if (mode == DesktopKeyboardMode.overlay) {
        expect(tester.getSize(surface), original);
        expect(
          requests,
          isEmpty,
          reason: 'IME and special keys must not resize the remote desktop',
        );
      } else {
        expect(tester.getSize(surface).height, original.height - 320 - 96);
        expect(requests.last, ['size', 390, 428]);
      }
      expect(
        tester
            .getRect(find.byKey(const ValueKey('desktop_special_keybar')))
            .bottom,
        524,
      );
      await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(surface), original);
      expect(DesktopKeyboardController.instance.overlayActive, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  for (final initialBottom in [0.0, 56.0]) {
    testWidgets('overlay retains pre-IME safe area (bottom=$initialBottom)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      if (initialBottom == 0) {
        final fullscreen = FullscreenController(
          supported: true,
          read: () async => true,
          changes: const Stream.empty(),
          apply: (v) async => v,
        )..enabled = true;
        FullscreenController.debugInstance = fullscreen;
        addTearDown(() {
          fullscreen.dispose();
          FullscreenController.debugInstance = null;
        });
      }
      tester.view.viewPadding = FakeViewPadding(bottom: initialBottom);
      tester.view.padding = FakeViewPadding(bottom: initialBottom);
      addTearDown(tester.view.reset);
      final session = await _mount(tester, safeArea: true);
      await tester.pump(const Duration(milliseconds: 300));
      final surface = find.byKey(const ValueKey('desktop_remote_surface'));
      final before = tester.getSize(surface);
      session.sent.clear();
      await _open(tester);
      tester.view.viewPadding = const FakeViewPadding(bottom: 56);
      tester.view.viewInsets = const FakeViewPadding(bottom: 356);
      tester.view.padding = const FakeViewPadding();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(surface), before);
      expect(session.sent.where((e) => e.first == 'size'), isEmpty);
      await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
      // Visibility notification precedes Android's closing IME animation.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(surface), before);
      expect(session.sent.where((e) => e.first == 'size'), isEmpty);
      tester.view.viewInsets = const FakeViewPadding();
      // IME dismissal can leave the fullscreen navigation bar transiently visible.
      tester.view.padding = const FakeViewPadding(bottom: 56);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getSize(surface), before);
      expect(session.sent.where((e) => e.first == 'size'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'phone keeps arrows visible and wide key labels scroll; each key has one actionable semantics node',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final semantics = tester.ensureSemantics();
      try {
        await _mount(tester);
        await _open(tester);
        for (final code in [65507, 65361, 65362, 65363, 65364]) {
          final rect = tester.getRect(
            find.byKey(ValueKey('desktop_key_$code')),
          );
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(390));
        }
        final ctrl = tester.getSemantics(
          find.byKey(const ValueKey('desktop_key_65507')),
        );
        expect(ctrl.label, 'Ctrl');
        expect(ctrl.value, 'Off');
        expect(ctrl.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        // Ahem/large fonts make word labels wider than Roboto. Keep the
        // 390px case and prove those keys remain reachable without shrinking.
        final delete = find.byKey(const ValueKey('desktop_key_65535'));
        await tester.ensureVisible(delete);
        await tester.pump();
        expect(tester.getRect(delete).right, lessThanOrEqualTo(390));
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'two split panes own independent IME clients and release old Ctrl on focus switch',
    (tester) async {
      final a = _Session(), b = _Session();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: DesktopView(session: a)),
                Expanded(child: DesktopView(session: b)),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final toggles = find.byKey(const ValueKey('desktop_keyboard_toggle'));
      await tester.tap(toggles.first);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('desktop_key_65507')));
      await tester.pump();
      await tester.tap(toggles.last);
      await tester.pump();
      await tester.pump();
      expect(a.keys.last, ['key', 0xffe3, 0]);
      tester.testTextInput.enterText('\u200bb');
      await tester.pump();
      expect(b.keys, [
        ['key', 0x01000062, 1],
        ['key', 0x01000062, 0],
      ]);
      expect(a.keys.where((e) => e[1] == 0x01000062), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await a.close();
      await b.close();
    },
  );

  testWidgets(
    'desktop platforms preserve physical-keyboard view without mobile dock',
    (tester) async {
      await _mount(tester, platform: TargetPlatform.windows);
      expect(find.byType(DesktopMobileControls), findsNothing);
    },
  );

  testWidgets(
    'disconnection closes keyboard and prevents subsequent IME sends',
    (tester) async {
      final session = await _mount(tester);
      await _open(tester);
      session.state = 'error';
      session.notifyListeners();
      await tester.pump();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(
        find.byKey(const ValueKey('desktop_special_keybar')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('one dock tap activates an excluded pane before IME input', (
    tester,
  ) async {
    final session = _Session();
    var inactive = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Listener(
              onPointerDown: (_) => setState(() => inactive = false),
              child: ExcludeFocus(
                excluding: inactive,
                child: DesktopView(session: session),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await _open(tester);
    await tester.pump();
    tester.testTextInput.enterText('A');
    await tester.pump();
    expect(session.keys, [
      ['key', 0x01000041, 1],
      ['key', 0x01000041, 0],
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
    await session.close();
  });

  testWidgets('app pause releases soft modifiers and the IME connection', (
    tester,
  ) async {
    final session = await _mount(tester);
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('desktop_key_65507')));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(session.keys.last, ['key', 0xffe3, 0]);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  });

  group('soft keyboard input modes', () {
    testWidgets('input-method mode is the default and lets every IME compose', (
      tester,
    ) async {
      await _mount(tester);
      await _open(tester);
      final config = tester.testTextInput.setClientArgs!;
      // Android maps disabled suggestions to a visible-password field, where
      // IMEs offer only their Latin keyboard.
      expect(config['enableSuggestions'], isTrue);
      expect(config['autocorrect'], isFalse);
      expect(config['enableIMEPersonalizedLearning'], isFalse);
      expect(config['obscureText'], isFalse);
      expect((config['inputType'] as Map)['name'], 'TextInputType.multiline');
      expect(config['inputAction'], 'TextInputAction.newline');
      expect(tester.testTextInput.editingState!['text'], '\u200b');
      expect(find.byKey(_preedit), findsNothing);
    });

    testWidgets(
      'direct mode keeps the Latin-only configuration and is remembered',
      (tester) async {
        final session = await _mount(tester);
        await _open(tester);
        await tester.tap(find.byKey(_imeToggle));
        await tester.pump();
        expect(DesktopMobileControlsState.imeMode, DesktopImeMode.direct);
        var config = tester.testTextInput.setClientArgs!;
        expect(config['enableSuggestions'], isFalse);
        expect(config['autocorrect'], isFalse);
        expect(config['enableIMEPersonalizedLearning'], isFalse);
        expect((config['inputType'] as Map)['name'], 'TextInputType.multiline');
        expect(tester.testTextInput.isVisible, isTrue);
        expect(session.keys, isEmpty);
        // Every key the IME reports is sent at once.
        tester.testTextInput.enterText('\u200bl');
        tester.testTextInput.enterText('\u200bs');
        tester.testTextInput.updateEditingValue(TextEditingValue.empty);
        await tester.pump();
        expect(session.keys, _strokes([0x0100006c, 0x01000073, 0xff08]));
        // Closing and reopening keeps the chosen mode.
        await tester.tap(find.byKey(const ValueKey('desktop_keyboard_toggle')));
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isFalse);
        await _open(tester);
        config = tester.testTextInput.setClientArgs!;
        expect(config['enableSuggestions'], isFalse);
        await tester.tap(find.byKey(_imeToggle));
        await tester.pump();
        expect(DesktopMobileControlsState.imeMode, DesktopImeMode.composed);
        expect(
          tester.testTextInput.setClientArgs!['enableSuggestions'],
          isTrue,
        );
      },
    );

    testWidgets(
      'composing shows a local preedit bubble and sends only on commit (RDP)',
      (tester) async {
        final session = await _mount(tester);
        await _open(tester);
        tester.testTextInput.log.clear();
        for (final pinyin in ['n', 'ni', 'nih', 'nihao']) {
          _ime(tester, '', pinyin);
          await tester.pump();
          expect(session.keys, isEmpty);
          expect(
            find.descendant(
              of: find.byKey(_preedit),
              matching: find.text(pinyin),
            ),
            findsOneWidget,
          );
        }
        // The IME's own buffer is never rewritten while it composes.
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
        );
        final bubble = tester.getRect(find.byKey(_preedit));
        final bar = tester.getRect(
          find.byKey(const ValueKey('desktop_special_keybar')),
        );
        expect(bubble.bottom, lessThanOrEqualTo(bar.top));
        expect(bar.top - bubble.bottom, lessThan(16));
        _ime(tester, '你好');
        await tester.pump();
        expect(session.keys, _strokes([0x01004f60, 0x0100597d]));
        expect(find.byKey(_preedit), findsNothing);
        expect(tester.testTextInput.editingState!['text'], '\u200b');
        expect(
          session.sent.where((e) => e.first == 'mouse'),
          isEmpty,
          reason: 'the bubble never forwards touches',
        );
      },
    );

    testWidgets('VNC commit uses Latin-1 keysyms and Unicode keysyms above', (
      tester,
    ) async {
      final session = await _mount(tester, protocol: HostProtocol.vnc);
      await _open(tester);
      _ime(tester, '', 'nihao');
      await tester.pump();
      expect(session.keys, isEmpty);
      expect(find.byKey(_preedit), findsOneWidget);
      _ime(tester, '你好a é');
      await tester.pump();
      expect(session.keys, _strokes([0x01004f60, 0x0100597d, 97, 32, 233]));
      expect(find.byKey(_preedit), findsNothing);
    });

    testWidgets(
      'text committed in front of a new composition is sent once, in order',
      (tester) async {
        final session = await _mount(tester);
        await _open(tester);
        _ime(tester, '', 'nihaoshijie');
        await tester.pump();
        tester.testTextInput.log.clear();
        // The IME commits the first word and keeps composing the rest.
        _ime(tester, '你好', 'shijie');
        await tester.pump();
        expect(session.keys, _strokes([0x01004f60, 0x0100597d]));
        expect(
          find.descendant(
            of: find.byKey(_preedit),
            matching: find.text('shijie'),
          ),
          findsOneWidget,
        );
        expect(
          tester.testTextInput.log.where(
            (call) => call.method == 'TextInput.setEditingState',
          ),
          isEmpty,
          reason: 'resetting the buffer would end the running composition',
        );
        // More preedit changes repeat nothing.
        _ime(tester, '你好', 'shi');
        await tester.pump();
        expect(session.keys, hasLength(4));
        _ime(tester, '你好世界');
        await tester.pump();
        expect(
          session.keys,
          _strokes([0x01004f60, 0x0100597d, 0x01004e16, 0x0100754c]),
        );
        expect(find.byKey(_preedit), findsNothing);
        expect(tester.testTextInput.editingState!['text'], '\u200b');
        // The next commit starts from a clean buffer.
        _ime(tester, '！');
        await tester.pump();
        expect(session.keys.skip(8), _strokes([0x0100ff01]));
      },
    );

    testWidgets(
      'a sent character the IME takes back becomes Backspace; an abandoned composition sends nothing',
      (tester) async {
        final session = await _mount(tester);
        await _open(tester);
        _ime(tester, '', 'ni');
        await tester.pump();
        // Composition deleted again: only the sentinel is left.
        _ime(tester, '');
        await tester.pump();
        expect(session.keys, isEmpty);
        expect(find.byKey(_preedit), findsNothing);
        _ime(tester, '你好', 'ma');
        await tester.pump();
        session.sent.clear();
        _ime(tester, '你');
        await tester.pump();
        expect(session.keys, _strokes([0xff08]));
      },
    );

    testWidgets('Backspace at an empty field and Enter work in both modes', (
      tester,
    ) async {
      final session = await _mount(tester);
      await _open(tester);
      for (final mode in DesktopImeMode.values) {
        expect(DesktopMobileControlsState.imeMode, mode);
        session.sent.clear();
        tester.testTextInput.updateEditingValue(TextEditingValue.empty);
        await tester.pump();
        expect(tester.testTextInput.editingState!['text'], '\u200b');
        tester.testTextInput.updateEditingValue(TextEditingValue.empty);
        tester.testTextInput.enterText('\u200b\n');
        await tester.testTextInput.receiveAction(TextInputAction.newline);
        await tester.pump();
        expect(session.keys, _strokes([0xff08, 0xff08, 0xff0d, 0xff0d]));
        await tester.tap(find.byKey(_imeToggle));
        await tester.pump();
      }
    });

    testWidgets('a committed ASCII word and Enter type correctly', (
      tester,
    ) async {
      final session = await _mount(tester);
      await _open(tester);
      for (final word in ['l', 'ls']) {
        _ime(tester, '', word);
        await tester.pump();
      }
      _ime(tester, 'ls ');
      await tester.pump();
      _ime(tester, '', '-la');
      await tester.pump();
      expect(session.keys, _strokes('ls '.runes.map((r) => 0x01000000 | r)));
      _ime(tester, '-la\n');
      await tester.pump();
      expect(
        session.keys,
        _strokes([
          for (final rune in 'ls -la'.runes) 0x01000000 | rune,
          0xff0d,
        ]),
      );
    });

    testWidgets(
      'a soft modifier sends the composing Latin key at once as a shortcut',
      (tester) async {
        final session = await _mount(tester);
        await _open(tester);
        await tester.tap(find.byKey(const ValueKey('desktop_key_65507')));
        await tester.pump();
        _ime(tester, '', 'c');
        await tester.pump();
        expect(session.keys, [
          ['key', 0xffe3, 1],
          ['key', 99, 1],
          ['key', 99, 0],
          ['key', 0xffe3, 0],
        ]);
        expect(find.byKey(_preedit), findsNothing);
        expect(tester.testTextInput.editingState!['text'], '\u200b');
        // The one-shot modifier is used up: typing composes again.
        session.sent.clear();
        _ime(tester, '', 'c');
        await tester.pump();
        expect(session.keys, isEmpty);
        expect(find.byKey(_preedit), findsOneWidget);
      },
    );

    testWidgets(
      'switching modes while open keeps the keyboard, drops the composition and sends nothing',
      (tester) async {
        final session = await _mount(tester);
        await _open(tester);
        _ime(tester, '你', 'hao');
        await tester.pump();
        expect(session.keys, _strokes([0x01004f60]));
        session.sent.clear();
        tester.testTextInput.log.clear();
        await tester.tap(find.byKey(_imeToggle));
        await tester.pump();
        expect(session.sent, isEmpty);
        expect(find.byKey(_preedit), findsNothing);
        expect(tester.testTextInput.isVisible, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(
          find.byKey(const ValueKey('desktop_special_keybar')),
          findsOneWidget,
        );
        final calls = tester.testTextInput.log.map((call) => call.method);
        expect(calls, isNot(contains('TextInput.clearClient')));
        expect(calls, isNot(contains('TextInput.hide')));
        expect(calls, contains('TextInput.setClient'));
        expect(
          tester.testTextInput.setClientArgs!['enableSuggestions'],
          isFalse,
        );
        expect(tester.testTextInput.editingState, {
          ...const TextEditingValue(
            text: '\u200b',
            selection: TextSelection.collapsed(offset: 1),
          ).toJSON(),
        });
        // The new client starts clean: nothing of the old buffer is diffed.
        tester.testTextInput.enterText('\u200ba');
        await tester.pump();
        expect(session.keys, _strokes([0x01000061]));
        // Back to the input method with a locked modifier still held.
        session.sent.clear();
        await tester.tap(find.byKey(_imeToggle));
        await tester.pump();
        expect(session.sent, isEmpty);
        expect(
          tester.testTextInput.setClientArgs!['enableSuggestions'],
          isTrue,
        );
        expect(tester.testTextInput.isVisible, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    for (final (code, composedTip, directTip, composedValue, directValue) in [
      (
        'en',
        'Switch to direct keys: every key is sent at once, Latin only',
        'Switch to input method: type Chinese, Japanese and other languages',
        'Input method mode',
        'Direct key mode',
      ),
      (
        'zh',
        '切换为直接按键：每个按键立即发送，仅限英文',
        '切换为输入法：可输入中文、日文等各种语言',
        '输入法模式',
        '直接按键模式',
      ),
      (
        'ja',
        '直接キー入力に切り替え：キーをすぐに送信、英字のみ',
        'IME 入力に切り替え：日本語や中国語などを入力できます',
        'IME 入力モード',
        '直接キー入力モード',
      ),
      (
        'ru',
        'Переключить на прямой ввод: каждая клавиша отправляется сразу, только латиница',
        'Переключить на метод ввода: китайский, японский и другие языки',
        'Режим метода ввода',
        'Режим прямого ввода клавиш',
      ),
    ]) {
      testWidgets('the mode button and key bar fit 390 px ($code)', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final semantics = tester.ensureSemantics();
        try {
          await _mount(tester, locale: Locale(code));
          await _open(tester);
          final toggle = find.byKey(_imeToggle);
          final bar = tester.getRect(
            find.byKey(const ValueKey('desktop_special_keybar')),
          );
          expect(bar.left, 0);
          expect(bar.right, 390);
          expect(bar.height, 96);
          for (final (tip, value, icon) in [
            (composedTip, composedValue, Icons.translate),
            (directTip, directValue, Icons.abc),
          ]) {
            // Reachable without scrolling, at least 48 px, inside the bar.
            final rect = tester.getRect(toggle);
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(390));
            expect(rect.size, const Size(48, 48));
            expect(bar.contains(rect.center), isTrue);
            expect(
              find.descendant(of: toggle, matching: find.byIcon(icon)),
              findsOneWidget,
            );
            expect(find.byTooltip(tip), findsOneWidget);
            final node = tester.getSemantics(toggle);
            expect(node.label, tip);
            expect(node.value, value);
            expect(
              node.getSemanticsData().hasAction(SemanticsAction.tap),
              isTrue,
            );
            // The common keys stay on screen next to it.
            for (final sym in [65507, 65361, 65362, 65363, 65364]) {
              final key = tester.getRect(
                find.byKey(ValueKey('desktop_key_$sym')),
              );
              expect(key.left, greaterThanOrEqualTo(0));
              expect(key.right, lessThanOrEqualTo(390));
              expect(key.overlaps(rect), isFalse);
            }
            // A long composition stays inside the pane.
            _ime(tester, '', 'w' * 80);
            await tester.pump();
            final bubble = tester.getRect(find.byKey(_preedit));
            expect(bubble.left, greaterThanOrEqualTo(0));
            expect(bubble.right, lessThanOrEqualTo(390));
            expect(bubble.bottom, lessThanOrEqualTo(bar.top));
            expect(tester.takeException(), isNull);
            await tester.tap(toggle);
            await tester.pump();
            expect(find.byKey(_preedit), findsNothing);
          }
          // Scrolling the keys never moves the mode button away.
          await tester.drag(
            find.byKey(const ValueKey('desktop_key_65507')),
            const Offset(-300, 0),
          );
          await tester.pump();
          expect(tester.getRect(toggle).left, 0);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }

    testWidgets('a short pane keeps the mode button on its single key row', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 240);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _mount(tester);
      await _open(tester);
      await tester.pump();
      final bar = tester.getRect(
        find.byKey(const ValueKey('desktop_special_keybar')),
      );
      expect(bar.height, 48);
      final rect = tester.getRect(find.byKey(_imeToggle));
      expect(rect.left, 0);
      expect(bar.contains(rect.center), isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('relative touchpad', () {
    late Offset point;
    late List<(Offset, int)> events;
    late List<(Offset, int, int)> wheel;
    late DesktopTouchInput input;
    void handle(PointerEvent e) =>
        input.handle(e, bounds: const Rect.fromLTWH(0, 0, 500, 500), scale: 2);
    setUp(() {
      point = const Offset(100, 100);
      events = [];
      wheel = [];
      input = DesktopTouchInput(
        pointer: () => point,
        send: (p, b) {
          point = p;
          events.add((p, b));
        },
        scroll: (p, dx, dy) => wheel.add((p, dx, dy)),
      )..trackpad = true;
    });
    tearDown(() => input.dispose());
    test('one-finger motion is relative and sends no pressed button', () {
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerMoveEvent(pointer: 1, position: Offset(320, 340)));
      handle(const PointerUpEvent(pointer: 1, position: Offset(320, 340)));
      expect(point, const Offset(110, 120));
      expect(events.map((e) => e.$2), [0]);
    });
    test('tap clicks current cursor without jumping to touched position', () {
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerUpEvent(pointer: 1, position: Offset(300, 300)));
      expect(events, [
        (const Offset(100, 100), 1),
        (const Offset(100, 100), 0),
      ]);
    });
    test('a two-finger tap after a click only sends the right button', () {
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerUpEvent(pointer: 1));
      events.clear();
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerDownEvent(pointer: 2, position: Offset(320, 300)));
      handle(const PointerUpEvent(pointer: 1));
      handle(const PointerUpEvent(pointer: 2));
      expect(events.map((e) => e.$2), [4, 0]);
      expect(wheel, isEmpty);
    });
    test('two-finger scrolling follows the fingers and locks to one axis', () {
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerDownEvent(pointer: 2, position: Offset(320, 300)));
      handle(const PointerMoveEvent(pointer: 1, position: Offset(300, 345)));
      handle(const PointerMoveEvent(pointer: 2, position: Offset(375, 300)));
      handle(const PointerUpEvent(pointer: 1));
      handle(const PointerUpEvent(pointer: 2));
      expect(wheel, [(const Offset(100, 100), 0, 120)]);

      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerDownEvent(pointer: 2, position: Offset(320, 300)));
      handle(const PointerMoveEvent(pointer: 1, position: Offset(345, 290)));
      handle(const PointerUpEvent(pointer: 2));
      handle(const PointerMoveEvent(pointer: 1, position: Offset(400, 300)));
      handle(const PointerUpEvent(pointer: 1));
      expect(wheel.last, (const Offset(100, 100), -120, 0));
      expect(wheel, hasLength(2));
      expect(events, isEmpty);
    });
    test('second tap and drag holds button; cancel releases and clears it', () {
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      handle(const PointerUpEvent(pointer: 1));
      events.clear();
      handle(const PointerDownEvent(pointer: 2, position: Offset(300, 300)));
      handle(const PointerMoveEvent(pointer: 2, position: Offset(330, 300)));
      handle(const PointerCancelEvent(pointer: 2));
      expect(events.map((e) => e.$2), [1, 1, 0]);
      expect(point, const Offset(115, 100));
    });
    testWidgets('stationary long-press right-clicks once', (tester) async {
      handle(const PointerDownEvent(pointer: 1, position: Offset(300, 300)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 10));
      handle(const PointerUpEvent(pointer: 1));
      expect(events.map((e) => e.$2), [4, 0]);
    });
  });
}
