import 'dart:async';

import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../app_controller.dart';
import '../crypto/host_attachment_crypto.dart';
import '../domain/vault_wallpaper.dart';
import '../ui/wallpaper.dart';

/// What the account wallpaper sync is doing (shown in wallpaper settings).
enum WallpaperSyncState {
  /// Turned off on this device.
  off,

  /// No account Vault for it right now; see [WallpaperSyncCoordinator.availability].
  unavailable,

  /// This device and the account agree.
  synced,
  uploading,
  downloading,

  /// The last attempt failed; it is retried automatically.
  failed,
}

/// The account side of [WallpaperSyncCoordinator]; [AppController] in the
/// app, a fake in tests.
abstract interface class WallpaperAccount implements Listenable {
  WallpaperSyncAvailability get wallpaperSyncAvailability;
  String? get wallpaperSyncVaultId;
  VaultWallpaperRecord? get accountWallpaperRecord;
  ApiClient? get api;
  HostAttachmentCrypto wallpaperImageCrypto();
  Future<void> saveAccountWallpaper(
    VaultWallpaperValue value, {
    required String vaultId,
  });
}

/// [AppController] as the account of the wallpaper sync.
class AppWallpaperAccount implements WallpaperAccount {
  AppWallpaperAccount(this.app);

  final AppController app;

  @override
  void addListener(VoidCallback listener) => app.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => app.removeListener(listener);

  @override
  WallpaperSyncAvailability get wallpaperSyncAvailability =>
      app.wallpaperSyncAvailability;

  @override
  String? get wallpaperSyncVaultId => app.wallpaperSyncVaultId;

  @override
  VaultWallpaperRecord? get accountWallpaperRecord =>
      app.accountWallpaperRecord;

  @override
  ApiClient? get api => app.api;

  @override
  HostAttachmentCrypto wallpaperImageCrypto() => app.wallpaperImageCrypto();

  @override
  Future<void> saveAccountWallpaper(
    VaultWallpaperValue value, {
    required String vaultId,
  }) => app.saveAccountWallpaper(value, vaultId: vaultId);
}

/// Keeps the device wallpaper and the account wallpaper of the same user in
/// step.
///
/// Storage: the account wallpaper is an encrypted Vault record of type
/// `wallpaper` ([VaultWallpaperRecord]), kept only in a Vault whose sole
/// member is this account (so it never reaches another person). The image is
/// encrypted on the device
/// with a random key as an attachment (`atermius-host-attachment-v1`, 4 MiB
/// AES-GCM chunks) and uploaded to that Vault's object store; the record
/// carries the layout values, the image manifest with its key and the object
/// references. The server stores ciphertext only. Every device keeps its own
/// decrypted copy in the device-local wallpaper store, so startup and
/// credential-free child windows never need the account.
///
/// Conflicts: each change carries the time it was made; the newer of the
/// device and account values wins.
class WallpaperSyncCoordinator extends ChangeNotifier {
  WallpaperSyncCoordinator({
    required this.account,
    required this.wallpaper,
    this.debounce = const Duration(milliseconds: 600),
    this.retryDelay = const Duration(minutes: 1),
  });

  final WallpaperAccount account;
  final WallpaperController wallpaper;
  final Duration debounce;
  final Duration retryDelay;

  static final ValueNotifier<WallpaperSyncCoordinator?> current =
      ValueNotifier<WallpaperSyncCoordinator?>(null);

  /// Starts syncing [app] with the process wallpaper (main window only).
  static void bind(AppController app) {
    final existing = current.value;
    if (existing != null &&
        existing.account is AppWallpaperAccount &&
        identical((existing.account as AppWallpaperAccount).app, app)) {
      return;
    }
    unbind();
    current.value = WallpaperSyncCoordinator(
      account: AppWallpaperAccount(app),
      wallpaper: WallpaperController.instance,
    )..start();
  }

  /// Stops the running sync (for [app] only, when given).
  static void unbind([AppController? app]) {
    final existing = current.value;
    if (existing == null) return;
    if (app != null &&
        !(existing.account is AppWallpaperAccount &&
            identical((existing.account as AppWallpaperAccount).app, app))) {
      return;
    }
    current.value = null;
    existing.dispose();
  }

  WallpaperSyncState _state = WallpaperSyncState.unavailable;
  WallpaperSyncState get state => _state;

  WallpaperSyncAvailability get availability =>
      account.wallpaperSyncAvailability;

  Timer? _debounceTimer;
  Timer? _retryTimer;
  int _failures = 0;
  bool _running = false;
  bool _rerun = false;
  bool _disposed = false;
  bool _started = false;
  Object? _signature;

  @visibleForTesting
  Future<void>? debugRun;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    account.addListener(_changed);
    wallpaper.addListener(_changed);
    _changed();
  }

  /// Cheap fingerprint of everything a reconcile depends on; app updates
  /// that do not touch it are ignored.
  Object _currentSignature() {
    final record = account.accountWallpaperRecord;
    return Object.hash(
      wallpaper.syncEnabled,
      account.wallpaperSyncAvailability,
      account.wallpaperSyncVaultId,
      record?.id,
      record?.revisionId,
      record?.value.updatedAtMs,
      record?.value.blobId,
      wallpaper.updatedAtMs,
      wallpaper.syncedBlobId,
      wallpaper.hasImage,
      wallpaper.busy,
    );
  }

  void _changed() {
    if (_disposed) return;
    final signature = _currentSignature();
    if (signature == _signature) return;
    _signature = signature;
    _schedule();
  }

  void _schedule([Duration? delay]) {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(delay ?? debounce, () {
      _debounceTimer = null;
      debugRun = _run();
    });
  }

  /// Reconciles now (tests; also usable after a manual sync).
  @visibleForTesting
  Future<void> runNow() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    return debugRun = _run();
  }

  Future<void> _run() async {
    if (_disposed) return;
    if (_running) {
      _rerun = true;
      return;
    }
    _running = true;
    try {
      do {
        _rerun = false;
        await _reconcile();
      } while (_rerun && !_disposed);
      _failures = 0;
      _retryTimer?.cancel();
      _retryTimer = null;
    } on Object {
      _failures++;
      _setState(WallpaperSyncState.failed);
      _retryTimer?.cancel();
      // 1, 2, 4 … up to 16 retry delays.
      final factor = 1 << (_failures - 1).clamp(0, 4);
      _retryTimer = Timer(retryDelay * factor, () {
        _retryTimer = null;
        _signature = null;
        _changed();
      });
    } finally {
      _running = false;
    }
  }

  void _setState(WallpaperSyncState next) {
    if (_disposed || next == _state) return;
    _state = next;
    notifyListeners();
  }

  Future<void> _reconcile() async {
    if (!wallpaper.syncEnabled) {
      _setState(WallpaperSyncState.off);
      return;
    }
    final vaultId = account.wallpaperSyncVaultId;
    final api = account.api;
    if (vaultId == null || api == null) {
      _setState(WallpaperSyncState.unavailable);
      return;
    }
    // Picking or storing an image: its result is the next change.
    if (wallpaper.busy) return;
    final remote = account.accountWallpaperRecord?.value;
    final local = wallpaper.updatedAtMs;
    if (remote != null && remote.updatedAtMs > local) {
      await _applyAccount(remote, vaultId, api);
    } else if (remote != null && remote.updatedAtMs == local) {
      // Already the same change (published or applied here before).
      if (remote.hasImage &&
          wallpaper.hasImage &&
          wallpaper.syncedBlobId == null) {
        wallpaper.markPublished(updatedAtMs: local, blobId: remote.blobId);
      }
    } else if (remote != null || wallpaper.hasImage || local > 0) {
      await _publish(vaultId, api, remote);
    }
    if (!_rerun) _setState(WallpaperSyncState.synced);
  }

  Future<void> _applyAccount(
    VaultWallpaperValue remote,
    String vaultId,
    ApiClient api,
  ) async {
    final state = WallpaperAccountState(
      updatedAtMs: remote.updatedAtMs,
      mode: WallpaperLayoutMode.parse(remote.mode),
      blur: remote.blur,
      overlay: remote.overlay,
      blobId: remote.blobId,
    );
    if (!remote.hasImage) {
      await wallpaper.applyAccountRemoval(state);
      return;
    }
    if (wallpaper.hasImage && wallpaper.syncedBlobId == remote.blobId) {
      wallpaper.applyAccountSettings(state);
      return;
    }
    _setState(WallpaperSyncState.downloading);
    final bytes = await account.wallpaperImageCrypto().decryptWithLoader(
      manifestEntry: remote.imageManifest!,
      loadCiphertext: (chunk) async {
        final downloaded = await api.downloadObjectWithDigest(
          vaultId,
          chunk.objectId,
        );
        if (downloaded.sha256 != chunk.sha256) {
          throw const FormatException('Wallpaper object digest mismatch');
        }
        return Uint8List.fromList(downloaded.bytes);
      },
    );
    try {
      if (_disposed) return;
      // A local change made meanwhile is newer: it is published instead.
      if (wallpaper.updatedAtMs >= remote.updatedAtMs) {
        _rerun = true;
        return;
      }
      final error = await wallpaper.applyAccountImage(bytes, state);
      if (error != null) throw StateError('Wallpaper image rejected: $error');
      if (wallpaper.updatedAtMs != remote.updatedAtMs) {
        throw StateError('Wallpaper image was not applied');
      }
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<void> _publish(
    String vaultId,
    ApiClient api,
    VaultWallpaperValue? remote,
  ) async {
    // A wallpaper saved before account sync existed has no change time.
    if (wallpaper.updatedAtMs == 0) wallpaper.stampChangeTime();
    final changeTime = wallpaper.updatedAtMs;
    Map<String, Object?>? image;
    if (wallpaper.hasImage) {
      if (remote != null &&
          remote.blobId != null &&
          wallpaper.syncedBlobId == remote.blobId) {
        image = remote.imageManifest;
      } else {
        image = await _uploadImage(vaultId, api);
        if (image == null) return;
      }
    }
    if (_disposed) return;
    if (wallpaper.updatedAtMs != changeTime) {
      _rerun = true;
      return;
    }
    if (account.wallpaperSyncVaultId != vaultId) return;
    final value = VaultWallpaperValue(
      updatedAtMs: changeTime,
      mode: wallpaper.mode.code,
      blur: wallpaper.blur,
      overlay: wallpaper.overlay,
      image: image,
    );
    await account.saveAccountWallpaper(value, vaultId: vaultId);
    wallpaper.markPublished(updatedAtMs: changeTime, blobId: value.blobId);
  }

  /// Encrypts the stored image and uploads its ciphertext objects; returns
  /// the attachment manifest entry, or null when the image changed meanwhile.
  Future<Map<String, Object?>?> _uploadImage(
    String vaultId,
    ApiClient api,
  ) async {
    final changeTime = wallpaper.updatedAtMs;
    final bytes = await wallpaper.readImageBytes();
    if (bytes == null) {
      // The image copy is gone or unreadable: never publish "no image".
      throw StateError('The wallpaper image copy is not readable');
    }
    if (wallpaper.updatedAtMs != changeTime) {
      _rerun = true;
      return null;
    }
    if (bytes.length > vaultWallpaperMaxImageBytes) {
      throw StateError('The wallpaper image is too large to sync');
    }
    final mediaType = switch (wallpaperInspectImage(bytes).format) {
      WallpaperImageFormat.png => 'image/png',
      WallpaperImageFormat.jpeg => 'image/jpeg',
      WallpaperImageFormat.webp => 'image/webp',
    };
    _setState(WallpaperSyncState.uploading);
    final encrypted = await account.wallpaperImageCrypto().encrypt(
      fileName: vaultWallpaperFileName,
      mediaType: mediaType,
      bytes: bytes,
    );
    try {
      for (final object in encrypted.objects) {
        if (_disposed) return null;
        await _uploadObject(api, vaultId, object);
      }
      return encrypted.manifestEntry;
    } finally {
      encrypted.clearCiphertext();
    }
  }

  static const _maxTransportChunkBytes = 1024 * 1024;

  Future<void> _uploadObject(
    ApiClient api,
    String vaultId,
    EncryptedAttachmentObject object,
  ) async {
    final Map<String, dynamic> initialized;
    try {
      initialized = await api.initUpload(vaultId, {
        'object_id': object.objectId,
        'size': object.bytes.length,
        'sha256': object.sha256,
      });
    } on ApiException catch (error) {
      // Object IDs are random: an existing one is this upload, completed by
      // an earlier attempt whose answer was lost.
      if (error.code == 'OBJECT_EXISTS') return;
      rethrow;
    }
    final uploadId = initialized['upload_id'];
    final chunkSize = initialized['chunk_size'];
    if (uploadId is! String ||
        uploadId.isEmpty ||
        chunkSize is! int ||
        chunkSize < 1 ||
        chunkSize > _maxTransportChunkBytes) {
      throw const FormatException('The server returned an invalid upload');
    }
    final bytes = object.bytes;
    final chunks = (bytes.length + chunkSize - 1) ~/ chunkSize;
    for (var index = 0; index < chunks; index++) {
      final start = index * chunkSize;
      final end = start + chunkSize < bytes.length
          ? start + chunkSize
          : bytes.length;
      final part = Uint8List.sublistView(bytes, start, end);
      await api.uploadChunk(
        uploadId: uploadId,
        index: index,
        bytes: part,
        sha256: await _sha256Hex(part),
      );
    }
    final completed = await api.completeUpload(uploadId, const {});
    if (completed['object_id'] != object.objectId ||
        completed['size'] != bytes.length ||
        completed['sha256'] != object.sha256) {
      throw const FormatException('The server upload receipt does not match');
    }
  }

  static Future<String> _sha256Hex(List<int> bytes) async =>
      (await cryptography.Sha256().hash(
        bytes,
      )).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _debounceTimer?.cancel();
    _retryTimer?.cancel();
    if (_started) {
      account.removeListener(_changed);
      wallpaper.removeListener(_changed);
    }
    super.dispose();
  }
}
