// The development-only insecure option at controller level, against a real
// loopback HTTPS server with an untrusted certificate: what it permits, how it
// is remembered on the device, and that it never follows the user to another
// server.

import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/self_signed_tls_server.dart';

const _lastServerKey = 'atermius.v1.last_server';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Each simulated restart opens its own in-memory database.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SodiumSumo sodium;
  late String signingPublicKey;
  SecurityContext? tls;
  late Map<String, String> storage;
  late SelfSignedTlsServer server;
  late HttpServer plain;
  final databases = <ClientDatabase>[];
  final controllers = <AppController>[];

  Map<String, Object?> instanceJson() => {
    'instance_id': '11111111-1111-4111-8111-111111111111',
    'server_space_id': '22222222-2222-4222-8222-222222222222',
    'generation': '44444444-4444-4444-8444-444444444444',
    'protocol_version': 1,
    'setup_required': false,
    'capabilities': const <String>[],
    'signing_public_key': signingPublicKey,
    'signing_key_transitions': const <Object>[],
  };

  setUpAll(() async {
    // The widget test binding replaces dart:io's HttpClient with a mock that
    // never reaches the network; these tests need the real one.
    HttpOverrides.global = null;
    sodium = await SodiumSumoInit.init();
    final identity = DeviceIdentity.create(sodium);
    signingPublicKey = identity.signingPublicKey;
    identity.dispose();
    tls = await SelfSignedTlsServer.createSelfSignedContext();
  });

  /// False (and the test is reported as skipped) without `openssl`.
  Future<bool> start() async {
    final context = tls;
    if (context == null) {
      markTestSkipped('openssl is required to create the test certificate');
      return false;
    }
    storage = {};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      storage,
    );
    server = await SelfSignedTlsServer.start(
      context,
      json: (request) =>
          request.uri.path == '/api/v1/instance' ? instanceJson() : null,
    );
    // A second, different origin that needs no permission: loopback http.
    plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    plain.listen((request) async {
      await request.drain<void>();
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(instanceJson()));
      await request.response.close();
    });
    addTearDown(() async {
      for (final controller in controllers) {
        controller.dispose();
      }
      controllers.clear();
      for (final database in databases) {
        await database.close();
      }
      databases.clear();
      await server.close();
      await plain.close(force: true);
    });
    return true;
  }

  /// A fresh controller over the same device storage: an app restart.
  AppController launch() {
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    databases.add(database);
    final controller = AppController(
      sodium: sodium,
      database: database,
      secureStore: ClientSecureStore(const FlutterSecureStorage()),
    );
    controllers.add(controller);
    return controller;
  }

  String plainOrigin() => 'http://127.0.0.1:${plain.port}';

  test('option off: an untrusted certificate is refused, nothing is stored '
      'and the message leads to the option', () async {
    if (!await start()) return;
    final app = launch();

    await expectLater(app.configureServer(server.origin), throwsA(anything));

    expect(app.api, isNull);
    expect(app.stage, ClientStage.server);
    expect(app.insecureServerOrigin, isNull);
    expect(app.errorMessage, currentL10n.insecureServerCertificateHint);
    expect(app.errorMessage, contains('Allow insecure connection'));
    expect(app.errorMessage, contains('Never use it for production'));
    expect(storage, isEmpty);
    expect(server.requests, isEmpty);
  });

  test('option on: connects to that server, is remembered on this device and '
      'survives a restart', () async {
    if (!await start()) return;
    final app = launch();

    await app.configureInsecureServer(server.origin);

    expect(app.stage, ClientStage.login);
    expect(app.serverUrl, server.origin);
    expect(app.insecureServerOrigin, server.origin);
    expect(app.errorMessage, isNull);
    expect(server.requests, ['GET /api/v1/instance']);
    // Stored with the server address in the single device-local value.
    final saved = SavedServerSelection.decode(storage[_lastServerKey])!;
    expect(saved.baseUrl, server.origin);
    expect(saved.allowInsecure, isTrue);
    expect(
      storage.keys.where((key) => key != _lastServerKey),
      everyElement(isNot(contains('insecure'))),
    );

    final restarted = launch();
    await restarted.restoreLastServer();

    expect(restarted.stage, ClientStage.login);
    expect(restarted.serverUrl, server.origin);
    expect(restarted.insecureServerOrigin, server.origin);
    expect(restarted.api?.insecureServer?.origin, server.origin);
    expect(server.requests, ['GET /api/v1/instance', 'GET /api/v1/instance']);
  });

  test('switching to another server drops the permission, also after a '
      'restart, and it does not come back for the first server', () async {
    if (!await start()) return;
    final app = launch();
    await app.configureInsecureServer(server.origin);
    expect(app.insecureServerOrigin, server.origin);

    await app.configureServer(plainOrigin());

    expect(app.serverUrl, plainOrigin());
    expect(app.insecureServerOrigin, isNull);
    expect(app.api?.insecureServer, isNull);
    // Back to the plain format: no trace of the earlier choice.
    expect(storage[_lastServerKey], plainOrigin());

    final restarted = launch();
    await restarted.restoreLastServer();
    expect(restarted.serverUrl, plainOrigin());
    expect(restarted.insecureServerOrigin, isNull);

    // The first server needs a fresh, explicit opt-in again.
    final requestsBefore = server.requests.length;
    await expectLater(
      restarted.configureServer(server.origin),
      throwsA(anything),
    );
    expect(restarted.errorMessage, currentL10n.insecureServerCertificateHint);
    expect(restarted.serverUrl, plainOrigin());
    expect(restarted.insecureServerOrigin, isNull);
    expect(server.requests.length, requestsBefore);
    expect(storage[_lastServerKey], plainOrigin());
  });

  test('the option is not sticky: reconnecting without it validates the '
      'certificate again', () async {
    if (!await start()) return;
    final app = launch();
    await app.configureInsecureServer(server.origin);

    await expectLater(app.configureServer(server.origin), throwsA(anything));

    expect(app.errorMessage, currentL10n.insecureServerCertificateHint);
    expect(server.requests, ['GET /api/v1/instance']);
  });

  test('a stored plain address restores with the option off', () async {
    if (!await start()) return;
    storage[_lastServerKey] = server.origin;
    final app = launch();

    await app.restoreLastServer();

    expect(app.api, isNull);
    expect(app.insecureServerOrigin, isNull);
    expect(server.requests, isEmpty);
    expect(storage[_lastServerKey], server.origin);
  });

  group('non-loopback http', () {
    test('option off: refused with today\'s message plus a pointer to the '
        'option', () async {
      if (!await start()) return;
      final app = launch();

      await expectLater(
        app.configureServer('http://192.168.1.20:8080'),
        throwsA(isA<ServerUrlRequiresHttpsException>()),
      );

      expect(
        app.errorMessage,
        'FormatException: Remote server URLs must use HTTPS. HTTP is allowed '
        'only for localhost development. '
        '${currentL10n.insecureServerHttpHint}',
      );
      expect(app.api, isNull);
      expect(storage, isEmpty);
    });

    test('option on: accepted for that origin and remembered', () async {
      if (!await start()) return;
      final created = <String>[];
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      databases.add(database);
      final app = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(const FlutterSecureStorage()),
        apiClientFactoryForTesting: (baseUrl) =>
            fail('the secure factory must not be used: $baseUrl'),
        insecureApiClientFactoryForTesting: (baseUrl) {
          created.add(baseUrl);
          return _InstanceApi(baseUrl, InstanceInfo.fromJson(instanceJson()));
        },
      );
      controllers.add(app);

      await app.configureInsecureServer('http://192.168.1.20:8080/');

      expect(created, ['http://192.168.1.20:8080']);
      expect(app.stage, ClientStage.login);
      expect(app.insecureServerOrigin, 'http://192.168.1.20:8080');
      final saved = SavedServerSelection.decode(storage[_lastServerKey])!;
      expect(saved.baseUrl, 'http://192.168.1.20:8080');
      expect(saved.allowInsecure, isTrue);
    });
  });
}

class _InstanceApi extends ApiClient {
  _InstanceApi(String baseUrl, this._instance)
    : super(baseUrl: baseUrl, allowInsecure: true);

  final InstanceInfo _instance;

  @override
  Future<InstanceInfo> fetchInstance() async => _instance;
}
