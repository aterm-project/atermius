import 'dart:async';

import 'package:aterm_client/desktop/desktop_resolution.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Remote implements DirectDesktopConnection {
  final stream = StreamController<DesktopEvent>();
  final sent = <List<Object>>[];
  @override
  Stream<DesktopEvent> get events => stream.stream;
  @override
  void send(List<Object> command) => sent.add(command);
  @override
  void paste(String text) {}
  @override
  Future<void> close() async {
    unawaited(stream.close());
  }
}

Future<(DesktopSession, _Remote)> _connect() async {
  final remote = _Remote();
  final session = DesktopSession(directConnectionForTesting: (_) => remote);
  await session.connectLocal(
    HostRecord(
      id: 'pane-menu',
      name: 'Pane menu',
      address: 'localhost',
      protocol: HostProtocol.vnc,
      manifest: const VncSettings(resolution: VncResolutionMode.fitWindow)
          .applyTo(null),
    ),
  );
  remote.stream.add(DesktopReady());
  session.state = 'connected';
  return (session, remote);
}

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizationSetup.delegates,
  supportedLocales: AppLocalizationSetup.locales,
  theme: buildAppTheme(),
  home: Scaffold(body: home),
);

final _menu = find.byTooltip('Remote desktop menu');

/// The translucent circle that used to carry the menu over the desktop.
final _floating = find.byWidgetPredicate(
  (widget) => widget is Material && widget.shape is CircleBorder,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> close(WidgetTester tester, DesktopSession session) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(session.close);
    session.dispose();
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
    testWidgets(
      '${platform.name}: a pane shows the desktop menu in its handle actions',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          final (session, remote) = await _connect();
          final workspace = SessionWorkspaceController()..activate('desk');
          addTearDown(workspace.dispose);
          await tester.pumpWidget(
            _app(
              SessionWorkspaceView(
                controller: workspace,
                onDuplicate: (_) {},
                terminalBuilder: (_, id) =>
                    DesktopView(key: ValueKey(id), session: session),
              ),
            ),
          );
          await tester.pump();
          // Nothing floats over the remote screen any more.
          expect(_floating, findsNothing);
          expect(_menu, findsNothing);
          expect(
            find.byKey(const ValueKey('pane-handle-desk')),
            findsOneWidget,
          );

          // The white handle reveals the pane actions, the menu among them.
          await tester.tap(find.byKey(const ValueKey('pane-handle-desk')));
          await tester.pumpAndSettle();
          expect(_menu, findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('pane-content-action-desk')),
              matching: _menu,
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('pane-duplicate-desk')),
            findsOneWidget,
          );

          // The pointer leaves the pane while the menu is open (it does on a
          // real desktop: the menu covers it); the choice still arrives.
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: tester.getCenter(_menu));
          await tester.pump();
          expect(_menu, findsOneWidget, reason: 'hovering the actions');
          await tester.tap(_menu);
          await tester.pumpAndSettle();
          await mouse.moveTo(const Offset(5, 590));
          await tester.pump();
          remote.sent.clear();
          await tester.tap(find.text('Send Ctrl+Alt+Delete'));
          await tester.pumpAndSettle();
          expect(
            [
              for (final command in remote.sent)
                if (command.first == 'key') (command[1], command[2]),
            ],
            [
              (65507, 1),
              (65513, 1),
              (65535, 1),
              (65535, 0),
              (65513, 0),
              (65507, 0),
            ],
          );
          // The actions retract again after the choice.
          expect(_menu, findsNothing);
          expect(_floating, findsNothing);
          await mouse.removePointer();

          // Ctrl+Alt+Home opens the menu although its button is hidden.
          await tester.tapAt(const Offset(400, 400));
          await tester.pump();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
          await tester.sendKeyDownEvent(LogicalKeyboardKey.home);
          await tester.pumpAndSettle();
          expect(find.text('Send Ctrl+Alt+Delete'), findsOneWidget);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.home);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.tapAt(const Offset(5, 590)); // dismiss
          await tester.pumpAndSettle();
          expect(find.text('Send Ctrl+Alt+Delete'), findsNothing);
          expect(_menu, findsNothing);
          expect(tester.takeException(), isNull);
          await close(tester, session);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  testWidgets('without a pane the menu still floats over the corner', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final (session, _) = await _connect();
      await tester.pumpWidget(_app(DesktopView(session: session)));
      await tester.pump();
      expect(_menu, findsOneWidget);
      expect(_floating, findsOneWidget);
      await close(tester, session);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a pane without a desktop keeps its usual actions', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final workspace = SessionWorkspaceController()..activate('term');
      addTearDown(workspace.dispose);
      await tester.pumpWidget(
        _app(
          SessionWorkspaceView(
            controller: workspace,
            onDuplicate: (_) {},
            terminalBuilder: (_, id) => const ColoredBox(color: Colors.black),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('pane-handle-term')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('pane-content-action-term')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('pane-duplicate-term')), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
