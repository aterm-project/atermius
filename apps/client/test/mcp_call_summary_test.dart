import 'package:aterm_client/mcp/mcp_access_policy_store.dart';
import 'package:aterm_client/mcp/mcp_call_summary.dart';
import 'package:aterm_client/mcp/mcp_service.dart';
import 'package:aterm_client/mcp/mcp_token_store.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('summarizeArguments', () {
    test('leaves out session and host IDs', () {
      expect(summarizeArguments('session_focus', {'session_id': 's1'}), '');
      expect(summarizeArguments('host_connect', {'host_id': 'h1'}), '');
    });

    test('shows the command first, then filters as name=value', () {
      expect(
        summarizeArguments('ssh_exec', {
          'session_id': 's1',
          'command': 'systemctl status nginx',
          'timeout_seconds': 30,
        }),
        'systemctl status nginx',
      );
      expect(
        summarizeArguments('terminal_run', {
          'session_id': 's1',
          'command': 'make test',
          'until': r'\$ $',
        }),
        r'make test · until=\$ $',
      );
      expect(
        summarizeArguments('ssh_service_logs', {
          'session_id': 's1',
          'source': 'journal',
          'unit': 'nginx',
          'contains': 'error',
          'lines': 100,
        }),
        'source=journal · unit=nginx · contains=error · lines=100',
      );
    });

    test('paths, renames, patterns, keys and messages', () {
      expect(
        summarizeArguments('sftp_list', {
          'session_id': 's1',
          'path': '/var/log',
          'limit': 50,
        }),
        '/var/log · limit=50',
      );
      expect(
        summarizeArguments('sftp_rename', {
          'session_id': 's1',
          'from': '/tmp/a.txt',
          'to': '/tmp/b.txt',
        }),
        '/tmp/a.txt → /tmp/b.txt',
      );
      expect(
        summarizeArguments('sftp_remove', {
          'session_id': 's1',
          'path': '/tmp/old',
          'type': 'directory',
        }),
        '/tmp/old · type=directory',
      );
      expect(
        summarizeArguments('terminal_search', {
          'session_id': 's1',
          'pattern': 'ERROR',
        }),
        'ERROR',
      );
      expect(
        summarizeArguments('terminal_send_keys', {
          'session_id': 's1',
          'keys': ['ctrl+c', 'enter'],
        }),
        'ctrl+c enter',
      );
      expect(
        summarizeArguments('ui_notify', {
          'message': 'Deploy finished',
          'level': 'success',
        }),
        'Deploy finished · level=success',
      );
      expect(summarizeArguments('docs_read', {'topic': 'tools'}), 'tools');
    });

    test('never shows file contents, only their size', () {
      final summary = summarizeArguments('sftp_write_text', {
        'session_id': 's1',
        'path': '/etc/app.conf',
        'text': 'password=hunter2\nport=1',
        'mode': 'replace',
        'expected_sha256': 'a' * 64,
      });
      expect(summary, '/etc/app.conf · 23 bytes · mode=replace');
      expect(summary, isNot(contains('hunter2')));
      // Unknown tools are treated the same way.
      expect(
        summarizeArguments('future_upload', {'content': 'secret'}),
        '6 bytes',
      );
      // UTF-8 size, not characters.
      expect(
        summarizeArguments('sftp_write_text', {'path': '/a', 'text': 'é'}),
        '/a · 2 bytes',
      );
    });

    test('terminal input is shown with control characters escaped', () {
      expect(
        summarizeArguments('terminal_write', {
          'session_id': 's1',
          'text': 'ls -la\n\x1b[2J\x03',
        }),
        r'ls -la\n\e[2J\x03',
      );
    });

    test('direction overrides are made visible', () {
      final summary = summarizeArguments('ssh_exec', {
        'command': 'echo \u202etxt.exe',
      });
      expect(summary, r'echo \u{202e}txt.exe');
    });

    test('long values are cut on one line', () {
      final summary = summarizeArguments('ssh_exec', {'command': 'x' * 500});
      expect(summary.length, lessThanOrEqualTo(mcpSummaryLength + 1));
      expect(summary, endsWith('…'));
      expect(summary, isNot(contains('\n')));
    });

    test('unknown tools still render their arguments', () {
      expect(
        summarizeArguments('future_tool', {
          'session_id': 's1',
          'flag': true,
          'items': ['a', 'b'],
          'options': {'depth': 2},
        }),
        'flag=true · items=a, b · options={"depth":2}',
      );
    });
  });

  group('summarizeResult', () {
    test('command outcomes', () {
      expect(summarizeResult('ssh_exec', {'exit_code': 0}), 'exit 0');
      expect(
        summarizeResult('ssh_exec', {'exit_code': null, 'exit_signal': 'KILL'}),
        'signal KILL',
      );
      expect(
        summarizeResult('ssh_exec', {'exit_code': null, 'timed_out': true}),
        'timed out',
      );
      expect(
        summarizeResult('ssh_exec', {'cancelled': true, 'timed_out': false}),
        'cancelled',
      );
      expect(
        summarizeResult('terminal_run', {
          'output': 'secret output',
          'matched': true,
          'idle': false,
          'timed_out': false,
        }),
        'matched',
      );
      expect(
        summarizeResult('terminal_wait', {'matched': false, 'idle': true}),
        'idle',
      );
      expect(
        summarizeResult('terminal_run', {'matched': false, 'timed_out': true}),
        'timed out',
      );
    });

    test('counts and sizes', () {
      expect(
        summarizeResult('sftp_list', {'items': List.filled(12, {})}),
        '12 items',
      );
      expect(
        summarizeResult('hosts_list', {
          'items': [{}],
          'total': 40,
        }),
        '1 of 40 items',
      );
      expect(
        summarizeResult('sftp_list', {
          'items': [{}, {}],
          'next_offset': 2,
        }),
        '2 items (more)',
      );
      expect(
        summarizeResult('terminal_search', {
          'matches': [{}, {}, {}],
        }),
        '3 matches',
      );
      expect(
        summarizeResult('sftp_read_text', {
          'text': 'secret',
          'bytes': 4096,
          'sha256': 'x',
        }),
        '4096 bytes',
      );
      expect(
        summarizeResult('ssh_process_snapshot', {'count': 1}),
        '1 process',
      );
      expect(
        summarizeResult('ssh_service_logs', {'line_count': 25}),
        '25 lines',
      );
      expect(
        summarizeResult('terminal_read', {'text': 'a\nb\nc\n'}),
        '3 lines',
      );
    });

    test('flags and nothing to say', () {
      expect(summarizeResult('sftp_write_text', {'saved': true}), 'saved');
      expect(summarizeResult('terminal_write', {'sent': true}), 'sent');
      expect(
        summarizeResult('host_connect', {
          'sessions': [
            {'id': 's9'},
          ],
        }),
        'opened',
      );
      expect(summarizeResult('workspace_status', {'mode': 'local'}), isNull);
      expect(summarizeResult('anything', null), isNull);
    });
  });

  test('tool titles come from the tool definitions', () {
    expect(mcpToolTitle('ssh_exec'), 'Run a command (separate SSH channel)');
    expect(mcpToolTitle('not_a_tool'), 'not_a_tool');
  });

  group('McpService audit entries', () {
    test('name the target and summarize arguments and outcome', () {
      final service = McpService(
        policyStore: MemoryMcpAccessPolicyStore(),
        tokenStore: MemoryMcpTokenStore(),
      )..attach(_workspace());
      addTearDown(service.dispose);

      final end = service.debugBeginCall('ssh_exec', {
        'session_id': 's1',
        'command': 'uptime',
      });
      final entry = service.audit.first;
      expect(entry.running, isTrue);
      expect(service.activeCalls, [entry]);
      expect(entry.target, 'web-01');
      expect(entry.summary, 'uptime');
      end(true, output: {'exit_code': 0, 'stdout': 'up 3 days'});
      expect(entry.success, isTrue);
      expect(entry.result, 'exit 0');
      expect(entry.duration, isNotNull);
      expect(service.activeCalls, isEmpty);

      final connect = service.debugBeginCall('host_connect', {'host_id': 'h1'});
      expect(service.audit.first.target, 'web-01 saved');
      connect(
        true,
        output: {
          'sessions': [
            {'id': 's2'},
          ],
        },
      );
      expect(service.audit.first.focusSessionId, 's2');

      final failed = service.debugBeginCall('terminal_write', {
        'session_id': 'gone',
        'text': 'x',
      });
      failed(false, error: 'session_unavailable');
      expect(service.audit.first.target, isNull);
      expect(service.audit.first.error, 'session_unavailable');
      expect(service.audit.first.result, isNull);
      expect(service.lastActivity, isNotNull);
    });
  });
}

McpWorkspace _workspace() => McpWorkspace(
  scope: () => 'test',
  describe: () => const {},
  hosts: () => [
    const HostRecord(
      id: 'h1',
      name: 'web-01 saved',
      address: '10.0.0.1',
      username: 'root',
    ),
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
