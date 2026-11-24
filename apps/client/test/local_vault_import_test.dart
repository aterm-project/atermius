import 'dart:io';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/jcs.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_resume_store.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/sync/local_vault_import.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_vault_import_card.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _password = 'correct horse battery staple';
const _instanceId = '11111111-1111-4111-8111-111111111111';
const _otherInstanceId = '33333333-3333-4333-8333-333333333333';
const _spaceId = '22222222-2222-4222-8222-222222222222';
const _accountId = '90000000-0000-4000-8000-000000000009';
const _seededRecords = 7;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SodiumSumo sodium;
  late VaultCrypto crypto;
  late LocalProfileCatalog catalog;
  late _MemoryResumeStore resumeStore;
  late LocalProfileService service;
  late LocalProfileRecord record;
  late DeviceIdentity accountDevice;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    crypto = VaultCrypto(sodium);
    catalog = LocalProfileCatalog.forTesting(NativeDatabase.memory());
    resumeStore = _MemoryResumeStore();
    service = LocalProfileService(
      catalog: catalog,
      crypto: crypto,
      resumeStore: resumeStore,
      deviceKeyStore: _MemoryResumeStore(),
    );
    final created = await service.create(password: _password);
    record = created.record;
    // The device keeps the key: the import needs no password.
    await service.remember(created);
    await created.lock();
    accountDevice = DeviceIdentity.create(sodium);
  });

  tearDownAll(() async {
    accountDevice.dispose();
    await catalog.close();
  });

  group('LocalVaultImport', () {
    late Directory directory;
    late File vaultFile;
    late List<UnlockedLocalProfile> openedProfiles;
    late List<LocalVaultDatabase> openedDatabases;

    Future<LocalVaultDatabase> openVault({bool create = false}) =>
        LocalVaultDatabase.openForTesting(
          executor: NativeDatabase(vaultFile),
          profileId: record.profileId,
          localDataDomainId: record.localDataDomainId,
          localVaultId: record.localVaultId,
          mode: create
              ? LocalVaultOpenMode.createNew
              : LocalVaultOpenMode.openExisting,
        );

    /// Runs [action] on the LocalVault outside the import.
    Future<T> withRepository<T>(
      Future<T> Function(LocalHostRepository repository) action, {
      bool create = false,
    }) async {
      final profile = (await service.tryUnlockForMigration(record.profileId))!;
      final database = await openVault(create: create);
      try {
        return await action(
          LocalHostRepository(
            database: database,
            profile: profile,
            crypto: crypto,
          ),
        );
      } finally {
        await database.close();
        await profile.lock();
      }
    }

    Future<List<LocalMigrationJournalSummary>> journals() =>
        withRepository((repository) => repository.listMigrationJournals());

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('atermius-import-');
      vaultFile = File('${directory.path}/vault.sqlite');
      openedProfiles = [];
      openedDatabases = [];
      await withRepository((repository) async {
        await repository.createGroup(
          const GroupRecord(
            id: '0f000000-0000-4000-8000-00000000000f',
            name: 'Fleet',
          ),
        );
        for (var index = 0; index < _seededRecords - 1; index++) {
          await repository.createHost(
            HostRecord(
              id: 'draft',
              name: 'host $index',
              address: 'host$index.example.test',
              username: 'deploy',
            ),
          );
        }
      }, create: true);
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    LocalVaultImport makeImport(
      _FakeDestination destination, {
      LocalProfileService? profiles,
      LocalProfileCatalog? profileCatalog,
      DatabaseQuarantineRegistry? quarantine,
      bool autoResume = false,
      int giveUpAfterIdleRounds = 5,
    }) => LocalVaultImport(
      destination: destination,
      crypto: crypto,
      openStorage: () async =>
          (catalog: profileCatalog ?? catalog, service: profiles ?? service),
      quarantine: quarantine ?? DatabaseQuarantineRegistry(),
      openDatabase: (profile) async {
        openedProfiles.add(profile);
        final database = await openVault();
        openedDatabases.add(database);
        return database;
      },
      retry: LocalImportRetry(
        firstDelay: const Duration(milliseconds: 1),
        maxDelay: const Duration(milliseconds: 4),
        giveUpAfterIdleRounds: giveUpAfterIdleRounds,
      ),
      autoResume: autoResume,
      autoResumeDelay: Duration.zero,
    );

    _FakeDestination destination() =>
        _FakeDestination(crypto: crypto, identity: accountDevice);

    Future<void> expectEverythingClosed() async {
      expect(openedProfiles, isNotEmpty);
      for (final profile in openedProfiles) {
        expect(profile.isLocked, isTrue);
      }
      for (final database in openedDatabases) {
        await expectLater(
          database.customSelect('SELECT 1').get(),
          throwsA(anything),
        );
      }
    }

    /// Starts an import whose upload is interrupted by a sign-out, leaving
    /// a frozen journal with every record staged (the state of the user
    /// whose import never finished).
    Future<String> interruptedImport(_FakeDestination target) async {
      final import = makeImport(target);
      target
        ..commitPerSync = 0
        ..onSync = (_) {
          if (import.progress?.phase == LocalImportPhase.uploading) {
            target.signOut();
          }
        };
      expect(
        await import.importProfile(record.profileId),
        LocalImportAccess.started,
      );
      await import.idle;
      expect(
        import.resultFor(record.profileId)?.outcome,
        LocalImportOutcome.paused,
      );
      expect(
        import.resultFor(record.profileId)?.message,
        currentL10n.localImportPausedSignedOut,
      );
      import.dispose();
      target.onSync = null;
      final frozen = (await journals()).single;
      expect(frozen.state, 'frozen');
      expect(frozen.stagedItemCount, _seededRecords);
      return frozen.migrationId;
    }

    test('finishes in the background after several sync rounds that commit '
        'records gradually', () async {
      final target = destination()..commitPerSync = 2;
      final import = makeImport(target);
      final seen = <LocalImportProgress>[];
      import.addListener(() {
        final progress = import.progress;
        if (progress != null) seen.add(progress);
      });

      expect(
        await import.importProfile(record.profileId),
        LocalImportAccess.started,
      );
      expect(import.busy, isTrue);
      await import.idle;

      final result = import.resultFor(record.profileId)!;
      expect(
        result.outcome,
        LocalImportOutcome.completed,
        reason: result.message,
      );
      expect(result.recordCount, _seededRecords);
      expect(result.vaultName, 'Imported local profiles');
      expect(
        import.takeNotice(),
        'Imported $_seededRecords records into Imported local profiles',
      );
      expect(import.takeNotice(), isNull);
      // One sync before staging, then one per round until all of the seven
      // records were committed two at a time.
      expect(target.syncCalls, greaterThanOrEqualTo(5));
      expect(target.committed, hasLength(_seededRecords));
      expect(target.pending, isEmpty);
      expect(target.prepareCalls, 1);
      final uploads = [
        for (final item in seen)
          if (item.phase == LocalImportPhase.uploading) item.done,
      ];
      expect(uploads, containsAllInOrder([2, 4, 6, 7]));
      expect(seen.last.phase, LocalImportPhase.verifying);
      expect(import.busy, isFalse);
      expect((await journals()).single.state, 'completed');
      await expectEverythingClosed();
      import.dispose();
    });

    test('asks for the password when the key is not stored here', () async {
      final passwordOnly = LocalProfileService(
        catalog: catalog,
        crypto: crypto,
        resumeStore: _MemoryResumeStore(),
        deviceKeyStore: _MemoryResumeStore(),
      );
      final target = destination();
      final import = makeImport(target, profiles: passwordOnly);

      await import.refresh();
      expect(import.profiles.single.keyStored, isFalse);
      expect(import.profiles.single.journals, isNull);
      expect(
        await import.importProfile(record.profileId),
        LocalImportAccess.passwordRequired,
      );
      expect(target.prepareCalls, 0);
      expect(
        await import.importProfile(
          record.profileId,
          password: 'wrong password!',
        ),
        LocalImportAccess.passwordRejected,
      );
      expect(
        await import.importProfile(record.profileId, password: _password),
        LocalImportAccess.started,
      );
      await import.idle;
      expect(
        import.resultFor(record.profileId)?.outcome,
        LocalImportOutcome.completed,
      );
      // The password session told what the profile holds.
      expect(import.profiles.single.lastCompleted?.itemCount, _seededRecords);
      await expectEverythingClosed();
      import.dispose();
    });

    test('finishes an interrupted import of this server when the workspace '
        'becomes ready, without asking', () async {
      final target = destination();
      final migrationId = await interruptedImport(target);
      // Like the reported user: the server confirmed every record, but the
      // local profile stayed frozen.
      target.commitEverything();

      target.signIn();
      final import = makeImport(target, autoResume: true);
      await _eventually(() => import.resultFor(record.profileId) != null);
      await import.idle;

      final result = import.resultFor(record.profileId)!;
      expect(
        result.outcome,
        LocalImportOutcome.completed,
        reason: result.message,
      );
      expect(result.recordCount, _seededRecords);
      expect(import.takeNotice(), contains('Imported $_seededRecords records'));
      expect(target.prepareCalls, 1, reason: 'no second Vault');
      final finished = (await journals()).single;
      expect(finished.migrationId, migrationId);
      expect(finished.state, 'completed');
      await expectEverythingClosed();
      import.dispose();
    });

    test('never resumes an import of another server or account', () async {
      final target = destination();
      await interruptedImport(target);
      target.commitEverything();
      final createdBefore = target.createCalls;

      target
        ..instanceIdValue = _otherInstanceId
        ..signIn();
      final otherServer = makeImport(target, autoResume: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await otherServer.idle;
      expect(otherServer.resultFor(record.profileId), isNull);
      otherServer.dispose();

      target
        ..instanceIdValue = _instanceId
        ..accountId = '90000000-0000-4000-8000-0000000000aa'
        ..signIn();
      final otherAccount = makeImport(target, autoResume: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await otherAccount.idle;
      expect(otherAccount.resultFor(record.profileId), isNull);
      otherAccount.dispose();

      expect(target.createCalls, createdBefore);
      expect((await journals()).single.state, 'frozen');
    });

    test('pauses when another Vault opens and continues back there', () async {
      final target = destination()..commitPerSync = 0;
      final import = makeImport(target, autoResume: true);
      target.onSync = (_) {
        if (import.progress?.phase == LocalImportPhase.uploading) {
          target.openVault('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
        }
      };
      expect(
        await import.importProfile(record.profileId),
        LocalImportAccess.started,
      );
      await import.idle;
      final vaultId = target.materials.keys.single;
      expect(
        import.resultFor(record.profileId)?.message,
        currentL10n.localImportPausedVaultSwitched,
      );
      expect((await journals()).single.state, 'frozen');

      target
        ..onSync = null
        ..commitPerSync = 100;
      target.openVault(vaultId);
      await _eventually(
        () =>
            import.resultFor(record.profileId)?.outcome ==
            LocalImportOutcome.completed,
      );
      expect((await journals()).single.state, 'completed');
      import.dispose();
    });

    test('abandon makes the local profile editable again', () async {
      final target = destination();
      final migrationId = await interruptedImport(target);
      final import = makeImport(target);
      await import.refresh();
      expect(
        import.profiles.single.interrupted.single.migrationId,
        migrationId,
      );

      expect(
        await import.abandon(record.profileId, migrationId),
        LocalImportAccess.started,
      );
      expect(
        import.resultFor(record.profileId)?.outcome,
        LocalImportOutcome.stopped,
      );
      expect(import.profiles.single.interrupted, isEmpty);
      expect((await journals()).single.state, 'cancelled');
      // The destination keeps what it already has.
      expect(target.pending, hasLength(_seededRecords));
      await expectEverythingClosed();
      import.dispose();
    });

    test(
      'an import interrupted before anything was sent can be cancelled',
      () async {
        const migrationId = '50000000-0000-4000-8000-000000000005';
        await withRepository(
          (repository) => repository.prepareMigrationSnapshot(
            migrationId: migrationId,
            targetInstanceId: _instanceId,
            targetVaultId: '60000000-0000-4000-8000-000000000006',
          ),
        );
        final target = destination();
        final import = makeImport(target, autoResume: true);
        await import.refresh();
        expect(import.profiles.single.cancelableIds, {migrationId});
        // Automatic resume leaves it alone: nothing was sent.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(target.createCalls, 0);

        expect(
          await import.cancelPreparation(record.profileId, migrationId),
          LocalImportAccess.started,
        );
        expect((await journals()).single.state, 'cancelled');
        import.dispose();
      },
    );

    test('a quarantine during the upload closes the profile', () async {
      final quarantine = DatabaseQuarantineRegistry();
      final target = destination()..commitPerSync = 0;
      final import = makeImport(target, quarantine: quarantine);
      target.onSync = (_) {
        if (import.progress?.phase == LocalImportPhase.uploading) {
          quarantine.quarantine(localVaultDatabaseName(record.profileId));
        }
      };
      expect(
        await import.importProfile(record.profileId),
        LocalImportAccess.started,
      );
      await import.idle;

      expect(import.storageRecoveryRequired, isTrue);
      expect(
        import.resultFor(record.profileId)?.message,
        currentL10n.aLocalStorageWriteWasInterrupted,
      );
      await expectEverythingClosed();
      expect(
        await import.importProfile(record.profileId),
        LocalImportAccess.unavailable,
      );
      expect((await journals()).single.state, 'frozen');
      import.dispose();
    });

    test('a catalog quarantine prevents reading the profiles', () async {
      final quarantine = DatabaseQuarantineRegistry()
        ..quarantine(localProfileCatalogDatabaseName);
      final counting = _CountingCatalog(catalog);
      final import = makeImport(
        destination(),
        quarantine: quarantine,
        profileCatalog: counting,
      );
      await import.refresh();
      expect(import.storageRecoveryRequired, isTrue);
      expect(counting.listCalls, 0);
      import.dispose();
    });
  });

  test(
    'online import verifies the live instance before staging a migration',
    () async {
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final controller = AppController(
        sodium: sodium,
        database: database,
        secureStore: ClientSecureStore(),
      );
      addTearDown(() async {
        controller.dispose();
        await database.close();
      });
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
      final current = descriptor(
        _instanceId,
        _spaceId,
        signing.signingPublicKey,
        '1',
      );
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

      expect(
        await controller.migrationDestinationIsCurrent(_instanceId),
        isTrue,
      );
      api.reply = descriptor(
        _instanceId,
        _spaceId,
        signing.signingPublicKey,
        '2',
      );
      expect(
        await controller.migrationDestinationIsCurrent(_instanceId),
        isTrue,
      );
      api.reply = descriptor(_spaceId, _spaceId, signing.signingPublicKey, '2');
      expect(
        await controller.migrationDestinationIsCurrent(_instanceId),
        isFalse,
      );
      api.reply = descriptor(
        _instanceId,
        _instanceId,
        signing.signingPublicKey,
        '2',
      );
      expect(
        await controller.migrationDestinationIsCurrent(_instanceId),
        isFalse,
      );
      api.reply = descriptor(
        _instanceId,
        _spaceId,
        replacement.signingPublicKey,
        '2',
      );
      expect(
        await controller.migrationDestinationIsCurrent(_instanceId),
        isFalse,
      );

      // The app's destination is ready only for an unlocked signed-in
      // workspace whose server is known.
      final destination = AppControllerImportDestination(controller);
      expect(destination.ready, isTrue);
      expect(destination.instanceId, _instanceId);
      controller.workspaceLocked = true;
      expect(destination.ready, isFalse);
    },
  );

  group('Settings card', () {
    const profileId = '0a000000-0000-4000-8000-00000000000a';
    const otherProfileId = '0b000000-0000-4000-8000-00000000000b';
    const migrationId = '0c000000-0000-4000-8000-00000000000c';
    const vaultId = '0d000000-0000-4000-8000-00000000000d';

    LocalImportProfile profile(
      String id, {
      List<LocalMigrationJournalSummary>? journals,
      Set<String> cancelable = const {},
    }) => LocalImportProfile(
      profileId: id,
      createdAt: DateTime.utc(2026, 11, 1, 12),
      keyStored: true,
      journals: journals,
      cancelableIds: cancelable,
    );

    LocalMigrationJournalSummary journal({
      String state = 'frozen',
      String instanceId = _instanceId,
      int staged = 120,
      int total = 462,
    }) => LocalMigrationJournalSummary(
      migrationId: migrationId,
      targetInstanceId: instanceId,
      targetVaultId: vaultId,
      sourceFingerprint: 'fingerprint',
      state: state,
      itemCount: total,
      stagedItemCount: staged,
      createdAtMs: 1,
      updatedAtMs: 1,
      finishedAtMs: state == 'frozen' ? null : 2,
    );

    Future<_StubImport> pumpCard(
      WidgetTester tester, {
      Locale locale = const Locale('en'),
      List<LocalImportProfile>? profiles,
    }) async {
      final import = _StubImport(
        _FakeDestination(crypto: crypto, identity: accountDevice),
        crypto,
      )..stubProfiles = profiles ?? [profile(profileId)];
      addTearDown(import.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: LocalVaultImportNotices(
              import: import,
              child: SingleChildScrollView(
                child: LocalVaultImportCard(import: import),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return import;
    }

    testWidgets('one profile: just the import button, no picker', (
      tester,
    ) async {
      final import = await pumpCard(tester);
      expect(import.calls, contains('refresh'));
      expect(
        find.byKey(const ValueKey('migration_profile_select')),
        findsNothing,
      );
      expect(find.text('Import to server'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('local_to_sync_migration_open')),
      );
      await tester.pumpAndSettle();
      expect(import.calls, contains('import:$profileId:'));
      expect(
        find.byKey(const ValueKey('migration_profile_password')),
        findsNothing,
      );
    });

    testWidgets('several profiles get a picker', (tester) async {
      final import = await pumpCard(
        tester,
        profiles: [profile(profileId), profile(otherProfileId)],
      );
      expect(
        find.byKey(const ValueKey('migration_profile_select')),
        findsOneWidget,
      );
      expect(find.text('Local profile · 2026-11-01'), findsOneWidget);
      import.stubSelected = otherProfileId;
      import.update();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('local_to_sync_migration_open')),
      );
      await tester.pumpAndSettle();
      expect(import.calls, contains('import:$otherProfileId:'));
    });

    testWidgets('a profile without a stored key asks for its password', (
      tester,
    ) async {
      final import = await pumpCard(tester);
      import.onImport = (password) => switch (password) {
        null => LocalImportAccess.passwordRequired,
        'wrong' => LocalImportAccess.passwordRejected,
        _ => LocalImportAccess.started,
      };
      await tester.tap(
        find.byKey(const ValueKey('local_to_sync_migration_open')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Unlock local profile'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('migration_profile_password')),
        'wrong',
      );
      await tester.tap(find.byKey(const ValueKey('migration_password_submit')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining("Couldn't unlock or verify this local profile"),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('migration_profile_password')),
        _password,
      );
      await tester.tap(find.byKey(const ValueKey('migration_password_submit')));
      await tester.pumpAndSettle();
      expect(find.text('Unlock local profile'), findsNothing);
      expect(import.calls, [
        'refresh',
        'import:$profileId:',
        'import:$profileId:wrong',
        'import:$profileId:$_password',
      ]);
    });

    testWidgets('progress, completion line and background notice', (
      tester,
    ) async {
      final import = await pumpCard(tester);
      import
        ..stubBusy = true
        ..stubProgress = const LocalImportProgress(
          profileId: profileId,
          phase: LocalImportPhase.uploading,
          done: 120,
          total: 462,
        )
        ..update();
      await tester.pump();
      expect(find.text('Importing 120 / 462…'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('local_import_progress_bar')),
      );
      expect(bar.value, closeTo(120 / 462, 0.001));
      expect(
        find.byKey(const ValueKey('local_to_sync_migration_open')),
        findsNothing,
      );

      import
        ..stubBusy = false
        ..stubProgress = null
        ..stubResults[profileId] = const LocalImportResult(
          profileId: profileId,
          outcome: LocalImportOutcome.completed,
          vaultName: 'Imported local profiles',
          recordCount: 462,
        )
        ..notice = 'Imported 462 records into Imported local profiles'
        ..update();
      await tester.pump();
      expect(
        find.text('Imported 462 records into Imported local profiles'),
        findsNWidgets(2), // The card line and the SnackBar.
      );
      expect(find.byKey(const ValueKey('local_import_notice')), findsOneWidget);
    });

    testWidgets('a failure shows the reason and Retry', (tester) async {
      final import = await pumpCard(tester);
      import
        ..stubResults[profileId] = LocalImportResult(
          profileId: profileId,
          outcome: LocalImportOutcome.failed,
          message: currentL10n.localImportFailed('The server is offline.'),
        )
        ..update();
      await tester.pump();
      expect(
        find.text('Import stopped: The server is offline.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('local_import_retry')));
      await tester.pumpAndSettle();
      expect(import.calls.last, 'import:$profileId:');
    });

    testWidgets('an interrupted import offers Resume and a confirmed Abandon', (
      tester,
    ) async {
      final import = await pumpCard(
        tester,
        profiles: [
          profile(profileId, journals: [journal()]),
        ],
      );
      expect(
        find.textContaining('interrupted after preparing 120 of 462 records'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('local_to_sync_migration_open')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('migration_resume_$migrationId')),
      );
      await tester.pumpAndSettle();
      expect(import.calls.last, 'resume:$migrationId:');

      await tester.tap(
        find.byKey(const ValueKey('migration_abandon_$migrationId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('migration_abandon_cancel')));
      await tester.pumpAndSettle();
      expect(import.calls.where((call) => call.startsWith('abandon')), isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('migration_abandon_$migrationId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('migration_abandon_confirm')));
      await tester.pumpAndSettle();
      expect(import.calls.last, 'abandon:$migrationId:');
    });

    testWidgets('an import into another server can only be abandoned', (
      tester,
    ) async {
      await pumpCard(
        tester,
        profiles: [
          profile(profileId, journals: [journal(instanceId: _otherInstanceId)]),
        ],
      );
      expect(
        find.text(currentL10n.localImportInterruptedOtherServer),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('migration_resume_$migrationId')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('migration_abandon_$migrationId')),
        findsOneWidget,
      );
    });

    testWidgets('an empty preparation is cancelled without a dialog', (
      tester,
    ) async {
      final import = await pumpCard(
        tester,
        profiles: [
          profile(
            profileId,
            journals: [journal(staged: 0)],
            cancelable: {migrationId},
          ),
        ],
      );
      await tester.tap(
        find.byKey(const ValueKey('migration_cancel_$migrationId')),
      );
      await tester.pumpAndSettle();
      expect(import.calls.last, 'cancel:$migrationId:');
    });

    testWidgets('storage recovery shows only the reload action', (
      tester,
    ) async {
      final import = await pumpCard(tester);
      import
        ..stubRecovery = true
        ..update();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('migration_storage_recovery_message')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('local_to_sync_migration_open')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('migration_storage_reload')));
      expect(import.calls.last, 'reload');
    });

    testWidgets('no local profile on this device', (tester) async {
      await pumpCard(tester, profiles: const []);
      expect(
        find.byKey(const ValueKey('local_import_no_profiles')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('local_to_sync_migration_open')),
        findsNothing,
      );
    });

    testWidgets('Chinese wording', (tester) async {
      final import = await pumpCard(tester, locale: const Locale('zh'));
      expect(find.text('导入到服务器'), findsOneWidget);
      import
        ..stubBusy = true
        ..stubProgress = const LocalImportProgress(
          profileId: profileId,
          phase: LocalImportPhase.uploading,
          done: 120,
          total: 462,
        )
        ..update();
      await tester.pump();
      expect(find.text('正在导入 120 / 462…'), findsOneWidget);
    });
  });
}

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not reached');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A server and account workspace: records commit [commitPerSync] at a time,
/// one batch per [synchronizeTarget].
class _FakeDestination extends ChangeNotifier
    implements LocalImportDestination {
  _FakeDestination({required this.crypto, required this.identity});

  final VaultCrypto crypto;
  final DeviceIdentity identity;
  bool readyValue = true;
  int scopeValue = 1;
  String? instanceIdValue = _instanceId;
  @override
  String accountId = _accountId;
  String? active;
  int commitPerSync = 1 << 20;
  int syncCalls = 0;
  int prepareCalls = 0;
  int createCalls = 0;
  void Function(int call)? onSync;
  final materials = <String, InitialVaultMaterial>{};
  final pending = <String, Map<String, Object?>>{};
  final committed = <String, Map<String, Object?>>{};
  final _commitSeq = <String, int>{};
  var _sequence = 0;
  var _deviceSequence = 0;

  void signOut() {
    readyValue = false;
    notifyListeners();
  }

  void signIn() {
    readyValue = true;
    scopeValue++;
    notifyListeners();
  }

  void openVault(String vaultId) {
    active = vaultId;
    notifyListeners();
  }

  void commitEverything() {
    for (final entry in pending.entries.toList()) {
      committed[entry.key] = entry.value;
      _commitSeq[entry.key] = ++_sequence;
    }
    pending.clear();
  }

  @override
  bool get ready => readyValue;

  @override
  Object get scope => scopeValue;

  @override
  String? get instanceId => instanceIdValue;

  @override
  String? get deviceId => identity.deviceId;

  @override
  String? get activeVaultId => active;

  @override
  Object? get preferenceError => null;

  @override
  String vaultName(String vaultId) => 'Imported local profiles';

  @override
  String describeError(Object error) => '$error';

  @override
  Future<bool> destinationIsCurrent(String instanceId) async =>
      readyValue && instanceId == instanceIdValue;

  @override
  Future<({String vaultId, String payloadJson})> prepareVaultCreation(
    String name,
  ) async {
    prepareCalls++;
    final material = await crypto.createInitialVault(
      accountId: accountId,
      name: name,
      identity: identity,
    );
    materials[material.vaultId] = material;
    return (
      vaultId: material.vaultId,
      payloadJson: canonicalJson(material.payload),
    );
  }

  @override
  Future<void> createOrResumeVault({
    required String vaultId,
    required String payloadJson,
  }) async {
    createCalls++;
    expect(materials, contains(vaultId));
    active = vaultId;
    notifyListeners();
  }

  @override
  Future<void> synchronizeTarget(String vaultId) async {
    syncCalls++;
    if (active != vaultId) throw StateError('The sync Vault was switched.');
    onSync?.call(syncCalls);
    for (final id in pending.keys.take(commitPerSync).toList()) {
      committed[id] = pending.remove(id)!;
      _commitSeq[id] = ++_sequence;
    }
  }

  @override
  Future<Map<String, Object?>> encryptRecord({
    required String targetVaultId,
    required String recordId,
    required Map<String, Object?> plaintext,
  }) async {
    final key = materials[targetVaultId]!.vaultKey.sublist(0);
    try {
      return await crypto.encryptRecord(
        vaultKey: key,
        serverSpaceId: _spaceId,
        vaultId: targetVaultId,
        recordId: recordId,
        baseRevisionId: null,
        deviceId: identity.deviceId,
        deviceSequence: '${++_deviceSequence}',
        keyEpoch: '1',
        membershipVersion: '1',
        operation: 'create',
        plaintext: plaintext,
        identity: identity,
      );
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  @override
  Future<ExactCreateOperationResult> enqueueEnvelope({
    required String targetVaultId,
    required Map<String, Object?> envelope,
  }) async {
    final recordId = (envelope['header']! as Map)['record_id']! as String;
    if (committed.containsKey(recordId)) {
      expect(canonicalJson(committed[recordId]), canonicalJson(envelope));
      return ExactCreateOperationResult.committed;
    }
    if (pending.containsKey(recordId)) {
      return ExactCreateOperationResult.pending;
    }
    pending[recordId] = envelope;
    return ExactCreateOperationResult.created;
  }

  @override
  Future<LocalImportTargetState> readTargetState({
    required String vaultId,
    required String instanceId,
  }) async {
    if (instanceId != instanceIdValue) throw StateError('Another server.');
    EncryptedRecord row(String id, Map<String, Object?> envelope, int? seq) =>
        EncryptedRecord(
          vaultId: vaultId,
          recordId: id,
          revisionId: (envelope['header']! as Map)['revision_id']! as String,
          envelopeJson: canonicalJson(envelope),
          isDeleted: false,
          commitSeq: seq?.toString(),
          updatedAt: 0,
        );
    return LocalImportTargetState(
      cached: [
        for (final entry in committed.entries)
          row(entry.key, entry.value, _commitSeq[entry.key]),
        for (final entry in pending.entries) row(entry.key, entry.value, null),
      ],
      pending: [
        for (final entry in pending.entries)
          PendingOperation(
            opId: (entry.value['header']! as Map)['op_id']! as String,
            vaultId: vaultId,
            recordId: entry.key,
            envelopeJson: canonicalJson(entry.value),
            status: 'queued',
            attemptCount: 0,
            createdAt: 0,
          ),
      ],
    );
  }
}

/// A coordinator whose state the card tests set directly.
class _StubImport extends LocalVaultImport {
  _StubImport(LocalImportDestination destination, VaultCrypto crypto)
    : super(
        destination: destination,
        crypto: crypto,
        openStorage: () async => null,
        quarantine: DatabaseQuarantineRegistry(),
        autoResume: false,
      );

  List<LocalImportProfile> stubProfiles = const [];
  String? stubSelected;
  LocalImportProgress? stubProgress;
  final stubResults = <String, LocalImportResult>{};
  bool stubBusy = false;
  bool stubRecovery = false;
  String? notice;
  LocalImportAccess Function(String? password)? onImport;
  final calls = <String>[];

  void update() => notifyListeners();

  @override
  Future<void> refresh() async => calls.add('refresh');

  @override
  bool get loaded => true;

  @override
  List<LocalImportProfile> get profiles => stubProfiles;

  @override
  String? get selectedProfileId =>
      stubSelected ?? stubProfiles.firstOrNull?.profileId;

  @override
  LocalImportProfile? get selectedProfile => stubProfiles
      .where((item) => item.profileId == selectedProfileId)
      .firstOrNull;

  @override
  LocalImportProgress? get progress => stubProgress;

  @override
  LocalImportResult? resultFor(String profileId) => stubResults[profileId];

  @override
  bool get busy => stubBusy;

  @override
  bool get storageRecoveryRequired => stubRecovery;

  @override
  String? takeNotice() {
    final value = notice;
    notice = null;
    return value;
  }

  @override
  void selectProfile(String profileId) {
    stubSelected = profileId;
    notifyListeners();
  }

  @override
  void reloadPage() => calls.add('reload');

  @override
  Future<LocalImportAccess> importProfile(
    String profileId, {
    String? password,
  }) async {
    calls.add('import:$profileId:${password ?? ''}');
    return onImport?.call(password) ?? LocalImportAccess.started;
  }

  @override
  Future<LocalImportAccess> resume(
    String profileId,
    String migrationId, {
    String? password,
  }) async {
    calls.add('resume:$migrationId:${password ?? ''}');
    return LocalImportAccess.started;
  }

  @override
  Future<LocalImportAccess> abandon(
    String profileId,
    String migrationId, {
    String? password,
  }) async {
    calls.add('abandon:$migrationId:${password ?? ''}');
    return LocalImportAccess.started;
  }

  @override
  Future<LocalImportAccess> cancelPreparation(
    String profileId,
    String migrationId, {
    String? password,
  }) async {
    calls.add('cancel:$migrationId:${password ?? ''}');
    return LocalImportAccess.started;
  }
}

class _MemoryResumeStore implements LocalProfileResumeStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;

  @override
  Future<void> clear() async => value = null;
}

class _CountingCatalog implements LocalProfileCatalog {
  _CountingCatalog(this.inner);

  final LocalProfileCatalog inner;
  int listCalls = 0;

  @override
  Future<List<LocalProfileRecord>> list() {
    listCalls++;
    return inner.list();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MigrationInstanceApi extends ApiClient {
  _MigrationInstanceApi(this.reply)
    : super(baseUrl: 'https://migration.example.test');

  InstanceInfo reply;

  @override
  Future<InstanceInfo> fetchInstance() async => reply;
}
