import 'dart:async';

import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_local_drives.dart';
import 'package:aterm_client/desktop/rdp_permissions.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/rdp_storage.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/l10n_fixture.dart';
import 'support/rdp_local_volumes_fake.dart';
import 'support/rdp_permissions_fake.dart';

class _Connection implements DirectDesktopConnection {
  final controller = StreamController<DesktopEvent>();
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }

  @override
  void send(List<Object> command) {}
  @override
  void paste(String text) {}
}

// Local audio playback (the default) is available, so only the notices under
// test show.
const _engine = RdpFeatures(
  RdpFeatures.configV1 |
      RdpFeatures.drive |
      RdpFeatures.audioOut |
      RdpFeatures.audioIn |
      RdpFeatures.camera,
);
const _base = HostRecord(
  id: 'win',
  name: 'Win',
  address: 'win.example',
  protocol: HostProtocol.rdp,
);
final _host = _base.copyWith(
  manifest: const RdpSettings(microphone: true, cameras: true).applyTo(null),
);
const _storage = RdpLocalVolume(
  name: 'Local Storage',
  path: '/storage/emulated/0',
);

void main() {
  useAppLocaleFixture('en');

  late FakeRdpPermissionBroker broker;
  late FakeLocalVolumes source;
  late RdpLocalDrivesController local;
  late List<_Connection> connections;
  late List<String> notices;

  setUp(() async {
    broker = FakeRdpPermissionBroker();
    source = FakeLocalVolumes(
      os: RdpAutoDriveOs.android,
      access: false,
      volumes: const [_storage],
    );
    local = await fakeLocalDrives(source);
    connections = [];
    notices = [];
  });

  DesktopSession session({
    RdpPermissionPrompter? view,
    Duration wait = Duration.zero,
    Future<HostRecord> Function(HostRecord host, String sha256)?
    saveCertificate,
  }) {
    final desktop = DesktopSession(
      localDrives: local,
      permissions: RdpConnectPermissions(broker: broker),
      permissionViewWait: wait,
      saveRdpCertificate: saveCertificate,
      directConnectionForTesting: (_) {
        final c = _Connection();
        connections.add(c);
        return c;
      },
    )..rdpFeaturesForTesting = _engine;
    desktop.onNotice = notices.add;
    if (view != null) desktop.permissionPrompter = view;
    addTearDown(() async {
      await desktop.close();
      desktop.dispose();
    });
    return desktop;
  }

  Future<void> drop(_Connection connection) async {
    connection.controller.addError(StateError('Disconnected'));
    await Future<void>.delayed(Duration.zero);
  }

  String lines(DesktopSession desktop) => desktop.rdpConfig!.text;

  test('refused microphone and camera: the attempt connects without them, '
      'the Host keeps them and a notice says how to allow them', () async {
    source.access = true;
    await local.markNoticeShown(_host.id);
    final desktop = session(view: FakeRdpPrompter());
    await desktop.connectLocal(_host);
    expect(connections, hasLength(1), reason: 'the connection proceeds');
    expect(broker.requests, [
      {RdpDevicePermission.microphone, RdpDevicePermission.camera},
    ]);
    expect(lines(desktop), contains('\nmicrophone=0\n'));
    expect(lines(desktop), contains('\ncameras=0\n'));
    expect(desktop.rdpSettings.microphone, isTrue);
    expect(desktop.rdpSettings.cameras, isTrue);
    expect(notices, [
      currentL10n.rdpDevicesNeedPermission(
        [
          currentL10n.desktopMicrophone,
          currentL10n.desktopCameras,
        ].join(currentL10n.rdpListSeparator),
      ),
    ]);

    // Allowed in Android Settings meanwhile: the reconnect redirects them
    // without asking again, and the notice is not repeated.
    broker.states[RdpDevicePermission.microphone] = RdpPermissionState.granted;
    await drop(connections.single);
    await desktop.reconnect();
    expect(broker.requests, hasLength(1));
    expect(lines(desktop), contains('\nmicrophone=1\n'));
    expect(lines(desktop), contains('\ncameras=0\n'));
    expect(notices, hasLength(1), reason: 'once per tab');
  });

  test('Android storage is explained and asked for before the handshake, '
      'and the granted volume is mapped', () async {
    broker.answer = RdpPermissionState.granted;
    final view = FakeRdpPrompter()..pending = Completer();
    final desktop = session(view: view);
    final states = <bool>[];
    desktop.addListener(() => states.add(desktop.awaitingPermission));
    final connecting = desktop.connectLocal(_host);
    await pumpEventQueue();
    expect(view.explained, hasLength(1));
    expect(desktop.awaitingPermission, isTrue);
    expect(connections, isEmpty, reason: 'no handshake while asking');

    view.pending!.complete(RdpStorageChoice.grant);
    await connecting;
    expect(source.requests, 1);
    expect(desktop.awaitingPermission, isFalse);
    expect(states, containsAllInOrder([true, false]));
    expect(connections, hasLength(1));
    expect(
      lines(desktop),
      contains('\ndrive=Local Storage|/storage/emulated/0\n'),
    );
    expect(lines(desktop), contains('\nmicrophone=1\n'));
    expect(notices, [currentL10n.rdpLocalDisksMapped('Local Storage')]);
  });

  test(
    'closing the tab while the explanation is open never connects',
    () async {
      final view = FakeRdpPrompter()..pending = Completer();
      final desktop = session(view: view);
      final connecting = desktop.connectLocal(_host);
      await pumpEventQueue();
      expect(desktop.awaitingPermission, isTrue);
      await desktop.close();
      expect(desktop.awaitingPermission, isFalse);
      view.pending!.complete(RdpStorageChoice.grant);
      await connecting;
      expect(source.requests, 0);
      expect(broker.requests, isEmpty);
      expect(connections, isEmpty);
    },
  );

  test('Don\'t map turns the device-local switch off and connects without '
      'local storage', () async {
    final desktop = session(
      view: FakeRdpPrompter(choice: RdpStorageChoice.dontMap),
    );
    await desktop.connectLocal(_host);
    expect(local.enabled(_host.id), isFalse);
    expect(source.requests, 0);
    expect(lines(desktop), isNot(contains('drive=')));
    expect(
      notices,
      isNot(contains(currentL10n.rdpLocalDisksNeedAccess)),
      reason: 'nothing to grant once mapping is off',
    );
    expect(desktop.rdpSettings, RdpSettings.of(_host));
  });

  test(
    'a view that attaches while the connect waits for it is asked',
    () async {
      final view = FakeRdpPrompter();
      final desktop = session(wait: const Duration(seconds: 5));
      final connecting = desktop.connectLocal(_host);
      await pumpEventQueue();
      expect(connections, isEmpty);
      desktop.permissionPrompter = view;
      await connecting;
      expect(view.explained, hasLength(1));
      expect(source.requests, 1);
    },
  );

  test('without a view, the connect proceeds without asking and the notices '
      'explain', () async {
    final desktop = session();
    await desktop.connectLocal(_host);
    expect(connections, hasLength(1));
    expect(source.requests, 0);
    expect(broker.requests, isEmpty);
    expect(lines(desktop), isNot(contains('drive=')));
    expect(notices, [
      currentL10n.rdpLocalDisksNeedAccess,
      currentL10n.rdpDevicesNeedPermission(
        [
          currentL10n.desktopMicrophone,
          currentL10n.desktopCameras,
        ].join(currentL10n.rdpListSeparator),
      ),
    ]);
  });

  test(
    'a connect an external AI starts never asks, even with a view',
    () async {
      final view = FakeRdpPrompter();
      final desktop = session(view: view);
      await desktop.connectLocal(_host, userStarted: false);
      expect(connections, hasLength(1));
      expect(view.explained, isEmpty);
      expect(source.requests, 0);
      expect(broker.requests, isEmpty);
      expect(lines(desktop), contains('\nmicrophone=0\n'));

      // The user's Restore connection may ask.
      await drop(connections.single);
      await desktop.reconnect();
      expect(view.explained, hasLength(1));
      expect(broker.requests, hasLength(1));
    },
  );

  test('trusting the certificate of a connection an external AI started '
      'continues it without asking', () async {
    final view = FakeRdpPrompter();
    final desktop = session(
      view: view,
      saveCertificate: (host, sha256) async =>
          host.copyWith(rdpCertificateSha256: sha256),
    );
    await desktop.connectLocal(_host, userStarted: false);
    connections.single.controller.addError(RdpCertificateException('c' * 64));
    await pumpEventQueue();
    final request = desktop.certificateRequest;
    expect(request, isNotNull);
    expect(await desktop.trustCertificate(request!), isTrue);
    expect(connections, hasLength(2));
    expect(view.explained, isEmpty);
    expect(source.requests, 0);
    expect(broker.requests, isEmpty);
    expect(lines(desktop), contains('\nmicrophone=0\n'));
  });

  test(
    'Host folders are skipped, not fatal, without All files access',
    () async {
      final host = _base.copyWith(
        manifest: const RdpSettings(
          drives: [
            RdpDriveRedirect(name: 'Work', path: '/storage/emulated/0/Work'),
          ],
        ).applyTo(null),
      );
      final desktop = session();
      await desktop.connectLocal(host);
      expect(connections, hasLength(1));
      expect(lines(desktop), isNot(contains('drive=')));
      expect(notices, [
        currentL10n.rdpFoldersNeedAccess('Work'),
        currentL10n.rdpLocalDisksNeedAccess,
      ]);
    },
  );
}
