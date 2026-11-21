// Account wallpaper sync on the REAL AppController against the REAL server
// binary: two devices of the same account (the second enrolled by approval)
// exchange an encrypted wallpaper image and its layout values through the
// personal Vault; a team Vault pauses it.
//
// Run: ATERMIUS_TEST_SERVER_BINARY=<cargo target>/debug/atermius-server \
//      flutter test test/wallpaper_sync_real_server_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/vault_wallpaper.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/storage/wallpaper_store.dart';
import 'package:aterm_client/sync/wallpaper_sync.dart';
import 'package:aterm_client/ui/wallpaper.dart';
import 'package:drift/native.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/cloud_real_server.dart';

Future<Uint8List> _png(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  canvas.drawRect(rect, Paint()..color = color);
  canvas.drawCircle(rect.center, height / 3, Paint()..color = const Color(0xFFFFFFFF));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

class _Device {
  _Device(this.app)
    : store = MemoryWallpaperStore(),
      wallpaper = WallpaperController();

  final AppController app;
  final MemoryWallpaperStore store;
  final WallpaperController wallpaper;
  late final WallpaperSyncCoordinator sync = WallpaperSyncCoordinator(
    account: AppWallpaperAccount(app),
    wallpaper: wallpaper,
    debounce: const Duration(hours: 1),
    retryDelay: const Duration(hours: 1),
  );

  Future<void> start() async {
    await wallpaper.load(store);
    sync.start();
  }

  /// Pull, reconcile, push: what automatic sync and the coordinator do.
  Future<void> round() async {
    await app.synchronize();
    await idle(app);
    await sync.runNow();
    await wallpaper.debugIdle;
    await app.synchronize();
    await idle(app);
  }
}

void main() {
  if (realServerBinary == null || !File(realServerBinary!).existsSync()) {
    test(
      'account wallpaper sync on a real server',
      () {},
      skip: 'set ATERMIUS_TEST_SERVER_BINARY to the built atermius-server',
    );
    return;
  }
  const username = 'owner@example.test';
  late SodiumSumo sodium;
  late TestServer server;
  late Party owner;
  late _Device a;
  late _Device b;
  late String personalVaultId;

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    sodium = await SodiumSumoInit.init();
    server = await TestServer.start();
    owner = await party(
      sodium,
      server.baseUrl,
      username: username,
      bootstrap: server.bootstrapToken(),
    );
    personalVaultId = owner.app.activeVault!.id;

    // A second device of the same account, enrolled by the first one.
    final second = AppController(
      sodium: sodium,
      database: ClientDatabase.forTesting(NativeDatabase.memory()),
      secureStore: ClientSecureStore(const PrefixedStorage('second.')),
      apiClientFactoryForTesting: (baseUrl) =>
          ApiClient(baseUrl: baseUrl, client: RecordingClient()),
    );
    await second.configureServer(server.baseUrl);
    final request = await second.createDeviceEnrollmentRequest(
      username: username,
      name: 'Second device',
    );
    final approval = await owner.app.approveDeviceEnrollment(request);
    await second.importDeviceApproval(approval);
    await second.login(username: username, password: realServerPassword);
    await idle(second);
    expect(second.account?.accountId, owner.app.account?.accountId);
    expect(second.activeVault?.id, personalVaultId);

    a = _Device(owner.app);
    b = _Device(second);
    await a.start();
    await b.start();
  });

  tearDownAll(() async {
    a.sync.dispose();
    b.sync.dispose();
    await server.stop();
  });

  test('the personal Vault of a single owner carries the wallpaper', () {
    expect(
      a.app.wallpaperSyncAvailability,
      WallpaperSyncAvailability.available,
    );
    expect(
      b.app.wallpaperSyncAvailability,
      WallpaperSyncAvailability.available,
    );
  });

  test('an image chosen on one device reaches the other, encrypted', () async {
    final png = await _png(120, 80, const Color(0xFF3949AB));
    expect(await a.wallpaper.setImageBytes(png), isNull);
    a.wallpaper.setMode(WallpaperLayoutMode.panes);
    a.wallpaper.setOverlay(.4);
    await a.round();
    expect(a.sync.state, WallpaperSyncState.synced);
    final record = a.app.accountWallpaperRecord!;
    expect(record.value.hasImage, isTrue);
    expect(a.app.pendingCount, 0, reason: 'the record was pushed');

    // What the server stores is ciphertext.
    final objectId = record.value.objectIds.single;
    final stored = await a.app.api!.downloadObject(personalVaultId, objectId);
    expect(stored, isNot(png));
    expect(stored.length, png.length + 16);

    await b.round();
    expect(b.sync.state, WallpaperSyncState.synced);
    expect(b.app.accountWallpaperRecord?.id, record.id);
    expect(b.wallpaper.active, isTrue);
    expect(b.wallpaper.mode, WallpaperLayoutMode.panes);
    expect(b.wallpaper.overlay, .4);
    expect(b.store.images.values.single, png);
    expect(b.wallpaper.syncedBlobId, record.value.blobId);
  });

  test('a layout change on the second device comes back without a new upload', () async {
    final objects = a.app.accountWallpaperRecord!.value.objectIds;
    b.wallpaper.setBlur(2);
    await b.round();
    expect(b.app.accountWallpaperRecord!.value.blur, 2);
    expect(b.app.accountWallpaperRecord!.value.objectIds, objects);
    await a.round();
    expect(a.wallpaper.blur, 2);
    expect(a.wallpaper.mode, WallpaperLayoutMode.panes);
    expect(a.wallpaper.active, isTrue);
  });

  test('removing the wallpaper removes it on the other device', () async {
    await a.wallpaper.reset();
    await a.round();
    expect(a.app.accountWallpaperRecord!.value.hasImage, isFalse);
    await b.round();
    expect(b.wallpaper.hasImage, isFalse);
    expect(b.store.images, isEmpty);
  });

  test('inviting someone into the Vault pauses wallpaper sync', () async {
    const friendName = 'friend@example.test';
    final friend = await party(
      sodium,
      server.baseUrl,
      username: friendName,
      invitation: server.accountInvitation(friendName),
      storagePrefix: 'friend.',
    );
    final saves = a.app.accountWallpaperRecord!.revisionId;
    final recipient = owner.app.verifyVaultShareRequest(
      friend.app.exportVaultShareRequest(),
    );
    final invitation = await owner.app.createVaultInvitation(
      recipient: recipient,
      role: 'viewer',
    );
    await idle(owner.app);
    expect(owner.app.activeVault?.id, personalVaultId);
    expect(
      owner.app.wallpaperSyncAvailability,
      WallpaperSyncAvailability.sharedVault,
    );

    // A change now stays on the device.
    expect(
      await a.wallpaper.setImageBytes(await _png(40, 40, const Color(0xFFE53935))),
      isNull,
    );
    await a.round();
    expect(a.sync.state, WallpaperSyncState.unavailable);
    expect(a.app.accountWallpaperRecord!.revisionId, saves);
    expect(a.app.accountWallpaperRecord!.value.hasImage, isFalse);

    // Still shared after a full reload of the verified membership.
    await friend.app.acceptVaultInvitation(invitation['token'] as String);
    await idle(friend.app);
    await owner.app.loadVaultsForTesting();
    await idle(owner.app);
    expect(owner.app.activeVault?.id, personalVaultId);
    expect(
      owner.app.wallpaperSyncAvailability,
      WallpaperSyncAvailability.sharedVault,
    );
    // The friend's own personal Vault is theirs alone.
    final friendVaults = friend.app.vaults.map((v) => v.id).toList();
    expect(friendVaults, contains(personalVaultId));
    final friendPersonal = friendVaults.firstWhere((id) => id != personalVaultId);
    await friend.app.selectVault(friendPersonal);
    await idle(friend.app);
    expect(
      friend.app.wallpaperSyncAvailability,
      WallpaperSyncAvailability.available,
    );
    await friend.app.selectVault(personalVaultId);
    await idle(friend.app);
    expect(
      friend.app.wallpaperSyncAvailability,
      WallpaperSyncAvailability.sharedVault,
    );
  });
}
