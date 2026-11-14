import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import 'rdp_features.dart';
import 'rdp_local_drives.dart';
import 'rdp_settings.dart';
import 'rdp_storage.dart';
import 'rdp_storage_stub.dart'
    if (dart.library.io) 'rdp_storage_io.dart'
    as storage;

/// Android runtime permissions behind RDP device redirection. The engine
/// opens the microphone and cameras inside the session, so Android must have
/// granted them before the handshake.
enum RdpDevicePermission { microphone, camera }

enum RdpPermissionState {
  granted,

  /// Android still shows its dialog when asked again.
  denied,

  /// Android no longer shows its dialog; only app settings can grant it.
  permanentlyDenied,
}

/// Checks and requests [RdpDevicePermission]s. Injectable so the connect
/// flow and the Host editor can be tested without the platform.
abstract interface class RdpPermissionBroker {
  /// False where this app does not request these permissions itself (every
  /// platform but Android): nothing is checked, requested or dropped.
  bool get active;

  /// Current states. Never prompts.
  Future<Map<RdpDevicePermission, RdpPermissionState>> check(
    Set<RdpDevicePermission> permissions,
  );

  /// Shows Android's dialog for the ones not granted yet. Only after a user
  /// action (starting a connection, turning a Host switch on). Throws when
  /// the app is not in front or another request is open.
  Future<Map<RdpDevicePermission, RdpPermissionState>> request(
    Set<RdpDevicePermission> permissions,
  );

  /// Opens this app's page in Android Settings.
  Future<bool> openSettings();
}

/// The broker this platform uses: the Android channel, elsewhere a no-op.
RdpPermissionBroker platformRdpPermissionBroker() =>
    storage.rdpRuntimePermissionsRequired
    ? const AndroidRdpPermissions()
    : const NoRdpPermissions();

/// Platforms where the OS asks on first use (or nothing needs asking).
class NoRdpPermissions implements RdpPermissionBroker {
  const NoRdpPermissions();
  @override
  bool get active => false;
  @override
  Future<Map<RdpDevicePermission, RdpPermissionState>> check(
    Set<RdpDevicePermission> permissions,
  ) async => {for (final p in permissions) p: RdpPermissionState.granted};
  @override
  Future<Map<RdpDevicePermission, RdpPermissionState>> request(
    Set<RdpDevicePermission> permissions,
  ) => check(permissions);
  @override
  Future<bool> openSettings() async => false;
}

/// `atermius/rdp_permissions` (RdpDevicePermissions.kt).
class AndroidRdpPermissions implements RdpPermissionBroker {
  const AndroidRdpPermissions();
  static const channel = MethodChannel('atermius/rdp_permissions');

  @override
  bool get active => true;

  @override
  Future<Map<RdpDevicePermission, RdpPermissionState>> check(
    Set<RdpDevicePermission> permissions,
  ) => _call('check', permissions);

  @override
  Future<Map<RdpDevicePermission, RdpPermissionState>> request(
    Set<RdpDevicePermission> permissions,
  ) => _call('request', permissions);

  @override
  Future<bool> openSettings() async =>
      await channel.invokeMethod<bool>('openSettings') == true;

  Future<Map<RdpDevicePermission, RdpPermissionState>> _call(
    String method,
    Set<RdpDevicePermission> permissions,
  ) async {
    if (permissions.isEmpty) return const {};
    final raw = await channel.invokeMapMethod<String, Object?>(method, {
      'permissions': [for (final p in permissions) p.name],
    });
    return rdpPermissionStatesFrom(permissions, raw);
  }
}

/// Parses a channel reply. Anything missing or unknown counts as denied, so
/// a malformed reply never turns a redirection on.
@visibleForTesting
Map<RdpDevicePermission, RdpPermissionState> rdpPermissionStatesFrom(
  Set<RdpDevicePermission> asked,
  Map<String, Object?>? raw,
) => {
  for (final permission in asked)
    permission: switch (raw?[permission.name]) {
      'granted' => RdpPermissionState.granted,
      'permanentlyDenied' => RdpPermissionState.permanentlyDenied,
      _ => RdpPermissionState.denied,
    },
};

/// What the user chose in the explanation shown before Android's storage
/// screen opens at connect.
enum RdpStorageChoice {
  /// Open the system screen now.
  grant,

  /// Connect without local storage this time.
  notNow,

  /// Turn "Map local disks" off for this Host on this device.
  dontMap,
}

/// The visible session view, which asks the user before Android permission
/// screens open at connect.
abstract interface class RdpPermissionPrompter {
  /// Whether the view is showing now. Nothing is requested otherwise.
  bool get canPrompt;

  /// Explains why Android's storage screen is about to open. [offerDontMap]
  /// adds "Don't map disks for this Host" (only while the switch is on).
  /// Null when the view went away before the user chose.
  Future<RdpStorageChoice?> explainStorage(
    HostRecord host, {
    required bool offerDontMap,
  });
}

/// What one RDP attempt may redirect after the connect-time permission step.
class RdpConnectGrants {
  const RdpConnectGrants({
    this.microphone = true,
    this.camera = true,
    this.mapLocalDisks = true,
  });

  /// False: the Host has it on but Android did not allow it, so this attempt
  /// connects without it.
  final bool microphone, camera;

  /// False when the user chose "Don't map disks for this Host" just now.
  final bool mapLocalDisks;

  /// Devices this attempt drops, in a fixed order for the notice.
  List<RdpDevicePermission> get dropped => [
    if (!microphone) RdpDevicePermission.microphone,
    if (!camera) RdpDevicePermission.camera,
  ];
}

/// Android permissions an RDP connection needs, asked when the user starts
/// the connection (never on automatic retries) and before the handshake.
/// Each permission is asked at most once per Host per app process, so
/// reconnects never nag; anything not granted is left out of that attempt's
/// native configuration only and never written back to the synchronized Host.
class RdpConnectPermissions {
  RdpConnectPermissions({RdpPermissionBroker? broker})
    : broker = broker ?? platformRdpPermissionBroker();

  static RdpConnectPermissions? _instance;
  static RdpConnectPermissions get instance =>
      _instance ??= RdpConnectPermissions();
  @visibleForTesting
  static set debugInstance(RdpConnectPermissions? value) => _instance = value;

  final RdpPermissionBroker broker;

  /// `hostId` + kind (`storage`, `microphone`, `camera`) asked in this
  /// process.
  final _asked = <String>{};
  static const _maxAsked = 4096;

  bool _wasAsked(String hostId, String kind) =>
      _asked.contains('$kind\n$hostId');

  void _markAsked(String hostId, String kind) {
    if (_asked.length >= _maxAsked) _asked.remove(_asked.first);
    _asked.add('$kind\n$hostId');
  }

  /// Checks what [settings] needs on this device and, when [userStarted]
  /// and a visible [prompter] exists, asks for what is missing: storage
  /// first (in-app explanation, then Android's screen), then microphone and
  /// camera in one system dialog. [mapLocalDisks] is the Host's "Map local
  /// disks" switch on this device. Never throws: a failed check or request
  /// counts as not granted. [current] is false once the attempt was closed
  /// or superseded; nothing more is asked then. [asking] is told while the
  /// user is being asked.
  Future<RdpConnectGrants> prepare({
    required HostRecord host,
    required RdpSettings settings,
    required RdpFeatures engine,
    required RdpLocalDrivesController localDrives,
    required bool mapLocalDisks,
    required bool userStarted,
    required Future<RdpPermissionPrompter?> Function() prompter,
    required bool Function() current,
    void Function(bool asking)? asking,
  }) async {
    final source = localDrives.source;
    final storageWanted =
        source.os == RdpAutoDriveOs.android &&
        engine.has(RdpFeatures.drive) &&
        (mapLocalDisks ||
            settings.drives.any(
              (drive) => rdpPathIsWindows(drive.path) == source.windowsPaths,
            ));
    final devices = <RdpDevicePermission>{
      if (broker.active &&
          settings.microphone &&
          engine.has(RdpFeatures.audioIn))
        RdpDevicePermission.microphone,
      if (broker.active && settings.cameras && engine.has(RdpFeatures.camera))
        RdpDevicePermission.camera,
    };
    final states = <RdpDevicePermission, RdpPermissionState>{};
    if (devices.isNotEmpty) {
      states.addAll(await _guard(() => broker.check(devices), devices));
    }
    var storageMissing = false;
    if (storageWanted) {
      try {
        storageMissing = !await source.hasAccess().timeout(_timeout);
      } on Object {
        // Unknown: expandRdpDrives checks again and maps nothing without it.
        storageMissing = false;
      }
    }
    var mapDisks = mapLocalDisks;
    RdpConnectGrants grants() => RdpConnectGrants(
      microphone:
          !devices.contains(RdpDevicePermission.microphone) ||
          states[RdpDevicePermission.microphone] == RdpPermissionState.granted,
      camera:
          !devices.contains(RdpDevicePermission.camera) ||
          states[RdpDevicePermission.camera] == RdpPermissionState.granted,
      mapLocalDisks: mapDisks,
    );
    final askStorage = storageMissing && !_wasAsked(host.id, 'storage');
    // Android no longer shows its dialog for a permanently denied one; the
    // notice says where to allow it instead.
    final askDevices = {
      for (final p in devices)
        if (states[p] == RdpPermissionState.denied &&
            !_wasAsked(host.id, p.name))
          p,
    };
    if (!userStarted || (!askStorage && askDevices.isEmpty)) return grants();
    RdpPermissionPrompter? view;
    try {
      view = await prompter();
    } on Object {
      view = null;
    }
    // No visible view: nothing opens, the notices explain (and a later
    // connect from a visible tab may still ask).
    if (view == null || !view.canPrompt || !current()) return grants();
    asking?.call(true);
    try {
      await _ask(
        host: host,
        view: view,
        source: source,
        localDrives: localDrives,
        askStorage: askStorage,
        offerDontMap: mapLocalDisks,
        askDevices: askDevices,
        states: states,
        dontMap: () => mapDisks = false,
        current: current,
      );
    } finally {
      asking?.call(false);
    }
    return grants();
  }

  Future<void> _ask({
    required HostRecord host,
    required RdpPermissionPrompter view,
    required RdpLocalVolumeSource source,
    required RdpLocalDrivesController localDrives,
    required bool askStorage,
    required bool offerDontMap,
    required Set<RdpDevicePermission> askDevices,
    required Map<RdpDevicePermission, RdpPermissionState> states,
    required void Function() dontMap,
    required bool Function() current,
  }) async {
    if (askStorage) {
      _markAsked(host.id, 'storage');
      RdpStorageChoice? choice;
      try {
        choice = await view.explainStorage(host, offerDontMap: offerDontMap);
      } on Object {
        choice = null;
      }
      if (!current()) return;
      switch (choice) {
        case RdpStorageChoice.grant:
          try {
            await source.requestAccess();
          } on Object {
            // expandRdpDrives checks again; without access nothing is mapped.
          }
        case RdpStorageChoice.dontMap:
          // The existing device-local switch; never the synchronized Host.
          dontMap();
          await localDrives.setEnabled(host.id, false);
        case RdpStorageChoice.notNow || null:
          break;
      }
      if (!current()) return;
    }
    if (askDevices.isNotEmpty && view.canPrompt) {
      try {
        states.addAll(await broker.request(askDevices));
        // Only a request Android actually handled counts as asked.
        for (final p in askDevices) {
          _markAsked(host.id, p.name);
        }
      } on Object {
        // Not in front or another request open: connect without them.
      }
    }
  }

  static const _timeout = Duration(seconds: 10);

  static Future<Map<RdpDevicePermission, RdpPermissionState>> _guard(
    Future<Map<RdpDevicePermission, RdpPermissionState>> Function() call,
    Set<RdpDevicePermission> asked,
  ) async {
    try {
      final result = await call().timeout(_timeout);
      return {for (final p in asked) p: result[p] ?? RdpPermissionState.denied};
    } on Object {
      return {for (final p in asked) p: RdpPermissionState.denied};
    }
  }
}
