// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/auth/session_startup.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/platform/server_hosted.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/auth_flow.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _serverUrl = 'https://restore.example.test/tenant';
const _instanceId = '11111111-1111-4111-8111-111111111111';
const _serverSpaceId = '22222222-2222-4222-8222-222222222222';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SodiumSumo sodium;
  late Map<String, String> storageValues;
  late ClientSecureStore secureStore;
  late ClientDatabase database;
  late AppController app;
  late List<InstanceInfo> instanceResponses;
  late List<String> requests;
  late List<_FakeInstanceApi> clients;
  late bool appDisposed;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  setUp(() {
    storageValues = {};
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
      storageValues,
    );
    secureStore = ClientSecureStore(const FlutterSecureStorage());
    database = ClientDatabase.forTesting(NativeDatabase.memory());
    instanceResponses = [];
    requests = [];
    clients = [];
    appDisposed = false;
    app = AppController(
      sodium: sodium,
      database: database,
      secureStore: secureStore,
      apiClientFactoryForTesting: (baseUrl) {
        final client = _FakeInstanceApi(
          baseUrl: baseUrl,
          instanceResponses: instanceResponses,
          requests: requests,
        );
        clients.add(client);
        return client;
      },
    );
  });

  tearDown(() async {
    if (!appDisposed) app.dispose();
    await database.close();
  });

  test(
    'same instance key rollback is isolated until exact out-of-band fingerprint confirmation',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final restored = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(restored.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(_instance(restored.signingPublicKey));

      await expectLater(
        app.configureServer(_serverUrl),
        throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
      );

      final pending = app.pendingInstanceIdentityRecovery!;
      expect(
        pending.pinnedIdentity.signingPublicKey,
        previous.signingPublicKey,
      );
      expect(pending.candidate.signingPublicKey, restored.signingPublicKey);
      expect(app.api, isNull);
      expect(app.instance, isNull);
      expect(app.stage, ClientStage.server);
      expect(requests, ['instance']);

      await expectLater(
        app.confirmPendingInstanceIdentityRecovery(
          candidateFingerprint: 'SHA256:wrong',
        ),
        throwsFormatException,
      );
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        previous.signingPublicKey,
      );
      expect(app.pendingInstanceIdentityRecovery, same(pending));
      expect(requests, ['instance']);

      await app.cancelPendingInstanceIdentityRecovery();
      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(clients.single.closed, isTrue);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        previous.signingPublicKey,
      );

      instanceResponses.add(_instance(restored.signingPublicKey));
      await expectLater(
        app.configureServer(_serverUrl),
        throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
      );
      instanceResponses.add(_instance(restored.signingPublicKey));
      final approvedCandidateFingerprint =
          app.pendingInstanceIdentityRecovery!.candidateFingerprint;

      await app.confirmPendingInstanceIdentityRecovery(
        candidateFingerprint: approvedCandidateFingerprint,
      );

      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        restored.signingPublicKey,
      );
      expect(app.api, same(clients.last));
      expect(app.instance?.signingPublicKey, restored.signingPublicKey);
      expect(app.serverUrl, _serverUrl);
      expect(app.stage, ClientStage.login);
      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(requests, ['instance', 'instance', 'instance']);
      expect(requests, isNot(contains('prelogin')));
      expect(
        storageValues.keys.where((key) => key.contains('.device.')),
        isEmpty,
      );
      expect(
        storageValues.keys.where((key) => key.contains('.session.')),
        isEmpty,
      );
    },
  );

  test(
    'startup preserves the identity mismatch and exposes its candidate',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final restored = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(restored.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      await secureStore.saveLastServer(_serverUrl);
      instanceResponses.add(_instance(restored.signingPublicKey));

      await app.restoreLastServer();

      expect(app.pendingInstanceIdentityRecovery, isNotNull);
      expect(app.errorMessage, contains('separate trusted channel'));
      expect(app.errorMessage, isNot(contains('Couldn\'t read local security settings. Check browser storage and try again.')));
      expect(app.api, isNull);
      expect(requests, ['instance']);
    },
  );

  group('server replaced by a new instance', () {
    const replacedInstanceId = '55555555-5555-4555-8555-555555555555';
    const replacedSpaceId = '66666666-6666-4666-8666-666666666666';

    void hostAt(String page) {
      debugServerHostedOverride = true;
      debugServerHostedBase = Uri.parse(page);
      addTearDown(() {
        debugServerHostedOverride = null;
        debugServerHostedBase = null;
      });
    }

    test(
      'hosted client names the cause and can start over with the new instance',
      () async {
        hostAt('https://restore.example.test/');
        final origin = serverHostedOrigin;
        final previous = DeviceIdentity.create(sodium);
        final replacement = DeviceIdentity.create(sodium);
        final staleDevice = DeviceIdentity.create(sodium);
        addTearDown(previous.dispose);
        addTearDown(replacement.dispose);
        addTearDown(staleDevice.dispose);
        await secureStore.saveServerIdentityPin(
          origin,
          _pin(previous.signingPublicKey),
        );
        await secureStore.saveDevice(origin, staleDevice);
        await secureStore.saveDeviceAccountId(origin, 'old-account');
        await secureStore.saveRefreshToken(origin, 'admin@example.test', 'r');
        await secureStore.saveSessionResumeHint(
          origin,
          SessionResumeHint(
            username: 'admin@example.test',
            accountId: 'old-account',
            deviceId: staleDevice.deviceId,
          ),
        );
        await secureStore.saveKnownHost(origin, 'ssh.example.test:22', 'fp');
        instanceResponses.add(
          _instance(
            replacement.signingPublicKey,
            instanceId: replacedInstanceId,
            serverSpaceId: replacedSpaceId,
          ),
        );

        await app.restoreLastServer();

        expect(app.pendingInstanceReplacement, isNotNull);
        expect(app.api, isNull);
        expect(
          app.errorMessage,
          isNot(currentL10n.couldntReadLocalSecuritySettingsCheck),
        );
        expect(
          app.errorMessage,
          currentL10n.theServerInstanceIdentityChangedTo,
        );
        expect(
          (await secureStore.readServerIdentityPin(origin))?.instanceId,
          _instanceId,
        );

        instanceResponses.add(
          _instance(
            replacement.signingPublicKey,
            instanceId: replacedInstanceId,
            serverSpaceId: replacedSpaceId,
          ),
        );
        await app.confirmPendingInstanceReplacement();

        expect(app.pendingInstanceReplacement, isNull);
        expect(app.errorMessage, isNull);
        expect(app.api, isNotNull);
        final pin = await secureStore.readServerIdentityPin(origin);
        expect(pin?.instanceId, replacedInstanceId);
        expect(pin?.signingPublicKey, replacement.signingPublicKey);
        expect(await secureStore.loadDevice(origin, app.crypto), isNull);
        expect(await secureStore.deviceAccountId(origin), isNull);
        expect(await secureStore.sessionResumeHint(origin), isNull);
        expect(
          await secureStore.readRefreshToken(origin, 'admin@example.test'),
          isNull,
        );
        // SSH host trust is the user's data, not sign-in state.
        expect(
          await secureStore.readKnownHost(origin, 'ssh.example.test:22'),
          'fp',
        );
      },
    );

    test(
      'a different instance appearing during confirmation changes nothing',
      () async {
        hostAt('https://restore.example.test/');
        final origin = serverHostedOrigin;
        final previous = DeviceIdentity.create(sodium);
        final shown = DeviceIdentity.create(sodium);
        final other = DeviceIdentity.create(sodium);
        final staleDevice = DeviceIdentity.create(sodium);
        addTearDown(previous.dispose);
        addTearDown(shown.dispose);
        addTearDown(other.dispose);
        addTearDown(staleDevice.dispose);
        await secureStore.saveServerIdentityPin(
          origin,
          _pin(previous.signingPublicKey),
        );
        await secureStore.saveDevice(origin, staleDevice);
        instanceResponses.add(
          _instance(
            shown.signingPublicKey,
            instanceId: replacedInstanceId,
            serverSpaceId: replacedSpaceId,
          ),
        );
        await app.restoreLastServer();
        instanceResponses.add(
          _instance(
            other.signingPublicKey,
            instanceId: replacedInstanceId,
            serverSpaceId: replacedSpaceId,
          ),
        );

        await expectLater(
          app.confirmPendingInstanceReplacement(),
          throwsStateError,
        );

        expect(app.api, isNull);
        expect(
          (await secureStore.readServerIdentityPin(origin))?.instanceId,
          _instanceId,
        );
        expect(await secureStore.loadDevice(origin, app.crypto), isNotNull);
      },
    );

    test('a typed server address still refuses a replaced instance', () async {
      final previous = DeviceIdentity.create(sodium);
      final replacement = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(replacement.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(
        _instance(
          replacement.signingPublicKey,
          instanceId: replacedInstanceId,
          serverSpaceId: replacedSpaceId,
        ),
      );

      await expectLater(
        app.configureServer(_serverUrl),
        throwsA(isA<InstanceReplacedException>()),
      );

      expect(app.pendingInstanceReplacement, isNull);
      expect(app.api, isNull);
      expect(clients.single.closed, isTrue);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.instanceId,
        _instanceId,
      );
    });
  });

  group('sign-in with a device left by another account', () {
    const accountId = '77777777-7777-4777-8777-777777777777';

    Future<_FakeSignInApi> connect() async {
      final signing = DeviceIdentity.create(sodium);
      addTearDown(signing.dispose);
      final fake = _FakeSignInApi(baseUrl: _serverUrl, accountId: accountId);
      final signIn = AppController(
        sodium: sodium,
        database: database,
        secureStore: secureStore,
        apiClientFactoryForTesting: (_) => fake,
      );
      addTearDown(signIn.dispose);
      fake.instance = InstanceInfo(
        instanceId: _instanceId,
        serverSpaceId: _serverSpaceId,
        generation: '44444444-4444-4444-8444-444444444444',
        protocolVersion: 1,
        setupRequired: false,
        capabilities: const ['password_device_enrollment'],
        signingPublicKey: signing.signingPublicKey,
        signingKeyTransitions: const [],
      );
      await signIn.configureServer(_serverUrl);
      fake.controller = signIn;
      return fake;
    }

    Future<void> signIn(_FakeSignInApi fake) => expectLater(
      fake.controller.login(
        username: 'admin@example.test',
        password: 'correct horse battery',
      ),
      throwsA(isA<ApiException>()),
    );

    test('a device recorded for another account is not presented', () async {
      final stale = DeviceIdentity.create(sodium);
      addTearDown(stale.dispose);
      await secureStore.saveDevice(_serverUrl, stale);
      await secureStore.saveDeviceAccountId(_serverUrl, 'someone-else');
      final fake = await connect();

      await signIn(fake);

      expect(fake.logins, hasLength(1));
      expect(fake.logins.single.enrolled, isTrue);
      expect(fake.logins.single.deviceId, isNot(stale.deviceId));
      // Nothing was accepted, so the stored device is untouched.
      final kept = await secureStore.loadDevice(
        _serverUrl,
        fake.controller.crypto,
      );
      addTearDown(() => kept?.dispose());
      expect(kept?.deviceId, stale.deviceId);
    });

    test(
      'a device of unknown owner is retried once as an enrollment',
      () async {
        final stale = DeviceIdentity.create(sodium);
        addTearDown(stale.dispose);
        await secureStore.saveDevice(_serverUrl, stale);
        final fake = await connect();

        await signIn(fake);

        expect(fake.logins.map((l) => l.enrolled), [false, true]);
        expect(fake.logins.first.deviceId, stale.deviceId);
        expect(fake.logins.last.deviceId, isNot(stale.deviceId));
        expect(
          fake.controller.errorMessage,
          currentL10n.signInCredentialsRejected,
        );
      },
    );

    test(
      'this account\'s own device is presented once, without a retry',
      () async {
        final own = DeviceIdentity.create(sodium);
        addTearDown(own.dispose);
        await secureStore.saveDevice(_serverUrl, own);
        await secureStore.saveDeviceAccountId(_serverUrl, accountId);
        final fake = await connect();

        await signIn(fake);

        expect(fake.logins, hasLength(1));
        expect(fake.logins.single.enrolled, isFalse);
        expect(fake.logins.single.deviceId, own.deviceId);
      },
    );
  });

  test('server identity pins persist per canonical URL namespace', () async {
    final oldKey = DeviceIdentity.create(sodium);
    final candidateKey = DeviceIdentity.create(sodium);
    addTearDown(oldKey.dispose);
    addTearDown(candidateKey.dispose);
    const anotherTenant = 'https://restore.example.test/other';
    await secureStore.saveServerIdentityPin(
      _serverUrl,
      _pin(oldKey.signingPublicKey),
    );

    final reloadedStore = ClientSecureStore(const FlutterSecureStorage());
    expect(
      (await reloadedStore.readServerIdentityPin(
        'HTTPS://RESTORE.EXAMPLE.TEST:443/tenant/',
      ))?.signingPublicKey,
      oldKey.signingPublicKey,
    );
    expect(await reloadedStore.readServerIdentityPin(anotherTenant), isNull);

    await reloadedStore.saveServerIdentityPin(
      _serverUrl,
      _pin(candidateKey.signingPublicKey),
    );
    expect(
      (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
      candidateKey.signingPublicKey,
    );
    expect(await reloadedStore.readServerIdentityPin(anotherTenant), isNull);
  });

  test(
    'candidate change during confirmation keeps pin unchanged and review recoverable',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final reviewed = DeviceIdentity.create(sodium);
      final changed = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(reviewed.dispose);
      addTearDown(changed.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(_instance(reviewed.signingPublicKey));

      await expectLater(
        app.configureServer(_serverUrl),
        throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
      );
      final recovery = app.pendingInstanceIdentityRecovery!;
      instanceResponses.add(_instance(changed.signingPublicKey));

      await expectLater(
        app.confirmPendingInstanceIdentityRecovery(
          candidateFingerprint: recovery.candidateFingerprint,
        ),
        throwsStateError,
      );

      expect(app.pendingInstanceIdentityRecovery, same(recovery));
      expect(app.api, isNull);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        previous.signingPublicKey,
      );
      expect(requests, ['instance', 'instance']);
      expect(requests, isNot(contains('prelogin')));
    },
  );

  test(
    'confirmation is single-flight and blocks cancel or server changes',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final restored = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(restored.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(_instance(restored.signingPublicKey));
      await expectLater(
        app.configureServer(_serverUrl),
        throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
      );
      instanceResponses.add(_instance(restored.signingPublicKey));
      final client = clients.single;
      client.fetchGate = Completer<void>();

      final confirmation = app.confirmPendingInstanceIdentityRecovery(
        candidateFingerprint:
            app.pendingInstanceIdentityRecovery!.candidateFingerprint,
      );
      await expectLater(
        app.confirmPendingInstanceIdentityRecovery(
          candidateFingerprint:
              app.pendingInstanceIdentityRecovery!.candidateFingerprint,
        ),
        throwsStateError,
      );
      await expectLater(
        app.cancelPendingInstanceIdentityRecovery(),
        throwsStateError,
      );
      await expectLater(app.configureServer(_serverUrl), throwsStateError);
      expect(requests, ['instance', 'instance']);

      client.fetchGate!.complete();
      await confirmation;
      expect(app.stage, ClientStage.login);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        restored.signingPublicKey,
      );
      expect(requests, ['instance', 'instance']);
    },
  );

  test('disposing controller closes its isolated candidate API', () async {
    final previous = DeviceIdentity.create(sodium);
    final restored = DeviceIdentity.create(sodium);
    addTearDown(previous.dispose);
    addTearDown(restored.dispose);
    await secureStore.saveServerIdentityPin(
      _serverUrl,
      _pin(previous.signingPublicKey),
    );
    instanceResponses.add(_instance(restored.signingPublicKey));
    await expectLater(
      app.configureServer(_serverUrl),
      throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
    );

    final pending = app.pendingInstanceIdentityRecovery;
    app.dispose();
    appDisposed = true;

    expect(pending, isNotNull);
    expect(clients.single.closed, isTrue);
    expect(app.pendingInstanceIdentityRecovery, isNull);
    expect(
      (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
      previous.signingPublicKey,
    );
  });

  test(
    'different instance or server-space IDs never offer key repinning',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final candidate = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(candidate.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(
        _instance(
          candidate.signingPublicKey,
          instanceId: '33333333-3333-4333-8333-333333333333',
        ),
      );

      await expectLater(app.configureServer(_serverUrl), throwsFormatException);

      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(clients.single.closed, isTrue);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        previous.signingPublicKey,
      );

      const differentSpaceUrl = 'https://restore.example.test/space-mismatch';
      await secureStore.saveServerIdentityPin(
        differentSpaceUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(
        _instance(
          candidate.signingPublicKey,
          serverSpaceId: '33333333-3333-4333-8333-333333333333',
        ),
      );
      await expectLater(
        app.configureServer(differentSpaceUrl),
        throwsFormatException,
      );

      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(clients.last.closed, isTrue);
      expect(
        (await secureStore.readServerIdentityPin(
          differentSpaceUrl,
        ))?.signingPublicKey,
        previous.signingPublicKey,
      );
      expect(requests, ['instance', 'instance']);
    },
  );

  test(
    'valid old-key transition still updates pin without a confirmation prompt',
    () async {
      final previous = DeviceIdentity.create(sodium);
      final intermediate = DeviceIdentity.create(sodium);
      final current = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(intermediate.dispose);
      addTearDown(current.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      final first = _transition(
        sodium,
        previous,
        intermediate.signingPublicKey,
      );
      final second = _transition(
        sodium,
        intermediate,
        current.signingPublicKey,
        fromPublicKey: intermediate.signingPublicKey,
      );
      instanceResponses.add(
        _instance(current.signingPublicKey, transitions: [first, second]),
      );

      await app.configureServer(_serverUrl);

      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(app.stage, ClientStage.login);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        current.signingPublicKey,
      );
      expect(requests, ['instance']);
    },
  );

  testWidgets(
    'recovery review is accessible, cancel preserves the pin, confirmation proceeds to login without auth',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      final previous = DeviceIdentity.create(sodium);
      final restored = DeviceIdentity.create(sodium);
      addTearDown(previous.dispose);
      addTearDown(restored.dispose);
      await secureStore.saveServerIdentityPin(
        _serverUrl,
        _pin(previous.signingPublicKey),
      );
      instanceResponses.add(_instance(restored.signingPublicKey));
      await expectLater(
        app.configureServer(_serverUrl),
        throwsA(isA<InstanceIdentityRecoveryRequiredException>()),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: AnimatedBuilder(
            animation: app,
            builder: (context, _) => AuthFlow(controller: app),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final firstReview = app.pendingInstanceIdentityRecovery!;
      expect(
        find.text('Restored server identity needs confirmation'),
        findsOneWidget,
      );
      expect(
        find.text('Previously trusted fingerprint · SHA-256'),
        findsOneWidget,
      );
      expect(
        find.text('Fingerprint returned by this server · SHA-256'),
        findsOneWidget,
      );
      expect(find.text(firstReview.pinnedFingerprint), findsOneWidget);
      expect(find.text(firstReview.candidateFingerprint), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('confirm_instance_identity_recovery')),
            )
            .onPressed,
        isNull,
      );

      await tester.ensureVisible(find.text('Cancel').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(app.pendingInstanceIdentityRecovery, isNull);
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        previous.signingPublicKey,
      );

      instanceResponses.add(_instance(restored.signingPublicKey));
      await tester.enterText(_textFieldWithLabel('Server URL'), _serverUrl);
      await tester.tap(find.text('Connect securely'));
      await tester.pumpAndSettle();
      instanceResponses.add(_instance(restored.signingPublicKey));
      final secondReview = app.pendingInstanceIdentityRecovery!;
      final fingerprintField = _textFieldWithLabel(
        'Type the candidate fingerprint exactly',
      );
      await tester.enterText(
        fingerprintField,
        ' ${secondReview.candidateFingerprint} ',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('confirm_instance_identity_recovery')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        fingerprintField,
        secondReview.candidateFingerprint,
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('confirm_instance_identity_recovery')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('confirm_instance_identity_recovery')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('confirm_instance_identity_recovery')),
      );
      await tester.pumpAndSettle();

      expect(app.stage, ClientStage.login);
      expect(find.text('Email or username'), findsOneWidget);
      expect(
        find.text('Restored server identity needs confirmation'),
        findsNothing,
      );
      expect(
        (await secureStore.readServerIdentityPin(_serverUrl))?.signingPublicKey,
        restored.signingPublicKey,
      );
      expect(requests, ['instance', 'instance', 'instance']);
      expect(requests, isNot(contains('prelogin')));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
    },
  );
}

Finder _textFieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'TextField labeled "$label"',
);

ServerIdentityPin _pin(String publicKey) => ServerIdentityPin(
  instanceId: _instanceId,
  serverSpaceId: _serverSpaceId,
  signingPublicKey: publicKey,
);

InstanceInfo _instance(
  String signingPublicKey, {
  String instanceId = _instanceId,
  String serverSpaceId = _serverSpaceId,
  List<Map<String, dynamic>> transitions = const [],
}) => InstanceInfo(
  instanceId: instanceId,
  serverSpaceId: serverSpaceId,
  generation: '44444444-4444-4444-8444-444444444444',
  protocolVersion: 1,
  setupRequired: false,
  capabilities: const [],
  signingPublicKey: signingPublicKey,
  signingKeyTransitions: transitions,
);

Map<String, dynamic> _transition(
  SodiumSumo sodium,
  DeviceIdentity signer,
  String toPublicKey, {
  String? fromPublicKey,
}) {
  final unsigned = <String, Object?>{
    'format': 'atermius-instance-key-transition-v1',
    'instance_id': _instanceId,
    'from_public_key': fromPublicKey ?? signer.signingPublicKey,
    'to_public_key': toPublicKey,
    'issued_at': '2026-10-07T10:00:00Z',
  };
  return {
    ...unsigned,
    'signature': encodeBase64Url(
      sodium.crypto.sign.detached(
        message: Uint8List.fromList(utf8.encode(canonicalJson(unsigned))),
        secretKey: signer.signing.secretKey,
      ),
    ),
  };
}

class _FakeInstanceApi extends ApiClient {
  _FakeInstanceApi({
    required super.baseUrl,
    required this.instanceResponses,
    required this.requests,
  });

  final List<InstanceInfo> instanceResponses;
  final List<String> requests;
  bool closed = false;
  Completer<void>? fetchGate;

  @override
  Future<InstanceInfo> fetchInstance() async {
    requests.add('instance');
    await fetchGate?.future;
    return instanceResponses.removeAt(0);
  }

  @override
  Future<Map<String, dynamic>> prelogin(String username) async {
    requests.add('prelogin');
    throw StateError('unexpected authenticated-path request');
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _FakeSignInApi extends ApiClient {
  _FakeSignInApi({required super.baseUrl, required this.accountId});

  final String accountId;
  late InstanceInfo instance;
  late AppController controller;
  final logins = <({String deviceId, bool enrolled})>[];

  @override
  Future<InstanceInfo> fetchInstance() async => instance;

  @override
  Future<Map<String, dynamic>> prelogin(String username) async => {
    'account_id': accountId,
    'kdf': {
      'id': 'argon2id13',
      'iterations': 3,
      'mem_kib': 65536,
      'parallelism': 1,
      'salt': 'TAW9hVBsv6IxMQolQub8Bg',
      'version': 1,
    },
  };

  /// Rejects every attempt the way the server rejects both a wrong password
  /// and an unknown device.
  @override
  Future<AuthLoginResult> login({
    required String username,
    required String loginVerifier,
    required String deviceId,
    Map<String, Object?>? newDevice,
  }) async {
    logins.add((deviceId: deviceId, enrolled: newDevice != null));
    throw const ApiException(
      statusCode: 401,
      code: 'AUTH_REQUIRED',
      message: 'authentication is required',
    );
  }
}
