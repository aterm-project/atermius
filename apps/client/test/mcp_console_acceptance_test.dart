import 'dart:async';
import 'dart:io';

import 'package:aterm_client/console/local_console.dart';
import 'package:aterm_client/mcp/mcp_protocol.dart';
import 'package:aterm_client/mcp/mcp_service.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// The terminal tools against a real local shell (a PTY running `sh`), the
/// way an AI client drives them. Linux only, opt-in like the other console
/// acceptance tests:
///   flutter test test/mcp_console_acceptance_test.dart \
///     --dart-define=CONSOLE_ACCEPTANCE=true
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip =
      !Platform.isLinux || !const bool.fromEnvironment('CONSOLE_ACCEPTANCE');

  test(
    'terminal_run, wait, keys, search and screen on a real shell',
    () async {
      final dir = await Directory.systemTemp.createTemp('atermius-mcp-e2e-');
      addTearDown(() => dir.delete(recursive: true));
      final console = openLocalConsole(
        launch: LocalShellLaunch(
          kind: LocalShellKind.sh,
          workingDirectory: dir.path,
        ),
      );
      addTearDown(console.close);
      final terminal = Terminal(maxLines: 4000);
      terminal.onOutput = console.input;
      terminal.onResize = (w, h, _, _) => console.resize(w, h);
      final subscription = console.output.listen(terminal.write);
      addTearDown(subscription.cancel);
      terminal.resize(100, 30);

      var id = 0;
      final protocol = McpProtocol(
        workspace: McpWorkspace(
          scope: () => 'e2e',
          describe: () => {'mode': 'e2e'},
          hosts: () => const [],
          sessions: () => [
            McpSession(
              id: 'c1',
              name: 'Console',
              kind: 'console',
              state: 'connected',
              isAlive: () => true,
              focus: () {},
              close: () async {},
              input: console.input,
              terminal: terminal,
            ),
          ],
          connect: (_) async {},
          openConsole: () async {},
        ),
        validateAccess: () {},
        access: (host) => host == mcpLocalDeviceHostId
            ? McpAccessMode.readWrite
            : McpAccessMode.denied,
      );
      Future<Map> call(String name, Map<String, Object?> args) async {
        final reply = await protocol.handle({
          'jsonrpc': '2.0',
          'id': ++id,
          'method': 'tools/call',
          'params': {
            'name': name,
            'arguments': {'session_id': 'c1', ...args},
          },
        });
        final result = reply.body!['result'] as Map;
        expect(result['isError'], isFalse, reason: '$name: $result');
        return result['structuredContent'] as Map;
      }

      // Let the shell print its first prompt.
      await call('terminal_wait', {'idle_ms': 300, 'timeout_seconds': 5});

      final run = await call('terminal_run', {
        'command': r'echo $((6*7))',
        'until': r'^42$',
        'regex': true,
        'timeout_seconds': 10,
      });
      expect(run['matched'], isTrue);
      expect(run['timed_out'], isFalse);
      expect(run['output'], contains(r'echo $((6*7))'));
      expect((run['output'] as String).split('\n'), contains('42'));

      // `until` must not match the echoed command line itself.
      final slow = await call('terminal_run', {
        'command': 'sleep 1; echo done-sleeping',
        'until': 'done-sleeping',
        'idle_ms': 200,
        'timeout_seconds': 10,
      });
      expect(slow['matched'], isTrue);
      expect(slow['waited_ms'] as int, greaterThanOrEqualTo(900));

      // Incremental read and wait from a cursor.
      final before = await call('terminal_read', {'lines': 5});
      final cursor = before['cursor'] as int;
      // The pattern is in the announcement and in the echoed command line
      // as well; only the command's own output may end the wait. The
      // announcement is left out of matching, and the regex skips the echo.
      await call('terminal_write', {'text': 'sleep 0.5; echo later-line\r'});
      final waited = await call('terminal_wait', {
        'since_cursor': cursor,
        'pattern': r'^LATER-LINE$',
        'regex': true,
        'timeout_seconds': 10,
      });
      expect(waited['matched'], isTrue);
      expect(waited['waited_ms'] as int, greaterThanOrEqualTo(400));
      final literal = await call('terminal_wait', {
        'since_cursor': cursor,
        'pattern': '[MCP] terminal_write',
        'timeout_seconds': 1,
      });
      expect(literal['matched'], isFalse);
      expect(literal['timed_out'], isTrue);
      final increment = await call('terminal_read', {'since_cursor': cursor});
      expect(increment['first_line'], cursor);
      expect((increment['text'] as String).split('\n'), contains('later-line'));
      expect(increment['text'], isNot(contains('done-sleeping')));

      // Keys: interrupt a blocking program, then the shell answers again.
      await call('terminal_write', {'text': 'cat\r'});
      await call('terminal_wait', {'idle_ms': 300, 'timeout_seconds': 5});
      await call('terminal_send_keys', {
        'keys': ['ctrl_c'],
      });
      final after = await call('terminal_run', {
        'command': 'echo back-at-prompt',
        'until': r'^back-at-prompt$',
        'regex': true,
        'timeout_seconds': 10,
      });
      expect(after['matched'], isTrue);

      final search = await call('terminal_search', {
        'pattern': 'done-sleeping',
        'context_lines': 1,
      });
      expect((search['matches'] as List), isNotEmpty);

      final screen = await call('terminal_screen', {});
      expect(screen['alternate_screen'], isFalse);
      expect(screen['columns'], 100);
      expect(screen['text'], contains('back-at-prompt'));

      // What the user saw: every step is announced in the terminal.
      final all = (await call('terminal_read', {'lines': 2000}))['text'];
      expect(all, contains(r'[MCP] terminal_run echo $((6*7))'));
      expect(all, contains('[MCP] terminal_send_keys ctrl_c'));
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
