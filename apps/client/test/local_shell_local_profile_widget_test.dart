import 'dart:io';

import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:aterm_client/console/local_console.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/platform/native_coordination.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:xterm/xterm.dart';

import 'support/fake_local_console.dart';
import 'support/l10n_fixture.dart';

const _password = 'correct horse battery staple';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  useAppLocaleFixture('en');

  late Directory directory;
  late LocalProfileCatalog catalog;
  late LocalProfileService profileService;
  late VaultCrypto crypto;
  late LocalProfileRecord profileRecord;
  late List<LocalVaultDatabase> openedDatabases;
  late FakeConsoleFactory consoles;

  setUpAll(() async {
    crypto = VaultCrypto(await SodiumSumoInit.init());
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('atermius-local-shell-');
    coordinationDirectory = () async =>
        Directory('${directory.path}/coordination');
    catalog = LocalProfileCatalog.forTesting(
      NativeDatabase(File('${directory.path}/catalog.sqlite')),
    );
    profileService = LocalProfileService(catalog: catalog, crypto: crypto);
    final profile = await profileService.create(password: _password);
    profileRecord = profile.record;
    final seed = await LocalVaultDatabase.openForTesting(
      executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
      profileId: profileRecord.profileId,
      localDataDomainId: profileRecord.localDataDomainId,
      localVaultId: profileRecord.localVaultId,
    );
    await seed.close();
    await profile.lock();
    openedDatabases = [];
    consoles = FakeConsoleFactory();
    localProfileConsoleOpenerForTesting = consoles.call;
  });

  tearDown(() async {
    localProfileConsoleOpenerForTesting = null;
    for (final database in openedDatabases.reversed) {
      try {
        await database.close();
      } on Object {
        // Already closed by the flow.
      }
    }
    await catalog.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }
    await tester.pumpAndSettle();
  }

  Future<void> unlock(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: LocalProfileFlow(
          catalog: catalog,
          service: profileService,
          crypto: crypto,
          onExit: () {},
          quarantineRegistry: DatabaseQuarantineRegistry(),
          databaseFactory: (profile, {required mode}) async {
            final record = profile.record;
            final database = await LocalVaultDatabase.openForTesting(
              executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
              profileId: record.profileId,
              localDataDomainId: record.localDataDomainId,
              localVaultId: record.localVaultId,
              mode: mode,
            );
            openedDatabases.add(database);
            return database;
          },
        ),
      ),
    );
    await settle(tester);
    await tester.tap(
      find.byKey(ValueKey('local_profile_${profileRecord.profileId}')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('local_profile_unlock_password')),
      _password,
    );
    await tester.tap(find.byKey(const ValueKey('local_profile_unlock_button')));
    for (var attempt = 0; attempt < 200; attempt++) {
      await tester.pump(const Duration(milliseconds: 50));
      final bars = find.byType(WorkspaceTabBar).evaluate();
      if (bars.isNotEmpty &&
          flattenWorkspaceActions(
            (bars.single.widget as WorkspaceTabBar).homeMenuActions,
          ).any((a) => a.id == 'local_new_console')) {
        await settle(tester);
        return;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .whereType<String>()
        .take(40)
        .join(' | ');
    fail('local profile did not unlock: $texts');
  }

  Future<void> typeInto(WidgetTester tester, String id, String text) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('session-pane-$id')),
        matching: find.byType(TerminalView),
      ),
    );
    await tester.pump();
    tester.testTextInput.updateEditingValue(TextEditingValue(text: text));
    await tester.pump();
  }

  testWidgets(
    'local Profile: plus-menu shell, lone split = new PTY, per-pane input, duplicate, close',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await unlock(tester);
      WorkspaceTabBar bar() =>
          tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
      final actions = flattenWorkspaceActions(bar().homeMenuActions);
      expect(actions.any((a) => a.id == 'local_shell_options'), isTrue);
      consoles.nextCwd = '/home/u/project';
      await tester.runAsync(
        () async =>
            actions.firstWhere((a) => a.id == 'local_new_console').run(),
      );
      await settle(tester);
      expect(consoles.opened.single.shell, LocalShellLaunch.systemDefault);
      final shellId = bar().selectedId;
      expect(
        bar().tabs.firstWhere((t) => t.id == shellId).title,
        'Local Console',
      );

      bar().onSplit!(shellId, Axis.horizontal);
      await settle(tester);
      expect(consoles.opened, hasLength(2));
      final original = consoles.opened.first;
      final copy = consoles.opened.last;
      expect(copy.shell?.kind, LocalShellKind.system);
      expect(copy.shell?.workingDirectory, '/home/u/project');
      final layout = tester
          .widget<SessionWorkspaceView>(find.byType(SessionWorkspaceView))
          .controller;
      expect(layout.root, isA<SessionWorkspaceSplit>());
      final copyId = layout.sessionIds.firstWhere((id) => id != shellId);
      expect(find.byType(TerminalView), findsNWidgets(2));
      expect(original.resizes, isNotEmpty);
      expect(copy.resizes, isNotEmpty);

      await typeInto(tester, shellId, 'left');
      await typeInto(tester, copyId, 'right');
      expect(original.inputs.join(), 'left');
      expect(copy.inputs.join(), 'right');

      // Duplicate (tab menu) is a third independent PTY with the same shell.
      bar().onDuplicate!(copyId);
      await settle(tester);
      expect(consoles.opened, hasLength(3));
      expect(consoles.opened.last.shell?.kind, LocalShellKind.system);

      bar().onClose(copyId);
      await settle(tester);
      expect(copy.closed, isTrue);
      expect(original.closed, isFalse);
      expect(consoles.opened.last.closed, isFalse);

      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 40 && consoles.opened.any((c) => !c.closed); i++) {
        await settle(tester);
      }
      for (final console in consoles.opened) {
        expect(console.closed, isTrue, reason: 'no PTY may outlive the flow');
      }
    },
  );

  testWidgets('local Profile: serial console duplicate/split stays serial', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await unlock(tester);
    WorkspaceTabBar bar() =>
        tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
    await tester.tap(
      find.byKey(const ValueKey('workspace_host_search_button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('local_host_search')),
      'console COM3 -b 9600',
    );
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);
    expect(consoles.opened.single.serialPort, 'COM3');
    final serialId = bar().selectedId;
    bar().onSplit!(serialId, Axis.vertical);
    await settle(tester);
    bar().onDuplicate!(serialId);
    await settle(tester);
    expect(consoles.opened, hasLength(3));
    for (final console in consoles.opened) {
      expect(
        (console.serialPort, console.baudRate, console.shell),
        ('COM3', 9600, null),
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });

  testWidgets(
    'local Profile: console Stage-2 burst flushes before exit banner and retains post-exitCode tail before EOF',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await unlock(tester);
      final bar = tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
      await tester.runAsync(
        () async =>
            flattenWorkspaceActions(bar.homeMenuActions)
                .firstWhere((a) => a.id == 'local_new_console')
                .run(),
      );
      await settle(tester);

      final console = consoles.opened.single;
      final terminal = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .terminal;
      String dump() => [
        for (var i = 0; i < terminal.buffer.lines.length; i++)
          terminal.buffer.lines[i].getText(),
      ].join('\n');

      // 先推送 20KiB 打满 Stage-1 预算，再推入末行使其进入 Stage-2 帧缓冲，随后模拟
      // 真实 PTY 的 exitCode 先于 stdout 尾包与 onDone 到达。
      await tester.runAsync(() async {
        console.emit('${'L' * 20000}\r\n');
        for (var i = 0; i < 4; i++) {
          await Future<void>.microtask(() {});
        }
        console.emit('LOCAL_CONSOLE_PRE_EXIT_TAIL\r\n');
        for (var i = 0; i < 4; i++) {
          await Future<void>.microtask(() {});
        }
        console.completeExitCodeOnly(0);
        await pumpEventQueue();
      });
      await tester.pump();

      final afterExit = dump();
      final prePos = afterExit.indexOf('LOCAL_CONSOLE_PRE_EXIT_TAIL');
      final exitPos = afterExit.indexOf('exited');
      expect(prePos, greaterThanOrEqualTo(0), reason: '退出前缓冲末行不得丢失');
      expect(exitPos, greaterThan(prePos), reason: '退出提示必须排在已缓冲末行之后');

      await tester.runAsync(() async {
        console.emit('LOCAL_CONSOLE_POST_EXIT_TAIL\r\n');
        await console.finishOutput();
        await pumpEventQueue();
      });
      await tester.pump();

      expect(
        dump(),
        contains('LOCAL_CONSOLE_POST_EXIT_TAIL'),
        reason: 'exitCode 先于 EOF 到达时的晚到 stdout 尾包不得被吞掉',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    },
  );

  testWidgets('local Profile: an Android USB serial Console opens only after '
      'startup and shows why it could not', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final started = <_StartupConsole>[];
    var fail = true;
    localProfileConsoleOpenerForTesting =
        ({LocalShellLaunch? shell, String? serialPort, int baudRate = 115200}) {
          final console = _StartupConsole(
            serialPort: serialPort,
            baudRate: baudRate,
            failure: fail ? 'USB access to the adapter was denied.' : null,
          );
          started.add(console);
          return console;
        };
    await unlock(tester);
    WorkspaceTabBar bar() =>
        tester.widget<WorkspaceTabBar>(find.byType(WorkspaceTabBar));
    Future<void> quickConnect(String text) async {
      await tester.tap(
        find.byKey(const ValueKey('workspace_host_search_button')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('local_host_search')),
        text,
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await settle(tester);
    }

    await quickConnect('console usb:1A86:7523 -b 9600');
    expect(started.single.serialPort, 'usb:1a86:7523');
    expect(started.single.closed, isTrue);
    expect(
      bar().tabs.where((t) => t.title == 'usb:1a86:7523 · 9600'),
      hasLength(1),
    );
    expect(
      find.textContaining('USB access to the adapter was denied.'),
      findsWidgets,
    );

    fail = false;
    await quickConnect('console usb:1a86:7523#1');
    expect(started.last.closed, isFalse);
    expect(started.last.outputHasListener, isTrue);
    expect(
      bar().tabs.where((t) => t.title == 'usb:1a86:7523#1 · 115200'),
      hasLength(1),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
  });
}

/// Fake Android USB serial console: [ready] fails with [failure] or succeeds.
class _StartupConsole extends FakeLocalConsole implements LocalConsoleStartup {
  _StartupConsole({super.serialPort, super.baudRate, String? failure})
    : ready = failure == null
          ? Future<void>.value()
          : Future<void>.error(LocalConsoleStartException(failure));

  @override
  final Future<void> ready;
}
