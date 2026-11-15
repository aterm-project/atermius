// The development-only "allow insecure connection" option on the sign-in
// page and the persistent indicator shown while it is in use.

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/storage/workspace_mode.dart';
import 'package:aterm_client/ui/account_settings.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/auth_flow.dart';
import 'package:aterm_client/ui/locked_workspace_screen.dart';
import 'package:aterm_client/ui/workspace_mode_settings.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _lastServerKey = 'atermius.v1.last_server';
const _devServer = 'https://172.19.99.1';
const _locales = [Locale('en'), Locale('zh'), Locale('ja'), Locale('ru')];

const _control = ValueKey('allow_insecure_server');
const _confirm = ValueKey('allow_insecure_server_confirm');
const _cancel = ValueKey('allow_insecure_server_cancel');
const _dialog = ValueKey('allow_insecure_server_dialog');
const _indicator = ValueKey('insecure_server_indicator');
const _details = ValueKey('insecure_server_details');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SodiumSumo sodium;
  late InstanceInfo instance;
  late Map<String, String> storage;
  late ClientDatabase database;
  late AppController app;
  late List<String> secureClients;
  late List<String> insecureClients;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    final identity = DeviceIdentity.create(sodium);
    instance = InstanceInfo(
      instanceId: '11111111-1111-4111-8111-111111111111',
      serverSpaceId: '22222222-2222-4222-8222-222222222222',
      generation: '44444444-4444-4444-8444-444444444444',
      protocolVersion: 1,
      setupRequired: false,
      capabilities: const [],
      signingPublicKey: identity.signingPublicKey,
      signingKeyTransitions: const [],
    );
    identity.dispose();
  });

  setUp(() {
    storage = {};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      storage,
    );
    database = ClientDatabase.forTesting(NativeDatabase.memory());
    secureClients = [];
    insecureClients = [];
    app = AppController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(const FlutterSecureStorage()),
      apiClientFactoryForTesting: (baseUrl) {
        secureClients.add(baseUrl);
        return _InstanceApi(baseUrl, instance, allowInsecure: false);
      },
      insecureApiClientFactoryForTesting: (baseUrl) {
        insecureClients.add(baseUrl);
        return _InstanceApi(baseUrl, instance, allowInsecure: true);
      },
    );
  });

  tearDown(() async {
    app.dispose();
    await database.close();
  });

  Widget host(Widget child, {Locale locale = const Locale('en')}) =>
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildAppTheme(locale: locale),
        builder: (context, routeChild) => WorkspaceModeScope(
          mode: WorkspaceMode.server,
          busy: false,
          onSwitch: () async {},
          child: routeChild!,
        ),
        home: child,
      );

  Widget signIn({Locale locale = const Locale('en'), bool? web}) => host(
    AnimatedBuilder(
      animation: app,
      builder: (context, _) => AuthFlow(controller: app, webForTesting: web),
    ),
    locale: locale,
  );

  Future<void> phone(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  bool optionOn(WidgetTester tester) =>
      tester.widget<SwitchListTile>(find.byKey(_control)).value;

  Future<void> toggle(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(_control));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_control));
    await tester.pumpAndSettle();
  }

  Future<void> typeServer(WidgetTester tester, String url) async {
    await tester.enterText(find.byType(TextField).first, url);
    await tester.pumpAndSettle();
  }

  Future<void> connect(WidgetTester tester, String label) async {
    final button = find.widgetWithText(FilledButton, label);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  /// Lets a snack bar time out so it cannot cover the next tap target.
  Future<void> dismissSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  for (final locale in _locales) {
    final l10n = lookupAppLocalizations(locale);
    final code = locale.languageCode;

    testWidgets('sign-in page at 390 px ($code): off by default, confirmation, '
        'cancel, connect and the persistent indicator', (tester) async {
      await phone(tester);
      await tester.pumpWidget(signIn(locale: locale));
      await tester.pumpAndSettle();

      // Off by default, with the warning always visible.
      expect(find.byKey(_control), findsOneWidget);
      expect(optionOn(tester), isFalse);
      expect(find.text(l10n.allowInsecureServerTitle), findsOneWidget);
      expect(find.text(l10n.allowInsecureServerWarning), findsOneWidget);
      expect(find.text(l10n.connectSecurely), findsOneWidget);
      expect(find.byKey(_indicator), findsNothing);
      expect(tester.takeException(), isNull);

      // It is bound to one server, so it needs the address first.
      await toggle(tester);
      expect(find.byKey(_dialog), findsNothing);
      expect(find.text(l10n.allowInsecureServerNeedsAddress), findsOneWidget);
      expect(optionOn(tester), isFalse);
      await dismissSnackBar(tester);

      // Turning it on asks first and says plainly what it does.
      await typeServer(tester, '$_devServer/');
      await toggle(tester);
      expect(find.byKey(_dialog), findsOneWidget);
      expect(find.text(l10n.allowInsecureServerConfirmTitle), findsOneWidget);
      expect(
        find.text(l10n.allowInsecureServerConfirmBody(_devServer)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // Cancel leaves it off.
      await tester.tap(find.byKey(_cancel));
      await tester.pumpAndSettle();
      expect(find.byKey(_dialog), findsNothing);
      expect(optionOn(tester), isFalse);
      expect(find.text(l10n.connectSecurely), findsOneWidget);

      // Confirm turns it on and the button stops promising security.
      await toggle(tester);
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();
      expect(optionOn(tester), isTrue);
      expect(find.text(l10n.insecureServerConnect), findsOneWidget);
      expect(find.text(l10n.connectSecurely), findsNothing);
      expect(tester.takeException(), isNull);

      // Another server address was never confirmed.
      await typeServer(tester, 'https://172.19.99.2');
      expect(optionOn(tester), isFalse);
      expect(find.text(l10n.connectSecurely), findsOneWidget);
      await typeServer(tester, _devServer);
      expect(optionOn(tester), isTrue);

      await connect(tester, l10n.insecureServerConnect);
      expect(insecureClients, [_devServer]);
      expect(secureClients, isEmpty);
      expect(app.stage, ClientStage.login);
      expect(app.insecureServerOrigin, _devServer);

      // The sign-in form now carries the indicator, naming the server.
      expect(find.byKey(_indicator), findsOneWidget);
      expect(find.text(l10n.insecureServerIndicator), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(_indicator),
          matching: find.text(_devServer),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      // Details can be opened and closed; the indicator cannot be dismissed.
      await tester.ensureVisible(find.byKey(_indicator));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_indicator));
      await tester.pumpAndSettle();
      expect(find.byKey(_details), findsOneWidget);
      expect(
        find.text(l10n.insecureServerDetailBody(_devServer)),
        findsOneWidget,
      );
      expect(find.text(l10n.insecureServerDetailTurnOff), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.byKey(const ValueKey('insecure_server_details_close')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_details), findsNothing);
      expect(find.byKey(_indicator), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('account settings at 390 px ($code) show the indicator only '
        'for an insecure server', (tester) async {
      await phone(tester);
      Widget settings(String? insecureOrigin) => host(
        Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: AccountSettingsView(
              summary: AccountSessionSummary(
                username: 'alice',
                serverUrl: _devServer,
                accountId: 'acct-1234',
                deviceId: 'device-5678',
                vaultName: 'Personal',
                instanceAdmin: false,
                insecureServerOrigin: insecureOrigin,
              ),
              onLock: () async {},
              onSignOut: () async {},
              describeError: (_) => 'failed',
            ),
          ),
        ),
        locale: locale,
      );
      const indicator = ValueKey('account_settings_insecure_server');

      await tester.pumpWidget(settings(null));
      await tester.pumpAndSettle();
      expect(find.byKey(indicator), findsNothing);
      expect(find.text(l10n.insecureServerIndicator), findsNothing);

      await tester.pumpWidget(settings(_devServer));
      await tester.pumpAndSettle();
      expect(find.byKey(indicator), findsOneWidget);
      expect(find.text(l10n.insecureServerIndicator), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(indicator));
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.insecureServerDetailBody(_devServer)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('workspace at 390 px ($code) keeps a banner on screen for an '
        'insecure server', (tester) async {
      await phone(tester);
      final workspace =
          _WorkspaceController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(const FlutterSecureStorage()),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.hosts
            ..api = ApiClient(baseUrl: _devServer, allowInsecure: true);
      addTearDown(workspace.dispose);

      await tester.pumpWidget(
        host(AppShell(controller: workspace), locale: locale),
      );
      await tester.pumpAndSettle();

      const banner = ValueKey('insecure_server_banner');
      expect(find.byKey(banner), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(banner),
          matching: find.text(l10n.insecureServerIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(banner),
          matching: find.text(_devServer),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('workspace shows no banner for a normal server', (tester) async {
    final workspace =
        _WorkspaceController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(const FlutterSecureStorage()),
          )
          ..stage = ClientStage.workspace
          ..page = WorkspacePage.hosts
          ..api = ApiClient(baseUrl: _devServer);
    addTearDown(workspace.dispose);

    await tester.pumpWidget(host(AppShell(controller: workspace)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('insecure_server_banner')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('option off: connecting is unchanged and nothing is marked '
      'insecure', (tester) async {
    await phone(tester);
    await tester.pumpWidget(signIn());
    await tester.pumpAndSettle();

    await typeServer(tester, 'https://sync.example.test');
    await connect(tester, 'Connect securely');

    expect(secureClients, ['https://sync.example.test']);
    expect(insecureClients, isEmpty);
    expect(app.stage, ClientStage.login);
    expect(app.insecureServerOrigin, isNull);
    expect(find.byKey(_indicator), findsNothing);
    // Stored exactly as before this option existed.
    expect(storage[_lastServerKey], 'https://sync.example.test');
    expect(tester.takeException(), isNull);
  });

  testWidgets('option off: a refused http address points at the option', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(signIn());
    await tester.pumpAndSettle();

    await typeServer(tester, 'http://192.168.1.20:8080');
    await connect(tester, 'Connect securely');

    expect(
      find.textContaining('Remote server URLs must use HTTPS'),
      findsWidgets,
    );
    expect(
      find.textContaining(
        'you can turn on “Allow insecure connection” below. Never use it for '
        'production.',
      ),
      findsWidgets,
    );
    expect(app.api, isNull);
    expect(insecureClients, isEmpty);
    expect(optionOn(tester), isFalse);
  });

  testWidgets('a server already in use with the option shows it on the '
      'sign-in page and can be switched back off', (tester) async {
    await phone(tester);
    await app.configureInsecureServer(_devServer);
    expect(
      SavedServerSelection.decode(storage[_lastServerKey])?.allowInsecure,
      isTrue,
    );

    await tester.pumpWidget(signIn());
    await tester.pumpAndSettle();
    expect(app.stage, ClientStage.login);
    expect(find.byKey(_indicator), findsOneWidget);

    final changeServer = find.text('Change server');
    await tester.ensureVisible(changeServer);
    await tester.pumpAndSettle();
    await tester.tap(changeServer);
    await tester.pumpAndSettle();

    // Same address: the switch reflects the choice in effect.
    expect(optionOn(tester), isTrue);
    expect(find.byKey(_indicator), findsOneWidget);

    // Switching it off needs no confirmation.
    await toggle(tester);
    expect(find.byKey(_dialog), findsNothing);
    expect(optionOn(tester), isFalse);

    await connect(tester, 'Connect securely');
    expect(secureClients, [_devServer]);
    expect(app.insecureServerOrigin, isNull);
    expect(find.byKey(_indicator), findsNothing);
    expect(storage[_lastServerKey], _devServer);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing to another server never inherits the option', (
    tester,
  ) async {
    await phone(tester);
    await app.configureInsecureServer(_devServer);
    app.setStage(ClientStage.server);
    await tester.pumpWidget(signIn());
    await tester.pumpAndSettle();
    expect(optionOn(tester), isTrue);

    await typeServer(tester, 'https://sync.example.test');
    expect(optionOn(tester), isFalse);
    await connect(tester, 'Connect securely');

    expect(secureClients, ['https://sync.example.test']);
    expect(app.serverUrl, 'https://sync.example.test');
    expect(app.insecureServerOrigin, isNull);
    expect(find.byKey(_indicator), findsNothing);
    expect(storage[_lastServerKey], 'https://sync.example.test');
  });

  testWidgets('the confirmation only counts for the address it named', (
    tester,
  ) async {
    await phone(tester);
    await tester.pumpWidget(signIn());
    await tester.pumpAndSettle();

    await typeServer(tester, _devServer);
    await toggle(tester);
    expect(find.byKey(_dialog), findsOneWidget);
    // The address changes while the dialog is open.
    tester.widget<TextField>(find.byType(TextField).first).controller!.text =
        'https://172.19.99.2';
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();

    expect(optionOn(tester), isFalse);
    expect(find.text('Connect securely'), findsOneWidget);
  });

  testWidgets('locked workspace keeps the indicator in view', (tester) async {
    await phone(tester);
    await app.configureInsecureServer(_devServer);
    await tester.pumpWidget(host(LockedWorkspaceScreen(controller: app)));
    await tester.pumpAndSettle();

    expect(find.byKey(_indicator), findsOneWidget);
    expect(find.text(_devServer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('in a browser', () {
    final l10n = lookupAppLocalizations(const Locale('en'));

    testWidgets('the control only promises what a browser can do', (
      tester,
    ) async {
      await phone(tester);
      await tester.pumpWidget(signIn(web: true));
      await tester.pumpAndSettle();

      expect(find.text(l10n.allowInsecureServerWarningWeb), findsOneWidget);
      expect(find.text(l10n.allowInsecureServerWarning), findsNothing);

      // Certificate errors cannot be bypassed: refuse instead of pretending.
      await typeServer(tester, _devServer);
      await toggle(tester);
      expect(find.byKey(_dialog), findsNothing);
      expect(
        find.text(l10n.allowInsecureServerWebHttpsUnsupported),
        findsOneWidget,
      );
      expect(optionOn(tester), isFalse);
      await dismissSnackBar(tester);

      // A plain http address is the one thing it can permit.
      await typeServer(tester, 'http://172.19.99.1:8080');
      await toggle(tester);
      expect(
        find.text(
          l10n.allowInsecureServerConfirmBodyWeb('http://172.19.99.1:8080'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();
      expect(optionOn(tester), isTrue);

      await connect(tester, l10n.insecureServerConnect);
      expect(insecureClients, ['http://172.19.99.1:8080']);
      expect(app.insecureServerOrigin, 'http://172.19.99.1:8080');
      expect(tester.takeException(), isNull);
    });
  });
}

class _InstanceApi extends ApiClient {
  _InstanceApi(String baseUrl, this._instance, {required super.allowInsecure})
    : super(baseUrl: baseUrl);

  final InstanceInfo _instance;

  @override
  Future<InstanceInfo> fetchInstance() async => _instance;
}

class _WorkspaceController extends AppController {
  _WorkspaceController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });

  @override
  bool get authenticated => true;
}
