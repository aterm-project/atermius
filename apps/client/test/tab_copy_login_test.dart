import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/credential_visibility/sensitive_clipboard.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _key =
    '-----BEGIN OPENSSH PRIVATE KEY-----\ntest-only-key\n-----END OPENSSH PRIVATE KEY-----\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'tab menu copies the session sign-in details and its Jump Host as JSON',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final language = AppLanguageController(
        systemLocales: () => [const Locale('zh')],
      );
      addTearDown(() {
        language.dispose();
        debugCurrentL10n = appLocalizationsFor(fallbackAppLocale);
      });
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      SensitiveClipboard.debugForgetSecrets();
      addTearDown(SensitiveClipboard.debugForgetSecrets);

      const bastion = HostRecord(
        id: 'host-bastion',
        name: 'bastion',
        address: 'bastion.example.test',
        port: 2200,
        // Signs in with its own key, saved on the Host itself.
        authKind: AuthKind.privateKey,
        username: 'jump',
        login: HostLogin(
          kind: AuthKind.privateKey,
          privateKey: _key,
          passphrase: 'test-only-passphrase',
        ),
      );
      const web = HostRecord(
        id: 'host-web',
        name: 'web-1',
        address: 'web.example.test',
        username: 'ignored',
        credentialId: 'credential-web',
        jumpHostId: 'host-bastion',
      );
      const typed = HostRecord(
        id: 'host-typed',
        name: 'typed',
        address: 'typed.example.test',
        username: 'alice',
        credentialId: 'credential-empty',
      );
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final identity = DeviceIdentity.create(sodium);
      final app =
          AppController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
              sshConnectorWithJumpForTesting: ({
                required host,
                required credential,
                required verifyHostKey,
                jumpHost,
                jumpCredential,
                verifyJumpHostKey,
              }) async => _Connection(),
            )
            ..session = AuthSession(
              accountId: 'account-test',
              accessToken: 'access-test',
              expiresIn: 3600,
              refreshToken: 'refresh-test',
              deviceId: identity.deviceId,
              vaults: const [],
            )
            ..identity = identity
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.terminal
            ..activeVault = const VaultDescriptor(
              id: '11111111-1111-4111-8111-111111111111',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
            )
            ..hosts.addAll(const [bastion, web, typed])
            ..credentials.addAll(const [
              CredentialRecord(
                id: 'credential-web',
                name: 'Web credential',
                username: 'deploy',
                secret: 'test-only "password" \\ with quotes',
              ),
              // A saved identity without a password: it is typed at sign-in.
              CredentialRecord(
                id: 'credential-empty',
                name: 'Typed credential',
                username: '',
              ),
            ]);
      var shellMounted = false;
      final previousTargetPlatform = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;

      try {
        await app.openTerminalTab(web);
        final webTab = app.activeTerminalTab!;
        await app.openTerminalTab(typed);
        final typedTab = app.activeTerminalTab!;
        await tester.pumpWidget(
          AppLanguageHost(
            controller: language,
            builder: (_, locale) => MaterialApp(
              locale: locale,
              localizationsDelegates: AppLocalizationSetup.delegates,
              supportedLocales: AppLocalizationSetup.locales,
              theme: buildAppTheme(locale: locale),
              home: AnimatedBuilder(
                animation: app,
                builder: (context, _) => AppShell(controller: app),
              ),
            ),
          ),
        );
        shellMounted = true;
        await tester.pump();

        Future<void> copyFrom(String tabId) async {
          clipboard = null;
          await tester.tap(
            find.byKey(ValueKey('workspace-tab-$tabId')),
            kind: PointerDeviceKind.mouse,
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          final copy = find.byKey(const ValueKey('tab_copy_login'));
          expect(
            find.descendant(of: copy, matching: find.text('复制登录信息（JSON）')),
            findsOneWidget,
          );
          expect(
            tester.getTopLeft(copy).dy,
            lessThan(tester.getTopLeft(find.text('属性')).dy),
          );
          // Opening the menu copies nothing.
          expect(clipboard, isNull);
          await tester.tap(copy);
          await tester.pumpAndSettle();
          // The copy runs after the menu has closed; its notice then takes
          // the place of whatever notice was still showing.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(const Duration(milliseconds: 500));
        }

        await copyFrom(webTab.id);
        expect(jsonDecode(clipboard!), {
          'name': 'web-1',
          'protocol': 'ssh',
          'host': 'web.example.test',
          'port': 22,
          'username': 'deploy',
          'password': 'test-only "password" \\ with quotes',
          'jump_hosts': [
            {
              'name': 'bastion',
              'protocol': 'ssh',
              'host': 'bastion.example.test',
              'port': 2200,
              'username': 'jump',
              'private_key': _key,
              'passphrase': 'test-only-passphrase',
            },
          ],
        });
        expect(find.text('已复制登录信息（JSON）。'), findsOneWidget);
        // Never offered to a remote desktop by automatic clipboard sync.
        expect(SensitiveClipboard.isSecret(clipboard!), isTrue);
        // On the clipboard only, never on screen.
        expect(find.textContaining('test-only'), findsNothing);

        // Nothing saved to sign in with: the address and user name are still
        // copied, and the notice says the secret is missing.
        await copyFrom(typedTab.id);
        expect(jsonDecode(clipboard!), {
          'name': 'typed',
          'protocol': 'ssh',
          'host': 'typed.example.test',
          'port': 22,
          'username': 'alice',
        });
        expect(find.text('已复制地址和用户名。此主机没有保存密码或密钥。'), findsOneWidget);
      } finally {
        if (shellMounted) await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = previousTargetPlatform;
        app.dispose();
        await database.close();
      }
    },
  );
}

class _Connection implements SshConnection {
  final _output = StreamController<String>.broadcast(sync: true);

  @override
  Stream<String> get output => _output.stream;

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
