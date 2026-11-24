import 'dart:async';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_to_sync_migration_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SodiumSumo sodium;
  late VaultCrypto crypto;
  late LocalProfileCatalog fixtureCatalog;
  late LocalProfileService fixtureService;
  late LocalProfileRecord profileRecord;
  late UnlockedLocalProfile profileFixture;
  late AppController controller;
  late ClientDatabase controllerDatabase;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    crypto = VaultCrypto(sodium);
    fixtureCatalog = LocalProfileCatalog.forTesting(NativeDatabase.memory());
    fixtureService = LocalProfileService(
      catalog: fixtureCatalog,
      crypto: crypto,
    );
    profileFixture = await fixtureService.create(
      password: 'correct horse battery staple',
    );
    profileRecord = profileFixture.record;
  });

  tearDownAll(() async {
    await profileFixture.lock();
    await fixtureCatalog.close();
  });

  setUp(() {
    controllerDatabase = ClientDatabase.forTesting(NativeDatabase.memory());
    controller = AppController(
      sodium: sodium,
      database: controllerDatabase,
      secureStore: ClientSecureStore(),
    );
  });

  tearDown(() async {
    controller.dispose();
    await controllerDatabase.close();
  });

  test('online import verifies the live instance before staging a migration', () async {
    const instanceId = '11111111-1111-4111-8111-111111111111';
    const spaceId = '22222222-2222-4222-8222-222222222222';
    final signing = DeviceIdentity.create(sodium);
    final replacement = DeviceIdentity.create(sodium);
    addTearDown(signing.dispose);
    addTearDown(replacement.dispose);
    InstanceInfo descriptor(
      String id,
      String space,
      String key,
      String generation,
    ) => InstanceInfo(
      instanceId: id,
      serverSpaceId: space,
      generation: generation,
      protocolVersion: 1,
      setupRequired: false,
      capabilities: const [],
      signingPublicKey: key,
    );
    final current = descriptor(instanceId, spaceId, signing.signingPublicKey, '1');
    final api = _MigrationInstanceApi(current);
    controller
      ..api = api
      ..instance = current
      ..stage = ClientStage.workspace
      ..session = AuthSession(
        accountId: 'account',
        deviceId: signing.deviceId,
        accessToken: 'access',
        refreshToken: 'refresh',
        expiresIn: 600,
        vaults: const [],
      );

    expect(await controller.migrationDestinationIsCurrent(instanceId), isTrue);
    api.reply = descriptor(instanceId, spaceId, signing.signingPublicKey, '2');
    expect(await controller.migrationDestinationIsCurrent(instanceId), isTrue);
    api.reply = descriptor(spaceId, spaceId, signing.signingPublicKey, '2');
    expect(await controller.migrationDestinationIsCurrent(instanceId), isFalse);
    api.reply = descriptor(instanceId, instanceId, signing.signingPublicKey, '2');
    expect(await controller.migrationDestinationIsCurrent(instanceId), isFalse);
    api.reply = descriptor(instanceId, spaceId, replacement.signingPublicKey, '2');
    expect(await controller.migrationDestinationIsCurrent(instanceId), isFalse);
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    required LocalProfileCatalog catalog,
    required DatabaseQuarantineRegistry registry,
    LocalProfileService? service,
    VoidCallback? reloadPage,
    LocalVaultDatabaseFactoryForTesting? databaseFactory,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: LocalToSyncMigrationScreen(
          controller: controller,
          catalog: catalog,
          service: service ?? _UnusedProfileService(),
          crypto: crypto,
          quarantineRegistry: registry,
          reloadPageForTesting: reloadPage,
          databaseFactoryForTesting: databaseFactory,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('typed catalog recovery failure shows reload-only surface', (
    tester,
  ) async {
    final registry = DatabaseQuarantineRegistry();
    final catalog = _StubLocalProfileCatalog(
      failure: const DatabaseRecoveryRequiredException(),
    );
    var reloadCalls = 0;

    await pumpScreen(
      tester,
      catalog: catalog,
      registry: registry,
      reloadPage: () => reloadCalls++,
    );

    expect(catalog.listCalls, 1);
    expect(
      find.byKey(const ValueKey('migration_storage_recovery_message')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('migration_unlock')), findsNothing);
    expect(find.text("Couldn't read the local profile list. Close this page and try again."), findsNothing);

    await tester.tap(find.byKey(const ValueKey('migration_storage_reload')));
    await tester.pump();
    expect(reloadCalls, 1);
  });

  testWidgets('catalog quarantine prevents the initial catalog read', (
    tester,
  ) async {
    final registry = DatabaseQuarantineRegistry()
      ..quarantine(localProfileCatalogDatabaseName);
    final catalog = _StubLocalProfileCatalog(records: [profileRecord]);

    await pumpScreen(tester, catalog: catalog, registry: registry);

    expect(catalog.listCalls, 0);
    expect(
      find.byKey(const ValueKey('migration_storage_recovery_message')),
      findsOneWidget,
    );
  });

  testWidgets('catalog quarantine blocks a late in-flight list result', (
    tester,
  ) async {
    final registry = DatabaseQuarantineRegistry();
    final listResult = Completer<List<LocalProfileRecord>>();
    final catalog = _StubLocalProfileCatalog(listResult: listResult);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: LocalToSyncMigrationScreen(
          controller: controller,
          catalog: catalog,
          service: _UnusedProfileService(),
          crypto: crypto,
          quarantineRegistry: registry,
        ),
      ),
    );
    await tester.pump();

    expect(catalog.listCalls, 1);
    registry.quarantine(localProfileCatalogDatabaseName);
    await tester.pump();
    listResult.complete([profileRecord]);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('migration_storage_recovery_message')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('migration_unlock')), findsNothing);
    expect(
      find.text('No local-only profile exists in this browser yet.'),
      findsNothing,
    );
  });

  testWidgets('preexisting selected LocalVault quarantine blocks after load', (
    tester,
  ) async {
    final registry = DatabaseQuarantineRegistry()
      ..quarantine(localVaultDatabaseName(profileRecord.profileId));
    final catalog = _StubLocalProfileCatalog(records: [profileRecord]);

    await pumpScreen(tester, catalog: catalog, registry: registry);

    expect(catalog.listCalls, 1);
    expect(
      find.byKey(const ValueKey('migration_storage_recovery_message')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('migration_unlock')), findsNothing);
  });

  testWidgets(
    'typed LocalVault open failure enters recovery and locks profile',
    (tester) async {
      final registry = DatabaseQuarantineRegistry();
      final catalog = _StubLocalProfileCatalog(records: [profileRecord]);

      await pumpScreen(
        tester,
        catalog: catalog,
        registry: registry,
        service: _ProfileServiceStub(profileFixture),
        databaseFactory: (profile, {required mode}) async {
          expect(profile, same(profileFixture));
          expect(mode, LocalVaultOpenMode.openExisting);
          throw const DatabaseRecoveryRequiredException();
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('migration_profile_password')),
        'correct horse battery staple',
      );
      await tester.tap(find.byKey(const ValueKey('migration_unlock')));
      await tester.pumpAndSettle();

      expect(profileFixture.isLocked, isTrue);
      expect(
        find.byKey(const ValueKey('migration_storage_recovery_message')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('migration_unlock')), findsNothing);
    },
  );

  testWidgets('late successful unlock is locked after quarantine', (
    tester,
  ) async {
    final registry = DatabaseQuarantineRegistry();
    final catalog = _StubLocalProfileCatalog(records: [profileRecord]);
    final unlocked = await fixtureService.unlock(
      profileId: profileRecord.profileId,
      password: 'correct horse battery staple',
    );
    final unlockResult = Completer<UnlockedLocalProfile>();
    var databaseOpenCalls = 0;

    await pumpScreen(
      tester,
      catalog: catalog,
      registry: registry,
      service: _DeferredProfileService(unlockResult.future),
      databaseFactory: (profile, {required mode}) async {
        databaseOpenCalls++;
        throw StateError('database open must not proceed');
      },
    );
    await tester.enterText(
      find.byKey(const ValueKey('migration_profile_password')),
      'correct horse battery staple',
    );
    await tester.tap(find.byKey(const ValueKey('migration_unlock')));
    await tester.pump();

    registry.quarantine(localVaultDatabaseName(profileRecord.profileId));
    await tester.pump();
    unlockResult.complete(unlocked);
    await tester.pumpAndSettle();

    expect(unlocked.isLocked, isTrue);
    expect(databaseOpenCalls, 0);
    expect(
      find.byKey(const ValueKey('migration_storage_recovery_message')),
      findsOneWidget,
    );
  });

  testWidgets('late successful database open closes handle and locks profile', (
    tester,
  ) async {
    final registry = DatabaseQuarantineRegistry();
    final catalog = _StubLocalProfileCatalog(records: [profileRecord]);
    final unlocked = await fixtureService.unlock(
      profileId: profileRecord.profileId,
      password: 'correct horse battery staple',
    );
    final database = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase.memory(),
      profileId: unlocked.record.profileId,
      localDataDomainId: unlocked.record.localDataDomainId,
      localVaultId: unlocked.record.localVaultId,
    );
    final databaseResult = Completer<LocalVaultDatabase>();

    await pumpScreen(
      tester,
      catalog: catalog,
      registry: registry,
      service: _ProfileServiceStub(unlocked),
      databaseFactory: (profile, {required mode}) => databaseResult.future,
    );
    await tester.enterText(
      find.byKey(const ValueKey('migration_profile_password')),
      'correct horse battery staple',
    );
    await tester.tap(find.byKey(const ValueKey('migration_unlock')));
    await tester.pump();

    registry.quarantine(localVaultDatabaseName(profileRecord.profileId));
    await tester.pump();
    databaseResult.complete(database);
    await tester.pumpAndSettle();

    expect(unlocked.isLocked, isTrue);
    expect(
      find.byKey(const ValueKey('migration_storage_recovery_message')),
      findsOneWidget,
    );
    await expectLater(
      database.customSelect('SELECT 1').get(),
      throwsA(anything),
    );
  });

  testWidgets('server-only quarantine is ignored, selected LocalVault is not', (
    tester,
  ) async {
    final registry = DatabaseQuarantineRegistry()..quarantine('atermius_vault');
    final catalog = _StubLocalProfileCatalog(records: [profileRecord]);

    await pumpScreen(tester, catalog: catalog, registry: registry);

    expect(catalog.listCalls, 1);
    expect(find.byKey(const ValueKey('migration_unlock')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('migration_storage_recovery_message')),
      findsNothing,
    );

    registry.quarantine(localVaultDatabaseName(profileRecord.profileId));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('migration_storage_recovery_message')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('migration_unlock')), findsNothing);
  });

  testWidgets('stored local access opens migration without a password field', (
    tester,
  ) async {
    final unlocked = await fixtureService.unlock(
      profileId: profileRecord.profileId,
      password: 'correct horse battery staple',
    );
    final database = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase.memory(),
      profileId: profileRecord.profileId,
      localDataDomainId: profileRecord.localDataDomainId,
      localVaultId: profileRecord.localVaultId,
    );
    final service = _ProfileServiceStub(unlocked, stored: true);

    await pumpScreen(
      tester,
      catalog: _StubLocalProfileCatalog(records: [profileRecord]),
      registry: DatabaseQuarantineRegistry(),
      service: service,
      databaseFactory: (_, {required mode}) async {
        expect(mode, LocalVaultOpenMode.openExisting);
        return database;
      },
    );

    expect(find.byKey(const ValueKey('migration_start')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('migration_profile_password')),
      findsNothing,
    );
    expect(service.passwordUnlocks, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(unlocked.isLocked, isTrue);
  });
}

class _MigrationInstanceApi extends ApiClient {
  _MigrationInstanceApi(this.reply) : super(baseUrl: 'https://migration.example.test');

  InstanceInfo reply;

  @override
  Future<InstanceInfo> fetchInstance() async => reply;
}

class _StubLocalProfileCatalog implements LocalProfileCatalog {
  _StubLocalProfileCatalog({
    this.records = const [],
    this.failure,
    this.listResult,
  });

  final List<LocalProfileRecord> records;
  final Object? failure;
  final Completer<List<LocalProfileRecord>>? listResult;
  int listCalls = 0;

  @override
  Future<List<LocalProfileRecord>> list() async {
    listCalls++;
    final error = failure;
    if (error != null) throw error;
    final result = listResult;
    if (result != null) return result.future;
    return records;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedProfileService implements LocalProfileService {
  @override
  Future<UnlockedLocalProfile?> tryUnlockForMigration(String profileId) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ProfileServiceStub extends _UnusedProfileService {
  _ProfileServiceStub(this.profile, {this.stored = false});

  final UnlockedLocalProfile profile;
  final bool stored;
  int passwordUnlocks = 0;

  @override
  Future<UnlockedLocalProfile?> tryUnlockForMigration(String profileId) async =>
      stored && profileId == profile.record.profileId ? profile : null;

  @override
  Future<UnlockedLocalProfile> unlock({
    required String profileId,
    required String password,
  }) async {
    passwordUnlocks++;
    return profile;
  }
}

class _DeferredProfileService extends _UnusedProfileService {
  _DeferredProfileService(this.unlockResult);

  final Future<UnlockedLocalProfile> unlockResult;

  @override
  Future<UnlockedLocalProfile> unlock({
    required String profileId,
    required String password,
  }) => unlockResult;

}
