import 'dart:async';

import 'package:aterm_client/ui/app_motion.dart';
import 'package:aterm_client/ui/dialog_frames.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A workspace with a tab row and two panes ('a' left, 'b' right).
class _Workspace extends StatefulWidget {
  const _Workspace();

  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace>
    with DialogFrameOwner<_Workspace> {
  @override
  late final DialogFrameController dialogFrames = DialogFrameController(
    currentFrame: () => current,
  );
  String? current = 'a';
  bool showB = true;
  bool removedB = false;
  int tabTaps = 0, bTaps = 0;

  void update(VoidCallback change) => setState(change);

  @override
  void dispose() {
    dialogFrames.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DialogFrameLayer(
    controller: dialogFrames,
    child: Column(
      children: [
        SizedBox(
          height: 40,
          child: TextButton(
            key: const ValueKey('tab'),
            onPressed: () => tabTaps++,
            child: const Text('tab'),
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: DialogFrame(
                  id: 'a',
                  child: Container(
                    key: const ValueKey('pane-a'),
                    color: Colors.blue,
                  ),
                ),
              ),
              if (removedB)
                const Spacer()
              else
                Expanded(
                  child: Offstage(
                    offstage: !showB,
                    child: DialogFrame(
                      id: 'b',
                      child: Center(
                        child: TextButton(
                          key: const ValueKey('pane-b'),
                          onPressed: () => bTaps++,
                          child: const Text('b'),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

Future<_WorkspaceState> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1000, 640));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: _Workspace())),
  );
  await tester.pumpAndSettle();
  return tester.state<_WorkspaceState>(find.byType(_Workspace));
}

Widget _editor(String text) => AlertDialog(
  key: const ValueKey('editor'),
  content: SizedBox(
    width: 260,
    child: TextFormField(key: const ValueKey('field'), initialValue: text),
  ),
  actions: [
    Builder(
      builder: (context) => TextButton(
        key: const ValueKey('ok'),
        onPressed: () => Navigator.pop(context, 'ok'),
        child: const Text('OK'),
      ),
    ),
  ],
);

Rect _rect(WidgetTester tester, Finder finder) => tester.getRect(finder);

void main() {
  testWidgets('a dialog from a pane covers only that pane', (tester) async {
    final workspace = await _pump(tester);
    final result = showAppDialog<String>(
      context: tester.element(find.byKey(const ValueKey('pane-a'))),
      builder: (_) => _editor('alpha'),
    );
    await tester.pumpAndSettle();

    final pane = _rect(tester, find.byKey(const ValueKey('pane-a')));
    final dialog = _rect(tester, find.byKey(const ValueKey('editor')));
    expect(
      pane.contains(dialog.topLeft) &&
          pane.contains(dialog.bottomRight - const Offset(1, 1)),
      isTrue,
      reason: 'dialog $dialog inside pane $pane',
    );
    expect(dialog.center.dx, closeTo(pane.center.dx, 1));
    final barrier = find.byWidgetPredicate(
      (widget) => widget is ModalBarrier && widget.dismissible,
    );
    expect(_rect(tester, barrier.last), pane);

    // The tab row and the other pane still take input.
    await tester.tap(find.byKey(const ValueKey('tab')));
    await tester.tap(find.byKey(const ValueKey('pane-b')));
    await tester.pumpAndSettle();
    expect(workspace.tabTaps, 1);
    expect(workspace.bTaps, 1);
    expect(find.byKey(const ValueKey('editor')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ok')));
    await tester.pumpAndSettle();
    expect(await result, 'ok');
    expect(find.byKey(const ValueKey('editor')), findsNothing);
  });

  testWidgets(
    'outside every frame the current frame is used, or the one named',
    (tester) async {
      final workspace = await _pump(tester);
      final tab = tester.element(find.byKey(const ValueKey('tab')));
      unawaited(
        showAppDialog<void>(context: tab, builder: (_) => _editor('x')),
      );
      await tester.pumpAndSettle();
      final paneA = _rect(tester, find.byKey(const ValueKey('pane-a')));
      expect(
        paneA.contains(
          _rect(tester, find.byKey(const ValueKey('editor'))).center,
        ),
        isTrue,
      );
      expect(workspace.dialogFrames.hasDialogs('a'), isTrue);
      Navigator.of(tester.element(find.byKey(const ValueKey('field')))).pop();
      await tester.pumpAndSettle();

      // The shell's own context counts as outside every frame too.
      unawaited(
        showAppDialog<void>(
          context: workspace.context,
          frameId: 'b',
          builder: (_) => _editor('y'),
        ),
      );
      await tester.pumpAndSettle();
      final paneB = _rect(tester, find.byKey(const ValueKey('pane-b'))).center;
      final editor = _rect(tester, find.byKey(const ValueKey('editor')));
      expect(editor.center.dx, greaterThan(500));
      expect(editor.center.dx, closeTo(paneB.dx, 1));
      expect(workspace.dialogFrames.hasDialogs('b'), isTrue);
      expect(workspace.dialogFrames.hasDialogs('a'), isFalse);
    },
  );

  testWidgets('a dialog from outside the frames follows the last press', (
    tester,
  ) async {
    final workspace = await _pump(tester);
    expect(workspace.current, 'a');
    // A pane's own menu runs its action with a context outside the frames.
    await tester.tap(find.byKey(const ValueKey('pane-b')));
    await tester.pump();
    unawaited(
      showAppDialog<void>(
        context: workspace.context,
        builder: (_) => _editor('pressed'),
      ),
    );
    await tester.pumpAndSettle();
    expect(workspace.dialogFrames.hasDialogs('b'), isTrue);
    expect(workspace.dialogFrames.hasDialogs('a'), isFalse);
    Navigator.of(tester.element(find.byKey(const ValueKey('field')))).pop();
    await tester.pumpAndSettle();

    // A press outside every frame (the tab row) falls back to the current one.
    await tester.tap(find.byKey(const ValueKey('tab')));
    await tester.pump();
    unawaited(
      showAppDialog<void>(
        context: workspace.context,
        builder: (_) => _editor('tab row'),
      ),
    );
    await tester.pumpAndSettle();
    expect(workspace.dialogFrames.hasDialogs('a'), isTrue);
  });

  testWidgets('a pane menu action opens its dialogs in that pane', (
    tester,
  ) async {
    final workspace = await _pump(tester);
    // Selected pane is 'a'; the menu belongs to 'b' and its action is built
    // with the shell's context, and waits before it opens the dialog.
    final paneB = tester.element(find.byKey(const ValueKey('pane-b')));
    unawaited(
      Future<void>.sync(
        () => DialogFrames.runInFrameOf(paneB, () async {
          await Future<void>.delayed(Duration.zero);
          await showAppDialog<void>(
            context: workspace.context,
            builder: (_) => _editor('menu'),
          );
        }),
      ),
    );
    await tester.pumpAndSettle();
    expect(workspace.dialogFrames.hasDialogs('b'), isTrue);
    expect(workspace.dialogFrames.hasDialogs('a'), isFalse);
  });

  testWidgets('a dialog that closes and opens the next keeps it in its pane', (
    tester,
  ) async {
    final workspace = await _pump(tester);
    // Pane 'b' shows a dialog whose button closes it and asks the shell (a
    // context outside the frames) for the next dialog.
    unawaited(
      showAppDialog<void>(
        context: tester.element(find.byKey(const ValueKey('pane-b'))),
        builder: (dialogContext) => TextButton(
          key: const ValueKey('next'),
          onPressed: () {
            Navigator.pop(dialogContext);
            showAppDialog<void>(
              context: workspace.context,
              builder: (_) => _editor('next'),
            );
          },
          child: const Text('next'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // A screen reader's tap: no pointer press lands anywhere.
    final semantics = tester.ensureSemantics();
    tester.semantics.tap(find.semantics.byLabel('next'));
    semantics.dispose();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor')), findsOneWidget);
    expect(workspace.dialogFrames.hasDialogs('b'), isTrue);
    expect(workspace.dialogFrames.hasDialogs('a'), isFalse);
  });

  testWidgets('the tab row stays readable while a pane shows a dialog', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await _pump(tester);
      unawaited(
        showAppDialog<void>(
          context: tester.element(find.byKey(const ValueKey('pane-a'))),
          builder: (_) => _editor('a11y'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('tab'), findsOneWidget);
      expect(find.bySemanticsLabel('b'), findsOneWidget);
      expect(find.bySemanticsLabel('OK'), findsOneWidget);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a hidden frame keeps its dialog and its input', (tester) async {
    final workspace = await _pump(tester);
    unawaited(
      showAppDialog<void>(
        context: tester.element(find.byKey(const ValueKey('pane-b'))),
        builder: (_) => _editor('typed'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field')), 'changed');
    await tester.pump();

    workspace.update(() => workspace.showB = false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor')).hitTestable(), findsNothing);
    expect(workspace.dialogFrames.isVisible('b'), isFalse);
    // Pane a and the tab row work while b's dialog waits.
    await tester.tap(find.byKey(const ValueKey('tab')));
    expect(workspace.tabTaps, 1);

    workspace.update(() => workspace.showB = true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor')).hitTestable(), findsOneWidget);
    expect(find.text('changed'), findsOneWidget);
    expect(workspace.dialogFrames.isVisible('b'), isTrue);
  });

  testWidgets('ending a frame cancels its dialogs', (tester) async {
    final workspace = await _pump(tester);
    final result = showAppDialog<String>(
      context: tester.element(find.byKey(const ValueKey('pane-b'))),
      builder: (_) => _editor('b'),
    );
    await tester.pumpAndSettle();
    workspace.update(() => workspace.removedB = true);
    workspace.dialogFrames.retain((id) => id != 'b');
    await tester.pumpAndSettle();
    expect(await result, isNull);
    expect(find.byKey(const ValueKey('editor')), findsNothing);
    expect(workspace.dialogFrames.frameIds, isNot(contains('b')));
  });

  testWidgets('system back closes the dialog of the frame on screen', (
    tester,
  ) async {
    await _pump(tester);
    final result = showAppDialog<String>(
      context: tester.element(find.byKey(const ValueKey('pane-a'))),
      builder: (_) => _editor('a'),
    );
    await tester.pumpAndSettle();
    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(await result, isNull);
    expect(find.byKey(const ValueKey('editor')), findsNothing);
  });

  testWidgets('outside a workspace dialogs still cover the window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: const ValueKey('open'),
              onPressed: () => showAppDialog<void>(
                context: context,
                builder: (_) => _editor('r'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    final barrier = find.byWidgetPredicate(
      (widget) => widget is ModalBarrier && widget.dismissible,
    );
    expect(_rect(tester, barrier.last), Offset.zero & const Size(1000, 640));
  });

  testWidgets('a pane that resizes takes its dialog along', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _Workspace())),
    );
    await tester.pumpAndSettle();
    unawaited(
      showAppDialog<void>(
        context: tester.element(find.byKey(const ValueKey('pane-a'))),
        builder: (_) => _editor('a'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(1400, 800));
    await tester.pumpAndSettle();
    final pane = _rect(tester, find.byKey(const ValueKey('pane-a')));
    final barrier = find.byWidgetPredicate(
      (widget) => widget is ModalBarrier && widget.dismissible,
    );
    expect(_rect(tester, barrier.last), pane);
    expect(
      _rect(tester, find.byKey(const ValueKey('editor'))).center.dx,
      closeTo(pane.center.dx, 1),
    );
  });
}
