import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/storage/session_reconnect_store.dart';
import 'package:aterm_client/telnet/telnet_transport.dart';
import 'package:aterm_client/terminal/connect_progress.dart';
import 'package:aterm_client/terminal/session_reconnect_policy.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

import 'support/l10n_fixture.dart';
import 'support/settings_navigation.dart';

// Signed-in workspace: a dropped SSH or Telnet tab keeps its terminal under
// the "Connection lost" card, which counts down the automatic reconnect.

const _vault = '11111111-1111-4111-8111-111111111111';
const _alpha = HostRecord(
  id: 'host-alpha',
  name: 'Alpha host',
  address: 'alpha.example.test',
  username: 'tester',
  credentialId: 'credential-reconnect',
);
const _switch = HostRecord(
  id: 'host-switch',
  name: 'Lab switch',
  address: '192.0.2.30',
  port: 2323,
  protocol: HostProtocol.telnet,
);

const _restore = ValueKey('session_restore_connection');
const _automatic = ValueKey('session_recovery_automatic');
const _countdown = ValueKey('session_recovery_countdown');
const _gaveUp = ValueKey('session_recovery_gave_up');
const _overlayClose = ValueKey('session_recovery_close');
final _pane = find.byKey(const ValueKey('connect_progress_pane'));

void main() {
  useAppLocaleFixture('en');

  late SessionReconnectController policy;
  late MemorySessionReconnectStore store;

  setUp(() async {
    store = MemorySessionReconnectStore();
    policy = SessionReconnectController();
    await policy.load(store);
    SessionReconnectController.debugInstance = policy;
  });
  tearDown(() => SessionReconnectController.debugInstance = null);

  WorkspaceTabBar tabBar(WidgetTester tester) =>
      tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
  List<String> sessionTabs(WidgetTester tester) => [
    for (final tab in tabBar(tester).tabs)
      if (!tab.isHome) tab.title,
  ];
  String? text(WidgetTester tester, Key key) {
    final found = find.byKey(key);
    return found.evaluate().isEmpty ? null : tester.widget<Text>(found).data;
  }

  /// Seconds left on the card's countdown, or null when none is shown.
  int? secondsLeft(WidgetTester tester) {
    final match = RegExp(
      r'^Stops trying in (\d+):(\d\d)$',
    ).firstMatch(text(tester, _countdown) ?? '');
    return match == null
        ? null
        : int.parse(match.group(1)!) * 60 + int.parse(match.group(2)!);
  }

  Terminal shownTerminal(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal;
  String screen(WidgetTester tester) {
    final terminal = shownTerminal(tester);
    return [
      for (var i = 0; i < terminal.buffer.lines.length; i++)
        terminal.buffer.lines[i].getText(),
    ].join('\n');
  }

  /// The interrupted tab shows its own terminal under the card, never the
  /// "Secure terminal workspace" welcome pane or the connect progress pane.
  void expectTerminalWithCard(WidgetTester tester, Terminal terminal) {
    expect(find.text('Secure terminal workspace'), findsNothing);
    expect(find.text('SSH connection failed'), findsNothing);
    expect(_pane, findsNothing);
    expect(find.byType(TerminalView), findsOneWidget);
    expect(shownTerminal(tester), same(terminal));
    expect(find.text('Connection lost'), findsOneWidget);
    expect(find.byKey(_restore).hitTestable(), findsOneWidget);
  }

  testWidgets('a dropped SSH tab keeps its terminal under the card, which '
      'counts down; the attempts stop at the limit and manual restore still '
      'works', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final fixture = await _Fixture.create();
    try {
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('host_connect_host-alpha')));
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, 1);
      final tab = fixture.app.activeTerminalTab!;
      final first = _Connection();
      fixture.attempts[0].result.complete(first);
      await tester.pump();
      await tester.pump();
      expect(tab.state, 'connected');
      expect(fixture.app.terminalTabs, [tab], reason: 'one tab, not split');
      first.emit('uptime: 41 days\r\n');
      await tester.pump();
      final terminal = shownTerminal(tester);
      expect(screen(tester), contains('uptime: 41 days'));
      expect(find.text('Connection lost'), findsNothing);

      // The server ends the session.
      await first.end();
      await tester.pump();
      expect(tab.state, 'disconnected');
      expect(tab.connection, isNull);
      expectTerminalWithCard(tester, terminal);
      expect(screen(tester), contains('uptime: 41 days'), reason: 'scrollback');
      expect(
        text(tester, _automatic),
        'Reconnecting automatically, next attempt in 5 s',
      );
      expect(text(tester, _countdown), 'Stops trying in 1:00');
      expect(find.byKey(_gaveUp), findsNothing);
      expect(find.byKey(_overlayClose), findsOneWidget);

      // The countdown runs down while it waits for the next attempt.
      await tester.pump(const Duration(seconds: 2));
      expect(text(tester, _countdown), 'Stops trying in 0:58');
      expect(
        text(tester, _automatic),
        'Reconnecting automatically, next attempt in 3 s',
      );
      expect(fixture.attempts, hasLength(1), reason: 'not before 5 seconds');
      await tester.pump(const Duration(milliseconds: 2999));
      expect(fixture.attempts, hasLength(1));

      // 5 seconds after the drop the first automatic attempt starts, in the
      // same tab and with the terminal still shown.
      await tester.pump(const Duration(milliseconds: 1));
      await fixture.pumpUntilAttempts(tester, 2);
      expect(tab.state, 'connecting');
      expect(fixture.app.terminalTabs, [tab]);
      expectTerminalWithCard(tester, terminal);
      expect(text(tester, _automatic), 'Reconnecting automatically');
      expect(secondsLeft(tester), inInclusiveRange(52, 55));
      expect(
        tester.widget<ButtonStyleButton>(find.byKey(_restore)).onPressed,
        isNull,
        reason: 'an attempt is running',
      );

      // It fails: still the terminal, still counting down.
      fixture.attempts[1].result.completeError(
        StateError('The SSH server refused the connection.'),
      );
      await tester.pump();
      await tester.pump();
      expect(tab.state, 'failed');
      expectTerminalWithCard(tester, terminal);
      expect(screen(tester), contains('uptime: 41 days'));
      expect(text(tester, _automatic), startsWith('Reconnecting automatically'));
      final afterFirstFailure = secondsLeft(tester)!;
      expect(afterFirstFailure, inInclusiveRange(51, 55));

      // Every further attempt fails until the minute is used up.
      var last = afterFirstFailure;
      for (var i = 0; i < 80 && find.byKey(_gaveUp).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
        await fixture.failPending(tester);
        final left = secondsLeft(tester);
        if (left != null) {
          expect(left, lessThanOrEqualTo(last), reason: 'only counts down');
          last = left;
        }
      }
      expect(last, lessThanOrEqualTo(3), reason: 'it counted down to the end');
      expect(
        text(tester, _gaveUp),
        "Couldn't restore the connection automatically.",
      );
      expect(find.byKey(_automatic), findsNothing);
      expect(find.byKey(_countdown), findsNothing);
      expectTerminalWithCard(tester, terminal);
      expect(find.byKey(_overlayClose).hitTestable(), findsOneWidget);
      // Why it fails is written into the terminal once, not per attempt.
      final reason = tab.errorMessage!;
      expect(reason, isNotEmpty);
      final reasonStart = reason.substring(0, reason.length.clamp(0, 24));
      expect(
        RegExp(RegExp.escape(reasonStart)).allMatches(screen(tester)).length,
        1,
        reason: screen(tester),
      );
      final automaticAttempts = fixture.attempts.length - 1;
      expect(
        automaticAttempts,
        inInclusiveRange(8, 12),
        reason: 'about one attempt every 5 seconds for a minute',
      );

      // Given up: nothing is tried any more.
      await tester.pump(const Duration(minutes: 5));
      await fixture.failPending(tester);
      expect(fixture.attempts, hasLength(automaticAttempts + 1));
      expect(tab.recovery!.expired, isTrue);
      expectTerminalWithCard(tester, terminal);

      // Manual restore still works and brings the same tab back.
      await tester.tap(find.byKey(_restore));
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, automaticAttempts + 2);
      final second = _Connection();
      fixture.attempts.last.result.complete(second);
      await tester.pump();
      await tester.pump();
      expect(tab.state, 'connected');
      expect(fixture.app.terminalTabs, [tab]);
      expect(find.text('Connection lost'), findsNothing);
      expect(shownTerminal(tester), same(terminal));
      expect(screen(tester), contains('uptime: 41 days'));
      await tester.pump(const Duration(minutes: 2));
      expect(fixture.attempts, hasLength(automaticAttempts + 2));

      // A later drop starts with the full minute again; Close ends the tab.
      await second.end();
      await tester.pump();
      expectTerminalWithCard(tester, terminal);
      expect(text(tester, _countdown), 'Stops trying in 1:00');
      await tester.tap(find.byKey(_overlayClose));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sessionTabs(tester), isEmpty);
      expect(fixture.app.terminalTabs, isEmpty);
      await tester.pump(const Duration(minutes: 2));
      expect(fixture.attempts, hasLength(automaticAttempts + 2));
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('the configured interval and "no limit" apply; switching '
      'automatic reconnect off stops it', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await policy.select(
      const SessionReconnectPolicy(
        intervalSeconds: 10,
        limitSeconds: sessionReconnectNoLimit,
      ),
    );
    final fixture = await _Fixture.create();
    try {
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('host_connect_host-alpha')));
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, 1);
      final tab = fixture.app.activeTerminalTab!;
      final first = _Connection();
      fixture.attempts[0].result.complete(first);
      await tester.pump();
      await tester.pump();
      final terminal = shownTerminal(tester);
      await first.end();
      await tester.pump();
      expectTerminalWithCard(tester, terminal);
      expect(
        text(tester, _automatic),
        'Reconnecting automatically, next attempt in 10 s',
      );
      expect(find.byKey(_countdown), findsNothing, reason: 'no limit');
      await tester.pump(const Duration(milliseconds: 9999));
      expect(fixture.attempts, hasLength(1));
      await tester.pump(const Duration(milliseconds: 1));
      await fixture.pumpUntilAttempts(tester, 2);

      // Far beyond any limit it is still trying.
      for (var i = 0; i < 30; i++) {
        await fixture.failPending(tester);
        await tester.pump(const Duration(seconds: 10));
      }
      await fixture.failPending(tester);
      expect(fixture.attempts.length, greaterThan(20));
      expect(find.byKey(_gaveUp), findsNothing);
      expect(tab.recovery!.expired, isFalse);
      expectTerminalWithCard(tester, terminal);
      expect(find.byKey(_automatic), findsOneWidget);

      // Switched off in settings: the card offers the manual restore only.
      await policy.setAutomatic(false);
      await tester.pump();
      final attempts = fixture.attempts.length;
      expectTerminalWithCard(tester, terminal);
      expect(find.byKey(_automatic), findsNothing);
      expect(find.byKey(_countdown), findsNothing);
      expect(find.byKey(_gaveUp), findsNothing);
      await tester.pump(const Duration(minutes: 5));
      expect(fixture.attempts, hasLength(attempts));
      expect(store.value, '0,10,0');
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('a user disconnect keeps the terminal with manual restore only', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final fixture = await _Fixture.create();
    try {
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('host_connect_host-alpha')));
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, 1);
      final tab = fixture.app.activeTerminalTab!;
      fixture.attempts[0].result.complete(_Connection());
      await tester.pump();
      await tester.pump();
      final terminal = shownTerminal(tester);

      await tester.runAsync(() => fixture.app.disconnectTerminalTab(tab.id));
      await tester.pump();
      expect(tab.state, 'disconnected');
      expectTerminalWithCard(tester, terminal);
      expect(find.byKey(_automatic), findsNothing);
      expect(find.byKey(_countdown), findsNothing);
      expect(find.byKey(_gaveUp), findsNothing);
      await tester.pump(const Duration(minutes: 3));
      expect(fixture.attempts, hasLength(1), reason: 'no automatic retry');
      expect(find.byKey(_gaveUp), findsNothing);
      expect(tab.recovery!.expired, isFalse);
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('a tab that never connected keeps its failed surface and is '
      'not retried', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final fixture = await _Fixture.create();
    try {
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('host_connect_host-alpha')));
      await tester.pump();
      await fixture.pumpUntilAttempts(tester, 1);
      final tab = fixture.app.activeTerminalTab!;
      fixture.attempts[0].result.completeError(
        StateError('The SSH server refused the connection.'),
      );
      await tester.pump();
      await tester.pump();
      expect(tab.state, 'failed');
      expect(tab.recovery!.everConnected, isFalse);
      expect(tab.connectProgress.phase, ConnectPhase.failed);
      expect(_pane.hitTestable(), findsOneWidget);
      expect(find.text("Couldn't connect to Alpha host"), findsOneWidget);
      expect(
        find.byKey(const ValueKey('connect_progress_retry')).hitTestable(),
        findsOneWidget,
      );
      expect(find.text('Secure terminal workspace'), findsNothing);
      expect(find.byType(TerminalView).hitTestable(), findsNothing);
      expect(find.byKey(_restore).hitTestable(), findsNothing);
      expect(find.byKey(_countdown), findsNothing);

      await tester.pump(const Duration(minutes: 3));
      expect(fixture.attempts, hasLength(1));
      expect(_pane.hitTestable(), findsOneWidget);
      expect(find.byKey(_gaveUp), findsNothing);
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('a dropped Telnet tab keeps its terminal under the card and '
      'reconnects after the interval', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final fixture = await _Fixture.create();
    final channels = <_TelnetChannel>[];
    var refuse = false;
    fixture.app.telnetConnectorForTesting = (host, port) async {
      if (refuse) throw StateError('refused');
      final channel = _TelnetChannel();
      channels.add(channel);
      return channel;
    };
    Future<void> pumpUntil(bool Function() condition) async {
      for (var i = 0; i < 100 && !condition(); i++) {
        await tester.pump(const Duration(milliseconds: 10));
        if (!condition()) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)),
          );
        }
      }
      expect(condition(), isTrue);
      await tester.pump();
    }

    try {
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('host_connect_host-switch')));
      await tester.pump();
      await pumpUntil(() => channels.length == 1);
      final tab = fixture.app.activeTerminalTab!;
      await pumpUntil(() => tab.state == 'connected');
      channels[0].emit('Switch> show version\r\n'.codeUnits);
      await pumpUntil(() => screen(tester).contains('show version'));
      final terminal = shownTerminal(tester);
      expect(find.text('Connection lost'), findsNothing);

      // The device closes the connection.
      refuse = true;
      await channels[0].incoming.close();
      await pumpUntil(() => tab.state == 'disconnected');
      expect(tab.telnet, isNull);
      expectTerminalWithCard(tester, terminal);
      expect(screen(tester), contains('show version'), reason: 'scrollback');
      expect(text(tester, _automatic), startsWith('Reconnecting automatically'));
      final left = secondsLeft(tester)!;
      expect(left, inInclusiveRange(58, 60));

      // Attempts that fail keep the terminal and the countdown.
      await tester.pump(const Duration(seconds: 12));
      await pumpUntil(() => tab.state == 'failed');
      expect(channels, hasLength(1));
      expectTerminalWithCard(tester, terminal);
      expect(secondsLeft(tester), lessThan(left - 10));
      expect(find.byKey(_gaveUp), findsNothing);
      expect(
        'unencrypted'.allMatches(screen(tester)).length,
        1,
        reason: 'the plaintext notice is not repeated for every attempt',
      );

      // The device is back: the next attempt reconnects the same tab.
      refuse = false;
      await tester.pump(const Duration(seconds: 5));
      await pumpUntil(() => channels.length == 2);
      await pumpUntil(() => tab.state == 'connected');
      expect(find.text('Connection lost'), findsNothing);
      expect(shownTerminal(tester), same(terminal));
      expect(screen(tester), contains('show version'));
      expect(fixture.app.terminalTabs, [tab]);

      // Dropped for longer than the limit: given up, manual restore remains.
      refuse = true;
      await channels[1].incoming.close();
      await pumpUntil(() => tab.state == 'disconnected');
      for (var i = 0; i < 80 && find.byKey(_gaveUp).evaluate().isEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pump();
      expect(
        text(tester, _gaveUp),
        "Couldn't restore the connection automatically.",
      );
      expectTerminalWithCard(tester, terminal);
      refuse = false;
      await tester.pump(const Duration(minutes: 3));
      expect(channels, hasLength(2), reason: 'no automatic attempt any more');
      await tester.tap(find.byKey(_restore));
      await tester.pump();
      await pumpUntil(() => channels.length == 3);
      await pumpUntil(() => tab.state == 'connected');
      expect(find.text('Connection lost'), findsNothing);
      expect(shownTerminal(tester), same(terminal));
    } finally {
      await fixture.cleanup(tester);
    }
  });

  testWidgets('cloud settings show Automatic reconnect next to Scrollback and '
      'store the choices', (tester) async {
    final fixture = await _Fixture.create(page: WorkspacePage.settings);
    try {
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      await tester.pumpWidget(_shell(fixture.app));
      await tester.pumpAndSettle();
      final setting = find.byKey(const ValueKey('session_reconnect_setting'));
      final toggle = find.byKey(const ValueKey('session_reconnect_switch'));
      for (final width in [1280.0, 390.0]) {
        await tester.binding.setSurfaceSize(Size(width, 900));
        await tester.pumpAndSettle();
        await openSettingsCategory(tester, 'appearance');
        await tester.pumpAndSettle();
        expect(setting, findsOneWidget, reason: 'width $width');
        expect(
          find.byKey(const ValueKey('terminal_scrollback_setting')),
          findsOneWidget,
          reason: 'same category as the other terminal behaviour settings',
        );
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'width $width');
        expect(
          find.descendant(
            of: setting,
            matching: find.text('Automatic reconnect'),
          ),
          findsOneWidget,
        );
      }

      final interval = find.byKey(
        const ValueKey('session_reconnect_interval_dropdown'),
      );
      await tester.ensureVisible(interval);
      await tester.pumpAndSettle();
      await tester.tap(interval);
      await tester.pumpAndSettle();
      await tester.tap(find.text('15 seconds').last);
      await tester.pumpAndSettle();
      final limit = find.byKey(
        const ValueKey('session_reconnect_limit_dropdown'),
      );
      await tester.ensureVisible(limit);
      await tester.pumpAndSettle();
      await tester.tap(limit);
      await tester.pumpAndSettle();
      await tester.tap(find.text('No limit').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        policy.policy,
        const SessionReconnectPolicy(intervalSeconds: 15, limitSeconds: 0),
      );
      expect(store.value, '1,15,0');

      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(policy.policy.automatic, isFalse);
      expect(store.value, '0,15,0');

      // The next start reads what was stored.
      final relaunched = SessionReconnectController();
      await relaunched.load(store);
      expect(relaunched.policy, policy.policy);
    } finally {
      await fixture.cleanup(tester);
    }
  });
}

Widget _shell(AppController app) => MaterialApp(
  theme: buildAppTheme(),
  home: AppShell(controller: app),
);

class _Attempt {
  _Attempt(this.host, this.cancellation);
  final String host;
  final SshConnectCancellation cancellation;
  final result = Completer<SshConnection>();
}

class _WorkspaceController extends AppController {
  _WorkspaceController({
    required super.sodium,
    required super.database,
    required super.secureStore,
    super.sshConnectorWithCancellationForTesting,
  });
  @override
  bool get isInstanceAdmin => true;
}

class _Fixture {
  _Fixture(this.app, this.database, this.attempts);
  final AppController app;
  final ClientDatabase database;
  final List<_Attempt> attempts;

  Future<void> pumpUntilAttempts(WidgetTester tester, int count) async {
    for (var i = 0; i < 100 && attempts.length < count; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      if (attempts.length < count) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
      }
    }
    expect(attempts, hasLength(count));
    await tester.pump();
  }

  /// Lets a started reconnect reach the connector and makes it fail.
  Future<void> failPending(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      final tab = app.terminalTabs.firstOrNull;
      if (tab == null || tab.state != 'connecting') break;
      final pending = attempts.where((a) => !a.result.isCompleted).toList();
      if (pending.isNotEmpty) {
        for (final attempt in pending) {
          attempt.result.completeError(
            StateError('The SSH server refused the connection.'),
          );
        }
        await tester.pump();
        await tester.pump();
        continue;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  static Future<_Fixture> create({
    WorkspacePage page = WorkspacePage.hosts,
  }) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final identity = DeviceIdentity.create(sodium);
    final attempts = <_Attempt>[];
    final app =
        _WorkspaceController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
            sshConnectorWithCancellationForTesting:
                ({
                  required host,
                  required credential,
                  required verifyHostKey,
                  required jumpHops,
                  required cancellation,
                  required onUserInfoRequest,
                }) {
                  final attempt = _Attempt(host.address, cancellation);
                  attempts.add(attempt);
                  return attempt.result.future;
                },
          )
          ..api = ApiClient(baseUrl: 'https://server.test')
          ..session = AuthSession(
            accountId: 'account-reconnect',
            accessToken: 'test',
            expiresIn: 3600,
            refreshToken: 'test',
            deviceId: identity.deviceId,
            vaults: const [],
          )
          ..identity = identity
          ..stage = ClientStage.workspace
          ..page = page
          ..activeVault = const VaultDescriptor(
            id: _vault,
            role: 'owner',
            activeKeyEpoch: '1',
            membershipVersion: '1',
            canWrite: true,
          )
          ..vaults.add(
            const VaultDescriptor(
              id: _vault,
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
              canWrite: true,
            ),
          )
          ..credentials.add(
            const CredentialRecord(
              id: 'credential-reconnect',
              name: 'Credential',
              username: 'tester',
              secret: 'ephemeral-test-secret',
            ),
          )
          ..hosts.addAll([_alpha, _switch]);
    return _Fixture(app, database, attempts);
  }

  Future<void> cleanup(WidgetTester tester) async {
    for (final attempt in attempts) {
      if (!attempt.result.isCompleted) {
        attempt.result.completeError(const SshConnectCancelledException());
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => app.disconnectAllTerminalTabs());
    app.dispose();
    await tester.runAsync(() => database.close());
    await tester.binding.setSurfaceSize(null);
  }
}

class _Connection implements SshConnection {
  final _output = StreamController<String>.broadcast(sync: true);

  @override
  Stream<String> get output => _output.stream;

  void emit(String text) => _output.add(text);

  /// The remote side closes the session.
  Future<void> end() => _output.close();

  @override
  void input(String text) {}

  @override
  void resize(int columns, int rows) {}

  @override
  Future<void> close() async {
    if (!_output.isClosed) await _output.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TelnetChannel implements TelnetByteChannel {
  final StreamController<Uint8List> incoming = StreamController<Uint8List>();
  bool closed = false;

  void emit(List<int> bytes) => incoming.add(Uint8List.fromList(bytes));

  @override
  Stream<Uint8List> get stream => incoming.stream;

  @override
  void add(Uint8List bytes) {}

  @override
  Future<void> close() async {
    closed = true;
    if (!incoming.isClosed) unawaited(incoming.close());
  }
}
