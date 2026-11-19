// DesktopView drives automatic clipboard sync (focus, resume, Android clip
// changes) and explains an empty or refused clipboard on manual paste.
import 'dart:async';

import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/clipboard_paste.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_local_clipboard.dart';

class _Connection implements DirectDesktopConnection {
  final controller = StreamController<DesktopEvent>();
  final pasted = <String>[];
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  void send(List<Object> command) {}
  @override
  void paste(String text) => pasted.add(text);
  @override
  Future<void> close() async => controller.close();
}

Future<(DesktopSession, _Connection)> _session(
  WidgetTester tester,
  FakeLocalClipboard clipboard,
) async {
  final connection = _Connection();
  final session = DesktopSession(
    directConnectionForTesting: (_) => connection,
    localClipboard: clipboard,
  );
  await tester.runAsync(
    () => session.connectLocal(
      const HostRecord(
        id: 'r',
        name: 'R',
        address: 'r',
        protocol: HostProtocol.rdp,
      ),
    ),
  );
  session.state = 'connected';
  return (session, connection);
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.home);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.home);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  final l10n = appLocalizationsFor(fallbackAppLocale);

  testWidgets('focus, resume and Android clip changes offer local text', (
    tester,
  ) async {
    final clipboard = FakeLocalClipboard(text: 'first');
    final (session, connection) = await _session(tester, clipboard);
    final other = FocusNode();
    addTearDown(other.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Focus(focusNode: other, child: const SizedBox(height: 10)),
              Expanded(child: DesktopView(session: session)),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    // The view takes focus when shown.
    expect(connection.pasted, ['first']);

    clipboard
      ..copy('copied in the keyboard')
      ..notifyChanged();
    await tester.pump();
    expect(connection.pasted.last, 'copied in the keyboard');

    clipboard.copy('copied in another app');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(connection.pasted.last, 'copied in another app');

    // Another view has focus: changes wait for this desktop's focus.
    other.requestFocus();
    await tester.pump();
    clipboard
      ..copy('while elsewhere')
      ..notifyChanged();
    await tester.pump();
    expect(connection.pasted.last, 'copied in another app');
    await tester.tap(find.byType(DesktopView));
    await tester.pump();
    await tester.pump();
    expect(connection.pasted.last, 'while elsewhere');
    expect(connection.pasted, hasLength(4));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(session.close);
  });

  testWidgets('manual paste says why when there is no text', (tester) async {
    final clipboard = FakeLocalClipboard();
    final (session, connection) = await _session(tester, clipboard);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DesktopView(session: session)),
      ),
    );
    await tester.pump();
    await _openMenu(tester);
    await tester.tap(find.text(l10n.pasteLocalClipboardText));
    await tester.pumpAndSettle();
    expect(find.text(l10n.clipboardIsEmpty), findsOneWidget);
    expect(connection.pasted, isEmpty);

    // Copying an empty remote clipboard says so instead of clearing ours.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    clipboard.copy('keep me');
    await _openMenu(tester);
    await tester.tap(find.text(l10n.copyRemoteClipboardText));
    await tester.pumpAndSettle();
    expect(find.text(l10n.desktopRemoteClipboardEmpty), findsOneWidget);
    expect(clipboard.text, 'keep me');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(session.close);
  });

  testWidgets('a refused read offers the system settings', (tester) async {
    final clipboard = FakeLocalClipboard()
      ..copy('blocked')
      ..allowed = false
      ..hasSettingsValue = true;
    late BuildContext context;
    String? result = 'unset';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    result = await readClipboardForPaste(
      context,
      maxBytes: 100,
      clipboard: clipboard,
    );
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text(l10n.clipboardReadDenied), findsOneWidget);
    await tester.tap(find.text(l10n.settings));
    expect(clipboard.settingsOpened, 1);
  });

  testWidgets('too large and successful reads', (tester) async {
    final clipboard = FakeLocalClipboard(text: 'x' * 65537);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    expect(
      await readClipboardForPaste(
        context,
        maxBytes: 65536,
        clipboard: clipboard,
      ),
      isNull,
    );
    await tester.pump();
    expect(find.text(l10n.clipboardTextTooLarge('64 KiB')), findsOneWidget);
    clipboard.copy('fits');
    expect(
      await readClipboardForPaste(
        context,
        maxBytes: 65536,
        clipboard: clipboard,
      ),
      'fits',
    );
    expect(formatClipboardLimit(terminalPasteMaxBytes), '16 MiB');
  });
}
