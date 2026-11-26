import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/mcp/mcp_access_policy_store.dart';
import 'package:aterm_client/mcp/mcp_notices.dart';
import 'package:aterm_client/mcp/mcp_service.dart';
import 'package:aterm_client/mcp/mcp_token_store.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/mcp_activity_panel.dart';
import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A service that reports a running listener without opening a port.
class _ListeningService extends McpService {
  _ListeningService()
    : super(
        policyStore: MemoryMcpAccessPolicyStore(),
        tokenStore: MemoryMcpTokenStore(),
      );

  bool listening = false;
  int stops = 0;

  @override
  bool get running => listening;

  @override
  Uri? get endpoint =>
      listening ? Uri.parse('http://127.0.0.1:8765/mcp') : null;

  @override
  Future<void> stop() {
    stops++;
    listening = false;
    return super.stop();
  }
}

McpService _service({bool listening = false}) {
  final service = listening
      ? _ListeningService()
      : McpService(
          policyStore: MemoryMcpAccessPolicyStore(),
          tokenStore: MemoryMcpTokenStore(),
        );
  // Attaching stops a listener; the fake starts listening afterwards.
  service.attach(_workspace());
  if (service is _ListeningService) {
    service
      ..listening = true
      ..stops = 0;
  }
  return service;
}

final _button = find.byKey(const ValueKey('mcp_activity_button'));
final _spinner = find.byKey(const ValueKey('mcp_activity_spinner'));
final _panel = find.byKey(const ValueKey('mcp_activity_panel'));

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1280, 800),
  TargetPlatform platform = TargetPlatform.windows,
  Brightness brightness = Brightness.dark,
  Locale locale = const Locale('en'),
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizationSetup.delegates,
      supportedLocales: AppLocalizationSetup.locales,
      theme: buildAppTheme(
        locale: locale,
        platform: platform,
        brightness: brightness,
      ),
      home: Scaffold(
        body: Align(alignment: Alignment.topRight, child: child),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('hidden while MCP is stopped and nothing was called', (
    tester,
  ) async {
    final service = _service();
    addTearDown(service.dispose);
    await _pump(tester, McpActivityButton(service: service));
    expect(_button, findsNothing);
  });

  testWidgets('shown while listening, even without calls', (tester) async {
    final service = _service(listening: true);
    addTearDown(service.dispose);
    await _pump(tester, McpActivityButton(service: service));
    expect(_button, findsOneWidget);
    expect(_spinner, findsNothing);
  });

  testWidgets('a running call shows progress and the tool, then stays for '
      'two minutes', (tester) async {
    final service = _service();
    addTearDown(service.dispose);
    await _pump(tester, McpActivityButton(service: service, showLabel: true));
    final end = service.debugBeginCall('ssh_exec', {
      'session_id': 's1',
      'command': 'uptime',
    });
    await tester.pump();
    expect(_button, findsOneWidget);
    expect(_spinner, findsOneWidget);
    expect(
      find.text('AI · Run a command (separate SSH channel)'),
      findsOneWidget,
    );
    expect(
      find.byTooltip(
        'AI is running Run a command (separate SSH channel) · '
        'web-01',
      ),
      findsOneWidget,
    );

    end(true, output: {'exit_code': 0});
    await tester.pump();
    expect(_spinner, findsNothing);
    expect(_button, findsOneWidget, reason: 'recent call');

    await tester.pump(const Duration(minutes: 1));
    expect(_button, findsOneWidget);
    await tester.pump(const Duration(minutes: 1, seconds: 1));
    expect(_button, findsNothing);
  });

  testWidgets('without room the running call is a ring around the icon', (
    tester,
  ) async {
    final service = _service();
    addTearDown(service.dispose);
    await _pump(tester, McpActivityButton(service: service));
    service.debugBeginCall('terminal_read', {'session_id': 's1'});
    await tester.pump();
    expect(_spinner, findsOneWidget);
    expect(find.byKey(const ValueKey('mcp_activity_label')), findsNothing);
    expect(tester.widget(_button), isA<IconButton>());
  });

  testWidgets('the panel lists calls with target, summary and outcome; '
      'tapping one focuses its session', (tester) async {
    final service = _service(listening: true);
    addTearDown(service.dispose);
    final focused = <String>[];
    var settings = 0;
    await _pump(
      tester,
      McpActivityButton(
        service: service,
        liveSessionIds: const {'s1'},
        onFocusSession: focused.add,
        onOpenSettings: () => settings++,
      ),
    );
    service.debugBeginCall('ssh_exec', {
      'session_id': 's1',
      'command': 'systemctl restart nginx',
    })(true, output: {'exit_code': 0});
    service.debugBeginCall('sftp_write_text', {
      'session_id': 'gone',
      'path': '/etc/motd',
      'text': 'top secret',
      'mode': 'create',
    })(false, error: 'session_unavailable');
    await tester.pump();

    await tester.tap(_button);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mcp_activity_popover')), findsOneWidget);
    expect(find.text('Listening on http://127.0.0.1:8765/mcp'), findsOneWidget);
    // The bearer token is shown in plain text next to the endpoint.
    final token = service.token;
    expect(token, isNotNull);
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('mcp_activity_token')),
          )
          .data,
      token,
    );
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('mcp_activity_copy_token')));
    await tester.pump();
    expect(clipboard, token);
    expect(find.text('systemctl restart nginx'), findsOneWidget);
    expect(find.text('/etc/motd · 10 bytes · mode=create'), findsOneWidget);
    expect(find.textContaining('top secret'), findsNothing);
    expect(
      find.text('Run a command (separate SSH channel) · web-01'),
      findsOneWidget,
    );
    expect(find.textContaining('exit 0'), findsOneWidget);
    expect(find.textContaining('Failed · session_unavailable'), findsOneWidget);
    // Newest first.
    final write = tester.getRect(
      find.byKey(const ValueKey('mcp_activity_entry_2')),
    );
    final exec = tester.getRect(
      find.byKey(const ValueKey('mcp_activity_entry_1')),
    );
    expect(write.top, lessThan(exec.top));
    // The popover hangs under the button, inside the window.
    final popover = tester.getRect(
      find.byKey(const ValueKey('mcp_activity_popover')),
    );
    expect(popover.right, lessThanOrEqualTo(1280));
    expect(popover.top, greaterThanOrEqualTo(tester.getRect(_button).bottom));

    // A call on a session that is not open here cannot be focused.
    await tester.tap(find.byKey(const ValueKey('mcp_activity_entry_2')));
    await tester.pump();
    expect(focused, isEmpty);

    await tester.tap(find.byKey(const ValueKey('mcp_activity_entry_1')));
    await tester.pumpAndSettle();
    expect(focused, ['s1']);
    expect(_panel, findsNothing, reason: 'focusing closes the panel');

    await tester.tap(_button);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mcp_activity_settings')));
    await tester.pumpAndSettle();
    expect(settings, 1);
    expect(_panel, findsNothing);

    await tester.tap(_button);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mcp_activity_stop')));
    await tester.pumpAndSettle();
    expect((service as _ListeningService).stops, 1);
    expect(find.byKey(const ValueKey('mcp_activity_empty')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mcp_activity_not_listening')),
      findsOneWidget,
    );
  });

  testWidgets('a narrow window opens the panel as a bottom sheet', (
    tester,
  ) async {
    final service = _service(listening: true);
    addTearDown(service.dispose);
    await _pump(
      tester,
      McpActivityButton(service: service),
      size: const Size(390, 844),
      platform: TargetPlatform.android,
      brightness: Brightness.light,
    );
    await tester.tap(_button);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('mcp_activity_empty')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mcp_activity_close')));
    await tester.pumpAndSettle();
    expect(_panel, findsNothing);
  });

  testWidgets('ui_notify messages show once, as plain text, and open the '
      'panel', (tester) async {
    final service = _service(listening: true);
    addTearDown(service.dispose);
    await _pump(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          McpActivityButton(service: service),
          // A second bar (another layout of the same window).
          McpActivityButton(service: service),
        ],
      ),
    );
    McpNotices.post(
      McpNotice('Deploy \u202efinished\x1b[31m', McpNoticeLevel.warning),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('AI: Deploy  finished [31m'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.byKey(const ValueKey('mcp_notice_warning')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mcp_notice_view')));
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('390 px top bar with a running call fits '
        '(${brightness.name})', (tester) async {
      final service = McpService.instance;
      final end = service.debugBeginCall('terminal_write', {
        'session_id': 'a',
        'text': 'make deploy-production-cluster-with-a-long-name\n',
      });
      addTearDown(() {
        end(true, output: {'sent': true});
        service.stop();
      });
      await _pump(
        tester,
        Column(
          children: [
            WorkspaceTabBar(
              tabs: const [
                WorkspaceTab(id: 'home', title: 'Hosts', isHome: true),
                WorkspaceTab(
                  id: 'a',
                  title: 'production-database-primary',
                  isConnected: true,
                ),
                WorkspaceTab(id: 'b', title: 'Beta'),
              ],
              selectedId: 'a',
              onSelect: (_) {},
              onClose: (_) {},
              onSearch: () {},
              onToggleTools: () {},
              homeMenuActions: [
                WorkspaceAction('add', 'Add host', Icons.add, () {}),
              ],
            ),
          ],
        ),
        size: const Size(390, 844),
        platform: TargetPlatform.android,
        brightness: brightness,
      );
      expect(tester.takeException(), isNull);
      expect(_button, findsOneWidget);
      expect(_spinner, findsOneWidget);
      expect(tester.getRect(_button).right, lessThanOrEqualTo(390));

      await tester.tap(_button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        find.text(r'make deploy-production-cluster-with-a-long-name\n'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final locale in AppLocalizationSetup.locales) {
    testWidgets('panel rows fit 390 px (${locale.languageCode})', (
      tester,
    ) async {
      final service = _service(listening: true);
      addTearDown(service.dispose);
      service.debugBeginCall(
        'ssh_exec',
        {'session_id': 's1', 'command': 'x' * 300},
        source: 'apple_intelligence_with_a_long_caller_name',
      )(false, error: 'access_revoked_while_the_call_was_running');
      service.debugBeginCall('session_focus', {'session_id': 's1'});
      await _pump(
        tester,
        SizedBox(
          width: 390,
          child: McpActivityPanel(
            service: service,
            canFocus: (_) => true,
            onFocusSession: (_) {},
            onOpenSettings: () {},
            onClose: () {},
          ),
        ),
        size: const Size(390, 844),
        platform: TargetPlatform.android,
        locale: locale,
      );
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('mcp_activity_entry_1')), findsOne);
      expect(find.byKey(const ValueKey('mcp_activity_entry_2')), findsOne);
    });
  }
}

McpWorkspace _workspace() => McpWorkspace(
  scope: () => 'test',
  describe: () => const {},
  hosts: () => const [
    HostRecord(id: 'h1', name: 'web-01', address: '10.0.0.1', username: 'u'),
  ],
  sessions: () => [
    McpSession(
      id: 's1',
      name: 'web-01',
      kind: 'ssh',
      state: 'connected',
      isAlive: () => true,
      focus: () {},
      close: () async {},
      input: (_) {},
    ),
  ],
  connect: (_) async {},
  openConsole: () async {},
);
