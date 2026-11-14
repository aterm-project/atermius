import 'dart:async';

import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_local_drives.dart';
import 'package:aterm_client/desktop/rdp_permissions.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/rdp_storage.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/rdp_local_volumes_fake.dart';
import 'support/rdp_permissions_fake.dart';

const _host = HostRecord(
  id: 'win',
  name: 'Win',
  address: 'win.example',
  protocol: HostProtocol.rdp,
);
const _other = HostRecord(
  id: 'other',
  name: 'Other',
  address: 'other.example',
  protocol: HostProtocol.rdp,
);
const _engine = RdpFeatures(
  RdpFeatures.configV1 |
      RdpFeatures.drive |
      RdpFeatures.audioIn |
      RdpFeatures.camera,
);
const _devices = RdpSettings(microphone: true, cameras: true);
const _mic = RdpDevicePermission.microphone;
const _camera = RdpDevicePermission.camera;

FakeLocalVolumes _android({bool access = false}) => FakeLocalVolumes(
  os: RdpAutoDriveOs.android,
  access: access,
  volumes: const [
    RdpLocalVolume(name: 'Local Storage', path: '/storage/emulated/0'),
  ],
);

void main() {
  late FakeRdpPermissionBroker broker;
  late RdpConnectPermissions permissions;
  late FakeLocalVolumes source;
  late RdpLocalDrivesController local;
  late FakeRdpPrompter view;
  late int viewLookups;
  late List<bool> asking;

  setUp(() async {
    broker = FakeRdpPermissionBroker(answer: RdpPermissionState.granted);
    permissions = RdpConnectPermissions(broker: broker);
    source = _android();
    local = await fakeLocalDrives(source);
    view = FakeRdpPrompter();
    viewLookups = 0;
    asking = [];
  });

  Future<RdpConnectGrants> prepare({
    HostRecord host = _host,
    RdpSettings settings = _devices,
    RdpFeatures engine = _engine,
    bool? mapLocalDisks,
    bool userStarted = true,
    RdpPermissionPrompter? Function()? prompter,
    bool Function()? current,
  }) => permissions.prepare(
    host: host,
    settings: settings,
    engine: engine,
    localDrives: local,
    mapLocalDisks: mapLocalDisks ?? local.enabled(host.id),
    userStarted: userStarted,
    prompter: () async {
      viewLookups++;
      return prompter == null ? view : prompter();
    },
    current: current ?? () => true,
    asking: asking.add,
  );

  test('a user-started connect explains storage first, then asks for the '
      'microphone and camera in one Android dialog', () async {
    final grants = await prepare();
    expect(view.explained, [(hostId: _host.id, offerDontMap: true)]);
    expect(source.requests, 1);
    expect(source.access, isTrue);
    expect(broker.requests, [
      {_mic, _camera},
    ]);
    expect(grants.microphone, isTrue);
    expect(grants.camera, isTrue);
    expect(grants.mapLocalDisks, isTrue);
    expect(grants.dropped, isEmpty);
    expect(asking, [true, false]);
  });

  test('refused devices are dropped from this attempt only', () async {
    broker.answer = RdpPermissionState.denied;
    final grants = await prepare();
    expect(grants.dropped, [_mic, _camera]);
    expect(grants.mapLocalDisks, isTrue);
  });

  test(
    'each permission is asked at most once per Host per app process',
    () async {
      broker.answer = RdpPermissionState.denied;
      source.grant = false;
      await prepare();
      expect(view.explained, hasLength(1));
      expect(source.requests, 1);
      expect(broker.requests, hasLength(1));

      // A reconnect of the same Host does not nag.
      final again = await prepare();
      expect(view.explained, hasLength(1));
      expect(source.requests, 1);
      expect(broker.requests, hasLength(1));
      expect(again.dropped, [_mic, _camera]);
      expect(viewLookups, 1, reason: 'nothing left to ask: no view needed');

      // Another Host asks for itself.
      await prepare(host: _other);
      expect(view.explained, hasLength(2));
      expect(broker.requests, hasLength(2));

      // A separate process (a new broker state) asks again.
      final fresh = RdpConnectPermissions(broker: broker);
      await fresh.prepare(
        host: _host,
        settings: _devices,
        engine: _engine,
        localDrives: local,
        mapLocalDisks: true,
        userStarted: true,
        prompter: () async => view,
        current: () => true,
      );
      expect(view.explained, hasLength(3));
      expect(broker.requests, hasLength(3));
    },
  );

  test('connects an external AI starts never ask, and leave the question '
      'for the user', () async {
    final grants = await prepare(userStarted: false);
    expect(viewLookups, 0);
    expect(view.explained, isEmpty);
    expect(source.requests, 0);
    expect(broker.requests, isEmpty);
    expect(grants.dropped, [_mic, _camera]);
    expect(asking, isEmpty);

    await prepare();
    expect(view.explained, hasLength(1));
    expect(broker.requests, hasLength(1));
  });

  test('without a visible view nothing is asked; a later connect from a '
      'visible tab may ask', () async {
    var grants = await prepare(prompter: () => null);
    expect(source.requests, 0);
    expect(broker.requests, isEmpty);
    expect(grants.dropped, [_mic, _camera]);

    view.canPrompt = false;
    grants = await prepare();
    expect(view.explained, isEmpty);
    expect(broker.requests, isEmpty);
    expect(asking, isEmpty);

    view.canPrompt = true;
    grants = await prepare();
    expect(view.explained, hasLength(1));
    expect(grants.dropped, isEmpty);
  });

  test('Not now connects without local storage; Don\'t map turns only the '
      'device-local switch off', () async {
    broker.answer = RdpPermissionState.denied;
    view.choice = RdpStorageChoice.notNow;
    var grants = await prepare();
    expect(source.requests, 0);
    expect(grants.mapLocalDisks, isTrue, reason: 'the notice explains');
    expect(local.enabled(_host.id), isTrue);

    view.choice = RdpStorageChoice.dontMap;
    grants = await prepare(host: _other);
    expect(source.requests, 0);
    expect(grants.mapLocalDisks, isFalse);
    expect(local.enabled(_other.id), isFalse);
    expect(local.enabled(_host.id), isTrue);
    // The devices are still asked for after the storage choice.
    expect(broker.requests, hasLength(2));
  });

  test('a dismissed explanation counts as Not now', () async {
    view.choice = null;
    final grants = await prepare();
    expect(source.requests, 0);
    expect(grants.mapLocalDisks, isTrue);
    expect(local.enabled(_host.id), isTrue);
  });

  test('Host folders alone ask for storage without offering to turn mapping '
      'off; folders of another system do not', () async {
    source.grant = false;
    await local.setEnabled(_host.id, false);
    const folders = RdpSettings(
      drives: [RdpDriveRedirect(name: 'Work', path: '/storage/emulated/0/W')],
    );
    await prepare(settings: folders);
    expect(view.explained, [(hostId: _host.id, offerDontMap: false)]);

    await local.setEnabled(_other.id, false);
    const windows = RdpSettings(
      drives: [RdpDriveRedirect(name: 'Work', path: r'D:\Work')],
    );
    await prepare(host: _other, settings: windows);
    expect(view.explained, hasLength(1));
    expect(source.requests, 1);
  });

  test('storage that is already allowed, or an engine without the drive '
      'channel, needs no explanation', () async {
    source.access = true;
    await prepare(settings: RdpSettings.defaults);
    source.access = false;
    await prepare(
      host: _other,
      settings: RdpSettings.defaults,
      engine: const RdpFeatures(RdpFeatures.configV1),
    );
    expect(view.explained, isEmpty);
    expect(viewLookups, 0);
  });

  test('permanently denied permissions are not requested; the notice '
      'explains instead', () async {
    source.access = true;
    broker.states[_mic] = RdpPermissionState.permanentlyDenied;
    final grants = await prepare();
    expect(broker.requests, [
      {_camera},
    ]);
    expect(grants.dropped, [_mic]);
  });

  test('a request Android could not show is not counted as asked', () async {
    source.access = true;
    broker.requestError = PlatformException(code: 'unavailable');
    var grants = await prepare();
    expect(grants.dropped, [_mic, _camera]);
    broker.requestError = null;
    grants = await prepare();
    expect(broker.requests, hasLength(2));
    expect(grants.dropped, isEmpty);
  });

  test(
    'devices the engine cannot redirect are neither checked nor dropped',
    () async {
      source.access = true;
      final grants = await prepare(
        engine: const RdpFeatures(RdpFeatures.configV1 | RdpFeatures.drive),
      );
      expect(broker.checks, isEmpty);
      expect(grants.dropped, isEmpty);
    },
  );

  test('other platforms check, ask and drop nothing', () async {
    broker = FakeRdpPermissionBroker(active: false);
    permissions = RdpConnectPermissions(broker: broker);
    source = FakeLocalVolumes(volumes: const [windowsC]);
    local = await fakeLocalDrives(source);
    final grants = await prepare();
    expect(broker.checks, isEmpty);
    expect(broker.requests, isEmpty);
    expect(view.explained, isEmpty);
    expect(grants.dropped, isEmpty);
    expect(grants.mapLocalDisks, isTrue);
  });

  test(
    'an attempt closed while the explanation is open asks nothing more',
    () async {
      var open = true;
      view.pending = Completer();
      final preparing = prepare(current: () => open);
      await pumpEventQueue();
      expect(view.explained, hasLength(1));
      open = false;
      view.pending!.complete(RdpStorageChoice.grant);
      await preparing;
      expect(source.requests, 0);
      expect(broker.requests, isEmpty);
      expect(asking, [true, false]);
    },
  );

  test('a failing permission check counts as not allowed', () async {
    source.access = true;
    final failing = _FailingChecks();
    permissions = RdpConnectPermissions(broker: failing);
    final grants = await prepare(userStarted: false);
    expect(grants.dropped, [_mic, _camera]);
  });

  test('channel replies: anything missing or unknown counts as denied', () {
    expect(
      rdpPermissionStatesFrom(
        {_mic, _camera},
        {'microphone': 'granted', 'camera': 'maybe'},
      ),
      {_mic: RdpPermissionState.granted, _camera: RdpPermissionState.denied},
    );
    expect(
      rdpPermissionStatesFrom({_camera}, {'camera': 'permanentlyDenied'}),
      {_camera: RdpPermissionState.permanentlyDenied},
    );
    expect(rdpPermissionStatesFrom({_mic}, null), {
      _mic: RdpPermissionState.denied,
    });
  });
}

class _FailingChecks extends FakeRdpPermissionBroker {
  @override
  Future<Map<RdpDevicePermission, RdpPermissionState>> check(
    Set<RdpDevicePermission> permissions,
  ) async => throw PlatformException(code: 'gone');
}
