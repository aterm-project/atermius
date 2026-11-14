import 'dart:async';

import 'package:aterm_client/desktop/rdp_permissions.dart';
import 'package:aterm_client/domain/models.dart';

/// Android's microphone/camera permissions, as the platform would report
/// them. [answer] decides what a shown dialog returns.
class FakeRdpPermissionBroker implements RdpPermissionBroker {
  FakeRdpPermissionBroker({
    this.active = true,
    Map<RdpDevicePermission, RdpPermissionState>? states,
    this.answer = RdpPermissionState.denied,
  }) : states = {
         for (final p in RdpDevicePermission.values)
           p: RdpPermissionState.denied,
         ...?states,
       };

  @override
  final bool active;
  final Map<RdpDevicePermission, RdpPermissionState> states;

  /// The user's choice in Android's dialog for every permission asked.
  RdpPermissionState answer;

  /// Thrown by [request] instead of answering (not in front, busy).
  Object? requestError;

  final checks = <Set<RdpDevicePermission>>[];
  final requests = <Set<RdpDevicePermission>>[];
  int settingsOpened = 0;

  @override
  Future<Map<RdpDevicePermission, RdpPermissionState>> check(
    Set<RdpDevicePermission> permissions,
  ) async {
    checks.add(permissions);
    return {for (final p in permissions) p: states[p]!};
  }

  @override
  Future<Map<RdpDevicePermission, RdpPermissionState>> request(
    Set<RdpDevicePermission> permissions,
  ) async {
    requests.add(permissions);
    final error = requestError;
    if (error != null) throw error;
    for (final p in permissions) {
      // Android shows no dialog for granted or permanently denied ones.
      if (states[p] == RdpPermissionState.denied) states[p] = answer;
    }
    return {for (final p in permissions) p: states[p]!};
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }
}

/// The visible session view. [choice] answers the storage explanation; a
/// [pending] completer holds it open until the test completes it.
class FakeRdpPrompter implements RdpPermissionPrompter {
  FakeRdpPrompter({this.choice = RdpStorageChoice.grant});

  @override
  bool canPrompt = true;
  RdpStorageChoice? choice;
  Completer<RdpStorageChoice?>? pending;
  final explained = <({String hostId, bool offerDontMap})>[];

  @override
  Future<RdpStorageChoice?> explainStorage(
    HostRecord host, {
    required bool offerDontMap,
  }) async {
    explained.add((hostId: host.id, offerDontMap: offerDontMap));
    final hold = pending;
    if (hold != null) return hold.future;
    return choice;
  }
}
