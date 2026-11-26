// Two devices of one account on the REAL server binary, with the app's own
// automatic sync (edit debounce + realtime hints) and no manual sync calls:
// an edit made on one device must reach the other within seconds, and both
// devices must end up holding the same data.
//
// Run: ATERMIUS_TEST_SERVER_BINARY=<cargo target>/debug/atermius-server \
//      flutter test test/sync_propagation_real_server_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/cloud_real_server.dart';

/// Waits for [done] without triggering a sync; returns the time it took.
Future<Duration> eventually(
  String what,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > timeout) {
      fail('$what did not happen within ${timeout.inSeconds}s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return watch.elapsed;
}

/// The synced content of a Host, without device-local projection fields.
String hostContent(HostRecord host) {
  final json = Map<String, Object?>.from(host.toJson())
    ..remove('revision_id')
    ..remove('base_revision_id')
    ..remove('online');
  return canonical(json);
}

String canonical(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) => switch (value) {
  final Map map => {
    for (final key in map.keys.map((k) => '$k').toList()..sort())
      key: _sorted(map[key]),
  },
  final List list => [for (final item in list) _sorted(item)],
  _ => value,
};

void main() {
  if (realServerBinary == null || !File(realServerBinary!).existsSync()) {
    test(
      'sync propagation on a real server',
      () {},
      skip: 'set ATERMIUS_TEST_SERVER_BINARY to the built atermius-server',
    );
    return;
  }
  const username = 'owner@example.test';
  late SodiumSumo sodium;
  late TestServer server;
  late AppController a;
  late AppController b;

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    sodium = await SodiumSumoInit.init();
    server = await TestServer.start();
    final owner = await party(
      sodium,
      server.baseUrl,
      username: username,
      bootstrap: server.bootstrapToken(),
    );
    a = owner.app;
    b = AppController(
      sodium: sodium,
      database: ClientDatabase.forTesting(NativeDatabase.memory()),
      secureStore: ClientSecureStore(const PrefixedStorage('second.')),
      apiClientFactoryForTesting: (baseUrl) =>
          ApiClient(baseUrl: baseUrl, client: RecordingClient()),
    );
    await b.configureServer(server.baseUrl);
    final request = await b.createDeviceEnrollmentRequest(
      username: username,
      name: 'Second device',
    );
    final approval = await a.approveDeviceEnrollment(request);
    await b.importDeviceApproval(approval);
    await b.login(username: username, password: realServerPassword);
    await idle(b);
    expect(b.activeVault?.id, a.activeVault?.id);
    // Let both devices finish their start-up passes and open hint sockets.
    await Future<void>.delayed(const Duration(seconds: 3));
    await idle(a);
    await idle(b);
  });

  tearDownAll(() async {
    await server.stop();
  });

  test('a new Host reaches the other device on its own', () async {
    final host = testHost('propagation-new');
    await a.saveHost(host);
    final took = await eventually(
      'B receiving the new Host',
      () => b.hosts.any((item) => item.id == host.id),
    );
    // ignore: avoid_print
    print('new host reached B after ${took.inMilliseconds} ms');
    expect(a.pendingCount, 0);
  });

  test('an edit from the Host editor reaches the other device', () async {
    final original = a.hosts.firstWhere((h) => h.name == 'propagation-new');
    final edited = original.copyWith(port: 2222, username: 'admin');
    await a.saveHostFromEditor(original: original, edited: edited);
    final took = await eventually(
      'B receiving the edited port',
      () => b.hosts.any((h) => h.id == original.id && h.port == 2222),
    );
    // ignore: avoid_print
    print('editor edit reached B after ${took.inMilliseconds} ms');
    final onB = b.hosts.firstWhere((h) => h.id == original.id);
    expect(onB.username, 'admin');
  });

  test('RDP settings changed in the Host editor are saved and synced', () async {
    final rdp = testHost('propagation-rdp', protocol: HostProtocol.rdp);
    await a.saveHost(rdp);
    await eventually(
      'B receiving the RDP Host',
      () => b.hosts.any((h) => h.id == rdp.id),
    );
    final original = a.hosts.firstWhere((h) => h.id == rdp.id);
    const settings = RdpSettings(
      resolution: RdpResolutionMode.fixed,
      width: 1920,
      height: 1080,
      microphone: true,
    );
    // What the editor builds: its settings applied onto the existing manifest.
    final edited = original.copyWith(
      manifest: settings.applyTo(original.manifest),
    );
    await a.saveHostFromEditor(original: original, edited: edited);
    final onA = a.hosts.firstWhere((h) => h.id == rdp.id);
    expect(RdpSettings.of(onA), settings, reason: 'saved on this device');
    await eventually(
      'B receiving the RDP settings',
      () => b.hosts.any((h) => h.id == rdp.id && RdpSettings.of(h) == settings),
    );
  });

  test('two devices editing different fields of a Host both keep their '
      'change', () async {
    final rdpId = a.hosts.firstWhere((h) => h.name == 'propagation-rdp').id;
    final staleOnA = a.hosts.firstWhere((h) => h.id == rdpId);
    final onB = b.hosts.firstWhere((h) => h.id == rdpId);
    await b.saveHostFromEditor(original: onB, edited: onB.copyWith(port: 3390));
    // A's editor was opened before B's change arrived.
    await eventually(
      'A receiving the port from B',
      () => a.hosts.any((h) => h.id == rdpId && h.port == 3390),
    );
    const settings = RdpSettings(cameras: true, printers: RdpPrinterMode.all);
    await a.saveHostFromEditor(
      original: staleOnA,
      edited: staleOnA.copyWith(manifest: settings.applyTo(staleOnA.manifest)),
    );
    await eventually(
      'B receiving the RDP settings on top of its port',
      () => b.hosts.any(
        (h) => h.id == rdpId && h.port == 3390 && RdpSettings.of(h) == settings,
      ),
    );
  });

  test('a terminal preference reaches the other device on its own', () async {
    final next = a.terminalFontSize == 16 ? 18 : 16;
    await a.saveTerminalFontSizePreference(next);
    final took = await eventually(
      'B receiving the font size',
      () => b.terminalFontSize == next,
    );
    // ignore: avoid_print
    print('font size reached B after ${took.inMilliseconds} ms');
  });

  test('edits made one after another while a sync runs all arrive', () async {
    final host = a.hosts.firstWhere((h) => h.name == 'propagation-new');
    var current = host;
    for (var port = 3001; port <= 3005; port++) {
      final edited = current.copyWith(port: port);
      await a.saveHostFromEditor(original: current, edited: edited);
      current = a.hosts.firstWhere((h) => h.id == host.id);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await eventually(
      'B receiving the last of several quick edits',
      () => b.hosts.any((h) => h.id == host.id && h.port == 3005),
    );
    await eventually('A outbox drained', () => a.pendingCount == 0);
  });

  test('an edit on the second device comes back to the first', () async {
    final original = b.hosts.firstWhere((h) => h.name == 'propagation-new');
    final edited = original.copyWith(name: 'propagation-renamed');
    await b.saveHostFromEditor(original: original, edited: edited);
    final took = await eventually(
      'A receiving the rename from B',
      () => a.hosts.any(
        (h) => h.id == original.id && h.name == 'propagation-renamed',
      ),
    );
    // ignore: avoid_print
    print('rename reached A after ${took.inMilliseconds} ms');
  });

  test('both devices end with the same data and nothing pending', () async {
    await eventually(
      'both outboxes drained',
      () =>
          a.pendingCount == 0 &&
          b.pendingCount == 0 &&
          !a.syncing &&
          !b.syncing,
    );
    final onA = {for (final h in a.hosts) h.id: hostContent(h)};
    final onB = {for (final h in b.hosts) h.id: hostContent(h)};
    expect(onB, onA);
    expect(
      {for (final h in b.hosts) h.id: h.revisionId},
      {for (final h in a.hosts) h.id: h.revisionId},
    );
    expect(b.terminalFontSize, a.terminalFontSize);
    expect(a.conflictCount, 0);
    expect(b.conflictCount, 0);
  });
}
