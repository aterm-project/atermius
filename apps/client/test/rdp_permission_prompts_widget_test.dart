import 'dart:async';

import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/desktop_view.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/rdp_features.dart';
import 'package:aterm_client/desktop/rdp_local_drives.dart';
import 'package:aterm_client/desktop/rdp_permission_prompts.dart';
import 'package:aterm_client/desktop/rdp_permissions.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/desktop/rdp_settings_editor.dart';
import 'package:aterm_client/desktop/rdp_storage.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:flutter/material.dart';
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

const _host = HostRecord(
  id: 'win',
  name: 'Office PC',
  address: 'win.example',
  protocol: HostProtocol.rdp,
);
const _grant = ValueKey('rdp_storage_grant');
const _notNow = ValueKey('rdp_storage_not_now');
const _dontMap = ValueKey('rdp_storage_dont_map');
const _explanation = ValueKey('rdp_storage_explanation');

void main() {
  useAppLocaleFixture('en');

  group('connect-time storage explanation in the session view', () {
    late FakeLocalVolumes source;
    late RdpLocalDrivesController local;
    late List<_Connection> connections;
    late DesktopSession session;

    Future<void> mount(WidgetTester tester, {bool visible = true}) async {
      source = FakeLocalVolumes(
        os: RdpAutoDriveOs.android,
        access: false,
        volumes: const [
          RdpLocalVolume(name: 'Local Storage', path: '/storage/emulated/0'),
        ],
      );
      local = await fakeLocalDrives(source);
      connections = [];
      session =
          DesktopSession(
              localDrives: local,
              permissions: RdpConnectPermissions(
                broker: FakeRdpPermissionBroker(active: false),
              ),
              permissionViewWait: Duration.zero,
              directConnectionForTesting: (_) {
                final c = _Connection();
                connections.add(c);
                return c;
              },
            )
            ..rdpFeaturesForTesting = const RdpFeatures(
              RdpFeatures.configV1 | RdpFeatures.drive | RdpFeatures.audioOut,
            );
      final view = DesktopView(session: session);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            // A pane behind the Hosts page is a hidden IndexedStack child.
            body: IndexedStack(
              index: visible ? 1 : 0,
              children: [const SizedBox.shrink(), view],
            ),
          ),
        ),
      );
    }

    // Closing the fake transport completes outside the test's fake clock, so
    // it is not awaited here; the connect timeout then fires on the closed
    // session and does nothing.
    Future<void> finish(WidgetTester tester, Future<void> connecting) async {
      await connecting;
      unawaited(session.close());
      await tester.pump(const Duration(seconds: 36));
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    }

    testWidgets('explains before Android Settings opens; Allow access asks '
        'and the disks map', (tester) async {
      await mount(tester);
      final connecting = session.connectLocal(_host);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_explanation), findsOneWidget);
      expect(find.text(currentL10n.rdpStorageAccessTitle), findsOneWidget);
      expect(
        find.text(currentL10n.rdpStorageAccessBody('Office PC')),
        findsOneWidget,
      );
      expect(find.byKey(_dontMap), findsOneWidget);
      expect(session.awaitingPermission, isTrue);
      expect(source.requests, 0, reason: 'Settings waits for the user');
      expect(connections, isEmpty);

      await tester.tap(find.byKey(_grant));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(_explanation), findsNothing);
      expect(source.requests, 1);
      expect(connections, hasLength(1));
      expect(
        session.rdpConfig!.text,
        contains('\ndrive=Local Storage|/storage/emulated/0\n'),
      );
      await finish(tester, connecting);
    });

    testWidgets('Don\'t map disks for this host turns the device-local switch '
        'off', (tester) async {
      await mount(tester);
      final connecting = session.connectLocal(_host);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(_dontMap));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(local.enabled(_host.id), isFalse);
      expect(source.requests, 0);
      expect(session.rdpConfig!.text, isNot(contains('drive=')));
      await finish(tester, connecting);
    });

    testWidgets('Not now connects without local storage', (tester) async {
      await mount(tester);
      final connecting = session.connectLocal(_host);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(_notNow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(source.requests, 0);
      expect(local.enabled(_host.id), isTrue);
      expect(connections, hasLength(1));
      expect(session.rdpConfig!.text, isNot(contains('drive=')));
      await finish(tester, connecting);
    });

    testWidgets('stopping the attempt closes the explanation', (tester) async {
      await mount(tester);
      final connecting = session.connectLocal(_host);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_explanation), findsOneWidget);
      unawaited(session.close());
      expect(session.awaitingPermission, isFalse);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(_explanation), findsNothing);
      await connecting;
      expect(source.requests, 0);
      expect(connections, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
    });

    testWidgets('a hidden pane never asks', (tester) async {
      await mount(tester, visible: false);
      final connecting = session.connectLocal(_host);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_explanation), findsNothing);
      await connecting;
      expect(source.requests, 0);
      expect(connections, hasLength(1));
      await finish(tester, connecting);
    });
  });

  testWidgets('the explanation offers Don\'t map only while mapping is on', (
    tester,
  ) async {
    RdpStorageChoice? choice;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => choice = await showDialog<RdpStorageChoice>(
              context: context,
              builder: (_) => const RdpStorageExplanationDialog(
                hostName: 'Office PC',
                offerDontMap: false,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(_dontMap), findsNothing);
    await tester.tap(find.byKey(_grant));
    await tester.pumpAndSettle();
    expect(choice, RdpStorageChoice.grant);
  });

  group('Host editor microphone and camera', () {
    const devices = RdpFeatures(
      RdpFeatures.configV1 | RdpFeatures.audioIn | RdpFeatures.camera,
    );
    const mic = ValueKey('host_rdp_microphone');
    const camera = ValueKey('host_rdp_cameras');

    Future<void> mount(
      WidgetTester tester,
      RdpPermissionBroker broker, {
      RdpSettings initial = RdpSettings.defaults,
      RdpFeatures features = devices,
      ValueChanged<RdpSettings>? changed,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RdpSettingsEditor(
                initial: initial,
                features: features,
                onChanged: changed ?? (_) {},
                permissions: broker,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('RDP options'));
      await tester.pumpAndSettle();
    }

    Future<void> toggle(WidgetTester tester, Key key) async {
      await tester.ensureVisible(find.byKey(key));
      await tester.tap(find.byKey(key));
      await tester.pumpAndSettle();
    }

    testWidgets('turning the microphone on asks right away; a refusal shows '
        'Allow, which asks again', (tester) async {
      final broker = FakeRdpPermissionBroker();
      RdpSettings? saved;
      await mount(tester, broker, changed: (v) => saved = v);
      expect(broker.requests, isEmpty, reason: 'opening never prompts');
      await toggle(tester, mic);
      expect(saved?.microphone, isTrue);
      expect(broker.requests, [
        {RdpDevicePermission.microphone},
      ]);
      expect(
        find.text(currentL10n.rdpPermissionMicrophoneDenied),
        findsOneWidget,
      );
      // The synchronized switch stays on: another device may allow it.
      expect(tester.widget<SwitchListTile>(find.byKey(mic)).value, isTrue);

      broker.answer = RdpPermissionState.granted;
      await tester.tap(
        find.byKey(const ValueKey('host_rdp_microphone_permission_allow')),
      );
      await tester.pumpAndSettle();
      expect(broker.requests, hasLength(2));
      expect(find.text(currentL10n.rdpPermissionGranted), findsOneWidget);
    });

    testWidgets('permanently denied offers Open app settings, and the state '
        'is read again when the app resumes', (tester) async {
      final broker = FakeRdpPermissionBroker(
        states: {RdpDevicePermission.camera: RdpPermissionState.denied},
        answer: RdpPermissionState.permanentlyDenied,
      );
      await mount(tester, broker);
      await toggle(tester, camera);
      final settings = find.byKey(
        const ValueKey('host_rdp_camera_permission_settings'),
      );
      expect(find.text(currentL10n.rdpPermissionCameraDenied), findsOneWidget);
      expect(settings, findsOneWidget);
      await tester.tap(settings);
      await tester.pump();
      expect(broker.settingsOpened, 1);

      broker.states[RdpDevicePermission.camera] = RdpPermissionState.granted;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text(currentL10n.rdpPermissionGranted), findsOneWidget);
      expect(settings, findsNothing);
    });

    testWidgets('a switch already on shows its state without asking', (
      tester,
    ) async {
      final broker = FakeRdpPermissionBroker();
      await mount(tester, broker, initial: const RdpSettings(microphone: true));
      expect(broker.requests, isEmpty);
      expect(
        find.text(currentL10n.rdpPermissionMicrophoneDenied),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('host_rdp_microphone_permission_allow')),
        findsOneWidget,
      );
    });

    testWidgets('other platforms and engines without the device show and ask '
        'nothing', (tester) async {
      final inactive = FakeRdpPermissionBroker(active: false);
      await mount(tester, inactive);
      await toggle(tester, mic);
      expect(inactive.checks, isEmpty);
      expect(inactive.requests, isEmpty);
      expect(
        find.text(currentL10n.rdpPermissionMicrophoneDenied),
        findsNothing,
      );

      final broker = FakeRdpPermissionBroker();
      await tester.pumpWidget(const SizedBox.shrink());
      await mount(
        tester,
        broker,
        initial: const RdpSettings(microphone: true),
        features: const RdpFeatures(RdpFeatures.configV1),
      );
      expect(broker.checks, isEmpty);
      expect(
        find.text(currentL10n.rdpPermissionMicrophoneDenied),
        findsNothing,
      );
    });
  });
}
