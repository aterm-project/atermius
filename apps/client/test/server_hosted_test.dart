// The browser build is served by an Atermius server and belongs to it: no
// local mode, no server address to choose, only that server's sign-in page.

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/main.dart';
import 'package:aterm_client/platform/server_hosted.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/storage/workspace_mode.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/auth_flow.dart';
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
const _origin = 'https://vault.example.test:8443';
const _locales = [Locale('en'), Locale('zh'), Locale('ja'), Locale('ru')];

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
  var reachable = true;

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

  void hosted(String page) {
    debugServerHostedOverride = true;
    debugServerHostedBase = Uri.parse(page);
    addTearDown(() {
      debugServerHostedOverride = null;
      debugServerHostedBase = null;
    });
  }

  setUp(() {
    reachable = true;
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
        return _InstanceApi(baseUrl, instance, () => reachable, false);
      },
      insecureApiClientFactoryForTesting: (baseUrl) {
        insecureClients.add(baseUrl);
        return _InstanceApi(baseUrl, instance, () => reachable, true);
      },
    );
  });

  tearDown(() async {
    app.dispose();
    await database.close();
  });

  Widget signIn({Locale locale = const Locale('en')}) => MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: buildAppTheme(locale: locale),
    builder: (context, child) => WorkspaceModeScope(
      mode: WorkspaceMode.server,
      busy: false,
      onSwitch: () async {},
      child: child!,
    ),
    home: AnimatedBuilder(
      animation: app,
      builder: (context, _) => AuthFlow(controller: app),
    ),
  );

  test('native clients are not hosted', () {
    expect(serverHostedClient, isFalse);
  });

  test('the page origin is the server, whatever path the page has', () {
    hosted('$_origin/some/page?x=1#frag');
    expect(serverHostedOrigin, _origin);
    expect(serverHostedOverPlainHttp, isFalse);
    debugServerHostedBase = Uri.parse('http://192.168.1.9:8080/');
    expect(serverHostedOrigin, 'http://192.168.1.9:8080');
    expect(serverHostedOverPlainHttp, isTrue);
    debugServerHostedBase = Uri.parse('http://localhost:8081/');
    expect(serverHostedOverPlainHttp, isFalse);
  });

  group('session restore', () {
    test('connects to the page server without asking for an address', () async {
      hosted('$_origin/');
      await app.restoreLastServer();
      expect(app.serverUrl, _origin);
      expect(secureClients, [_origin]);
      expect(insecureClients, isEmpty);
      expect(app.stage, isNot(ClientStage.server));
      expect(app.insecureServerOrigin, isNull);
    });

    test('an address remembered for another server is not used', () async {
      storage[_lastServerKey] = 'https://other.example.test';
      hosted('$_origin/');
      await app.restoreLastServer();
      expect(app.serverUrl, _origin);
      expect(secureClients, [_origin]);
    });

    test('a page loaded over plain http from another computer connects with '
        'the insecure warning', () async {
      hosted('http://192.168.1.9:8080/');
      await app.restoreLastServer();
      expect(app.serverUrl, 'http://192.168.1.9:8080');
      expect(insecureClients, ['http://192.168.1.9:8080']);
      expect(app.insecureServerOrigin, 'http://192.168.1.9:8080');
    });

    test('native clients still use the remembered address', () async {
      storage[_lastServerKey] = 'https://other.example.test';
      await app.restoreLastServer();
      expect(app.serverUrl, 'https://other.example.test');
      expect(secureClients, ['https://other.example.test']);
    });
  });

  group('sign-in page', () {
    for (final locale in _locales) {
      final l10n = lookupAppLocalizations(locale);
      testWidgets('390 px (${locale.languageCode}): account and password of '
          'this server only', (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        hosted('$_origin/');
        await tester.runAsync(app.restoreLastServer);
        await tester.pumpWidget(signIn(locale: locale));
        await tester.pumpAndSettle();

        // The sign-in fields are there...
        expect(find.text(l10n.emailOrUsername), findsOneWidget);
        expect(find.text(l10n.masterPassword), findsOneWidget);
        // ...and nothing that names, changes or weakens the server.
        expect(find.text(l10n.serverUrl), findsNothing);
        expect(find.text(l10n.changeServer), findsNothing);
        expect(
          find.byKey(const ValueKey('allow_insecure_server')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('hosted_server_form')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('native clients keep the address field and Change server', (
      tester,
    ) async {
      await tester.pumpWidget(signIn());
      await tester.pumpAndSettle();
      expect(find.text('Server URL'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('allow_insecure_server')),
        findsOneWidget,
      );
    });

    testWidgets('an unreachable server offers only to try again', (
      tester,
    ) async {
      hosted('$_origin/');
      reachable = false;
      await tester.runAsync(app.restoreLastServer);
      await tester.pumpWidget(signIn());
      await tester.pumpAndSettle();

      expect(app.stage, ClientStage.server);
      expect(find.byKey(const ValueKey('hosted_server_form')), findsOneWidget);
      expect(find.text(_origin), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byKey(const ValueKey('allow_insecure_server')), findsNothing);

      reachable = true;
      secureClients.clear();
      await tester.tap(find.byKey(const ValueKey('hosted_server_retry')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(secureClients, [_origin]);
      expect(app.stage, isNot(ClientStage.server));
      expect(find.byKey(const ValueKey('hosted_server_form')), findsNothing);
      expect(find.text('Email or username'), findsOneWidget);
    });
  });

  group('no local mode', () {
    testWidgets('startup goes straight to the server, even when an earlier '
        'version stored local mode', (tester) async {
      hosted('$_origin/');
      final store = _ModeStore(WorkspaceMode.local);
      var serverStarts = 0;
      await tester.pumpWidget(
        AtermiusApp(
          enableProfileModeSelection: true,
          modeStore: store,
          serverInitializer: () async {
            serverStarts++;
            return app;
          },
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      expect(serverStarts, 1);
      expect(find.text('Choose a workspace'), findsNothing);
      expect(find.byKey(const ValueKey('local_mode_start')), findsNothing);
      expect(find.text('Email or username'), findsOneWidget);
      expect(find.text('Server URL'), findsNothing);
      // The stored choice is left as it was; it is simply not offered here.
      expect(await store.read(), WorkspaceMode.local);
    });

    testWidgets('settings offer no switch to local mode', (tester) async {
      hosted('$_origin/');
      var switched = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: WorkspaceModeScope(
              mode: WorkspaceMode.server,
              busy: false,
              onSwitch: () async => switched++,
              child: const ScopedWorkspaceModeSettings(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceModeSettings), findsNothing);
      expect(find.text('Switch to local mode'), findsNothing);
      expect(switched, 0);
    });

    testWidgets('native clients still offer the switch', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: WorkspaceModeScope(
              mode: WorkspaceMode.server,
              busy: false,
              onSwitch: () async {},
              child: const ScopedWorkspaceModeSettings(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceModeSettings), findsOneWidget);
    });
  });
}

class _InstanceApi extends ApiClient {
  _InstanceApi(String baseUrl, this._instance, this._reachable, bool insecure)
    : super(baseUrl: baseUrl, allowInsecure: insecure);

  final InstanceInfo _instance;
  final bool Function() _reachable;

  @override
  Future<InstanceInfo> fetchInstance() async {
    if (!_reachable()) {
      throw const ApiException(
        statusCode: 503,
        code: 'unavailable',
        message: 'unavailable',
      );
    }
    return _instance;
  }
}

class _ModeStore implements WorkspaceModeStore {
  _ModeStore(this.value);
  WorkspaceMode? value;

  @override
  Future<WorkspaceMode?> read() async => value;

  @override
  Future<void> write(WorkspaceMode mode) async => value = mode;
}
