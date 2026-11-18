import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/host_operating_system.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/host_operating_system_persistence.dart';
import 'package:aterm_client/storage/local_host_repository.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  late VaultCrypto crypto;
  late LocalProfileCatalog catalog;
  late UnlockedLocalProfile profile;
  late LocalVaultDatabase database;
  late LocalHostRepository repository;
  late HostRecord original;
  final observed = HostOperatingSystem(
    family: HostOperatingSystemFamily.linux,
    displayName: 'Debian GNU/Linux 12',
    distributionId: 'debian',
    version: '12',
    detectedAt: DateTime.utc(2026, 11, 6),
  );
  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });
  setUp(() async {
    catalog = LocalProfileCatalog.forTesting(NativeDatabase.memory());
    profile = await LocalProfileService(
      catalog: catalog,
      crypto: crypto,
    ).create(password: 'operating system observation test');
    final r = profile.record;
    database = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase.memory(),
      profileId: r.profileId,
      localDataDomainId: r.localDataDomainId,
      localVaultId: r.localVaultId,
    );
    repository = LocalHostRepository(
      database: database,
      profile: profile,
      crypto: crypto,
    );
    original = await repository.createHost(
      const HostRecord(
        id: '11111111-1111-4111-8111-111111111111',
        name: 'Original Host',
        address: 'example.test',
        username: 'demo',
        manifest: {
          'future_plugin': {'keep': true},
        },
      ),
    );
  });
  tearDown(() async {
    await database.close();
    await profile.lock();
    await catalog.close();
  });

  test('an RDP Host keeps the system its server stated; other protocols do not', () async {
    final windows = HostOperatingSystem(
      family: HostOperatingSystemFamily.windows,
      displayName: 'Windows',
      version: '10.0.22631',
      detectedAt: DateTime.utc(2026, 11, 18),
    );
    final rdp = await repository.createHost(
      const HostRecord(
        id: '22222222-2222-4222-8222-222222222222',
        name: 'Desktop',
        address: 'desktop.example.test',
        port: 3389,
        username: 'demo',
        protocol: HostProtocol.rdp,
      ),
    );
    final saved = await HostOperatingSystemPersistence.saveLocal(
      repository: repository,
      connectedHost: rdp,
      observation: windows,
      isCurrentConnection: () => true,
    );
    expect(saved!.detectedOperatingSystem!.sameSystem(windows), isTrue);
    expect(saved.revisionId, isNot(rdp.revisionId));
    // The same system again writes no new revision.
    final again = await HostOperatingSystemPersistence.saveLocal(
      repository: repository,
      connectedHost: saved,
      observation: windows,
      isCurrentConnection: () => true,
    );
    expect(again!.revisionId, saved.revisionId);
    final vnc = await repository.createHost(
      const HostRecord(
        id: '33333333-3333-4333-8333-333333333333',
        name: 'Screen',
        address: 'screen.example.test',
        port: 5900,
        protocol: HostProtocol.vnc,
      ),
    );
    expect(
      await HostOperatingSystemPersistence.saveLocal(
        repository: repository,
        connectedHost: vnc,
        observation: windows,
        isCurrentConnection: () => true,
      ),
      isNull,
    );
  });

  test('encrypted metadata roundtrips through strict repository while preserving current edits', () async {
    await repository.updateHost(
      host: original.copyWith(name: 'Edited while connecting'),
      baseRevisionId: original.revisionId!,
    );
    final saved = await HostOperatingSystemPersistence.saveLocal(
      repository: repository,
      connectedHost: original,
      observation: observed,
      isCurrentConnection: () => true,
    );
    expect(saved?.name, 'Edited while connecting');
    expect(saved?.detectedOperatingSystem?.sameSystem(observed), isTrue);
    expect(saved?.manifest?['future_plugin'], {'keep': true});
    final stored = await repository.getHost(original.id);
    expect(stored?.detectedOperatingSystem?.distributionId, 'debian');
    final unchanged = await HostOperatingSystemPersistence.saveLocal(
      repository: repository,
      connectedHost: original,
      observation: observed,
      isCurrentConnection: () => true,
    );
    expect(unchanged?.revisionId, stored?.revisionId);
  });

  test('unknown observations and stale scopes never erase metadata or write a revision', () async {
    final saved = await repository.updateHost(
      host: original.copyWithDetectedOperatingSystem(observed),
      baseRevisionId: original.revisionId!,
    );
    expect(
      await HostOperatingSystemPersistence.saveLocal(
        repository: repository,
        connectedHost: original,
        observation: null,
        isCurrentConnection: () => true,
      ),
      isNull,
    );
    expect(
      await HostOperatingSystemPersistence.saveLocal(
        repository: repository,
        connectedHost: original,
        observation: observed,
        isCurrentConnection: () => false,
      ),
      isNull,
    );
    final generic = HostOperatingSystem(
      family: HostOperatingSystemFamily.linux,
      displayName: 'Linux',
      detectedAt: DateTime.utc(2026, 11, 6),
    );
    final retained = await HostOperatingSystemPersistence.saveLocal(
      repository: repository,
      connectedHost: original,
      observation: generic,
      isCurrentConnection: () => true,
    );
    expect(retained?.detectedOperatingSystem?.distributionId, 'debian');
    expect(
      (await repository.getHost(original.id))?.revisionId,
      saved.revisionId,
    );
  });

  test('endpoint edits and deleted hosts cannot be overwritten or resurrected by a probe', () async {
    final edited = await repository.updateHost(
      host: original.copyWith(address: 'other.test'),
      baseRevisionId: original.revisionId!,
    );
    expect(
      await HostOperatingSystemPersistence.saveLocal(
        repository: repository,
        connectedHost: original,
        observation: observed,
        isCurrentConnection: () => true,
      ),
      isNull,
    );
    expect(
      (await repository.getHost(original.id))?.revisionId,
      edited.revisionId,
    );
    await repository.deleteHost(
      recordId: original.id,
      baseRevisionId: edited.revisionId!,
    );
    expect(
      await HostOperatingSystemPersistence.saveLocal(
        repository: repository,
        connectedHost: original,
        observation: observed,
        isCurrentConnection: () => true,
      ),
      isNull,
    );
    expect(await repository.getHost(original.id), isNull);
  });
}
