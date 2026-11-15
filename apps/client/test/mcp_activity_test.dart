import 'dart:convert';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/mcp_access_policy.dart';
import 'package:aterm_client/mcp/mcp_activity.dart';
import 'package:aterm_client/mcp/mcp_protocol.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Map<String, Object?> _call(
  String tool, [
  Map<String, Object?> args = const {},
]) => {
  'jsonrpc': '2.0',
  'id': 1,
  'method': 'tools/call',
  'params': {'name': tool, 'arguments': args},
};

Map<String, dynamic> _content(McpReply reply) =>
    ((reply.body!['result'] as Map)['structuredContent'] as Map)
        .cast<String, dynamic>();

class _Connection implements SshConnection {
  String stdout = 'one\ntwo\n', stderr = '';
  int? exitCode = 0;
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
    return SshExecResult(
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      exitSignal: null,
      cancelled: false,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  bool write = true;
  final input = <String>[];
  final notices = <String>[];
  final focused = <String>[];
  final terminal = Terminal(maxLines: 4000);
  final connection = _Connection();
  bool connectAdds = false, opened = false;

  McpSession _terminalSession(String id, {SshConnection? ssh}) => McpSession(
    id: id,
    name: 'test',
    kind: 'ssh',
    hostId: 'h1',
    state: 'connected',
    isAlive: () => true,
    focus: () => focused.add(id),
    close: () async {},
    input: input.add,
    terminal: terminal,
    connection: ssh,
  );

  late final workspace = McpWorkspace(
    scope: () => 'fixture:one',
    describe: () => {'mode': 'fixture'},
    hosts: () => const [
      HostRecord(id: 'h1', name: 'test', address: 'fixture.example'),
      HostRecord(
        id: 'h2',
        name: 'desk',
        address: 'desk.example',
        protocol: HostProtocol.rdp,
      ),
    ],
    sessions: () => [
      _terminalSession('s1', ssh: connection),
      _terminalSession('telnet'),
      McpSession(
        id: 'desk',
        name: 'desk',
        kind: 'rdp',
        hostId: 'h2',
        state: 'connected',
        isAlive: () => true,
        focus: () => focused.add('desk'),
        close: () async {},
        input: (_) {},
        notice: notices.add,
      ),
      if (opened)
        McpSession(
          id: 'new',
          name: 'desk',
          kind: 'rdp',
          hostId: 'h2',
          state: 'connecting',
          isAlive: () => true,
          focus: () {},
          close: () async {},
          input: (_) {},
          notice: notices.add,
        ),
    ],
    connect: (_) async {
      if (connectAdds) opened = true;
    },
    openConsole: () async {},
  );
  late final protocol = McpProtocol(
    workspace: workspace,
    validateAccess: () {},
    access: (host) => host == null
        ? McpAccessMode.denied
        : write
        ? McpAccessMode.readWrite
        : McpAccessMode.readOnly,
  );

  /// Non-empty lines of the terminal scrollback.
  List<String> get screen => [
    for (var i = 0; i < terminal.buffer.lines.length; i++)
      terminal.buffer.lines[i].getText().trimRight(),
  ].where((line) => line.isNotEmpty).toList();
}

void main() {
  test('every tool that reaches a terminal session is shown in it', () async {
    final h = _Harness();
    h.terminal.write('user@host:~\$ ');

    await h.protocol.handle(
      _call('terminal_write', {'session_id': 's1', 'text': 'ls -la\n'}),
    );
    expect(h.input, ['ls -la\n']);
    expect(h.screen.last, r'[MCP] terminal_write ls -la\n');

    await h.protocol.handle(
      _call('ssh_exec', {'session_id': 's1', 'command': 'cat /etc/hosts'}),
    );
    expect(h.connection.commands, ['cat /etc/hosts']);
    expect(h.screen.sublist(h.screen.length - 4), [
      '[MCP] ssh_exec cat /etc/hosts',
      '[MCP] ssh_exec → exit 0',
      '  one',
      '  two',
    ]);
    // The prompt the user had is still there, above the first line.
    expect(h.screen.first, r'user@host:~$');

    await h.protocol.handle(_call('session_focus', {'session_id': 's1'}));
    expect(h.focused, ['s1']);
    expect(h.screen.last, '[MCP] session_focus');
    await h.protocol.handle(_call('session_close', {'session_id': 's1'}));
    expect(h.screen.last, '[MCP] session_close');
  });

  test('a failed or refused step is shown as failed, a denied one not at '
      'all', () async {
    final h = _Harness();
    h.connection
      ..stdout = ''
      ..stderr = 'permission denied\n'
      ..exitCode = 1;
    await h.protocol.handle(
      _call('ssh_exec', {'session_id': 's1', 'command': 'rm /x'}),
    );
    expect(h.screen, [
      '[MCP] ssh_exec rm /x',
      '[MCP] ssh_exec → exit 1',
      '  permission denied',
    ]);

    // Telnet has no SSH channel: the attempt is on screen with its outcome.
    final failed = await h.protocol.handle(
      _call('ssh_exec', {'session_id': 'telnet', 'command': 'id'}),
    );
    expect(_content(failed)['error'], 'ssh_required');
    expect(h.screen.last, '[MCP] ssh_exec → failed: ssh_required');

    // Read-only: nothing reached the session, so nothing is drawn in it.
    final before = h.screen.length;
    h.write = false;
    final denied = await h.protocol.handle(
      _call('terminal_write', {'session_id': 's1', 'text': 'reboot\n'}),
    );
    expect(_content(denied)['error'], 'read_only');
    expect(h.input, isEmpty);
    expect(h.screen.length, before);
  });

  test('tool arguments cannot drive the terminal', () async {
    final h = _Harness();
    await h.protocol.handle(
      _call('ssh_exec', {
        'session_id': 's1',
        'command': 'echo \x1b[2J\x1b]0;title\x07 \r\nnext',
      }),
    );
    final line = h.screen.firstWhere(
      (l) => l.startsWith('[MCP] ssh_exec echo'),
    );
    expect(line, r'[MCP] ssh_exec echo \e[2J\e]0;title\x07 \r\nnext');
    expect(
      McpActivity.printable('a' * 500).length,
      McpActivity.maxValueLength + 1,
    );
    expect(McpActivity.printable('密码\t✓'), r'密码\t✓');

    // Long command output is echoed up to a bound; the client got all of it.
    h.connection.stdout = List.generate(500, (i) => 'line $i').join('\n');
    await h.protocol.handle(
      _call('ssh_exec', {'session_id': 's1', 'command': 'seq'}),
    );
    expect(h.screen.last, '  … (more output was returned to the client)');
    expect(
      h.screen.where((l) => l.startsWith('  line ')).length,
      McpActivity.maxEchoLines,
    );
  });

  test(
    'a read never contains its own line and polling does not flood',
    () async {
      final h = _Harness();
      h.terminal.write('output\r\n');
      final first = _content(
        await h.protocol.handle(_call('terminal_read', {'session_id': 's1'})),
      );
      expect(first['text'], isNot(contains('[MCP]')));
      expect(h.screen.last, startsWith('[MCP] terminal_read · '));
      final shown = h.screen.length;
      for (var i = 0; i < 5; i++) {
        await h.protocol.handle(_call('terminal_read', {'session_id': 's1'}));
      }
      expect(h.screen.length, shown, reason: 'one line per interval');
      // What MCP did earlier is part of the text a later read returns.
      final later = _content(
        await h.protocol.handle(_call('terminal_read', {'session_id': 's1'})),
      );
      expect(later['text'], contains('[MCP] terminal_read'));
    },
  );

  test('a full-screen program is not drawn over; lines appear when it '
      'exits', () async {
    final h = _Harness();
    h.terminal.write('\x1b[?1049h'); // vim, htop, ...
    expect(h.terminal.isUsingAltBuffer, isTrue);
    await h.protocol.handle(
      _call('terminal_write', {'session_id': 's1', 'text': ':q\n'}),
    );
    expect(h.input, [':q\n']);
    expect(h.screen, isEmpty);
    h.terminal.write('\x1b[?1049l');
    await h.protocol.handle(_call('session_focus', {'session_id': 's1'}));
    expect(h.screen, [r'[MCP] terminal_write :q\n', '[MCP] session_focus']);
  });

  test('a remote desktop shows what MCP does as a notice', () async {
    final h = _Harness();
    await h.protocol.handle(_call('session_focus', {'session_id': 'desk'}));
    expect(h.focused, ['desk']);
    expect(h.notices, ['[MCP] session_focus']);
    await h.protocol.handle(_call('session_close', {'session_id': 'desk'}));
    expect(h.notices.last, '[MCP] session_close');

    h.connectAdds = true;
    final opened = _content(
      await h.protocol.handle(_call('host_connect', {'host_id': 'h2'})),
    );
    expect((opened['sessions'] as List).single['id'], 'new');
    expect(
      h.notices.last,
      '[MCP] host_connect · opened by an external AI client',
    );
    expect(jsonEncode(opened), isNot(contains('MCP]')));
  });
}
