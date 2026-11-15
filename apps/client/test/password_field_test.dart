import 'dart:io';

import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/password_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _field = ValueKey<String>('secret');
final _reveal = passwordRevealKey('secret');

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  theme: buildAppTheme(),
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(16), child: child),
  ),
);

TextField _textField(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_field));

void main() {
  testWidgets('is obscured by default and the eye shows and hides the value', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'saved-secret-value');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        PasswordField(
          fieldKey: _field,
          controller: controller,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
      ),
    );

    expect(_textField(tester).obscureText, isTrue);
    expect(_textField(tester).maxLines, 1);
    expect(_textField(tester).autocorrect, isFalse);
    expect(_textField(tester).enableSuggestions, isFalse);
    expect(_textField(tester).enableIMEPersonalizedLearning, isFalse);
    expect(_textField(tester).decoration?.labelText, 'Password');
    expect(find.byTooltip('Show password'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);

    await tester.tap(find.byKey(_reveal));
    await tester.pump();
    expect(_textField(tester).obscureText, isFalse);
    expect(_textField(tester).keyboardType, TextInputType.visiblePassword);
    // Still nothing a keyboard may learn from while the value is readable.
    expect(_textField(tester).autocorrect, isFalse);
    expect(_textField(tester).enableSuggestions, isFalse);
    expect(_textField(tester).enableIMEPersonalizedLearning, isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);

    await tester.tap(find.byKey(_reveal));
    await tester.pump();
    expect(_textField(tester).obscureText, isTrue);
    expect(find.byTooltip('Show password'), findsOneWidget);
    // Showing and hiding never edits the value.
    expect(controller.text, 'saved-secret-value');
  });

  testWidgets('typing keeps working while revealed and reports changes', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final changes = <String>[];
    String? submitted;
    await tester.pumpWidget(
      _app(
        PasswordField(
          fieldKey: _field,
          controller: controller,
          onChanged: changes.add,
          onSubmitted: (value) => submitted = value,
        ),
      ),
    );

    await tester.enterText(find.byKey(_field), 'first');
    await tester.tap(find.byKey(_reveal));
    await tester.pump();
    await tester.enterText(find.byKey(_field), 'second');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(controller.text, 'second');
    expect(changes, ['first', 'second']);
    expect(submitted, 'second');
  });

  testWidgets('a field that may not be revealed has no button', (tester) async {
    final controller = TextEditingController(text: 'someone-elses-secret');
    addTearDown(controller.dispose);
    var canReveal = true;
    late StateSetter rebuild;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return PasswordField(
              fieldKey: _field,
              controller: controller,
              canReveal: canReveal,
            );
          },
        ),
      ),
    );
    await tester.tap(find.byKey(_reveal));
    await tester.pump();
    expect(_textField(tester).obscureText, isFalse);

    // Losing the permission hides the value at once and removes the button.
    rebuild(() => canReveal = false);
    await tester.pump();
    expect(_textField(tester).obscureText, isTrue);
    expect(find.byKey(_reveal), findsNothing);
    expect(find.byType(IconButton), findsNothing);

    // Getting it back does not reveal anything by itself.
    rebuild(() => canReveal = true);
    await tester.pump();
    expect(_textField(tester).obscureText, isTrue);
    expect(find.byKey(_reveal), findsOneWidget);
  });

  testWidgets('a revealed private key is shown on several lines', (
    tester,
  ) async {
    const pem = '-----BEGIN KEY-----\nline-one\nline-two\n-----END KEY-----\n';
    final controller = TextEditingController(text: pem);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        PasswordField(
          fieldKey: _field,
          controller: controller,
          revealedMaxLines: 5,
          showTooltip: 'Show key',
          hideTooltip: 'Hide key',
        ),
      ),
    );
    expect(_textField(tester).obscureText, isTrue);
    expect(_textField(tester).maxLines, 1);
    expect(find.byTooltip('Show key'), findsOneWidget);
    // Hidden it is one line, where an edit would drop the line breaks: the
    // saved key cannot be flattened by a stray keystroke.
    expect(_textField(tester).readOnly, isTrue);

    await tester.tap(find.byKey(_reveal));
    await tester.pump();
    expect(_textField(tester).obscureText, isFalse);
    expect(_textField(tester).maxLines, 5);
    expect(_textField(tester).keyboardType, TextInputType.multiline);
    expect(_textField(tester).readOnly, isFalse);
    expect(find.byTooltip('Hide key'), findsOneWidget);
    expect(controller.text, pem);

    // Shown, it is edited as several lines and keeps them.
    await tester.enterText(find.byKey(_field), '$pem# edited\n');
    await tester.tap(find.byKey(_reveal));
    await tester.pump();
    expect(controller.text, '$pem# edited\n');
    expect(_textField(tester).readOnly, isTrue);

    // A value without line breaks (a new key being typed) stays editable.
    controller.text = '';
    await tester.pump();
    expect(_textField(tester).obscureText, isTrue);
    expect(_textField(tester).readOnly, isFalse);
    await tester.enterText(find.byKey(_field), 'typed');
    expect(controller.text, 'typed');
  });

  testWidgets('Tab still moves from one field to the next', (tester) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            PasswordField(fieldKey: _field, focusNode: first),
            PasswordField(
              fieldKey: const ValueKey<String>('confirm'),
              focusNode: second,
            ),
          ],
        ),
      ),
    );
    first.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(second.hasFocus, isTrue);
  });

  testWidgets('a reopened field starts obscured again', (tester) async {
    final controller = TextEditingController(text: 'saved-secret-value');
    addTearDown(controller.dispose);
    Widget build() =>
        _app(PasswordField(fieldKey: _field, controller: controller));
    await tester.pumpWidget(build());
    await tester.tap(find.byKey(_reveal));
    await tester.pump();
    expect(_textField(tester).obscureText, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(build());
    expect(_textField(tester).obscureText, isTrue);
  });

  for (final entry in const {
    'en': ('Show password', 'Hide password'),
    'zh': ('显示密码', '隐藏密码'),
    'ja': ('パスワードを表示', 'パスワードを隠す'),
    'ru': ('Показать пароль', 'Скрыть пароль'),
  }.entries) {
    testWidgets('fits a 390 px wide screen in ${entry.key}', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TextEditingController(
        text: 'a-rather-long-saved-password-value-0123456789-abcdefghij',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          PasswordField(
            fieldKey: _field,
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'SSH password (optional when using a private key)',
              prefixIcon: Icon(Icons.password_rounded),
            ),
          ),
          locale: Locale(entry.key),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip(entry.value.$1), findsOneWidget);

      await tester.tap(find.byKey(_reveal));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip(entry.value.$2), findsOneWidget);
      expect(_textField(tester).obscureText, isFalse);

      // The button stays a full-size touch target inside the screen.
      final button = tester.getRect(find.byKey(_reveal));
      expect(button.width, greaterThanOrEqualTo(40));
      expect(button.height, greaterThanOrEqualTo(36));
      expect(button.right, lessThanOrEqualTo(390));
    });
  }

  test('every obscured field in the app is a PasswordField', () {
    // A bare `obscureText` field has no way to read the value again. Secret
    // inputs go through PasswordField, which owns the only obscured TextField.
    final offenders = <String>[];
    final withoutButton = <String>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path == 'lib/ui/password_field.dart') continue;
      final lines = entity.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        if (lines[index].contains('obscureText')) {
          offenders.add('$path:${index + 1}');
        }
        if (lines[index].contains('canReveal:')) withoutButton.add(path);
      }
    }
    expect(offenders, isEmpty);
    // No field withholds the button: every password can be read again.
    expect(withoutButton, isEmpty);
  });
}
