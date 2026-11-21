import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ssh/port_forward_runtime.dart';
import 'package:aterm_client/terminal/session_log.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/session_logs_page.dart';
import 'package:aterm_client/ui/ssh_forwarding_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ssh_port_forward_fakes.dart';

// Layout checks of the Logs and SSH forwarding pages on phone widths, in
// long (Russian) and CJK translations and at a large text size: nothing may
// overflow, and every row, filter and action stays on the page.

SessionLogEntry _entry(
  String id,
  String host,
  String endpoint,
  SessionLogStatus status, {
  required Duration ago,
  Duration? length,
  SessionLogFailure? failure,
  SessionLogEndReason? end,
  bool transcript = false,
  bool jump = false,
  String protocol = 'ssh',
}) {
  final started = DateTime.utc(2026, 11, 21, 12).subtract(ago);
  return SessionLogEntry(
    id: id,
    hostId: id,
    hostName: host,
    endpoint: endpoint,
    protocol: protocol,
    startedAt: started,
    connectedAt: status == SessionLogStatus.failed
        ? null
        : started.add(const Duration(seconds: 2)),
    endedAt: length == null ? null : started.add(length),
    status: status,
    failure: failure,
    endReason: end,
    viaJump: jump,
    transcriptSlot: transcript ? 1 : null,
    transcriptBytes: transcript ? 2048 : 0,
  );
}

Future<SessionLogBook> _book({bool empty = false}) async {
  final storage = MemorySessionLogStorage();
  if (!empty) {
    final rows = [
      _entry(
        'closed',
        'api-gateway-01.production.example',
        'deploy@api01.prod.example.test:22',
        SessionLogStatus.closed,
        ago: const Duration(minutes: 42),
        length: const Duration(minutes: 18, seconds: 7),
        end: SessionLogEndReason.user,
        transcript: true,
      ),
      _entry(
        'failed',
        'build-win',
        'Administrator@10.0.3.40:3389',
        SessionLogStatus.failed,
        ago: const Duration(hours: 2),
        failure: SessionLogFailure.hostKeyChanged,
        protocol: 'rdp',
      ),
      _entry(
        'remote',
        'core-switch',
        '192.168.10.1:23',
        SessionLogStatus.closed,
        ago: const Duration(hours: 5),
        length: const Duration(minutes: 3),
        end: SessionLogEndReason.remote,
        protocol: 'telnet',
      ),
      _entry(
        'lost',
        'grafana',
        'ops@grafana.staging.example.test:22',
        SessionLogStatus.closed,
        ago: const Duration(hours: 26),
        length: const Duration(hours: 1, minutes: 4),
        end: SessionLogEndReason.error,
        jump: true,
      ),
    ];
    await storage.update(
      'index',
      (_) => {
        'entries': [for (final row in rows) row.toJson()],
      },
    );
  }
  final book = SessionLogBook(storage: storage);
  await book.load();
  if (!empty) {
    book
        .begin(
          host: const HostRecord(
            id: 'live',
            name: 'db-primary',
            address: '10.0.1.21',
            username: 'postgres',
          ),
        )
        .markConnected();
  }
  await book.flush();
  return book;
}

const _pg = SshPortForwardProfile(
  id: 'pg',
  name: 'Postgres read replica',
  type: SshPortForwardType.local,
  bindAddress: '127.0.0.1',
  bindPort: 15432,
  destinationAddress: 'replica.db.internal.example.test',
  destinationPort: 5432,
);
const _socks = SshPortForwardProfile(
  id: 'socks',
  name: 'SOCKS',
  type: SshPortForwardType.dynamic,
  bindAddress: '0.0.0.0',
  bindPort: 1080,
  exposeToNetwork: true,
);
const _hook = SshPortForwardProfile(
  id: 'hook',
  name: 'Webhook receiver',
  type: SshPortForwardType.remote,
  bindAddress: '127.0.0.1',
  bindPort: 9000,
  destinationAddress: 'localhost',
  destinationPort: 8080,
);
const _push = SshPortForwardProfile(
  id: 'push',
  name: 'Metrics push',
  type: SshPortForwardType.remote,
  bindAddress: '127.0.0.1',
  bindPort: 9100,
  destinationAddress: 'localhost',
  destinationPort: 9100,
);

const _hosts = [
  HostRecord(
    id: 'db',
    name: 'db-primary.production.example',
    address: '10.0.1.21',
    username: 'postgres',
    portForwardProfiles: [_pg, _socks],
  ),
  HostRecord(
    id: 'bastion',
    name: 'bastion',
    address: 'bastion.example.test',
    username: 'ops',
    portForwardProfiles: [_hook, _push],
  ),
  HostRecord(id: 'plain', name: 'grafana', address: 'grafana.example.test'),
];

/// A forwarding workspace with one connected host, one host with two
/// sessions (a running and a failed rule), and a host without rules.
class _Forwarding {
  _Forwarding({this.hosts = _hosts});

  final List<HostRecord> hosts;
  final db = SshPortForwardManager(FakeForwardingSshClient());
  final first = SshPortForwardManager(FakeForwardingSshClient());
  final second = SshPortForwardManager(
    FakeForwardingSshClient()..rejectRemoteForward = true,
  );
  final controller = SshForwardingController(runtimeSupported: true);

  late final source = CallbackSshForwardingSource(
    scopeKey: () => 'vault',
    hosts: () => hosts,
    sessions: () => [
      SshForwardingSessionInfo(
        id: 'db-1',
        hostId: 'db',
        label: 'db-primary #1',
        phase: SshForwardingSessionPhase.connected,
        manager: db,
      ),
      SshForwardingSessionInfo(
        id: 'bastion-1',
        hostId: 'bastion',
        label: 'bastion #1',
        phase: SshForwardingSessionPhase.connected,
        manager: first,
      ),
      SshForwardingSessionInfo(
        id: 'bastion-2',
        hostId: 'bastion',
        label: 'bastion #2',
        phase: SshForwardingSessionPhase.connected,
        manager: second,
      ),
    ],
    saveRule: (_, _, _, _) async {},
    connect: (_) async => null,
    storageDescription: '',
    storageDescriptionGetter: () =>
        currentL10n.profilesAreEncryptedInsideThisHost,
  );

  Future<void> start(WidgetTester tester) async {
    controller.selectSession('bastion', 'bastion-2');
    await tester.runAsync(() async {
      await first.start(_hook);
      try {
        await second.start(_push);
      } on Object {
        // Recorded as the rule's failed status.
      }
    });
  }

  Future<void> close(WidgetTester tester) => tester.runAsync(
    () => Future.wait([db.closeAll(), first.closeAll(), second.closeAll()]),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget Function() page, {
  required Size size,
  required Locale locale,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  final previousL10n = currentL10n;
  debugCurrentL10n = lookupAppLocalizations(locale);
  addTearDown(() {
    debugCurrentL10n = previousL10n;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizationSetup.delegates,
      supportedLocales: AppLocalizationSetup.locales,
      theme: buildAppTheme(locale: locale, brightness: brightness),
      home: Scaffold(body: page()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final cases = [
    for (final lang in ['en', 'zh', 'ru'])
      for (final width in [320.0, 390.0]) (lang, width, 1.0),
    ('ru', 320.0, 1.5),
    ('en', 390.0, 1.5),
  ];

  for (final (lang, width, scale) in cases) {
    final label = '${width.toInt()} px in $lang at ${scale}x text';

    testWidgets('logs page fits $label', (tester) async {
      final book = await _book();
      await _pump(
        tester,
        () => SessionLogsPage(book: book),
        size: Size(width, 3200),
        locale: Locale(lang),
        textScale: scale,
      );
      for (final id in ['closed', 'failed', 'remote', 'lost']) {
        expect(find.byKey(ValueKey('session_log_$id')), findsOneWidget);
      }
      for (final filter in ['all', 'active', 'failed', 'closed']) {
        expect(
          find.byKey(ValueKey('session_logs_filter_$filter')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey('session_logs_record_toggle')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('session_logs_clear')), findsOneWidget);
      // A filter without rows shows the compact no-match row.
      await tester.enterText(
        find.byKey(const ValueKey('session_logs_search')),
        'nothing-matches-this',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('session_logs_empty')), findsOneWidget);
      book.dispose();
    });

    testWidgets('forwarding page fits $label', (tester) async {
      final forwarding = _Forwarding();
      await _pump(
        tester,
        () => SshForwardingPage(
          source: forwarding.source,
          controller: forwarding.controller,
        ),
        size: Size(width, 5200),
        locale: Locale(lang),
        textScale: scale,
        brightness: Brightness.dark,
      );
      await forwarding.start(tester);
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final rule in [
        'db-pg',
        'db-socks',
        'bastion-hook',
        'bastion-push',
      ]) {
        expect(find.byKey(ValueKey('r7fwd-rule-$rule')), findsOneWidget);
        expect(find.byKey(ValueKey('r7fwd-toggle-$rule')), findsOneWidget);
        expect(find.byKey(ValueKey('r7fwd-menu-$rule')), findsOneWidget);
      }
      expect(
        find.byKey(const ValueKey('r7fwd-session-select-bastion')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('r7fwd-other-bastion-hook-bastion-1')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('r7fwd-show-all')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('r7fwd-host-plain')), findsOneWidget);
      await forwarding.close(tester);
    });
  }

  testWidgets('empty logs and forwarding pages fit a phone at 1.5x text', (
    tester,
  ) async {
    final book = await _book(empty: true);
    await _pump(
      tester,
      () => SessionLogsPage(book: book),
      size: const Size(320, 1600),
      locale: const Locale('ru'),
      textScale: 1.5,
    );
    expect(find.byKey(const ValueKey('session_logs_empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('session_logs_search')), findsNothing);
    book.dispose();

    final noHosts = _Forwarding(hosts: const []);
    await _pump(
      tester,
      () => SshForwardingPage(
        source: noHosts.source,
        controller: noHosts.controller,
      ),
      size: const Size(320, 1600),
      locale: const Locale('ru'),
      textScale: 1.5,
    );
    expect(find.byKey(const ValueKey('r7fwd-empty')), findsOneWidget);
    await noHosts.close(tester);

    final noRules = _Forwarding(
      hosts: [
        for (final host in _hosts) host.copyWith(portForwardProfiles: const []),
      ],
    );
    await _pump(
      tester,
      () => SshForwardingPage(
        source: noRules.source,
        controller: noRules.controller,
      ),
      size: const Size(320, 1600),
      locale: const Locale('ru'),
      textScale: 1.5,
    );
    expect(find.byKey(const ValueKey('r7fwd-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('r7fwd-new-rule')), findsOneWidget);
    await noRules.close(tester);
  });

  testWidgets('log filters count the rows they would show', (tester) async {
    final book = await _book();
    await _pump(
      tester,
      () => SessionLogsPage(book: book),
      size: const Size(1280, 1200),
      locale: const Locale('en'),
    );
    String count(String filter) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey('session_logs_filter_$filter')),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Text &&
                  RegExp(r'^\d+$').hasMatch(widget.data ?? ''),
            ),
          ),
        )
        .data!;
    expect(
      [
        for (final f in ['all', 'active', 'failed', 'closed']) count(f),
      ],
      ['5', '1', '1', '3'],
    );
    expect(find.text('Keeps the latest 20 transcripts'), findsOneWidget);
    expect(find.text('Up to 24 KiB each'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('session_logs_search')),
      'grafana',
    );
    await tester.pump();
    expect(
      [
        for (final f in ['all', 'active', 'failed', 'closed']) count(f),
      ],
      ['1', '0', '0', '1'],
    );

    // Nothing failed matches: the no-match row offers the way back.
    await tester.tap(find.byKey(const ValueKey('session_logs_filter_failed')));
    await tester.pump();
    expect(find.byKey(const ValueKey('session_logs_empty')), findsOneWidget);
    await tester.tap(find.text('Clear search and filter'));
    await tester.pump();
    expect(find.byKey(const ValueKey('session_logs_empty')), findsNothing);
    expect(find.byKey(const ValueKey('session_log_failed')), findsOneWidget);
    expect(count('all'), '5');
    book.dispose();
  });

  testWidgets('forwarding rules show their route in monospace and the '
      'summary on the toolbar', (tester) async {
    final forwarding = _Forwarding();
    await _pump(
      tester,
      () => SshForwardingPage(
        source: forwarding.source,
        controller: forwarding.controller,
      ),
      size: const Size(1280, 1400),
      locale: const Locale('en'),
    );
    final route = tester.widget<Text>(
      find.text('127.0.0.1:15432 → replica.db.internal.example.test:5432'),
    );
    expect(route.style?.fontFamily, 'monospace');
    expect(find.text('0.0.0.0:1080'), findsOneWidget);
    expect(find.byKey(const ValueKey('r7fwd-summary')), findsOneWidget);
    expect(find.text('4 rules on 2 hosts · 0 running'), findsOneWidget);
    expect(find.text('Local (-L)'), findsOneWidget);
    expect(find.text('Remote (-R)'), findsNWidgets(2));
    await forwarding.close(tester);
  });
}
