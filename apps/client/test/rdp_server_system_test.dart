import 'dart:async';

import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/domain/host_operating_system.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/host_system_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const host = HostRecord(
  id: '11111111-1111-4111-8111-111111111111',
  name: 'RDP',
  address: 'example.test',
  port: 3389,
  protocol: HostProtocol.rdp,
);

class FakeDesktop implements DirectDesktopConnection {
  final stream = StreamController<DesktopEvent>();
  @override
  Stream<DesktopEvent> get events => stream.stream;
  @override
  Future<void> close() async {
    if (!stream.isClosed) await stream.close();
  }

  @override
  void send(List<Object> command) {}
  @override
  void paste(String text) {}
}

void main() {
  test('the version a server states while authenticating is saved', () async {
    final connection = FakeDesktop();
    final saves = <(HostRecord, HostOperatingSystem)>[];
    final session = DesktopSession(
      directConnectionForTesting: (_) => connection,
      saveOperatingSystem: (connected, system) async {
        saves.add((connected, system));
        return connected.copyWithDetectedOperatingSystem(system);
      },
    );
    await session.connectLocal(host);
    connection.stream.add(DesktopReady());
    connection.stream.add(DesktopServerSystem(10, 0, 22631));
    await pumpEventQueue();
    expect(saves, hasLength(1));
    expect(saves.single.$1.id, host.id);
    final system = saves.single.$2;
    expect(system.family, HostOperatingSystemFamily.windows);
    expect(system.displayName, 'Windows');
    expect(system.version, '10.0.22631');
    await session.close();
    session.dispose();
  });

  test('a server that states no system leaves the Host as it was', () async {
    final connection = FakeDesktop();
    var saves = 0;
    final session = DesktopSession(
      directConnectionForTesting: (_) => connection,
      saveOperatingSystem: (connected, system) async {
        saves++;
        return null;
      },
    );
    await session.connectLocal(host);
    connection.stream.add(DesktopReady());
    await pumpEventQueue();
    expect(saves, 0);
    await session.close();
    session.dispose();
  });

  test('a failing save does not disturb the session', () async {
    final connection = FakeDesktop();
    final session = DesktopSession(
      directConnectionForTesting: (_) => connection,
      saveOperatingSystem: (_, _) async => throw StateError('offline'),
    );
    await session.connectLocal(host);
    connection.stream.add(DesktopReady());
    connection.stream.add(DesktopServerSystem(10, 0, 20348));
    await pumpEventQueue();
    expect(session.error, isNull);
    await session.close();
    session.dispose();
  });

  testWidgets('an RDP Host shows Windows once known, its protocol icon before', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: HostSystemIcon(host: host)),
      ),
    );
    expect(find.byIcon(HostSystemIcon.unidentifiedIcon(host)), findsOneWidget);
    final known = host.copyWithDetectedOperatingSystem(
      HostOperatingSystem(
        family: HostOperatingSystemFamily.windows,
        displayName: 'Windows',
        version: '10.0.22631',
        detectedAt: DateTime.utc(2026, 11, 18),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HostSystemIcon(host: known)),
      ),
    );
    expect(find.byIcon(HostSystemIcon.unidentifiedIcon(host)), findsNothing);
    expect(find.byTooltip('Windows · 10.0.22631'), findsOneWidget);
  });
}
