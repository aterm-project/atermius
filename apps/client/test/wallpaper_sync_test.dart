import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/crypto/host_attachment_crypto.dart';
import 'package:aterm_client/domain/vault_wallpaper.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/wallpaper_store.dart';
import 'package:aterm_client/sync/wallpaper_sync.dart';
import 'package:aterm_client/ui/wallpaper.dart';
import 'package:aterm_client/ui/wallpaper_settings.dart';
import 'package:cryptography/cryptography.dart' as cryptography;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _vault = '11111111-1111-4111-8111-111111111111';

Future<Uint8List> _png(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  canvas.drawRect(rect, Paint()..color = color);
  canvas.drawCircle(rect.center, height / 3, Paint()..color = Colors.white);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<String> _sha(List<int> bytes) async => (await cryptography.Sha256()
    .hash(bytes))
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

final _random = math.Random(7);
HostAttachmentCrypto _crypto() => HostAttachmentCrypto(
  randomBytes: (count) =>
      Uint8List.fromList(List.generate(count, (_) => _random.nextInt(256))),
);

/// One account's Vault on a fake server: completed ciphertext objects and
/// the stored preference records, shared by every device of the account.
class _Server {
  final Map<String, Uint8List> objects = {};
  final Map<String, ({int size, String sha, List<Uint8List> chunks})>
  uploads = {};
  final List<VaultWallpaperRecord> records = [];
  final List<_Account> devices = [];
  int saves = 0;
  int uploadedObjects = 0;
  int downloads = 0;

  void publish() {
    for (final device in devices) {
      device.changed();
    }
  }
}

class _Api extends ApiClient {
  _Api(this.server) : super(baseUrl: 'https://wallpaper.test');
  final _Server server;

  @override
  Future<Map<String, dynamic>> initUpload(
    String vaultId,
    Map<String, Object?> body,
  ) async {
    expect(vaultId, _vault);
    final id = body['object_id']! as String;
    if (server.objects.containsKey(id)) {
      throw const ApiException(
        statusCode: 409,
        code: 'OBJECT_EXISTS',
        message: 'exists',
      );
    }
    server.uploads['up-$id'] = (
      size: body['size']! as int,
      sha: body['sha256']! as String,
      chunks: [],
    );
    return {'upload_id': 'up-$id', 'chunk_size': 1024 * 1024};
  }

  @override
  Future<Map<String, dynamic>> uploadChunk({
    required String uploadId,
    required int index,
    required List<int> bytes,
    required String sha256,
  }) async {
    final upload = server.uploads[uploadId]!;
    expect(index, upload.chunks.length);
    expect(await _sha(bytes), sha256);
    upload.chunks.add(Uint8List.fromList(bytes));
    return {};
  }

  @override
  Future<Map<String, dynamic>> completeUpload(
    String uploadId,
    Map<String, Object?> body,
  ) async {
    final upload = server.uploads.remove(uploadId)!;
    final bytes = Uint8List.fromList([for (final c in upload.chunks) ...c]);
    expect(bytes.length, upload.size);
    expect(await _sha(bytes), upload.sha);
    final id = uploadId.substring(3);
    server.objects[id] = bytes;
    server.uploadedObjects++;
    return {'object_id': id, 'size': bytes.length, 'sha256': upload.sha};
  }

  @override
  Future<DownloadedVaultObject> downloadObjectWithDigest(
    String vaultId,
    String objectId,
  ) async {
    final bytes = server.objects[objectId];
    if (bytes == null) {
      throw const ApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'missing',
      );
    }
    server.downloads++;
    return DownloadedVaultObject(
      bytes: Uint8List.fromList(bytes),
      sha256: await _sha(bytes),
    );
  }
}

class _Account extends ChangeNotifier implements WallpaperAccount {
  _Account(this.server) : api = _Api(server) {
    server.devices.add(this);
  }

  final _Server server;
  WallpaperSyncAvailability availability = WallpaperSyncAvailability.available;

  @override
  final ApiClient api;

  void changed() => notifyListeners();

  @override
  WallpaperSyncAvailability get wallpaperSyncAvailability => availability;

  @override
  String? get wallpaperSyncVaultId =>
      availability == WallpaperSyncAvailability.available ? _vault : null;

  @override
  VaultWallpaperRecord? get accountWallpaperRecord =>
      server.records.firstOrNull;

  @override
  HostAttachmentCrypto wallpaperImageCrypto() => _crypto();

  @override
  Future<void> saveAccountWallpaper(
    VaultWallpaperValue value, {
    required String vaultId,
  }) async {
    expect(vaultId, _vault);
    final existing = accountWallpaperRecord;
    final record = VaultWallpaperRecord.create(value: value, id: existing?.id);
    final plaintext = record.toJson();
    // The server only accepts references to completed objects.
    final refs =
        ((plaintext['_manifest'] as Map?)?['object_refs'] as List?) ?? [];
    for (final ref in refs) {
      expect(server.objects, contains(ref));
    }
    // Round-trip like a decrypted record row.
    final stored = VaultWallpaperRecord.fromJson({
      ...jsonDecode(jsonEncode(plaintext)) as Map<String, dynamic>,
      '_record_id': record.id,
      '_revision_id': '22222222-2222-4222-8222-${server.saves.toString().padLeft(12, '0')}',
    });
    server.saves++;
    server.records
      ..removeWhere((r) => r.id == record.id)
      ..add(stored);
    server.publish();
  }
}

class _Device {
  _Device(_Server server)
    : account = _Account(server),
      store = MemoryWallpaperStore(),
      wallpaper = WallpaperController();

  final _Account account;
  final MemoryWallpaperStore store;
  final WallpaperController wallpaper;
  late final WallpaperSyncCoordinator sync = WallpaperSyncCoordinator(
    account: account,
    wallpaper: wallpaper,
    debounce: const Duration(hours: 1),
    retryDelay: const Duration(hours: 1),
  );

  Future<void> start() async {
    await wallpaper.load(store);
    sync.start();
  }

  Future<void> settle() async {
    await sync.runNow();
    await wallpaper.debugIdle;
  }

  void dispose() {
    sync.dispose();
    wallpaper.dispose();
  }
}

void main() {
  group('VaultWallpaperValue', () {
    Future<Map<String, Object?>> manifest({
      String fileName = vaultWallpaperFileName,
      String mediaType = 'image/png',
    }) async {
      final encrypted = await _crypto().encrypt(
        fileName: fileName,
        mediaType: mediaType,
        bytes: List.filled(10, 1),
      );
      return encrypted.manifestEntry;
    }

    test('round-trips and lists sorted object ids', () async {
      final image = await manifest();
      final value = VaultWallpaperValue(
        updatedAtMs: 1234,
        mode: 'panes',
        blur: 6.5,
        overlay: .4,
        image: image,
      );
      final parsed = VaultWallpaperValue.parse(value.encode());
      expect(parsed.updatedAtMs, 1234);
      expect(parsed.mode, 'panes');
      expect(parsed.blur, 6.5);
      expect(parsed.overlay, .4);
      expect(parsed.blobId, image['blob_id']);
      expect(parsed.objectIds, hasLength(1));
      expect(parsed.imageManifest, image);
      final bare = VaultWallpaperValue.parse(
        VaultWallpaperValue(
          updatedAtMs: 1,
          mode: 'window',
          blur: 0,
          overlay: null,
          image: null,
        ).encode(),
      );
      expect(bare.hasImage, isFalse);
      expect(bare.objectIds, isEmpty);
      expect(bare.overlay, isNull);
    });

    test('rejects unknown fields, bad values and foreign manifests', () async {
      void rejects(Map<String, Object?> json) => expect(
        () => VaultWallpaperValue.parse(jsonEncode(json)),
        throwsFormatException,
      );
      const base = {'v': 1, 'updated_at': 1, 'mode': 'window', 'blur': 8};
      VaultWallpaperValue.parse(jsonEncode(base));
      rejects({...base, 'v': 2});
      rejects({...base, 'path': '/home/me/a.png'});
      rejects({...base, 'mode': 'tile'});
      rejects({...base, 'blur': 99});
      rejects({...base, 'overlay': 2});
      rejects({...base, 'updated_at': -1});
      rejects({...base, 'image': await manifest(fileName: 'holiday.png')});
      rejects({...base, 'image': await manifest(mediaType: 'text/plain')});
      expect(
        () => VaultWallpaperValue.parse('x' * (vaultWallpaperMaxValueLength + 1)),
        throwsFormatException,
      );
    });

    test('the record references exactly its image objects', () async {
      final image = await manifest();
      final value = VaultWallpaperValue(
        updatedAtMs: 5,
        mode: 'window',
        blur: 8,
        overlay: null,
        image: image,
      );
      final record = VaultWallpaperRecord.create(value: value);
      final json = record.toJson();
      expect(json['type'], 'wallpaper');
      expect(json['mode'], 'window');
      expect(json['_manifest'], {'object_refs': value.objectIds});
      final parsed = VaultWallpaperRecord.fromJson(
        Map<String, dynamic>.from(json),
      );
      expect(parsed.id, record.id);
      expect(parsed.value.blobId, value.blobId);
      expect(
        () => VaultWallpaperRecord.fromJson({
          ...json,
          '_manifest': {'object_refs': <String>[]},
        }),
        throwsFormatException,
      );
      expect(
        () => VaultWallpaperRecord.fromJson({...json, 'path': '/tmp/a.png'}),
        throwsFormatException,
      );
      expect(
        () => VaultWallpaperRecord.fromJson({...json, 'type': 'preference'}),
        throwsFormatException,
      );
      // Without an image the record has no object refs at all.
      final bare = VaultWallpaperRecord.create(
        value: VaultWallpaperValue(
          updatedAtMs: 5,
          mode: 'window',
          blur: 8,
          overlay: null,
          image: null,
        ),
      );
      expect(bare.toJson().containsKey('_manifest'), isFalse);
    });
  });

  group('device wallpaper settings', () {
    test('keep the change time, synced image and sync choice', () {
      const prefs = WallpaperPreferences(
        imageId: '0123456789abcdef0123456789abcdef',
        updatedAtMs: 42,
        syncedBlobId: '33333333-3333-4333-8333-333333333333',
        syncEnabled: false,
      );
      final parsed = WallpaperPreferences.parse(prefs.encode());
      expect(parsed.updatedAtMs, 42);
      expect(parsed.syncedBlobId, prefs.syncedBlobId);
      expect(parsed.syncEnabled, isFalse);
      expect(prefs.encode().length, lessThan(wallpaperSettingsMaxLength));
      // Records written before account sync: defaults.
      final legacy = WallpaperPreferences.parse(
        '{"v":1,"mode":"window","blur":8.0}',
      );
      expect(legacy.updatedAtMs, 0);
      expect(legacy.syncedBlobId, isNull);
      expect(legacy.syncEnabled, isTrue);
      expect(
        WallpaperPreferences.parse('{"v":1,"remote":"../../etc"}').syncedBlobId,
        isNull,
      );
    });

    test('only user changes advance the local change revision', () async {
      final store = MemoryWallpaperStore();
      final controller = WallpaperController();
      await controller.load(store);
      expect(controller.updatedAtMs, 0);
      controller.setBlur(4);
      await controller.debugIdle;
      final changed = controller.updatedAtMs;
      expect(changed, greaterThan(0));
      expect(controller.localChangeRevision, 1);
      // The same value again is not a change.
      controller.setBlur(4);
      await controller.debugIdle;
      expect(controller.localChangeRevision, 1);
      controller.applyAccountSettings(
        const WallpaperAccountState(
          updatedAtMs: 99999999999999,
          mode: WallpaperLayoutMode.panes,
          blur: 2,
          overlay: .5,
          blobId: null,
        ),
      );
      await controller.debugIdle;
      expect(controller.localChangeRevision, 1);
      expect(controller.mode, WallpaperLayoutMode.panes);
      expect(controller.updatedAtMs, 99999999999999);
      final saved = WallpaperPreferences.parse(store.settings);
      expect(saved.overlay, .5);
      expect(saved.updatedAtMs, 99999999999999);
      controller.dispose();
    });
  });

  group('WallpaperSyncCoordinator', () {
    late _Server server;
    late _Device a;
    late _Device b;

    setUp(() async {
      server = _Server();
      a = _Device(server);
      b = _Device(server);
    });

    tearDown(() {
      a.dispose();
      b.dispose();
    });

    test('an image chosen on one device appears on the other', () async {
      await a.start();
      await b.start();
      final png = await _png(96, 64, Colors.indigo);
      expect(await a.wallpaper.setImageBytes(png), isNull);
      a.wallpaper.setMode(WallpaperLayoutMode.panes);
      await a.settle();

      expect(a.sync.state, WallpaperSyncState.synced);
      expect(server.saves, 1);
      expect(server.uploadedObjects, 1);
      final record = server.records.single;
      expect(record.value.mode, 'panes');
      expect(a.wallpaper.syncedBlobId, record.value.blobId);
      // The server holds ciphertext only.
      final object = server.objects.values.single;
      expect(object, isNot(png));
      expect(
        String.fromCharCodes(object).contains('PNG'),
        isFalse,
      );

      await b.settle();
      expect(b.sync.state, WallpaperSyncState.synced);
      expect(b.wallpaper.active, isTrue);
      expect(b.wallpaper.mode, WallpaperLayoutMode.panes);
      expect(b.wallpaper.updatedAtMs, a.wallpaper.updatedAtMs);
      expect(b.wallpaper.syncedBlobId, record.value.blobId);
      expect(b.store.images.values.single, png);
      // Applying is not a local change: nothing is published back.
      await b.settle();
      expect(server.saves, 1);
    });

    test('layout changes sync without uploading the image again', () async {
      await a.start();
      await b.start();
      expect(await a.wallpaper.setImageBytes(await _png(40, 40, Colors.red)),
          isNull);
      await a.settle();
      await b.settle();
      final downloads = server.downloads;

      b.wallpaper.setBlur(3);
      b.wallpaper.setOverlay(.3);
      await b.settle();
      expect(server.uploadedObjects, 1);
      expect(server.records.single.value.blur, 3);
      expect(server.records.single.value.overlay, .3);

      await a.settle();
      expect(a.wallpaper.blur, 3);
      expect(a.wallpaper.overlay, .3);
      expect(server.downloads, downloads); // same image: not downloaded
    });

    test('removing the wallpaper removes it everywhere', () async {
      await a.start();
      await b.start();
      expect(await a.wallpaper.setImageBytes(await _png(40, 40, Colors.red)),
          isNull);
      await a.settle();
      await b.settle();
      expect(b.wallpaper.hasImage, isTrue);

      await b.wallpaper.reset();
      await b.settle();
      expect(server.records.single.value.hasImage, isFalse);
      await a.settle();
      expect(a.wallpaper.hasImage, isFalse);
      expect(a.store.images, isEmpty);
    });

    test('the newer change wins over an older account value', () async {
      await a.start();
      await b.start();
      expect(await a.wallpaper.setImageBytes(await _png(40, 40, Colors.red)),
          isNull);
      await a.settle();
      // B changed something later, before it saw A's value.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      b.wallpaper.setBlur(1);
      await b.settle();
      expect(server.records.single.value.blur, 1);
      expect(server.records.single.value.hasImage, isFalse);
      await a.settle();
      expect(a.wallpaper.hasImage, isFalse);
      expect(a.wallpaper.blur, 1);
    });

    test('a wallpaper from before account sync is published once', () async {
      final png = await _png(30, 30, Colors.green);
      a.store.images['0123456789abcdef0123456789abcdef'] = png;
      a.store.settings =
          '{"v":1,"image":"0123456789abcdef0123456789abcdef","mode":"window","blur":8.0}';
      await a.start();
      await a.wallpaper.debugRestoring;
      await a.settle();
      expect(server.saves, 1);
      expect(a.wallpaper.updatedAtMs, greaterThan(0));
      // A second device with no wallpaper takes it.
      await b.start();
      await b.settle();
      expect(b.store.images.values.single, png);
    });

    test('nothing is published from an empty device', () async {
      await a.start();
      await a.settle();
      expect(server.saves, 0);
      expect(a.sync.state, WallpaperSyncState.synced);
    });

    test('shared Vaults and the off switch keep everything local', () async {
      a.account.availability = WallpaperSyncAvailability.sharedVault;
      await a.start();
      expect(await a.wallpaper.setImageBytes(await _png(20, 20, Colors.red)),
          isNull);
      await a.settle();
      expect(a.sync.state, WallpaperSyncState.unavailable);
      expect(server.saves, 0);
      expect(server.uploadedObjects, 0);

      a.account.availability = WallpaperSyncAvailability.available;
      a.wallpaper.setSyncEnabled(false);
      await a.settle();
      expect(a.sync.state, WallpaperSyncState.off);
      expect(server.saves, 0);

      a.wallpaper.setSyncEnabled(true);
      await a.settle();
      expect(server.saves, 1);
      expect(a.sync.state, WallpaperSyncState.synced);
    });

    test('a missing image object fails and keeps the local wallpaper', () async {
      await a.start();
      await b.start();
      expect(await b.wallpaper.setImageBytes(await _png(20, 20, Colors.blue)),
          isNull);
      // Keep B's own (older) wallpaper out of the way.
      b.wallpaper.setSyncEnabled(false);
      await b.settle();
      expect(await a.wallpaper.setImageBytes(await _png(20, 20, Colors.red)),
          isNull);
      await a.settle();
      server.objects.clear();
      b.wallpaper.setSyncEnabled(true);
      await b.settle();
      expect(b.sync.state, WallpaperSyncState.failed);
      expect(b.wallpaper.hasImage, isTrue);
      expect(b.wallpaper.syncedBlobId, isNull);
    });

    testWidgets('settings show the switch and the sync status', (
      tester,
    ) async {
      final controller = WallpaperController();
      final sync = WallpaperSyncCoordinator(
        account: _Account(_Server())
          ..availability = WallpaperSyncAvailability.sharedVault,
        wallpaper: controller,
        debounce: const Duration(hours: 1),
      );
      WallpaperSyncCoordinator.current.value = sync;
      addTearDown(() {
        WallpaperSyncCoordinator.current.value = null;
        sync.dispose();
        controller.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: WallpaperSettings(controller: controller),
            ),
          ),
        ),
      );
      await tester.runAsync(sync.runNow);
      await tester.pump();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(WallpaperSettings)),
      );
      expect(find.byKey(const ValueKey('wallpaper_sync_switch')), findsOne);
      expect(find.text(l10n.wallpaperSyncSharedVault), findsOne);
      await tester.ensureVisible(
        find.byKey(const ValueKey('wallpaper_sync_switch')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('wallpaper_sync_switch')));
      await tester.pump();
      expect(controller.syncEnabled, isFalse);
      expect(find.text(l10n.wallpaperSyncOff), findsOne);
    });

    testWidgets('settings hide the sync row without an account', (
      tester,
    ) async {
      final controller = WallpaperController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: WallpaperSettings(controller: controller),
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('wallpaper_sync_switch')), findsNothing);
    });
  });
}
