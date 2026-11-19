import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/mcp_access_policy.dart';
import 'package:aterm_client/mcp/mcp_protocol.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:aterm_client/ssh/ssh_live_tools.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Map<String, dynamic> _callTool(String name, Map<String, dynamic> args) => {
  'jsonrpc': '2.0',
  'id': 1,
  'method': 'tools/call',
  'params': {'name': name, 'arguments': args},
};

Map<String, dynamic> _resultOf(McpReply reply) =>
    reply.body!['result']! as Map<String, dynamic>;

void main() {
  group('SshLiveTools validation and escaping', () {
    test('rejects shell metacharacters and flag injection in host/unit/path', () {
      for (final badHost in [
        '',
        ' ',
        '-oProxyCommand=id',
        '127.0.0.1; rm -rf /',
        'example.com\$(id)',
        'host with space',
        '198.51.100.1|cat',
      ]) {
        expect(
          () => SshLiveTools.buildNetworkProbeCommand(
            mode: 'tcp_check',
            host: badHost,
            port: 443,
          ),
          throwsFormatException,
          reason: badHost,
        );
      }

      for (final badPort in [null, 0, -1, 65536]) {
        expect(
          () => SshLiveTools.buildNetworkProbeCommand(
            mode: 'tcp_check',
            host: '127.0.0.1',
            port: badPort,
          ),
          throwsFormatException,
        );
      }

      for (final badUnit in ['', '-f', 'nginx;id', 'foo bar', 'u`id`']) {
        expect(
          () => SshLiveTools.buildServiceLogsCommand(
            source: 'journal',
            unit: badUnit,
          ),
          throwsFormatException,
          reason: badUnit,
        );
      }

      for (final badPath in [
        '',
        'relative/path.log',
        '/var/log/a\x00b.log',
        '/var/log/a\nb.log',
      ]) {
        expect(
          () => SshLiveTools.buildServiceLogsCommand(
            source: 'file',
            path: badPath,
          ),
          throwsFormatException,
        );
      }

      final safeCmd = SshLiveTools.buildServiceLogsCommand(
        source: 'file',
        path: "/var/log/nginx/app's access.log",
        lines: 40,
      );
      expect(safeCmd, contains("'\\''"));
      expect(safeCmd, startsWith('tail -n 40 -- '));
    });

    test('parses system overview, listeners, processes and locally filtered logs', () {
      const overviewRaw = '''
__AT_HOST__=edge-tokyo-01
__AT_KERNEL__=6.8.0-49-generic
__AT_ARCH__=x86_64
__AT_OS__=Ubuntu 24.04.1 LTS
__AT_UPTIME__=up 42 days, 3 hours
__AT_LOAD__=0.18 0.24 0.19
__AT_CORES__=8
__AT_MEM_START__
               total        used        free      shared  buff/cache   available
Mem:           16000        4200        8100         120        3700       11400
__AT_MEM_END__
__AT_DISK_START__
Filesystem     1024-blocks      Used Available Capacity Mounted on
/dev/vda1        102400000  31000000  71400000      31% /
__AT_DISK_END__
''';
      final overview = SshLiveTools.parseSystemOverviewOutput(overviewRaw);
      expect(overview['hostname'], 'edge-tokyo-01');
      expect(overview['os'], 'Ubuntu 24.04.1 LTS');
      expect(overview['cpu_cores'], 8);
      expect((overview['memory'] as Map)['total_mb'], 16000);
      expect((overview['disk_root'] as Map)['capacity'], '31%');

      const ssRaw = '''
__AT_TOOL__=ss
Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port
tcp   LISTEN 0      4096   127.0.0.1:5432     0.0.0.0:*
udp   UNCONN 0      0      0.0.0.0:5353       0.0.0.0:*
''';
      final net = SshLiveTools.parseNetworkProbeOutput(
        mode: 'listening_ports',
        stdout: ssRaw,
      );
      expect(net['tool'], 'ss');
      expect(net['count'], 2);
      expect((net['listeners'] as List).first, {
        'proto': 'tcp',
        'state': 'LISTEN',
        'local': '127.0.0.1:5432',
      });

      const psRaw = '''
  101 root     0.5  1.2 systemd
  204 postgres 18.2 9.4 postgres: writer
  309 envoy    4.1 14.0 envoy --config
''';
      final byCpu = SshLiveTools.parseProcessSnapshotOutput(
        psRaw,
        sortBy: 'cpu',
        limit: 2,
      );
      expect(byCpu['count'], 2);
      expect((byCpu['items'] as List).first['pid'], 204);

      final byMem = SshLiveTools.parseProcessSnapshotOutput(
        psRaw,
        sortBy: 'memory',
        limit: 2,
      );
      expect((byMem['items'] as List).first['pid'], 309);

      final filteredLogs = SshLiveTools.parseServiceLogsOutput(
        'line 1 info\nline 2 ERROR timeout\nline 3 ok\nline 4 error auth\n',
        source: 'journal',
        unit: 'nginx',
        contains: 'error',
      );
      expect(filteredLogs['line_count'], 2);
      expect(filteredLogs['lines'], [
        'line 2 ERROR timeout',
        'line 4 error auth',
      ]);
    });
  });

  group('MCP integration for live SSH diagnostic tools', () {
    test('all 4 diagnostic tools work under read_only access and are visible in terminal', () async {
      final h = _LiveToolsHarness()..accessMode = McpAccessMode.readOnly;
      final resOverview = _resultOf(
        await h.protocol.handle(_callTool('ssh_system_overview', {'session_id': 's1'})),
      );
      expect(resOverview['isError'], isFalse);
      final overview = resOverview['structuredContent'] as Map<String, dynamic>;
      expect(overview['hostname'], 'edge-tokyo-01');
      expect(overview['cpu_cores'], 4);

      final resNet = _resultOf(
        await h.protocol.handle(
          _callTool('ssh_network_probe', {
            'session_id': 's1',
            'mode': 'tcp_check',
            'host': '198.51.100.11',
            'port': 443,
          }),
        ),
      );
      expect(resNet['isError'], isFalse);
      expect((resNet['structuredContent'] as Map)['reachable'], isTrue);

      final resProc = _resultOf(
        await h.protocol.handle(
          _callTool('ssh_process_snapshot', {
            'session_id': 's1',
            'sort_by': 'memory',
            'limit': 5,
          }),
        ),
      );
      expect(resProc['isError'], isFalse);
      expect(((resProc['structuredContent'] as Map)['items'] as List).first['pid'], 22);

      // Injecting shell syntax into `contains` stays local in Dart and never touches the remote shell.
      final resLogs = _resultOf(
        await h.protocol.handle(
          _callTool('ssh_service_logs', {
            'session_id': 's1',
            'source': 'file',
            'path': '/var/log/nginx/error.log',
            'contains': 'fatal;id',
          }),
        ),
      );
      expect(resLogs['isError'], isFalse);
      expect(h.connection.commands.last, "tail -n 80 -- '/var/log/nginx/error.log' 2>&1");

      final terminalText = [
        for (var i = 0; i < h.terminal.buffer.lines.length; i++)
          h.terminal.buffer.lines[i].getText().trimRight(),
      ].join('\n');
      expect(terminalText, contains('[MCP] ssh_system_overview'));
      expect(terminalText, contains('[MCP] ssh_network_probe'));
    });

    test('denied machine and invalid arguments are rejected safely', () async {
      final h = _LiveToolsHarness()..accessMode = McpAccessMode.denied;
      final deniedReply = _resultOf(
        await h.protocol.handle(_callTool('ssh_system_overview', {'session_id': 's1'})),
      );
      expect(deniedReply['isError'], isTrue);
      expect(
        (deniedReply['structuredContent'] as Map)['error'],
        'session_unavailable',
      );
      expect(h.connection.commands, isEmpty);

      h.accessMode = McpAccessMode.readOnly;
      final badReply = _resultOf(
        await h.protocol.handle(
          _callTool('ssh_network_probe', {
            'session_id': 's1',
            'mode': 'tcp_check',
            'host': '127.0.0.1; id',
            'port': 22,
          }),
        ),
      );
      expect(badReply['isError'], isTrue);
      expect((badReply['structuredContent'] as Map)['error'], 'invalid_arguments');
      expect(h.connection.commands, isEmpty);
    });
  });
}

class _LiveToolsHarness {
  McpAccessMode accessMode = McpAccessMode.readOnly;
  final terminal = Terminal(maxLines: 2000);
  final connection = _FakeSshConnection();
  late final workspace = McpWorkspace(
    scope: () => 'fixture:live-tools',
    describe: () => {'mode': 'fixture'},
    hosts: () => [
      const HostRecord(
        id: 'h1',
        name: 'edge-tokyo-01',
        address: '198.51.100.11',
        username: 'ops',
      ),
    ],
    sessions: () => [
      McpSession(
        id: 's1',
        name: 'edge-tokyo-01',
        kind: 'ssh',
        hostId: 'h1',
        state: 'connected',
        isAlive: () => true,
        focus: () {},
        close: () async {},
        input: (_) {},
        terminal: terminal,
        connection: connection,
      ),
    ],
    connect: (_) async {},
    openConsole: () async {},
  );
  late final protocol = McpProtocol(
    workspace: workspace,
    validateAccess: () {},
    access: (hostId) => hostId == 'h1' ? accessMode : McpAccessMode.denied,
  );
}

class _FakeSshConnection implements SshConnection {
  final commands = <String>[];

  @override
  Future<SshExecResult> executeRemoteCommand(
    String command, {
    required SshExecCancellation cancellation,
    List<int>? stdinData,
    Duration timeout = const Duration(minutes: 2),
    int maxOutputBytes = 65536,
    String bashUnavailableMarker = '__ATERMIUS_BASH_UNAVAILABLE__',
  }) async {
    commands.add(command);
    var stdout = '';
    if (command.contains('__AT_HOST__')) {
      stdout = '''
__AT_HOST__=edge-tokyo-01
__AT_KERNEL__=6.8.0
__AT_ARCH__=arm64
__AT_OS__=Debian 12
__AT_UPTIME__=up 10 days
__AT_LOAD__=0.10 0.12 0.08
__AT_CORES__=4
''';
    } else if (command.contains('__AT_TCP__')) {
      stdout = '__AT_TCP__=OPEN\n';
    } else if (command.contains('ps -eo')) {
      stdout = '  11 root  8.0  2.0 sshd\n  22 ops   1.5  12.4 node\n';
    } else if (command.contains('tail -n')) {
      stdout = '2026-11-19 ok\n2026-11-19 fatal;id happened\n';
    }
    return SshExecResult(
      stdout: stdout,
      stderr: '',
      exitCode: 0,
      exitSignal: null,
    );
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
