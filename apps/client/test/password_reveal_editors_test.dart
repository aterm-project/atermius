// A saved password, passphrase or key can be read again where it is edited:
// the Host editor (shared by the cloud and Local Profile workspaces) and the
// cloud Keychain editor. The Local Profile Keychain editor is covered in
// local_profile_flow_widget_test.dart against a real encrypted Profile.
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/host_editor_panel.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _savedPassword = 'saved-host-password-7d1c';
const _savedPassphrase = 'saved-key-passphrase-41aa';
const _savedKey = '-----BEGIN KEY-----\nsaved-key-material\n-----END KEY-----';

TextField _field(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(ValueKey(key)));

Future<void> _tapReveal(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey('${key}_reveal'));
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
}

/// Opens the Host editor for [existing] and returns what Save produced.
Future<HostRecord? Function()> _openHostEditor(
  WidgetTester tester,
  HostRecord existing, {
  String keyPrefix = 'host_editor',
  bool canEdit = true,
  Locale locale = const Locale('en'),
}) async {
  HostRecord? saved;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              saved = await showHostEditorPanel(
                context,
                existing: existing,
                groups: const [],
                hosts: const [],
                keyPrefix: keyPrefix,
                canEdit: canEdit,
              );
            },
            child: const Text('open-editor'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open-editor'));
  await tester.pumpAndSettle();
  return () => saved;
}

HostRecord _passwordHost(HostProtocol protocol) => HostRecord(
  id: 'host-${protocol.name}',
  name: 'Server',
  address: 'example.test',
  port: protocol.defaultPort,
  protocol: protocol,
  username: 'root',
  login: const HostLogin(kind: AuthKind.password, password: _savedPassword),
);

const _keyHost = HostRecord(
  id: 'host-key',
  name: 'Key server',
  address: 'example.test',
  username: 'root',
  authKind: AuthKind.privateKey,
  login: HostLogin(
    kind: AuthKind.privateKey,
    privateKey: _savedKey,
    passphrase: _savedPassphrase,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The same panel serves both workspaces; only the key prefix differs.
  for (final prefix in const ['host_editor', 'local_host']) {
    for (final protocol in const [
      HostProtocol.ssh,
      HostProtocol.rdp,
      HostProtocol.vnc,
    ]) {
      testWidgets(
        '$prefix: the saved ${protocol.name} password can be shown again and '
        'an untouched editor saves it unchanged',
        (tester) async {
          final original = _passwordHost(protocol);
          final saved = await _openHostEditor(
            tester,
            original,
            keyPrefix: prefix,
          );
          final key = '${prefix}_password';

          expect(_field(tester, key).controller!.text, _savedPassword);
          expect(_field(tester, key).obscureText, isTrue);
          await _tapReveal(tester, key);
          expect(_field(tester, key).obscureText, isFalse);
          expect(find.byTooltip('Hide password'), findsOneWidget);
          await _tapReveal(tester, key);
          expect(_field(tester, key).obscureText, isTrue);

          await tester.tap(find.byKey(ValueKey('${prefix}_save')));
          await tester.pumpAndSettle();
          expect(saved()?.login?.kind, AuthKind.password);
          expect(saved()?.login?.password, _savedPassword);
          expect(saved()?.credentialId, isNull);
          expect(saved()?.protocol, protocol);
        },
      );
    }

    testWidgets('$prefix: the saved key passphrase and private key can be '
        'shown again and are saved unchanged', (tester) async {
      final saved = await _openHostEditor(tester, _keyHost, keyPrefix: prefix);
      final passphrase = '${prefix}_passphrase';

      expect(_field(tester, passphrase).controller!.text, _savedPassphrase);
      expect(_field(tester, passphrase).obscureText, isTrue);
      await _tapReveal(tester, passphrase);
      expect(_field(tester, passphrase).obscureText, isFalse);

      // The private key keeps its own reveal: masked until it is opened.
      expect(find.byKey(ValueKey('${prefix}_private_key')), findsNothing);
      final showKey = find.text('Edit private key');
      await tester.ensureVisible(showKey);
      await tester.tap(showKey);
      await tester.pump();
      expect(
        _field(tester, '${prefix}_private_key').controller!.text,
        _savedKey,
      );
      expect(_field(tester, '${prefix}_private_key').obscureText, isFalse);

      await tester.tap(find.byKey(ValueKey('${prefix}_save')));
      await tester.pumpAndSettle();
      expect(saved()?.login?.kind, AuthKind.privateKey);
      expect(saved()?.login?.privateKey, _savedKey);
      expect(saved()?.login?.passphrase, _savedPassphrase);
    });
  }

  testWidgets('a read-only Vault can show the Host password but not save', (
    tester,
  ) async {
    final saved = await _openHostEditor(
      tester,
      _passwordHost(HostProtocol.ssh),
      canEdit: false,
    );
    const key = 'host_editor_password';
    expect(_field(tester, key).controller!.text, _savedPassword);
    expect(_field(tester, key).obscureText, isTrue);
    await _tapReveal(tester, key);
    expect(_field(tester, key).obscureText, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('host_editor_save')))
          .onPressed,
      isNull,
    );
    expect(saved(), isNull);
  });

  for (final code in const ['en', 'zh', 'ja', 'ru']) {
    testWidgets('the Host password reveal fits a 390 px screen in $code', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _openHostEditor(
        tester,
        _passwordHost(HostProtocol.ssh),
        locale: Locale(code),
      );
      expect(tester.takeException(), isNull);
      await _tapReveal(tester, 'host_editor_password');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_field(tester, 'host_editor_password').obscureText, isFalse);
      final l10n = appLocalizationsFor(Locale(code));
      expect(find.byTooltip(l10n.passwordRevealHide), findsOneWidget);
      final button = tester.getRect(
        find.byKey(const ValueKey('host_editor_password_reveal')),
      );
      expect(button.left, greaterThanOrEqualTo(0));
      expect(button.right, lessThanOrEqualTo(390));
    });
  }

  group('cloud Keychain editor', () {
    Future<_CredentialController> pumpKeychain(
      WidgetTester tester, {
      bool canWrite = true,
      Locale locale = const Locale('en'),
    }) async {
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          _CredentialController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.credentials
            ..activeVault = VaultDescriptor(
              id: '55555555-5555-4555-8555-555555555555',
              role: canWrite ? 'owner' : 'viewer',
              activeKeyEpoch: '1',
              membershipVersion: '1',
              canWrite: canWrite,
            )
            ..credentials.addAll(const [
              CredentialRecord(
                id: 'credential-password',
                name: 'Deploy password',
                username: 'deploy',
                secret: _savedPassword,
              ),
              CredentialRecord(
                id: 'credential-key',
                name: 'Deploy key',
                username: 'automation',
                kind: AuthKind.privateKey,
                privateKey: _savedKey,
                passphrase: _savedPassphrase,
              ),
            ]);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AppShell(controller: app),
        ),
      );
      await tester.pumpAndSettle();
      return app;
    }

    Future<void> openEditor(WidgetTester tester, String name) async {
      await tester.tap(find.byTooltip('Credential actions: $name'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit').last);
      await tester.pumpAndSettle();
    }

    testWidgets('the saved password can be shown again and an untouched '
        'editor saves it unchanged', (tester) async {
      final app = await pumpKeychain(tester);
      await openEditor(tester, 'Deploy password');

      const key = 'ssh-credential-password';
      expect(_field(tester, key).controller!.text, _savedPassword);
      expect(_field(tester, key).obscureText, isTrue);
      await _tapReveal(tester, key);
      expect(_field(tester, key).obscureText, isFalse);
      await _tapReveal(tester, key);
      expect(_field(tester, key).obscureText, isTrue);

      await tester.tap(find.text('Save encrypted credential'));
      await tester.pumpAndSettle();
      expect(app.savedCredential?.id, 'credential-password');
      expect(app.savedCredential?.kind, AuthKind.password);
      expect(app.savedCredential?.secret, _savedPassword);
    });

    testWidgets('the saved key passphrase can be shown again', (tester) async {
      final app = await pumpKeychain(tester);
      await openEditor(tester, 'Deploy key');

      const key = 'ssh-credential-passphrase';
      expect(_field(tester, key).controller!.text, _savedPassphrase);
      expect(_field(tester, key).obscureText, isTrue);
      await _tapReveal(tester, key);
      expect(_field(tester, key).obscureText, isFalse);
      // The private key itself is shown in full by this editor.
      expect(
        _field(tester, 'ssh-credential-private-key').controller!.text,
        _savedKey,
      );
      expect(_field(tester, 'ssh-credential-private-key').obscureText, isFalse);

      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(app.savedCredential, isNull);
    });

    testWidgets('a read-only Vault can view a saved password and key, and '
        'cannot change or save them', (tester) async {
      final app = await pumpKeychain(tester, canWrite: false);

      await tester.tap(find.byTooltip('Credential actions: Deploy password'));
      await tester.pumpAndSettle();
      // Viewing is the only action offered.
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Delete'), findsNothing);
      await tester.tap(find.text('View credential').last);
      await tester.pumpAndSettle();

      const password = 'ssh-credential-password';
      expect(_field(tester, password).controller!.text, _savedPassword);
      expect(_field(tester, password).obscureText, isTrue);
      expect(_field(tester, password).readOnly, isTrue);
      await _tapReveal(tester, password);
      expect(_field(tester, password).obscureText, isFalse);
      expect(_field(tester, password).readOnly, isTrue);
      expect(find.text('Save encrypted credential'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ssh-credential-view-close')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Credential actions: Deploy key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View credential').last);
      await tester.pumpAndSettle();
      const privateKey = 'ssh-credential-private-key';
      const passphrase = 'ssh-credential-passphrase';
      // The key is obscured until asked for, then shown on several lines.
      expect(_field(tester, privateKey).controller!.text, _savedKey);
      expect(_field(tester, privateKey).obscureText, isTrue);
      await _tapReveal(tester, privateKey);
      expect(_field(tester, privateKey).obscureText, isFalse);
      expect(_field(tester, privateKey).maxLines, 8);
      expect(_field(tester, privateKey).readOnly, isTrue);
      expect(_field(tester, passphrase).controller!.text, _savedPassphrase);
      expect(_field(tester, passphrase).obscureText, isTrue);
      await _tapReveal(tester, passphrase);
      expect(_field(tester, passphrase).obscureText, isFalse);
      expect(_field(tester, passphrase).readOnly, isTrue);
      expect(find.text('Save encrypted credential'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ssh-credential-view-close')));
      await tester.pumpAndSettle();
      expect(app.savedCredential, isNull);
    });

    for (final code in const ['en', 'zh', 'ja', 'ru']) {
      testWidgets('the read-only credential view fits a 390 px screen in '
          '$code', (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final l10n = appLocalizationsFor(Locale(code));
        await pumpKeychain(tester, canWrite: false, locale: Locale(code));
        expect(tester.takeException(), isNull);

        await tester.tap(
          find.byTooltip(l10n.credentialActionsName('Deploy password')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.keychainViewCredential).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // The menu item is gone; the same words are now the dialog title.
        expect(find.text(l10n.keychainViewCredential), findsOneWidget);
        await _tapReveal(tester, 'ssh-credential-password');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(_field(tester, 'ssh-credential-password').obscureText, isFalse);
        final button = tester.getRect(
          find.byKey(const ValueKey('ssh-credential-password_reveal')),
        );
        expect(button.left, greaterThanOrEqualTo(0));
        expect(button.right, lessThanOrEqualTo(390));
      });
    }
  });
}

class _CredentialController extends AppController {
  _CredentialController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  CredentialRecord? savedCredential;

  @override
  Future<void> saveCredential(CredentialRecord credential) async {
    savedCredential = credential;
  }
}
