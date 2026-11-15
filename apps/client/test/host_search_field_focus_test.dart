import 'package:aterm_client/domain/quick_connect.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/ui/host_search_field.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _field = ValueKey('home_search');
const _other = ValueKey('other_field');

/// A page like the home pages: the search field, something focusable that is
/// not a text field, and another text field.
class _Home extends StatefulWidget {
  const _Home({this.captureTyping = true, this.active = true, this.pageIndex});

  final bool captureTyping;
  final bool active;

  /// When set, the page is child 0 of an IndexedStack showing this index.
  final int? pageIndex;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final controller = TextEditingController();
  final changes = <String>[];
  final connects = <QuickConnectRequest>[];
  var submits = 0;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = Column(
      children: [
        HostSearchField(
          fieldKey: _field,
          controller: controller,
          captureTyping: widget.captureTyping,
          active: widget.active,
          onChanged: (value) => setState(() => changes.add(value)),
          onConnect: connects.add,
          onSearchSubmitted: () => submits++,
        ),
        ElevatedButton(onPressed: () {}, child: const Text('host card')),
        const TextField(key: _other),
      ],
    );
    final index = widget.pageIndex;
    return Scaffold(
      body: index == null
          ? page
          : IndexedStack(
              index: index,
              children: [page, const Text('terminal')],
            ),
    );
  }
}

Future<_HomeState> _pump(WidgetTester tester, _Home home) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
  await tester.pump();
  return tester.state<_HomeState>(find.byType(_Home));
}

bool _focused(WidgetTester tester, Key key) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(key, skipOffstage: false),
        matching: find.byType(EditableText, skipOffstage: false),
      ),
    )
    .focusNode
    .hasFocus;

Future<void> _type(WidgetTester tester, LogicalKeyboardKey key, String c) =>
    tester.sendKeyEvent(key, character: c);

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    testWidgets('the home search field has the focus on $platform', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      await _pump(tester, const _Home());
      expect(_focused(tester, _field), isTrue);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('no focus by default on $platform (on-screen keyboard)', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      await _pump(tester, const _Home());
      expect(_focused(tester, _field), isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('a field that does not capture typing is left alone', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final home = await _pump(tester, const _Home(captureTyping: false));
    expect(_focused(tester, _field), isFalse);
    await _type(tester, LogicalKeyboardKey.keyA, 'a');
    await tester.pump();
    expect(home.controller.text, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('typing with the focus elsewhere goes into the search', (
    tester,
  ) async {
    // Android: nothing is focused at first, as after a click on the page.
    final home = await _pump(tester, const _Home());
    await tester.tap(find.text('host card'));
    await tester.pump();
    expect(_focused(tester, _field), isFalse);

    await _type(tester, LogicalKeyboardKey.keyW, 'w');
    await tester.pump();
    expect(home.controller.text, 'w');
    expect(home.controller.selection, const TextSelection.collapsed(offset: 1));
    expect(home.changes, ['w']);
    expect(_focused(tester, _field), isTrue);

    // From here on the focused field receives ordinary text input; the key
    // handler must not add the characters a second time.
    await _type(tester, LogicalKeyboardKey.keyE, 'e');
    await tester.pump();
    expect(home.controller.text, 'w');
    tester.testTextInput.enterText('web');
    await tester.pump();
    expect(home.controller.text, 'web');
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    testWidgets('captured typing continues behind the existing text '
        'on $platform', (tester) async {
      // Desktop text fields select everything when they gain the focus; the
      // second captured character must not replace the first.
      debugDefaultTargetPlatformOverride = platform;
      final home = await _pump(tester, const _Home());
      await tester.enterText(find.byKey(_field), 'ab');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(_focused(tester, _field), isFalse);

      await _type(tester, LogicalKeyboardKey.keyC, 'c');
      await tester.pump();
      expect(home.controller.text, 'abc');
      expect(_focused(tester, _field), isTrue);
      expect(
        home.controller.selection,
        const TextSelection.collapsed(offset: 3),
      );
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('non-ASCII characters and AltGr combinations are text', (
    tester,
  ) async {
    final home = await _pump(tester, const _Home());
    await _type(tester, LogicalKeyboardKey.keyA, '中');
    await tester.pump();
    expect(home.controller.text, '中');

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altRight);
    await _type(tester, LogicalKeyboardKey.keyQ, '@');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(home.controller.text, '中@');
  });

  testWidgets('shortcuts, spaces and control keys are not captured', (
    tester,
  ) async {
    final home = await _pump(tester, const _Home());

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await _type(tester, LogicalKeyboardKey.keyA, 'a');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await _type(tester, LogicalKeyboardKey.keyF, 'f');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await _type(tester, LogicalKeyboardKey.keyK, 'k');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await _type(tester, LogicalKeyboardKey.space, ' ');
    await _type(tester, LogicalKeyboardKey.enter, '\r');
    await _type(tester, LogicalKeyboardKey.tab, '\t');
    await _type(tester, LogicalKeyboardKey.backspace, '\b');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(home.controller.text, isEmpty);
    expect(home.changes, isEmpty);
  });

  testWidgets('Space still presses a focused button', (tester) async {
    var pressed = 0;
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              HostSearchField(
                fieldKey: _field,
                controller: controller,
                captureTyping: true,
                onChanged: (_) {},
                onConnect: (_) {},
              ),
              ElevatedButton(
                autofocus: true,
                onPressed: () => pressed++,
                child: const Text('add'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(pressed, 1);
    expect(controller.text, isEmpty);
  });

  testWidgets('typing in another text field stays there', (tester) async {
    final home = await _pump(tester, const _Home());
    await tester.tap(find.byKey(_other));
    await tester.pump();
    expect(_focused(tester, _other), isTrue);

    await _type(tester, LogicalKeyboardKey.keyA, 'a');
    await tester.pump();
    expect(home.controller.text, isEmpty);
    expect(_focused(tester, _other), isTrue);
  });

  testWidgets('nothing is captured or focused under a dialog', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final home = await _pump(tester, const _Home());
    expect(_focused(tester, _field), isTrue);

    showDialog<void>(
      context: tester.element(find.byType(_Home)),
      builder: (_) => AlertDialog(
        content: const Text('dialog'),
        actions: [TextButton(onPressed: () {}, child: const Text('ok'))],
      ),
    );
    await tester.pumpAndSettle();
    expect(_focused(tester, _field), isFalse);

    await _type(tester, LogicalKeyboardKey.keyA, 'a');
    await tester.pump();
    expect(home.controller.text, isEmpty);
    expect(_focused(tester, _field), isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a hidden page captures nothing and refocuses when shown', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var home = await _pump(tester, const _Home(pageIndex: 0));
    expect(_focused(tester, _field), isTrue);

    // A session tab is selected: the home page stays mounted but hidden.
    home = await _pump(tester, const _Home(pageIndex: 1, active: false));
    expect(_focused(tester, _field), isFalse);
    await _type(tester, LogicalKeyboardKey.keyA, 'a');
    await tester.pump();
    expect(home.controller.text, isEmpty);

    // Hidden by the stack alone, without the parent saying so.
    home = await _pump(tester, const _Home(pageIndex: 1));
    await _type(tester, LogicalKeyboardKey.keyA, 'a');
    await tester.pump();
    expect(home.controller.text, isEmpty);
    expect(_focused(tester, _field), isFalse);

    // Back on the home tab.
    home = await _pump(tester, const _Home(pageIndex: 1, active: false));
    home = await _pump(tester, const _Home(pageIndex: 0));
    expect(_focused(tester, _field), isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Enter in the empty focused field does not connect', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final home = await _pump(tester, const _Home());
    expect(_focused(tester, _field), isTrue);

    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(home.submits, 0);

    await tester.enterText(find.byKey(_field), '   ');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(home.submits, 0);

    await tester.enterText(find.byKey(_field), 'web');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(home.submits, 1);

    await tester.enterText(find.byKey(_field), 'ssh root@10.0.0.1');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(home.connects, hasLength(1));
    expect(home.submits, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('without captureTyping Enter in an empty field still submits', (
    tester,
  ) async {
    final home = await _pump(tester, const _Home(captureTyping: false));
    await tester.tap(find.byKey(_field));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await tester.pump();
    expect(home.submits, 1);
  });

  testWidgets('the key handler is removed with the field', (tester) async {
    final home = await _pump(tester, const _Home());
    final controller = home.controller;
    await tester.pumpWidget(const SizedBox());
    await _type(tester, LogicalKeyboardKey.keyA, 'a');
    await tester.pump();
    // The controller is disposed with the page; nothing may touch it.
    expect(tester.takeException(), isNull);
    expect(identical(controller, home.controller), isTrue);
  });
}
