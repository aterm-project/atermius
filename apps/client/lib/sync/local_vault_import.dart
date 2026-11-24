import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../app_controller.dart';
import '../crypto/jcs.dart';
import '../crypto/vault_crypto.dart';
import '../l10n/l10n.dart';
import '../storage/application_reload.dart';
import '../storage/client_database.dart';
import '../storage/database_quarantine.dart';
import '../storage/local_host_repository.dart';
import '../storage/local_migration_target_validator.dart';
import '../storage/local_profile_catalog.dart';
import '../storage/local_profile_service.dart';
import '../storage/local_vault_database.dart';

/// The local profile storage of this device (catalog and key service).
typedef LocalImportStorage = ({
  LocalProfileCatalog catalog,
  LocalProfileService service,
});

/// Opens the LocalVault database of an unlocked profile.
typedef LocalImportDatabaseOpener = Future<LocalVaultDatabase> Function(
  UnlockedLocalProfile profile,
);

/// The target Vault's records as this device holds them.
class LocalImportTargetState {
  const LocalImportTargetState({required this.cached, required this.pending});

  final List<EncryptedRecord> cached;
  final List<PendingOperation> pending;
}

/// The signed-in account an import writes to: [AppController] in the app
/// ([AppControllerImportDestination]), a fake in tests.
abstract interface class LocalImportDestination implements Listenable {
  /// Signed in, unlocked, and the server instance is known.
  bool get ready;

  /// Changes whenever the session or server changes (sign-out, account or
  /// server switch).
  Object get scope;
  String? get instanceId;
  String? get accountId;
  String? get deviceId;
  String? get activeVaultId;
  Object? get preferenceError;
  String vaultName(String vaultId);
  String describeError(Object error);

  Future<bool> destinationIsCurrent(String instanceId);
  Future<({String vaultId, String payloadJson})> prepareVaultCreation(
    String name,
  );
  Future<void> createOrResumeVault({
    required String vaultId,
    required String payloadJson,
  });
  Future<void> synchronizeTarget(String vaultId);
  Future<Map<String, Object?>> encryptRecord({
    required String targetVaultId,
    required String recordId,
    required Map<String, Object?> plaintext,
  });
  Future<ExactCreateOperationResult> enqueueEnvelope({
    required String targetVaultId,
    required Map<String, Object?> envelope,
  });

  /// Throws when the workspace is no longer connected to [instanceId].
  Future<LocalImportTargetState> readTargetState({
    required String vaultId,
    required String instanceId,
  });
}

/// [AppController] as the destination of a LocalVault import.
class AppControllerImportDestination implements LocalImportDestination {
  AppControllerImportDestination(this.app);

  final AppController app;

  @override
  void addListener(VoidCallback listener) => app.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => app.removeListener(listener);

  @override
  bool get ready =>
      app.authenticated &&
      !app.workspaceLocked &&
      !app.restoringStoredSession &&
      app.instance != null;

  @override
  Object get scope => app.authScopeToken;

  @override
  String? get instanceId => app.instance?.instanceId;

  @override
  String? get accountId => app.currentAccountId;

  @override
  String? get deviceId => app.identity?.deviceId;

  @override
  String? get activeVaultId => app.activeVault?.id;

  @override
  Object? get preferenceError => app.preferenceError;

  @override
  String vaultName(String vaultId) => app.vaultNameFor(vaultId);

  @override
  String describeError(Object error) => app.friendlyError(error);

  @override
  Future<bool> destinationIsCurrent(String instanceId) =>
      app.migrationDestinationIsCurrent(instanceId);

  @override
  Future<({String vaultId, String payloadJson})> prepareVaultCreation(
    String name,
  ) => app.prepareMigrationVaultCreation(name);

  @override
  Future<void> createOrResumeVault({
    required String vaultId,
    required String payloadJson,
  }) => app.createOrResumeMigrationVault(
    vaultId: vaultId,
    payloadJson: payloadJson,
  );

  @override
  Future<void> synchronizeTarget(String vaultId) =>
      app.synchronizeMigrationTarget(vaultId);

  @override
  Future<Map<String, Object?>> encryptRecord({
    required String targetVaultId,
    required String recordId,
    required Map<String, Object?> plaintext,
  }) => app.encryptMigrationRecord(
    targetVaultId: targetVaultId,
    recordId: recordId,
    plaintext: plaintext,
  );

  @override
  Future<ExactCreateOperationResult> enqueueEnvelope({
    required String targetVaultId,
    required Map<String, Object?> envelope,
  }) => app.enqueueMigrationEnvelope(
    targetVaultId: targetVaultId,
    envelope: envelope,
  );

  @override
  Future<LocalImportTargetState> readTargetState({
    required String vaultId,
    required String instanceId,
  }) async {
    final instance = app.instance;
    if (instance == null || instance.instanceId != instanceId) {
      throw StateError(currentL10n.theMigrationDestinationBelongsToA);
    }
    final cached = await app.database.cachedEnvelopes(
      vaultId,
      instanceId: instance.instanceId,
      serverSpaceId: instance.serverSpaceId,
    );
    final pending = await app.database.allPendingOperations(
      vaultId,
      instanceId: instance.instanceId,
      serverSpaceId: instance.serverSpaceId,
    );
    return LocalImportTargetState(cached: cached, pending: pending);
  }
}

/// One local-only profile of this device, as the Settings card shows it.
class LocalImportProfile {
  const LocalImportProfile({
    required this.profileId,
    required this.createdAt,
    required this.keyStored,
    this.journals,
    this.cancelableIds = const {},
  });

  final String profileId;
  final DateTime createdAt;

  /// This device keeps the profile's key: no password is needed.
  final bool keyStored;

  /// Import journals, newest first; null while unknown (a profile whose key
  /// is not stored is read only after its password was entered).
  final List<LocalMigrationJournalSummary>? journals;

  /// Interrupted imports that never sent anything (no Vault creation data
  /// and no record was staged); they can be cancelled without a trace.
  final Set<String> cancelableIds;

  /// Imports that stopped before the server confirmed every record. The
  /// local profile cannot be edited while one of them exists.
  List<LocalMigrationJournalSummary> get interrupted => [
    for (final journal in journals ?? const <LocalMigrationJournalSummary>[])
      if (journal.state == 'frozen') journal,
  ];

  LocalMigrationJournalSummary? get lastCompleted =>
      journals?.where((journal) => journal.state == 'completed').firstOrNull;

  LocalImportProfile copyWith({
    List<LocalMigrationJournalSummary>? journals,
    Set<String>? cancelableIds,
  }) => LocalImportProfile(
    profileId: profileId,
    createdAt: createdAt,
    keyStored: keyStored,
    journals: journals ?? this.journals,
    cancelableIds: cancelableIds ?? this.cancelableIds,
  );
}

enum LocalImportPhase {
  /// Unlocking, checking the server, freezing the local snapshot.
  preparing,

  /// Encrypting and staging records for the target Vault.
  encrypting,

  /// Waiting until the server confirmed every staged record.
  uploading,

  /// Final verification before the local profile is released.
  verifying,
}

/// What the running import is doing.
class LocalImportProgress {
  const LocalImportProgress({
    required this.profileId,
    required this.phase,
    this.done = 0,
    this.total = 0,
    this.waitingForServer = false,
  });

  final String profileId;
  final LocalImportPhase phase;
  final int done;
  final int total;

  /// Several sync rounds went by without a new confirmation.
  final bool waitingForServer;
}

enum LocalImportOutcome {
  completed,

  /// Stopped with an error; the journal (if any) stays resumable.
  failed,

  /// Stopped because the workspace changed (sign-out, lock, another server
  /// or Vault); it continues later.
  paused,

  /// An interrupted import was abandoned or cancelled.
  stopped,
}

class LocalImportResult {
  const LocalImportResult({
    required this.profileId,
    required this.outcome,
    this.message,
    this.vaultName,
    this.recordCount = 0,
  });

  final String profileId;
  final LocalImportOutcome outcome;
  final String? message;
  final String? vaultName;
  final int recordCount;
}

/// How an import, resume, abandon or cancel request was taken.
enum LocalImportAccess {
  /// Started (an import runs on in the background) or done.
  started,

  /// The profile's key is not stored on this device: ask for its password.
  passwordRequired,

  /// The password did not unlock the profile.
  passwordRejected,

  /// Another import or action is running.
  busy,

  /// Local profile storage is not available (or needs a reload).
  unavailable,

  /// Refused or failed; [LocalVaultImport.resultFor] says why.
  failed,
}

/// Backoff of the background upload: a few seconds, doubling up to
/// [maxDelay] while the server confirms nothing new, given up after
/// [giveUpAfterIdleRounds] such rounds.
class LocalImportRetry {
  const LocalImportRetry({
    this.firstDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(minutes: 1),
    this.giveUpAfterIdleRounds = 20,
  });

  final Duration firstDelay;
  final Duration maxDelay;
  final int giveUpAfterIdleRounds;
}

const _uuid = Uuid();

/// Imports a LocalVault (local-only profile) into a new server Vault in the
/// background, and finishes imports that were interrupted.
///
/// It owns the unlocked profile and its LocalVault database only while an
/// import or a short read runs, and always locks and closes them afterwards
/// (also on errors, sign-out, workspace lock, account or server switch and
/// [dispose]). Source secrets are decrypted only in memory; the profile's
/// durable journal keeps the exact target ciphertext, so any stop is safe to
/// resume.
///
/// After staging, it keeps synchronizing the target Vault with a bounded
/// backoff until the server confirmed every staged record, verifies the
/// target, and only then releases the local profile ([LocalHostRepository
/// .finishMigration]). When the account workspace becomes ready it finishes
/// interrupted imports into the same server and account without asking, if
/// the profile's key is stored on this device. It never starts a new import
/// by itself.
class LocalVaultImport extends ChangeNotifier {
  LocalVaultImport({
    required this.destination,
    required this.crypto,
    required this._openStorage,
    DatabaseQuarantineRegistry? quarantine,
    LocalImportDatabaseOpener? openDatabase,
    this.retry = const LocalImportRetry(),
    this.autoResume = true,
    this.autoResumeDelay = const Duration(seconds: 3),
    VoidCallback? reloadPage,
  }) : _quarantine = quarantine ?? databaseQuarantineRegistry,
       _openDatabase =
           openDatabase ??
           ((profile) => LocalVaultDatabase.open(
             profile,
             mode: LocalVaultOpenMode.openExisting,
           )),
       _reloadPage = reloadPage ?? reloadApplication {
    _quarantine.addListener(_onQuarantineChanged);
    destination.addListener(_onDestinationChanged);
    _storageRecoveryRequired = _relevantQuarantine;
    _onDestinationChanged();
  }

  final LocalImportDestination destination;
  final VaultCrypto crypto;
  final LocalImportRetry retry;
  final bool autoResume;
  final Duration autoResumeDelay;
  final Future<LocalImportStorage?> Function() _openStorage;
  final DatabaseQuarantineRegistry _quarantine;
  final LocalImportDatabaseOpener _openDatabase;
  final VoidCallback _reloadPage;

  bool _disposed = false;
  bool _storageRecoveryRequired = false;
  bool _loading = false;
  bool _loaded = false;
  bool _available = true;
  bool _listFailed = false;
  bool _actionBusy = false;
  bool _autoResuming = false;
  String? _busyProfileId;
  List<LocalImportProfile> _profiles = const [];
  String? _selectedProfileId;
  _ImportJob? _job;
  final Map<String, LocalImportResult> _results = {};
  final List<String> _notices = [];
  Object? _readyKey;
  Timer? _autoResumeTimer;
  String? _resumeWhenVaultOpens;
  Future<void>? _refreshing;
  Future<void> _lockTail = Future<void>.value();
  LocalImportStorage? _openedStorage;
  Future<LocalImportStorage?>? _storageOpening;

  /// Local profile storage could be opened on this device.
  bool get available => _available;
  bool get loading => _loading;

  /// The profile list was read at least once.
  bool get loaded => _loaded;

  /// The profile list could not be read.
  bool get listFailed => _listFailed;

  /// A local database write was interrupted; the page must be reloaded.
  bool get storageRecoveryRequired => _storageRecoveryRequired;
  List<LocalImportProfile> get profiles => _profiles;
  String? get selectedProfileId => _selectedProfileId;
  LocalImportProfile? get selectedProfile => _profiles
      .where((item) => item.profileId == _selectedProfileId)
      .firstOrNull;

  /// An import (or a short action) is running; new requests are refused.
  bool get busy => _job != null || _actionBusy || _autoResuming;

  /// The running import, if any.
  LocalImportProgress? get progress => _job?.progress;

  /// How the last import or action for [profileId] ended (this session).
  LocalImportResult? resultFor(String profileId) => _results[profileId];

  /// Completion message of an import that finished since the last call
  /// (shown as a SnackBar wherever the user is).
  String? takeNotice() => _notices.isEmpty ? null : _notices.removeAt(0);

  /// Completes when the running import (if any) has ended.
  Future<void> get idle => _job?.done.future ?? Future<void>.value();

  void selectProfile(String profileId) {
    if (busy || _selectedProfileId == profileId) return;
    if (!_profiles.any((item) => item.profileId == profileId)) return;
    _selectedProfileId = profileId;
    _notify();
  }

  void reloadPage() => _reloadPage();

  /// Re-reads the local profiles and their import journals (opening each
  /// profile only with a key stored on this device).
  Future<void> refresh() {
    if (_disposed || _storageRecoveryRequired) return Future<void>.value();
    return _refreshing ??= _serialized(_refresh)
        .whenComplete(() => _refreshing = null);
  }

  /// Imports [profileId] into a new server Vault, or finishes its interrupted
  /// import into this server. Returns once the import runs in the background.
  Future<LocalImportAccess> importProfile(
    String profileId, {
    String? password,
  }) => _begin(profileId, password: password);

  /// Finishes the interrupted import [migrationId] of [profileId].
  Future<LocalImportAccess> resume(
    String profileId,
    String migrationId, {
    String? password,
  }) => _begin(profileId, password: password, migrationId: migrationId);

  /// Stops the interrupted import [migrationId] and makes the local profile
  /// editable again. Records already sent stay in the server Vault.
  Future<LocalImportAccess> abandon(
    String profileId,
    String migrationId, {
    String? password,
  }) => _journalAction(
    profileId,
    password: password,
    failure: currentL10n.couldntStopTheMigrationTheSource,
    success: currentL10n.localImportAbandoned,
    action: (repository) => repository.abandonMigration(migrationId),
  );

  /// Cancels an import that was interrupted before anything was sent.
  Future<LocalImportAccess> cancelPreparation(
    String profileId,
    String migrationId, {
    String? password,
  }) => _journalAction(
    profileId,
    password: password,
    failure: currentL10n.thisMigrationCantBeCancelledSafely,
    success: currentL10n.localImportPreparationCancelled,
    action: (repository) async {
      final payload = await repository.readMigrationCreatePayload(migrationId);
      final staged = await repository.listStagedMigrationItems(migrationId);
      if (payload != null || staged.isNotEmpty) {
        throw StateError(currentL10n.destinationDataIsAlreadyStagedThis);
      }
      await repository.cancelMigration(migrationId);
    },
  );

  /// Stops the running import (it stays resumable), waits briefly for it to
  /// close the local profile, and disposes this object.
  Future<void> close() async {
    if (_disposed) return;
    final job = _job;
    if (job != null) {
      job.stop(currentL10n.localImportPausedSignedOut);
      try {
        await job.done.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        // A network call cannot be cancelled; the profile is closed anyway.
      }
      await job.session.close();
    }
    dispose();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    _quarantine.removeListener(_onQuarantineChanged);
    destination.removeListener(_onDestinationChanged);
    final job = _job;
    if (job != null) {
      job.stop(currentL10n.localImportPausedSignedOut);
      unawaited(job.session.close());
    }
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Workspace and storage state.
  // ---------------------------------------------------------------------------

  void _onDestinationChanged() {
    if (_disposed) return;
    final job = _job;
    if (job != null && job.stopReason == null) {
      final loss = _scopeLoss(job);
      if (loss != null) job.stop(loss);
    }
    final ready = destination.ready && destination.instanceId != null;
    final key = ready ? (destination.scope, destination.instanceId) : null;
    if (key != _readyKey) {
      _readyKey = key;
      if (key != null) {
        _scheduleAutoResume();
      } else {
        _autoResumeTimer?.cancel();
        _autoResumeTimer = null;
      }
    }
    final waitingFor = _resumeWhenVaultOpens;
    if (ready &&
        waitingFor != null &&
        destination.activeVaultId == waitingFor &&
        _job == null) {
      _resumeWhenVaultOpens = null;
      _scheduleAutoResume();
    }
  }

  bool get _relevantQuarantine {
    final names = _quarantine.quarantinedDatabaseNames;
    return names.contains(localProfileCatalogDatabaseName) ||
        names.any((name) => name.startsWith(localVaultDatabaseNamePrefix));
  }

  void _onQuarantineChanged() {
    if (_relevantQuarantine) _enterStorageRecovery();
  }

  void _enterStorageRecovery() {
    if (_disposed || _storageRecoveryRequired) return;
    _storageRecoveryRequired = true;
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    final job = _job;
    if (job != null) {
      job.stop(currentL10n.aLocalStorageWriteWasInterrupted);
      // Like the old migration page: give up the unlocked profile now, not
      // after an in-flight step returns.
      unawaited(job.session.close());
    }
    _profiles = const [];
    _notify();
  }

  void _throwIfStorageRecovery() {
    if (_storageRecoveryRequired) {
      throw const DatabaseRecoveryRequiredException();
    }
  }

  /// Runs a LocalVault or catalog operation. A quarantine that happened while
  /// it ran discards its result (after [onQuarantined] cleanup).
  Future<T> _local<T>(
    Future<T> Function() operation, {
    FutureOr<void> Function(T result)? onQuarantined,
  }) async {
    _throwIfStorageRecovery();
    try {
      final result = await operation();
      if (_storageRecoveryRequired) {
        if (onQuarantined != null) {
          try {
            await onQuarantined(result);
          } on Object {
            // Keep the recovery error even if best-effort cleanup fails.
          }
        }
        throw const DatabaseRecoveryRequiredException();
      }
      return result;
    } on DatabaseRecoveryRequiredException {
      _enterStorageRecovery();
      rethrow;
    }
  }

  /// One profile session at a time: refreshes, auto-resume checks, actions
  /// and import starts never open the same LocalVault twice.
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _lockTail.then((_) => action());
    _lockTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<LocalImportStorage?> _storage() async {
    _throwIfStorageRecovery();
    final opened = _openedStorage;
    if (opened != null) return opened;
    // One open at a time: a second caller would find it still opening and
    // take the storage for unavailable.
    final storage = await (_storageOpening ??= _openStorage().whenComplete(
      () => _storageOpening = null,
    ));
    if (storage == null &&
        _quarantine.isQuarantined(localProfileCatalogDatabaseName)) {
      _enterStorageRecovery();
      throw const DatabaseRecoveryRequiredException();
    }
    _available = storage != null;
    _openedStorage = storage;
    return storage;
  }

  /// Unlocks [profileId] (with its stored key when [password] is null) and
  /// opens its LocalVault. Null: no stored key could be used.
  Future<_ProfileSession?> _openSession(
    LocalProfileService service,
    String profileId, {
    String? password,
  }) async {
    UnlockedLocalProfile? unlocked;
    LocalVaultDatabase? database;
    try {
      try {
        unlocked = await _local<UnlockedLocalProfile?>(
          () => password == null
              ? service.tryUnlockForMigration(profileId)
              : service.unlock(profileId: profileId, password: password),
          onQuarantined: (profile) => profile?.lock(),
        );
      } on DatabaseRecoveryRequiredException {
        rethrow;
      } on Object {
        if (password != null) throw const _PasswordRejected();
        rethrow;
      }
      final profile = unlocked;
      if (profile == null) return null;
      database = await _local<LocalVaultDatabase>(
        () => _openDatabase(profile),
        onQuarantined: (opened) => opened.close(),
      );
      final session = _ProfileSession(
        profile: profile,
        database: database,
        repository: LocalHostRepository(
          database: database,
          profile: profile,
          crypto: crypto,
        ),
      );
      unlocked = null;
      database = null;
      return session;
    } finally {
      final profile = unlocked;
      if (profile != null) {
        await _ProfileSession.closeParts(profile, database);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Profile list.
  // ---------------------------------------------------------------------------

  Future<void> _refresh() async {
    if (_disposed || _storageRecoveryRequired) return;
    _loading = true;
    _notify();
    try {
      final storage = await _storage();
      if (storage == null) {
        _profiles = const [];
        _listFailed = false;
        return;
      }
      final records = await _local(storage.catalog.list);
      final next = <LocalImportProfile>[];
      for (final record in records) {
        if (_disposed || _storageRecoveryRequired) return;
        next.add(await _inspect(storage, record));
      }
      _profiles = List.unmodifiable(next);
      _listFailed = false;
      if (!_profiles.any((item) => item.profileId == _selectedProfileId)) {
        _selectedProfileId = _profiles.firstOrNull?.profileId;
      }
    } on DatabaseRecoveryRequiredException {
      // Storage recovery is shown instead of the list.
    } on Object {
      _listFailed = true;
    } finally {
      _loading = false;
      _loaded = true;
      _notify();
    }
  }

  Future<LocalImportProfile> _inspect(
    LocalImportStorage storage,
    LocalProfileRecord record,
  ) async {
    final previous = _profiles
        .where((item) => item.profileId == record.profileId)
        .firstOrNull;
    final job = _job;
    if ((job != null && job.profileId == record.profileId) ||
        _busyProfileId == record.profileId) {
      // Its LocalVault is open for the import; keep what is known.
      return previous ??
          LocalImportProfile(
            profileId: record.profileId,
            createdAt: record.createdAt,
            keyStored: true,
          );
    }
    _ProfileSession? session;
    try {
      session = await _openSession(storage.service, record.profileId);
      if (session == null) {
        return LocalImportProfile(
          profileId: record.profileId,
          createdAt: record.createdAt,
          keyStored: false,
          // What a password session learned earlier stays visible.
          journals: previous?.journals,
          cancelableIds: previous?.cancelableIds ?? const {},
        );
      }
      final repository = session.repository;
      final journals = await _local(repository.listMigrationJournals);
      return LocalImportProfile(
        profileId: record.profileId,
        createdAt: record.createdAt,
        keyStored: true,
        journals: journals,
        cancelableIds: await _cancelablePreparations(repository, journals),
      );
    } on DatabaseRecoveryRequiredException {
      rethrow;
    } on Object {
      return LocalImportProfile(
        profileId: record.profileId,
        createdAt: record.createdAt,
        keyStored: false,
        journals: previous?.journals,
        cancelableIds: previous?.cancelableIds ?? const {},
      );
    } finally {
      await session?.close();
    }
  }

  Future<Set<String>> _cancelablePreparations(
    LocalHostRepository repository,
    List<LocalMigrationJournalSummary> journals,
  ) async {
    final result = <String>{};
    for (final journal in journals) {
      if (journal.state != 'frozen' || journal.stagedItemCount != 0) continue;
      try {
        final payload = await _local(
          () => repository.readMigrationCreatePayload(journal.migrationId),
        );
        if (payload == null) result.add(journal.migrationId);
      } on DatabaseRecoveryRequiredException {
        rethrow;
      } on Object {
        // A damaged or unavailable journal is never offered for cancel.
      }
    }
    return result;
  }

  /// Remembers the journals a (possibly password) session saw.
  Future<void> _rememberJournals(_ProfileSession session) async {
    try {
      final repository = session.repository;
      final journals = await _local(repository.listMigrationJournals);
      final cancelable = await _cancelablePreparations(repository, journals);
      _profiles = List.unmodifiable([
        for (final item in _profiles)
          item.profileId == session.profileId
              ? item.copyWith(journals: journals, cancelableIds: cancelable)
              : item,
      ]);
    } on Object {
      // The next refresh reads them again.
    }
  }

  // ---------------------------------------------------------------------------
  // Starting, resuming, abandoning.
  // ---------------------------------------------------------------------------

  Future<LocalImportAccess> _begin(
    String profileId, {
    String? password,
    String? migrationId,
  }) async {
    if (_disposed || _storageRecoveryRequired) {
      return LocalImportAccess.unavailable;
    }
    if (busy) return LocalImportAccess.busy;
    if (!destination.ready || destination.instanceId == null) {
      _results[profileId] = LocalImportResult(
        profileId: profileId,
        outcome: LocalImportOutcome.failed,
        message: currentL10n.theSyncServiceIdentityIsntVerified,
      );
      _notify();
      return LocalImportAccess.failed;
    }
    _actionBusy = true;
    _busyProfileId = profileId;
    _results.remove(profileId);
    _notify();
    try {
      return await _serialized(() async {
        _ProfileSession? session;
        try {
          final storage = await _storage();
          if (storage == null) return LocalImportAccess.unavailable;
          session = await _openSession(
            storage.service,
            profileId,
            password: password,
          );
          if (session == null) return LocalImportAccess.passwordRequired;
          final instanceId = destination.instanceId;
          if (!destination.ready || instanceId == null || _disposed) {
            return LocalImportAccess.failed;
          }
          _startJob(session, migrationId: migrationId, automatic: false);
          session = null;
          return LocalImportAccess.started;
        } on _PasswordRejected {
          return LocalImportAccess.passwordRejected;
        } on DatabaseRecoveryRequiredException {
          return LocalImportAccess.unavailable;
        } on Object {
          _results[profileId] = LocalImportResult(
            profileId: profileId,
            outcome: LocalImportOutcome.failed,
            message: currentL10n.couldntUnlockOrVerifyThisLocal,
          );
          return LocalImportAccess.failed;
        } finally {
          await session?.close();
        }
      });
    } finally {
      _actionBusy = false;
      _busyProfileId = null;
      _notify();
    }
  }

  Future<LocalImportAccess> _journalAction(
    String profileId, {
    required String? password,
    required String failure,
    required String success,
    required Future<void> Function(LocalHostRepository repository) action,
  }) async {
    if (_disposed || _storageRecoveryRequired) {
      return LocalImportAccess.unavailable;
    }
    if (busy) return LocalImportAccess.busy;
    _actionBusy = true;
    _busyProfileId = profileId;
    _results.remove(profileId);
    _notify();
    try {
      return await _serialized(() async {
        _ProfileSession? session;
        try {
          final storage = await _storage();
          if (storage == null) return LocalImportAccess.unavailable;
          session = await _openSession(
            storage.service,
            profileId,
            password: password,
          );
          if (session == null) return LocalImportAccess.passwordRequired;
          final repository = session.repository;
          try {
            await _local(() => action(repository));
          } on DatabaseRecoveryRequiredException {
            rethrow;
          } on Object {
            _results[profileId] = LocalImportResult(
              profileId: profileId,
              outcome: LocalImportOutcome.failed,
              message: failure,
            );
            await _rememberJournals(session);
            return LocalImportAccess.failed;
          }
          _results[profileId] = LocalImportResult(
            profileId: profileId,
            outcome: LocalImportOutcome.stopped,
            message: success,
          );
          await _rememberJournals(session);
          return LocalImportAccess.started;
        } on _PasswordRejected {
          return LocalImportAccess.passwordRejected;
        } on DatabaseRecoveryRequiredException {
          return LocalImportAccess.unavailable;
        } on Object {
          _results[profileId] = LocalImportResult(
            profileId: profileId,
            outcome: LocalImportOutcome.failed,
            message: currentL10n.couldntUnlockOrVerifyThisLocal,
          );
          return LocalImportAccess.failed;
        } finally {
          await session?.close();
        }
      });
    } finally {
      _actionBusy = false;
      _busyProfileId = null;
      _notify();
    }
  }

  void _startJob(
    _ProfileSession session, {
    required String? migrationId,
    required bool automatic,
  }) {
    final job = _ImportJob(
      session: session,
      scope: destination.scope,
      instanceId: destination.instanceId!,
      automatic: automatic,
    );
    _job = job;
    _selectedProfileId = session.profileId;
    _results.remove(session.profileId);
    _resumeWhenVaultOpens = null;
    _notify();
    unawaited(_run(job, migrationId));
  }

  // ---------------------------------------------------------------------------
  // Automatic resume.
  // ---------------------------------------------------------------------------

  void _scheduleAutoResume() {
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    if (!autoResume || _disposed || _storageRecoveryRequired) return;
    _autoResumeTimer = Timer(autoResumeDelay, () {
      _autoResumeTimer = null;
      unawaited(_autoResumeNow());
    });
  }

  /// Finishes interrupted imports into the current server and account, one
  /// profile after the other, for profiles whose key is stored here.
  Future<void> _autoResumeNow() async {
    if (_disposed || _storageRecoveryRequired || busy) return;
    final instanceId = destination.instanceId;
    if (!destination.ready || instanceId == null) return;
    _autoResuming = true;
    _notify();
    try {
      final storage = await _storage();
      if (storage == null) return;
      final records = await _local(storage.catalog.list);
      for (final record in records) {
        if (_disposed ||
            _storageRecoveryRequired ||
            !destination.ready ||
            destination.instanceId != instanceId) {
          return;
        }
        final job = await _serialized(
          () => _autoResumeProfile(storage, record.profileId, instanceId),
        );
        // The next profile is checked once this import has ended.
        if (job != null) await job.done.future;
      }
    } on Object {
      // Automatic resume never reports its own errors; the card shows the
      // interrupted import with Resume.
    } finally {
      _autoResuming = false;
      _notify();
    }
  }

  Future<_ImportJob?> _autoResumeProfile(
    LocalImportStorage storage,
    String profileId,
    String instanceId,
  ) async {
    _ProfileSession? session;
    try {
      final opened = session = await _openSession(storage.service, profileId);
      if (opened == null) return null;
      final repository = opened.repository;
      final journals = await _local(repository.listMigrationJournals);
      for (final journal in journals) {
        if (journal.state != 'frozen' ||
            journal.targetInstanceId != instanceId) {
          continue;
        }
        final payload = await _local(
          () => repository.readMigrationCreatePayload(journal.migrationId),
        );
        // Nothing was sent for an empty preparation: leave it to the user.
        if (payload == null || !_payloadBelongsHere(payload)) continue;
        if (_disposed ||
            !destination.ready ||
            destination.instanceId != instanceId) {
          return null;
        }
        _startJob(opened, migrationId: journal.migrationId, automatic: true);
        session = null;
        return _job;
      }
      return null;
    } finally {
      await session?.close();
    }
  }

  /// The staged Vault creation names this account as owner and this device
  /// as key recipient; an import of another account is never touched.
  bool _payloadBelongsHere(String payloadJson) {
    try {
      final payload = jsonDecode(payloadJson);
      if (payload is! Map) return false;
      final keyEnvelope = payload['key_envelope'];
      final membership = payload['membership'];
      if (keyEnvelope is! Map || membership is! Map) return false;
      final manifest = membership['manifest'];
      if (manifest is! Map || manifest['members'] is! List) return false;
      final accountId = destination.accountId;
      final deviceId = destination.deviceId;
      return accountId != null &&
          deviceId != null &&
          keyEnvelope['recipient_device_id'] == deviceId &&
          (manifest['members'] as List).any(
            (member) => member is Map && member['user_id'] == accountId,
          );
    } on Object {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // The import itself.
  // ---------------------------------------------------------------------------

  Future<void> _run(_ImportJob job, String? migrationId) async {
    LocalImportResult result;
    try {
      result = await _runJob(job, migrationId);
    } on _Paused catch (paused) {
      result = _paused(job, paused.reason);
    } on DatabaseRecoveryRequiredException {
      _enterStorageRecovery();
      result = LocalImportResult(
        profileId: job.profileId,
        outcome: LocalImportOutcome.failed,
        message: currentL10n.aLocalStorageWriteWasInterrupted,
      );
    } on Object catch (error) {
      final stopReason = job.stopReason ?? _scopeLoss(job);
      final finished = stopReason == null
          ? await _completedMeanwhile(job)
          : null;
      if (stopReason != null) {
        // A sign-out or switch explains the error.
        result = _paused(job, stopReason);
      } else if (finished != null) {
        // Another window or an earlier attempt finished the same journal.
        result = _completed(job, finished.itemCount);
      } else {
        result = LocalImportResult(
          profileId: job.profileId,
          outcome: LocalImportOutcome.failed,
          message: currentL10n.localImportFailed(_reason(error)),
        );
      }
    }
    if (!_storageRecoveryRequired && !_disposed) {
      await _rememberJournals(job.session);
    }
    await job.session.close();
    if (identical(_job, job)) _job = null;
    if (!_disposed) {
      _results[job.profileId] = result;
      // Wherever the user is: a finished import, or one that needs them.
      // A pause (sign-out, lock, switch) was their own doing.
      switch (result.outcome) {
        case LocalImportOutcome.completed:
          _notices.add(
            currentL10n.localImportCompleted(
              result.recordCount,
              result.vaultName ?? '',
            ),
          );
        case LocalImportOutcome.failed:
          if (result.message case final message?) _notices.add(message);
        case LocalImportOutcome.paused || LocalImportOutcome.stopped:
          break;
      }
    }
    job.done.complete();
    _notify();
  }

  LocalImportResult _paused(_ImportJob job, String reason) {
    if (job.vaultSwitched) _resumeWhenVaultOpens = job.targetVaultId;
    return LocalImportResult(
      profileId: job.profileId,
      outcome: LocalImportOutcome.paused,
      message: reason,
    );
  }

  LocalImportResult _completed(_ImportJob job, int recordCount) {
    final vaultId = job.targetVaultId;
    return LocalImportResult(
      profileId: job.profileId,
      outcome: LocalImportOutcome.completed,
      vaultName: vaultId == null ? null : destination.vaultName(vaultId),
      recordCount: recordCount,
    );
  }

  Future<LocalMigrationJournalSummary?> _completedMeanwhile(
    _ImportJob job,
  ) async {
    final migrationId = job.migrationId;
    if (migrationId == null || _storageRecoveryRequired) return null;
    try {
      final journals = await _local(
        job.session.repository.listMigrationJournals,
      );
      return journals
          .where(
            (item) =>
                item.migrationId == migrationId && item.state == 'completed',
          )
          .firstOrNull;
    } on Object {
      return null;
    }
  }

  String _reason(Object error) {
    if (error is StateError) return error.message;
    if (error is FormatException) return error.message;
    if (error is TimeoutException) return currentL10n.localImportServerTimeout;
    return destination.describeError(error);
  }

  void _progress(
    _ImportJob job,
    LocalImportPhase phase, {
    int done = 0,
    int total = 0,
    bool waitingForServer = false,
  }) {
    job.progress = LocalImportProgress(
      profileId: job.profileId,
      phase: phase,
      done: done,
      total: total,
      waitingForServer: waitingForServer,
    );
    _notify();
  }

  /// Why [job] can no longer run against the current workspace, or null.
  String? _scopeLoss(_ImportJob job) {
    if (_disposed || !destination.ready) {
      return currentL10n.localImportPausedSignedOut;
    }
    if (destination.instanceId != job.instanceId) {
      return currentL10n.localImportPausedOtherServer;
    }
    if (destination.scope != job.scope) {
      return currentL10n.localImportPausedSignedOut;
    }
    final target = job.targetVaultId;
    if (job.vaultSelected &&
        target != null &&
        destination.activeVaultId != target) {
      job.vaultSwitched = true;
      return currentL10n.localImportPausedVaultSwitched;
    }
    return null;
  }

  void _ensureCurrent(_ImportJob job) {
    _throwIfStorageRecovery();
    final reason = job.stopReason ?? _scopeLoss(job);
    if (reason != null) {
      job.stop(reason);
      throw _Paused(reason);
    }
  }

  /// Runs a call into the account workspace. A call already in flight cannot
  /// be cancelled, but its completion never starts another step after a
  /// sign-out, switch or quarantine.
  Future<T> _remote<T>(_ImportJob job, Future<T> Function() operation) async {
    _ensureCurrent(job);
    try {
      final result = await operation();
      _ensureCurrent(job);
      return result;
    } on _Paused {
      rethrow;
    } on Object {
      _ensureCurrent(job);
      rethrow;
    }
  }

  Future<void> _sleep(_ImportJob job, Duration duration) async {
    final waker = Completer<void>();
    job.sleeper = waker;
    final timer = Timer(duration, () {
      if (!waker.isCompleted) waker.complete();
    });
    try {
      await waker.future;
    } finally {
      timer.cancel();
      job.sleeper = null;
    }
    _ensureCurrent(job);
  }

  Future<LocalImportResult> _runJob(_ImportJob job, String? migrationId) async {
    final repository = job.session.repository;
    _progress(job, LocalImportPhase.preparing);
    _ensureCurrent(job);
    var journals = await _local(repository.listMigrationJournals);
    if (!job.automatic) {
      // An import interrupted before anything was sent is cancelled (as the
      // old "Cancel empty preparation" did) and started again from scratch.
      final cancelable = await _cancelablePreparations(repository, journals);
      if (cancelable.isNotEmpty) {
        for (final id in cancelable) {
          await _local(() => repository.cancelMigration(id));
        }
        if (cancelable.contains(migrationId)) migrationId = null;
        journals = await _local(repository.listMigrationJournals);
      }
    }
    final frozen = journals.where((item) => item.state == 'frozen').toList();
    LocalMigrationJournalSummary? target;
    if (migrationId != null) {
      target = frozen
          .where((item) => item.migrationId == migrationId)
          .firstOrNull;
      if (target == null) {
        final completed = journals
            .where(
              (item) =>
                  item.migrationId == migrationId && item.state == 'completed',
            )
            .firstOrNull;
        if (completed != null) {
          job.migrationId = migrationId;
          job.targetVaultId = completed.targetVaultId;
          return _completed(job, completed.itemCount);
        }
        throw StateError(currentL10n.localImportNoLongerInterrupted);
      }
    } else {
      final here = [
        for (final item in frozen)
          if (item.targetInstanceId == job.instanceId) item,
      ];
      if (here.length != frozen.length || here.length > 1) {
        throw StateError(currentL10n.localImportOtherUnfinished);
      }
      target = here.firstOrNull;
    }
    if (target == null) return _startNew(job);
    if (target.targetInstanceId != job.instanceId) {
      throw StateError(currentL10n.theMigrationDestinationBelongsToA);
    }
    return _resumeJournal(job, target.migrationId);
  }

  Future<LocalImportResult> _startNew(_ImportJob job) async {
    final repository = job.session.repository;
    final name = currentL10n.importedLocalProfiles;
    final current = await _remote(
      job,
      () => destination.destinationIsCurrent(job.instanceId),
    );
    final prepared = current
        ? await _remote(job, () => destination.prepareVaultCreation(name))
        : null;
    if (prepared == null || destination.scope != job.scope) {
      throw StateError(currentL10n.localImportServerChanged);
    }
    final migrationId = _uuid.v4();
    job.migrationId = migrationId;
    // Freezes the local profile: its edits pause until the import finishes
    // or is abandoned.
    final snapshot = await _local(
      () => repository.prepareMigrationSnapshot(
        migrationId: migrationId,
        targetInstanceId: job.instanceId,
        targetVaultId: prepared.vaultId,
      ),
    );
    await _local(
      () => repository.stageMigrationCreatePayload(
        migrationId: migrationId,
        payloadJson: prepared.payloadJson,
      ),
    );
    return _continue(job, snapshot, prepared.payloadJson);
  }

  Future<LocalImportResult> _resumeJournal(
    _ImportJob job,
    String migrationId,
  ) async {
    final repository = job.session.repository;
    job.migrationId = migrationId;
    final snapshot = await _local(
      () => repository.readMigrationSnapshot(migrationId),
    );
    final payload = await _local(
      () => repository.readMigrationCreatePayload(migrationId),
    );
    if (payload == null) {
      throw StateError(currentL10n.migrationPreparationHasntSavedTheVault);
    }
    return _continue(job, snapshot, payload);
  }

  Future<LocalImportResult> _continue(
    _ImportJob job,
    LocalMigrationSnapshot snapshot,
    String createPayload,
  ) async {
    final repository = job.session.repository;
    if (snapshot.targetInstanceId != job.instanceId ||
        snapshot.targetInstanceId != destination.instanceId) {
      throw StateError(currentL10n.theMigrationDestinationBelongsToA);
    }
    final vaultId = snapshot.targetVaultId;
    final total = snapshot.items.length;
    job.targetVaultId = vaultId;
    _progress(job, LocalImportPhase.preparing, total: total);

    await _remote(
      job,
      () => destination.createOrResumeVault(
        vaultId: vaultId,
        payloadJson: createPayload,
      ),
    );
    // From here on the target Vault is the open one; opening another Vault
    // pauses the import (see [_scopeLoss]).
    job.vaultSelected = true;
    _ensureCurrent(job);
    try {
      await _remote(job, () => destination.synchronizeTarget(vaultId));
    } on _Paused {
      rethrow;
    } on DatabaseRecoveryRequiredException {
      rethrow;
    } on Object {
      // Staging does not need it; the upload rounds below sync again and
      // only a successful sync can confirm the import.
    }

    final staged = await _local(
      () => repository.listStagedMigrationItems(snapshot.migrationId),
    );
    final stagedById = {for (final item in staged) item.recordId: item};
    if (stagedById.length != staged.length ||
        staged.length > snapshot.items.length) {
      throw StateError(currentL10n.theMigrationJournalContainsDuplicateOr);
    }
    final sourceById = {for (final item in snapshot.items) item.recordId: item};
    for (final item in staged) {
      final source = sourceById[item.recordId];
      if (source == null ||
          source.sourceRevisionId != item.sourceRevisionId ||
          source.recordType != item.recordType) {
        throw StateError(currentL10n.theMigrationJournalDoesntMatchThe);
      }
    }
    await _verifyTarget(job, snapshot, stagedById);

    // Stable dependency order keeps referential records available as early
    // as possible when another approved device observes the target.
    final ordered = [...snapshot.items]
      ..sort((left, right) {
        final byKind = _migrationKindOrder(left.recordType)
            .compareTo(_migrationKindOrder(right.recordType));
        return byKind != 0 ? byKind : left.recordId.compareTo(right.recordId);
      });
    _progress(
      job,
      LocalImportPhase.encrypting,
      done: stagedById.length,
      total: total,
    );
    for (final source in ordered) {
      var stagedItem = stagedById[source.recordId];
      if (stagedItem == null) {
        final envelope = await _remote(
          job,
          () => destination.encryptRecord(
            targetVaultId: vaultId,
            recordId: source.recordId,
            plaintext: Map<String, Object?>.from(source.plaintext),
          ),
        );
        final envelopeJson = canonicalJson(envelope);
        stagedItem = await _local<LocalMigrationStagedItem>(
          () => repository.stageMigrationItem(
            migrationId: snapshot.migrationId,
            recordId: source.recordId,
            sourceRevisionId: source.sourceRevisionId,
            recordType: source.recordType,
            targetEnvelopeJson: envelopeJson,
          ),
        );
        stagedById[source.recordId] = stagedItem;
      }
      final envelope = _decodeEnvelope(stagedItem.targetEnvelopeJson);
      await _remote(
        job,
        () => destination.enqueueEnvelope(
          targetVaultId: vaultId,
          envelope: envelope,
        ),
      );
      _progress(
        job,
        LocalImportPhase.encrypting,
        done: stagedById.length,
        total: total,
      );
    }

    await _awaitCommits(job, snapshot, stagedById, ordered);

    _progress(job, LocalImportPhase.verifying, done: total, total: total);
    await _verifyTarget(job, snapshot, stagedById, requireAllCommitted: true);
    await _local(() => repository.finishMigration(snapshot.migrationId));
    return _completed(job, total);
  }

  /// Synchronizes the target Vault until the server confirmed every staged
  /// record, re-queueing any staged record that is neither cached nor queued.
  /// Each round checks the exact staged state; a round without a new
  /// confirmation doubles the wait up to [LocalImportRetry.maxDelay].
  Future<void> _awaitCommits(
    _ImportJob job,
    LocalMigrationSnapshot snapshot,
    Map<String, LocalMigrationStagedItem> stagedById,
    List<LocalMigrationSourceItem> ordered,
  ) async {
    final vaultId = snapshot.targetVaultId;
    final total = ordered.length;
    var delay = retry.firstDelay;
    var best = -1;
    var idleRounds = 0;
    _progress(job, LocalImportPhase.uploading, total: total);
    while (true) {
      Object? syncError;
      try {
        await _remote(job, () => destination.synchronizeTarget(vaultId));
      } on _Paused {
        rethrow;
      } on DatabaseRecoveryRequiredException {
        rethrow;
      } on Object catch (error) {
        syncError = error;
      }

      final state = await _remote(
        job,
        () => destination.readTargetState(
          vaultId: vaultId,
          instanceId: snapshot.targetInstanceId,
        ),
      );
      validateLocalMigrationTargetState(
        cached: state.cached,
        pending: state.pending,
        stagedById: stagedById,
      );
      final committed = <String>{};
      final present = <String>{};
      for (final row in state.cached) {
        if (!stagedById.containsKey(row.recordId)) continue;
        present.add(row.recordId);
        if (row.commitSeq != null && !row.isDeleted) {
          committed.add(row.recordId);
        }
      }
      for (final operation in state.pending) {
        if (stagedById.containsKey(operation.recordId)) {
          present.add(operation.recordId);
        }
      }
      for (final source in ordered) {
        if (present.contains(source.recordId)) continue;
        final staged = stagedById[source.recordId];
        if (staged == null) {
          throw StateError(currentL10n.migrationCiphertextStagingIsIncomplete);
        }
        await _remote(
          job,
          () => destination.enqueueEnvelope(
            targetVaultId: vaultId,
            envelope: _decodeEnvelope(staged.targetEnvelopeJson),
          ),
        );
      }
      _progress(
        job,
        LocalImportPhase.uploading,
        done: committed.length,
        total: total,
        waitingForServer: idleRounds >= 2,
      );

      if (syncError == null && committed.length == total) {
        // As before the background import: an exact replay of every staged
        // create must report it committed after a fresh server pull.
        var allCommitted = true;
        for (final source in ordered) {
          final staged = stagedById[source.recordId];
          if (staged == null) {
            throw StateError(
              currentL10n.migrationCiphertextStagingIsIncomplete,
            );
          }
          final result = await _remote(
            job,
            () => destination.enqueueEnvelope(
              targetVaultId: vaultId,
              envelope: _decodeEnvelope(staged.targetEnvelopeJson),
            ),
          );
          if (result != ExactCreateOperationResult.committed) {
            allCommitted = false;
          }
        }
        if (allCommitted) return;
      }

      if (committed.length > best) {
        best = committed.length;
        idleRounds = 0;
        delay = retry.firstDelay;
      } else {
        idleRounds++;
        final doubled = delay * 2;
        delay = doubled > retry.maxDelay ? retry.maxDelay : doubled;
      }
      if (idleRounds >= retry.giveUpAfterIdleRounds) {
        throw StateError(
          syncError == null
              ? currentL10n.theServerHasntConfirmedAllMigration
              : _reason(syncError),
        );
      }
      _progress(
        job,
        LocalImportPhase.uploading,
        done: committed.length,
        total: total,
        waitingForServer: idleRounds >= 2,
      );
      await _sleep(job, idleRounds == 0 ? retry.firstDelay : delay);
    }
  }

  Future<void> _verifyTarget(
    _ImportJob job,
    LocalMigrationSnapshot snapshot,
    Map<String, LocalMigrationStagedItem> stagedById, {
    bool requireAllCommitted = false,
  }) async {
    if (destination.preferenceError != null) {
      throw StateError(currentL10n.theDestinationVaultsSyncPreferencesConflict);
    }
    if (destination.instanceId != snapshot.targetInstanceId) {
      throw StateError(currentL10n.theMigrationDestinationBelongsToA);
    }
    final state = await _remote(
      job,
      () => destination.readTargetState(
        vaultId: snapshot.targetVaultId,
        instanceId: snapshot.targetInstanceId,
      ),
    );
    validateLocalMigrationTargetState(
      cached: state.cached,
      pending: state.pending,
      stagedById: stagedById,
      requireAllCommitted: requireAllCommitted,
    );
  }

  Map<String, Object?> _decodeEnvelope(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw FormatException(currentL10n.theStagedDestinationCiphertextHasAn);
    }
    return Map<String, Object?>.from(decoded);
  }

  static int _migrationKindOrder(String kind) => switch (kind) {
    'credential' => 0,
    'group' => 1,
    'snippet' => 2,
    'preference' => 3,
    'host' => 4,
    _ => 99,
  };
}

/// An unlocked local profile with its open LocalVault.
class _ProfileSession {
  _ProfileSession({
    required this.profile,
    required this.database,
    required this.repository,
  });

  final UnlockedLocalProfile profile;
  final LocalVaultDatabase database;
  final LocalHostRepository repository;
  Future<void>? _closing;

  String get profileId => profile.record.profileId;

  /// Locks the profile and closes its database; repeated calls are safe.
  Future<void> close() => _closing ??= closeParts(profile, database);

  static Future<void> closeParts(
    UnlockedLocalProfile profile,
    LocalVaultDatabase? database,
  ) async {
    try {
      await profile.lock();
    } on Object {
      // Closing the database below still ends this session.
    }
    if (database != null) {
      try {
        await database.close();
      } on Object {
        // The browser may already have disposed the storage delegate.
      }
    }
  }
}

class _ImportJob {
  _ImportJob({
    required this.session,
    required this.scope,
    required this.instanceId,
    required this.automatic,
  }) : progress = LocalImportProgress(
         profileId: session.profileId,
         phase: LocalImportPhase.preparing,
       );

  final _ProfileSession session;
  final Object scope;
  final String instanceId;
  final bool automatic;
  final done = Completer<void>();
  LocalImportProgress progress;
  String? migrationId;
  String? targetVaultId;
  bool vaultSelected = false;
  bool vaultSwitched = false;
  String? stopReason;
  Completer<void>? sleeper;

  String get profileId => session.profileId;

  void stop(String reason) {
    stopReason ??= reason;
    final waker = sleeper;
    if (waker != null && !waker.isCompleted) waker.complete();
  }
}

class _Paused implements Exception {
  const _Paused(this.reason);
  final String reason;
}

class _PasswordRejected implements Exception {
  const _PasswordRejected();
}
