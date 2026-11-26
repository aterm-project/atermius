// Query and interaction tools of the built-in MCP server: host/group/session
// discovery, incremental terminal reading, search, waiting, keys, visible
// command runs, SFTP path operations and user notices.
import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/domain/host_operating_system.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/mcp/mcp_access_policy.dart';
import 'package:aterm_client/mcp/mcp_activity.dart';
import 'package:aterm_client/mcp/mcp_notices.dart';
import 'package:aterm_client/mcp/mcp_protocol.dart';
import 'package:aterm_client/mcp/mcp_terminal_text.dart';
import 'package:aterm_client/mcp/mcp_tools.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:clock/clock.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Map<String, Object?> _rpc(String tool, Map<String, Object?> args, Object id) =>
    {
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': tool, 'arguments': args},
    };

Map<String, dynamic> _content(McpReply reply) =>
    ((reply.body!['result'] as Map)['structuredContent'] as Map)
        .cast<String, dynamic>();

HostRecord _withOs(HostRecord host) => host.copyWithDetectedOperatingSystem(
  HostOperatingSystem(
    family: HostOperatingSystemFamily.linux,
    displayName: 'Ubuntu 24.04 LTS',
    distributionId: 'ubuntu',
    version: '24.04',
    detectedAt: DateTime.utc(2026, 11, 1),
  ),
);

final _web = _withOs(
  HostRecord(
    id: 'h1',
    name: 'web-1',
    address: 'web1.example',
    username: 'deploy',
    groupId: 'g-web',
    credentialId: 'cred-sentinel',
    jumpHostId: 'h4',
    tags: const ['production', 'Web'],
    isFavorite: true,
    lastConnected: DateTime.utc(2026, 11, 20, 8, 30),
    manifest: const {'privateKey': 'secret-sentinel'},
    portForwardProfiles: const [
      SshPortForwardProfile(
        id: 'f1',
        name: 'Admin UI',
        type: SshPortForwardType.local,
        bindAddress: '127.0.0.1',
        bindPort: 8080,
        destinationAddress: 'localhost',
        destinationPort: 80,
      ),
      SshPortForwardProfile(
        id: 'f2',
        name: 'SOCKS',
        type: SshPortForwardType.dynamic,
        bindAddress: '127.0.0.1',
        bindPort: 1080,
      ),
    ],
  ),
);

const _hosts = [
  HostRecord(
    id: 'h2',
    name: 'secret-db',
    address: 'db.internal',
    username: 'postgres',
    groupId: 'g-secret',
    tags: ['production'],
    isFavorite: true,
  ),
  HostRecord(
    id: 'h3',
    name: 'desk',
    address: 'desk.example',
    protocol: HostProtocol.rdp,
    groupId: 'g-prod',
    tags: ['office'],
    // Through the denied host: the reference must not be shown.
    jumpHostId: 'h2',
  ),
  HostRecord(
    id: 'h4',
    name: 'bastion',
    address: 'jump.example',
    username: 'jump',
    tags: ['infra'],
  ),
];

const _groups = [
  McpGroup(id: 'g-root', name: 'Company'),
  McpGroup(id: 'g-prod', name: 'Production', parentId: 'g-root'),
  McpGroup(id: 'g-web', name: 'Web', parentId: 'g-prod'),
  McpGroup(id: 'g-secret', name: 'Secret project', parentId: 'g-root'),
  McpGroup(id: 'g-hidden', name: 'Hidden', parentId: 'g-secret'),
  McpGroup(id: 'g-empty', name: 'Empty', parentId: 'g-root'),
  // A parent cycle must not hang the walk.
  McpGroup(id: 'g-loop-a', name: 'Loop A', parentId: 'g-loop-b'),
  McpGroup(id: 'g-loop-b', name: 'Loop B', parentId: 'g-loop-a'),
];

class _Sftp implements SftpClient {
  final entries = <String, SftpFileAttrs>{};
  final calls = <String>[];
  int? removeError;
  int closed = 0;

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    calls.add('stat $path${followLink ? '' : ' nofollow'}');
    return entries[path] ??
        (throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file'));
  }

  @override
  Future<void> mkdir(String path, [SftpFileAttrs? attrs]) async {
    calls.add('mkdir $path');
    entries[path] = _attrs(_directory);
  }

  @override
  Future<void> renameNoReplace(String oldPath, String newPath) async {
    calls.add('rename $oldPath $newPath');
    entries[newPath] = entries.remove(oldPath)!;
  }

  @override
  Future<void> remove(String filename) async {
    calls.add('remove $filename');
    if (removeError case final code?) throw SftpStatusError(code, 'refused');
    entries.remove(filename);
  }

  @override
  Future<void> rmdir(String dirname) async {
    calls.add('rmdir $dirname');
    if (removeError case final code?) throw SftpStatusError(code, 'refused');
    entries.remove(dirname);
  }

  @override
  Future<void> close() async => closed++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _directory = 1 << 14, _file = 1 << 15, _symlink = (1 << 15) + (1 << 13);
SftpFileAttrs _attrs(int type, {int permissions = 0x1ed /* 0755 */}) =>
    SftpFileAttrs(
      size: 42,
      userID: 1000,
      groupID: 100,
      mode: SftpFileMode.value(type | permissions),
      modifyTime: 1700000000,
      accessTime: 1700000000,
    );

class _Client implements SSHClient {
  _Client(this.sftpClient);
  final _Sftp sftpClient;
  int opened = 0;
  @override
  Future<SftpClient> sftp() async {
    opened++;
    return sftpClient;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connection implements SshConnection {
  final sftpClient = _Sftp();
  @override
  late final SSHClient client = _Client(sftpClient);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  final modes = <String, McpAccessMode>{'h2': McpAccessMode.denied};
  final terminal = Terminal(maxLines: 1000);
  final hiddenTerminal = Terminal(maxLines: 1000);
  final input = <String>[];
  final notices = <String>[];
  void Function(String text)? onInput;
  String state = 'connected';
  bool alive = true;
  String focused = 's1';
  final connection = _Connection();
  _Sftp get sftp => connection.sftpClient;

  McpSession _session(
    String id,
    String kind,
    String? hostId, {
    Terminal? terminal,
    SshConnection? connection,
  }) => McpSession(
    id: id,
    name: id,
    kind: kind,
    hostId: hostId,
    state: state,
    isAlive: () => alive,
    focus: () {},
    close: () async {},
    input: (text) {
      input.add(text);
      onInput?.call(text);
    },
    terminal: terminal,
    connection: connection,
    notice: terminal == null ? notices.add : null,
    isFocused: () => focused == id,
  );

  late final workspace = McpWorkspace(
    scope: () => 'fixture:one',
    describe: () => {'mode': 'fixture', 'hosts': 99},
    hosts: () => [_web, ..._hosts],
    groups: () => _groups,
    sessions: () => [
      _session('s1', 'ssh', 'h1', terminal: terminal, connection: connection),
      _session('s2', 'ssh', 'h2', terminal: hiddenTerminal),
      _session('d1', 'rdp', 'h3'),
      _session('c1', 'console', null, terminal: Terminal()),
    ],
    connect: (_) async {},
    openConsole: () async {},
  );

  late final protocol = McpProtocol(
    workspace: workspace,
    validateAccess: () {},
    access: (id) => id == null
        ? McpAccessMode.denied
        : modes[id] ?? McpAccessMode.readWrite,
  );

  int _ids = 1;
  Future<Map<String, dynamic>> call(
    String tool, [
    Map<String, Object?> args = const {},
  ]) async => _content(await protocol.handle(_rpc(tool, args, _ids++)));

  Future<McpReply> raw(String tool, Map<String, Object?> args) =>
      protocol.handle(_rpc(tool, args, _ids++));

  /// Uses up this interval's `terminal_read` line, so reads are exact.
  void quietReads() => McpActivity.readDue(workspace.sessions().first);

  /// Non-empty lines of the terminal.
  List<String> get screen => [
    for (var i = 0; i < terminal.buffer.lines.length; i++)
      terminal.buffer.lines[i].getText().trimRight(),
  ].where((line) => line.isNotEmpty).toList();
}

List<Object?> _ids(Map<String, dynamic> page) => [
  for (final item in page['items'] as List) (item as Map)['id'],
];

void main() {
  setUp(McpToolRunner.resetNoticeRateLimit);

  group('definitions', () {
    test('new tools are listed with the right access and hints', () {
      final byName = {for (final tool in mcpTools) tool.name: tool};
      for (final name in [
        'host_get',
        'groups_list',
        'terminal_screen',
        'terminal_search',
        'terminal_wait',
        'sftp_stat',
      ]) {
        expect(byName[name]!.mutating, isFalse, reason: name);
        expect(mcpRequiredAccess(name), McpAccessMode.readOnly, reason: name);
      }
      for (final name in [
        'terminal_send_keys',
        'terminal_run',
        'sftp_rename',
        'sftp_remove',
      ]) {
        expect(mcpRequiredAccess(name), McpAccessMode.readWrite, reason: name);
        expect(byName[name]!.destructive, isTrue, reason: name);
      }
      expect(byName['sftp_mkdir']!.destructive, isFalse);
      expect(byName['sftp_mkdir']!.mutating, isTrue);
      final notify = byName['ui_notify']!;
      expect(
        [notify.mutating, notify.destructive, notify.idempotent],
        [true, false, false],
      );
      for (final tool in mcpTools) {
        expect(tool.title, isNotEmpty, reason: tool.name);
        jsonEncode(tool.toJson());
      }
      expect(mcpHostProtocols, HostProtocol.values.map((p) => p.name));
      for (final key in mcpTerminalKeys) {
        expect(mcpKeySequence(key, cursorKeysMode: false), isNotEmpty);
      }
    });
  });

  group('hosts, groups and sessions', () {
    test('hosts_list shows metadata and filters, never denied hosts or '
        'credentials', () async {
      final h = _Harness();
      final all = await h.call('hosts_list');
      expect(_ids(all), ['h1', 'h3', 'h4']);
      final encoded = jsonEncode(all);
      for (final secret in [
        'secret-sentinel',
        'cred-sentinel',
        'secret-db',
        'db.internal',
        'h2',
      ]) {
        expect(encoded, isNot(contains(secret)), reason: secret);
      }
      final web = (all['items'] as List).first as Map;
      expect(web['tags'], ['production', 'Web']);
      expect(web['favorite'], isTrue);
      expect(web['jump_host_id'], 'h4');
      expect(web['last_connected'], '2026-11-20T08:30:00.000Z');
      expect(web['os'], {
        'family': 'linux',
        'name': 'Ubuntu 24.04 LTS',
        'distribution': 'ubuntu',
        'version': '24.04',
      });
      expect(web['access'], 'read_write');
      final desk = (all['items'] as List)[1] as Map;
      expect(desk.containsKey('jump_host_id'), isFalse);
      expect(desk.containsKey('os'), isFalse);

      Future<List<Object?>> ids(Map<String, Object?> args) async =>
          _ids(await h.call('hosts_list', args));
      expect(await ids({'query': 'WEB1'}), ['h1']);
      expect(await ids({'query': 'jump'}), ['h4']);
      expect(await ids({'query': 'infra'}), ['h4']);
      // Only visible hosts match, whatever the filter.
      expect(await ids({'query': 'secret'}), isEmpty);
      expect(await ids({'protocol': 'rdp'}), ['h3']);
      expect(await ids({'tag': 'web'}), ['h1']);
      expect(await ids({'tag': 'production'}), ['h1']);
      expect(await ids({'favorites_only': true}), ['h1']);
      expect(await ids({'group_id': 'g-prod'}), ['h1', 'h3']);
      expect(await ids({'group_id': 'g-web'}), ['h1']);
      expect(await ids({'group_id': 'g-secret'}), isEmpty);
      expect(await ids({'group_id': 'g-root', 'protocol': 'ssh'}), ['h1']);
      expect(
        (await h.raw('hosts_list', {'protocol': 'ftp'})).status,
        400,
        reason: 'protocol is an enum',
      );
    });

    test('host_get adds port forwards and open sessions; a denied host is '
        'indistinguishable from an unknown one', () async {
      final h = _Harness();
      final web = await h.call('host_get', {'host_id': 'h1'});
      expect(web['name'], 'web-1');
      expect(web['port_forwards'], [
        {
          'name': 'Admin UI',
          'type': 'local',
          'bind_address': '127.0.0.1',
          'bind_port': 8080,
          'destination_address': 'localhost',
          'destination_port': 80,
          'expose_to_network': false,
        },
        {
          'name': 'SOCKS',
          'type': 'dynamic',
          'bind_address': '127.0.0.1',
          'bind_port': 1080,
          'expose_to_network': false,
        },
      ]);
      expect((web['sessions'] as List).map((s) => (s as Map)['id']), ['s1']);
      expect(jsonEncode(web), isNot(contains('sentinel')));

      final denied = await h.call('host_get', {'host_id': 'h2'});
      final unknown = await h.call('host_get', {'host_id': 'nope'});
      expect(denied, unknown);
      expect(denied['error'], 'host_unavailable');
      // The local-device identity is not a saved host.
      expect(
        (await h.call('host_get', {'host_id': mcpLocalDeviceHostId}))['error'],
        'host_unavailable',
      );
      h.modes['h1'] = McpAccessMode.readOnly;
      expect(
        (await h.call('host_get', {'host_id': 'h1'}))['access'],
        'read_only',
      );
    });

    test('groups_list shows only groups leading to visible hosts and counts '
        'only visible hosts', () async {
      final h = _Harness();
      final groups = await h.call('groups_list');
      expect(groups['items'], [
        {'id': 'g-root', 'name': 'Company', 'host_count': 0},
        {
          'id': 'g-prod',
          'name': 'Production',
          'parent_id': 'g-root',
          'host_count': 1,
        },
        {'id': 'g-web', 'name': 'Web', 'parent_id': 'g-prod', 'host_count': 1},
      ]);
      expect(jsonEncode(groups), isNot(contains('Secret')));
      // Denying the web host removes its group, and its parents keep only
      // what remains visible.
      h.modes['h1'] = McpAccessMode.denied;
      expect(_ids(await h.call('groups_list')), ['g-root', 'g-prod']);
      h.modes['h2'] = McpAccessMode.readOnly;
      expect(_ids(await h.call('groups_list')), [
        'g-root',
        'g-prod',
        'g-secret',
      ]);
      expect(_ids(await h.call('groups_list', {'offset': 1, 'limit': 1})), [
        'g-prod',
      ]);
    });

    test('sessions_list adds focus, host name and terminal size, and '
        'filters by host', () async {
      final h = _Harness();
      h.terminal.resize(100, 30);
      final all = await h.call('sessions_list');
      expect(_ids(all), ['s1', 'd1', 'c1']);
      final s1 = (all['items'] as List).first as Map;
      expect(s1['focused'], isTrue);
      expect(s1['host_name'], 'web-1');
      expect(s1['columns'], 100);
      expect(s1['rows'], 30);
      expect(s1['alternate_screen'], isFalse);
      final desk = (all['items'] as List)[1] as Map;
      expect(desk['focused'], isFalse);
      expect(desk['host_name'], 'desk');
      expect(desk.containsKey('columns'), isFalse);
      final console = (all['items'] as List)[2] as Map;
      expect(console.containsKey('host_name'), isFalse);
      expect(console.containsKey('host_id'), isFalse);

      h.terminal.write('\x1b[?1049h');
      h.focused = 'd1';
      final filtered = await h.call('sessions_list', {'host_id': 'h1'});
      expect(_ids(filtered), ['s1']);
      expect(
        ((filtered['items'] as List).single as Map)['alternate_screen'],
        true,
      );
      expect(((filtered['items'] as List).single as Map)['focused'], false);
      // A denied host's sessions are not revealed by filtering on its ID.
      expect(await h.call('sessions_list', {'host_id': 'h2'}), {
        'items': [],
        'total': 0,
      });
    });
  });

  group('terminal reading', () {
    test('terminal_read continues from a cursor and re-reads the line being '
        'written', () async {
      final h = _Harness()..quietReads();
      h.terminal.write('one\r\ntwo\r\nthr');
      final first = await h.call('terminal_read', {'session_id': 's1'});
      expect(first['text'], 'one\ntwo\nthr');
      expect(first['first_line'], 0);
      expect(first['cursor'], 2);
      expect(first['truncated'], isFalse);
      expect(first['alternate_screen'], isFalse);

      h.terminal.write('ee\r\nfour\r\n');
      final next = await h.call('terminal_read', {
        'session_id': 's1',
        'since_cursor': first['cursor'],
      });
      expect(next['text'], 'three\nfour\n');
      expect(next['first_line'], 2);
      expect(next['cursor'], 4);
      expect(next['truncated'], isFalse);

      // lines keeps the newest lines of the range.
      final last = await h.call('terminal_read', {
        'session_id': 's1',
        'since_cursor': 0,
        'lines': 2,
      });
      expect(last['text'], 'four\n');
      expect(last['first_line'], 3);
      expect(last['truncated'], isTrue);
      // A cursor from the future reads from the current line.
      final ahead = await h.call('terminal_read', {
        'session_id': 's1',
        'since_cursor': 999,
      });
      expect(ahead['first_line'], 4);
      expect(ahead['text'], '');
    });

    test('a cursor older than the retained lines starts at the oldest one '
        'and says so', () async {
      final small = Terminal(maxLines: 40);
      final protocol = McpProtocol(
        workspace: McpWorkspace(
          scope: () => 'fixture:one',
          describe: () => {},
          hosts: () => [_web],
          sessions: () => [
            McpSession(
              id: 'small',
              name: 'small',
              kind: 'ssh',
              hostId: 'h1',
              state: 'connected',
              isAlive: () => true,
              focus: () {},
              close: () async {},
              input: (_) {},
              terminal: small,
            ),
          ],
          connect: (_) async {},
          openConsole: () async {},
        ),
        validateAccess: () {},
        access: (_) => McpAccessMode.readOnly,
      );
      small.write(List.generate(100, (i) => 'line $i\r\n').join());
      // Taken first: the read's own announcement scrolls this short buffer.
      final oldest = small.buffer.lines.absoluteStartIndex;
      final oldestText = mcpRowText(small.buffer.lines[0]);
      final cursor = McpTerminalView(small).cursor;
      final retained = small.buffer.lines.length;
      expect(oldest, greaterThan(5));
      final read = _content(
        await protocol.handle(
          _rpc('terminal_read', {'session_id': 'small', 'since_cursor': 5}, 1),
        ),
      );
      expect(read['truncated'], isTrue);
      expect(read['first_line'], oldest);
      expect((read['text'] as String).split('\n').first, oldestText);
      expect(oldestText, startsWith('line '));
      expect(read['cursor'], cursor);
      expect(read['total_retained_lines'], retained);
    });

    test('wrapped lines are returned as one line; gaps are spaces', () async {
      final h = _Harness()..quietReads();
      h.terminal.write('${'x' * 100}\r\na\tb\r\n');
      final read = await h.call('terminal_read', {'session_id': 's1'});
      expect((read['text'] as String).split('\n'), [
        'x' * 100,
        'a       b',
        '',
      ]);
    });

    test('terminal_screen shows the visible rows and the cursor', () async {
      final h = _Harness();
      h.terminal.write(List.generate(40, (i) => 'old $i\r\n').join());
      h.terminal.write('\x1b[2J\x1b[Htop\r\n  mid');
      final screen = await h.call('terminal_screen', {'session_id': 's1'});
      final rows = (screen['text'] as String).split('\n');
      expect(rows, hasLength(24));
      expect(rows.take(2), ['top', '  mid']);
      expect(screen['cursor'], {'row': 1, 'column': 5});
      expect([screen['columns'], screen['rows']], [80, 24]);
      expect(screen['alternate_screen'], isFalse);
      expect(h.screen.last, '[MCP] terminal_screen');
      // first_line numbers the top row as terminal_read does; the
      // announcement is part of what is read afterwards.
      final read = await h.call('terminal_read', {
        'session_id': 's1',
        'since_cursor': screen['first_line'],
      });
      expect(read['text'], 'top\n  mid\n[MCP] terminal_screen\n');

      h.terminal.write('\x1b[?1049h\x1b[Hvim buffer');
      final full = await h.call('terminal_screen', {'session_id': 's1'});
      expect(full['alternate_screen'], isTrue);
      expect((full['text'] as String).split('\n').first, 'vim buffer');
      expect(
        (await h.call('terminal_screen', {'session_id': 'd1'}))['error'],
        'not_a_terminal',
      );
    });
  });

  group('terminal_search', () {
    _Harness searchable() {
      final h = _Harness();
      h.terminal.write(
        [
          'alpha one',
          'Beta two',
          'gamma ERROR three',
          'delta',
          'error again',
          'wrapped ${'y' * 70}NEEDLE tail',
        ].join('\r\n'),
      );
      return h;
    }

    test('finds literal and regular-expression matches with context', () async {
      final h = searchable();
      final found = await h.call('terminal_search', {
        'session_id': 's1',
        'pattern': 'error',
      });
      expect(found['matches'], [
        {'line': 2, 'text': 'gamma ERROR three'},
        {'line': 4, 'text': 'error again'},
      ]);
      expect(found['more'], isFalse);
      expect(found['truncated'], isFalse);
      // The announcement names the count, never the pattern.
      expect(h.screen.last, '[MCP] terminal_search → 2 matches');

      final exact = await h.call('terminal_search', {
        'session_id': 's1',
        'pattern': 'error',
        'case_sensitive': true,
      });
      expect((exact['matches'] as List).single, {
        'line': 4,
        'text': 'error again',
      });

      final regex = await h.call('terminal_search', {
        'session_id': 's1',
        'pattern': r'ERR?OR\s+\w+$',
        'regex': true,
        'case_sensitive': true,
        'context_lines': 1,
      });
      expect(regex['matches'], [
        {
          'line': 2,
          'text': 'gamma ERROR three',
          'before': ['Beta two'],
          'after': ['delta'],
        },
      ]);

      final newest = await h.call('terminal_search', {
        'session_id': 's1',
        'pattern': 'ERROR',
        'max_results': 1,
      });
      expect(newest['matches'], [
        {'line': 4, 'text': 'error again'},
      ]);
      expect(newest['more'], isTrue);

      // A match across the wrap is found in the joined line.
      expect(h.terminal.buffer.lines[6].isWrapped, isTrue);
      final wrapped = await h.call('terminal_search', {
        'session_id': 's1',
        'pattern': 'needle',
      });
      expect((wrapped['matches'] as List).single, {
        'line': 5,
        'text': 'wrapped ${'y' * 70}NEEDLE tail',
      });

      final invalid = await h.call('terminal_search', {
        'session_id': 's1',
        'pattern': '(',
        'regex': true,
      });
      expect(invalid['error'], 'invalid_arguments');
    });

    test('a catastrophic regular expression times out without blocking the '
        'application', () async {
      final h = _Harness();
      h.terminal.write('${'a' * 40}b\r\n');
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => ticks++,
      );
      addTearDown(timer.cancel);
      final watch = Stopwatch()..start();
      final result = await h.call('terminal_search', {
        'session_id': 's1',
        'pattern': r'^(a+)+$',
        'regex': true,
      });
      expect(result['error'], 'pattern_timeout');
      expect(watch.elapsed, lessThan(const Duration(seconds: 8)));
      expect(ticks, greaterThan(20), reason: 'the UI isolate kept running');
    });
  });

  group('own [MCP] lines are never matches', () {
    test('a wait does not end on the announcement of the input it '
        'waits for, and a search skips announcements', () async {
      final h = _Harness();
      h.terminal.write(r'$ ');
      final start = McpTerminalView(h.terminal).cursor;
      await h.call('terminal_write', {
        'session_id': 's1',
        'text': 'make deploy-done\r',
      });
      expect(h.screen.any((l) => l.contains('deploy-done')), isTrue);
      final early = await h.call('terminal_wait', {
        'session_id': 's1',
        'since_cursor': start,
        'pattern': 'deploy-done',
        'timeout_seconds': 1,
      });
      expect(early['matched'], isFalse);
      expect(early['timed_out'], isTrue);
      final found = await h.call('terminal_search', {
        'session_id': 's1',
        'pattern': 'deploy-done',
      });
      expect(found['matches'], isEmpty);
      h.terminal.write('\r\ndeploy-done\r\n\$ ');
      final later = await h.call('terminal_wait', {
        'session_id': 's1',
        'since_cursor': start,
        'pattern': 'deploy-done',
        'timeout_seconds': 5,
      });
      expect(later['matched'], isTrue);
    });
  });

  group('terminal_wait', () {
    test('waits for a pattern that appears later', () async {
      final h = _Harness();
      h.terminal.write(r'$ make');
      final start = McpTerminalView(h.terminal).cursor;
      Timer(const Duration(milliseconds: 300), () {
        h.terminal.write('\r\ncompiling\r\nBUILD OK\r\n\$ ');
      });
      final waited = await h.call('terminal_wait', {
        'session_id': 's1',
        'since_cursor': start,
        'pattern': 'build ok',
        'timeout_seconds': 10,
      });
      expect(waited['matched'], isTrue);
      expect(waited['timed_out'], isFalse);
      expect(waited['waited_ms'], greaterThanOrEqualTo(250));
      expect(waited['text'], '\$ make\ncompiling\nBUILD OK\n\$ ');
      expect(waited['first_line'], start);
      expect(waited['cursor'], start + 3);
    });

    test('by default only output after the cursor counts; since_cursor '
        'counts whole lines', () async {
      final h = _Harness();
      h.terminal.write(r'user@host:~$ ');
      final fresh = await h.call('terminal_wait', {
        'session_id': 's1',
        'pattern': r'$',
        'timeout_seconds': 1,
      });
      expect(fresh['matched'], isFalse);
      expect(fresh['timed_out'], isTrue);
      expect(fresh['waited_ms'], greaterThanOrEqualTo(1000));

      final watch = Stopwatch()..start();
      final whole = await h.call('terminal_wait', {
        'session_id': 's1',
        'since_cursor': 0,
        'pattern': r'\$ $',
        'regex': true,
      });
      expect(whole['matched'], isTrue);
      expect(watch.elapsedMilliseconds, lessThan(1000));
    });

    test('without a pattern it returns once the screen is quiet', () async {
      final h = _Harness();
      Timer(const Duration(milliseconds: 150), () => h.terminal.write('late'));
      final waited = await h.call('terminal_wait', {
        'session_id': 's1',
        'idle_ms': 300,
      });
      expect(waited['idle'], isTrue);
      expect(waited['matched'], isFalse);
      expect(waited['waited_ms'], greaterThanOrEqualTo(400));
      expect(waited['text'], 'late');
      // The announcement comes afterwards and is not part of the result.
      expect(h.screen.last, startsWith('[MCP] terminal_wait → quiet after'));
    });

    test('a running wait is cancelled at once, and stops when the session '
        'closes', () async {
      final h = _Harness();
      final watch = Stopwatch()..start();
      final pending = h.protocol.handle(
        _rpc('terminal_wait', {
          'session_id': 's1',
          'pattern': 'never',
          'timeout_seconds': 60,
        }, 'wait'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await h.protocol.handle({
        'jsonrpc': '2.0',
        'method': 'notifications/cancelled',
        'params': {'requestId': 'wait'},
      });
      expect(_content(await pending)['error'], 'cancelled');
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));

      Timer(const Duration(milliseconds: 200), () => h.alive = false);
      final closed = await h.call('terminal_wait', {
        'session_id': 's1',
        'timeout_seconds': 60,
        'idle_ms': 30000,
      });
      expect(closed['error'], 'session_unavailable');
    });

    test('a full-screen program that takes over is matched too', () async {
      final h = _Harness();
      Timer(const Duration(milliseconds: 200), () {
        h.terminal.write('\x1b[?1049h\x1b[H-- INSERT --');
      });
      final waited = await h.call('terminal_wait', {
        'session_id': 's1',
        'pattern': '-- INSERT --',
        'timeout_seconds': 5,
      });
      expect(waited['matched'], isTrue);
      expect(waited['alternate_screen'], isTrue);
    });
  });

  group('terminal_send_keys', () {
    test(
      'named keys become the sequences xterm sends, announced first',
      () async {
        final h = _Harness();
        h.onInput = (_) => expect(
          h.screen.last,
          '[MCP] terminal_send_keys ctrl_c enter up f5 shift_tab ctrl_at '
          'ctrl_backslash',
        );
        final sent = await h.call('terminal_send_keys', {
          'session_id': 's1',
          'keys': [
            'ctrl_c',
            'enter',
            'up',
            'f5',
            'shift_tab',
            'ctrl_at',
            'ctrl_backslash',
          ],
        });
        expect(sent, {'sent': true, 'keys': 7});
        expect(h.input, ['\x03\r\x1b[A\x1b[15~\x1b[Z\x00\x1c']);

        // Application cursor keys (set by vim, less, ...).
        h.onInput = null;
        h.terminal.write('\x1b[?1h');
        await h.call('terminal_send_keys', {
          'session_id': 's1',
          'keys': ['up', 'left', 'home', 'end', 'page_down', 'escape'],
        });
        expect(h.input.last, '\x1bOA\x1bOD\x1bOH\x1bOF\x1b[6~\x1b');
        expect(mcpKeySequence('ctrl_z', cursorKeysMode: false), '\x1a');
        expect(mcpKeySequence('ctrl_a', cursorKeysMode: false), '\x01');
        expect(mcpKeySequence('f12', cursorKeysMode: true), '\x1b[24~');
      },
    );

    test(
      'needs read-write access, a connected terminal and known keys',
      () async {
        final h = _Harness();
        for (final keys in [
          <String>[],
          ['bogus'],
          List.filled(33, 'enter'),
        ]) {
          expect(
            (await h.raw('terminal_send_keys', {
              'session_id': 's1',
              'keys': keys,
            })).status,
            400,
          );
        }
        h.modes['h1'] = McpAccessMode.readOnly;
        final readOnly = await h.call('terminal_send_keys', {
          'session_id': 's1',
          'keys': ['ctrl_c'],
        });
        expect(readOnly['error'], 'read_only');
        h.modes.remove('h1');
        h.state = 'disconnected';
        final offline = await h.call('terminal_send_keys', {
          'session_id': 's1',
          'keys': ['enter'],
        });
        expect(offline['error'], 'not_a_terminal');
        expect(
          (await h.call('terminal_send_keys', {
            'session_id': 's2',
            'keys': ['enter'],
          }))['error'],
          'session_unavailable',
        );
        expect(h.input, isEmpty);
      },
    );
  });

  group('terminal_run', () {
    test('announces, then types, then waits; the echoed command never '
        'matches', () async {
      final h = _Harness();
      h.terminal.write(r'user@host:~$ ');
      var announcedFirst = false;
      h.onInput = (text) {
        announcedFirst = h.screen.last == '[MCP] terminal_run echo DONE';
        // The remote echoes the command at once and answers later.
        h.terminal.write('echo DONE\r\n');
        Timer(const Duration(milliseconds: 300), () {
          h.terminal.write('DONE\r\nuser@host:~\$ ');
        });
      };
      final run = await h.call('terminal_run', {
        'session_id': 's1',
        'command': 'echo DONE',
        'until': 'done',
        'timeout_seconds': 10,
      });
      expect(announcedFirst, isTrue);
      expect(h.input, ['echo DONE\r']);
      expect(run['matched'], isTrue);
      expect(run['waited_ms'], greaterThanOrEqualTo(250));
      expect(run['output'], 'echo DONE\nDONE\nuser@host:~\$ ');
      expect(run['output'], isNot(contains('[MCP]')));
      expect(run['cursor'], (run['first_line'] as int) + 2);
    });

    test('without until it returns when the output is quiet', () async {
      final h = _Harness();
      h.onInput = (_) => h.terminal.write('ls\r\nfile1  file2\r\n\$ ');
      final run = await h.call('terminal_run', {
        'session_id': 's1',
        'command': 'ls',
        'idle_ms': 200,
      });
      expect(run['idle'], isTrue);
      expect(run['timed_out'], isFalse);
      expect(run['output'], 'ls\nfile1  file2\n\$ ');

      h.onInput = null;
      final slow = await h.call('terminal_run', {
        'session_id': 's1',
        'command': 'sleep 99',
        'until': 'never printed',
        'timeout_seconds': 1,
      });
      expect(slow['timed_out'], isTrue);
      expect(slow['matched'], isFalse);
    });

    test('refuses multi-line input, control characters, full-screen '
        'programs and read-only machines before typing anything', () async {
      final h = _Harness();
      final multi = await h.call('terminal_run', {
        'session_id': 's1',
        'command': 'ls\nrm -rf /tmp/x',
      });
      expect(multi['error'], 'invalid_arguments');
      expect(multi['message'], contains('terminal_write'));
      expect(
        (await h.call('terminal_run', {
          'session_id': 's1',
          'command': 'ls\r',
        }))['error'],
        'invalid_arguments',
      );
      expect(
        (await h.call('terminal_run', {
          'session_id': 's1',
          'command': 'ls \x1b[A',
        }))['error'],
        'invalid_arguments',
      );
      expect(
        (await h.call('terminal_run', {
          'session_id': 's1',
          'command': 'ls',
          'until': '(',
          'regex': true,
        }))['error'],
        'invalid_arguments',
      );
      h.terminal.write('\x1b[?1049h');
      expect(
        (await h.call('terminal_run', {
          'session_id': 's1',
          'command': 'ls',
        }))['error'],
        'busy_fullscreen',
      );
      h.terminal.write('\x1b[?1049l');
      h.modes['h1'] = McpAccessMode.readOnly;
      final before = h.screen.length;
      expect(
        (await h.call('terminal_run', {
          'session_id': 's1',
          'command': 'reboot',
        }))['error'],
        'read_only',
      );
      expect(h.screen.length, before, reason: 'nothing shown when denied');
      expect(h.input, isEmpty);
      expect(h.screen.join('\n'), isNot(contains('terminal_run ls')));
    });
  });

  group('SFTP paths', () {
    test(
      'sftp_stat reports type, mode and absence without following links',
      () async {
        final h = _Harness();
        h.sftp.entries['/etc/hosts'] = _attrs(_file, permissions: 0x1a4);
        h.sftp.entries['/srv/current'] = _attrs(_symlink, permissions: 0x1ff);
        expect(
          await h.call('sftp_stat', {'session_id': 's1', 'path': '/etc/hosts'}),
          {
            'path': '/etc/hosts',
            'exists': true,
            'type': 'file',
            'size': 42,
            'permissions': '0644',
            'modified_at': 1700000000,
            'uid': 1000,
            'gid': 100,
          },
        );
        final link = await h.call('sftp_stat', {
          'session_id': 's1',
          'path': '/srv/current',
        });
        expect([link['type'], link['permissions']], ['symlink', '0777']);
        expect(
          await h.call('sftp_stat', {'session_id': 's1', 'path': '/nope'}),
          {'path': '/nope', 'exists': false},
        );
        expect(h.sftp.calls, everyElement(endsWith(' nofollow')));
        expect(h.screen.last, '[MCP] sftp_stat /nope → not found');
        expect(
          (await h.call('sftp_stat', {
            'session_id': 's1',
            'path': 'etc',
          }))['error'],
          'invalid_path',
        );
        h.modes['h1'] = McpAccessMode.readOnly;
        expect(
          (await h.call('sftp_stat', {
            'session_id': 's1',
            'path': '/etc/hosts',
          }))['exists'],
          isTrue,
        );
        expect((h.connection.client as _Client).opened, 4);
        expect(h.sftp.closed, 4);
      },
    );

    test(
      'mkdir and rename never overwrite; changes are announced first',
      () async {
        final h = _Harness();
        h.sftp.entries['/srv/a'] = _attrs(_file);
        h.sftp.entries['/srv/b'] = _attrs(_file);
        final client = h.connection.client as _Client;

        final opened = client.opened;
        final exists = await h.call('sftp_mkdir', {
          'session_id': 's1',
          'path': '/srv/a',
        });
        expect(exists['error'], 'already_exists');
        expect(h.sftp.calls, isNot(contains('mkdir /srv/a')));
        expect(client.opened, opened + 1);

        expect(
          await h.call('sftp_mkdir', {'session_id': 's1', 'path': '/srv/new'}),
          {'created': true, 'path': '/srv/new'},
        );
        expect(h.screen.sublist(h.screen.length - 2), [
          '[MCP] sftp_mkdir /srv/new',
          '[MCP] sftp_mkdir → created',
        ]);

        final taken = await h.call('sftp_rename', {
          'session_id': 's1',
          'from': '/srv/a',
          'to': '/srv/b',
        });
        expect(taken['error'], 'already_exists');
        expect(h.sftp.calls.where((c) => c.startsWith('rename')), isEmpty);
        expect(h.screen.last, '[MCP] sftp_rename → failed: already_exists');
        expect(
          (await h.call('sftp_rename', {
            'session_id': 's1',
            'from': '/srv/missing',
            'to': '/srv/c',
          }))['error'],
          'not_found',
        );
        expect(
          await h.call('sftp_rename', {
            'session_id': 's1',
            'from': '/srv/a',
            'to': '/srv/c',
          }),
          {'renamed': true, 'from': '/srv/a', 'to': '/srv/c'},
        );
        expect(h.sftp.calls.last, 'rename /srv/a /srv/c');
        expect(h.screen.sublist(h.screen.length - 2), [
          '[MCP] sftp_rename /srv/a → /srv/c',
          '[MCP] sftp_rename → renamed',
        ]);
      },
    );

    test('remove checks the type, removes only empty directories and maps '
        'server errors', () async {
      final h = _Harness();
      h.sftp.entries['/srv/file'] = _attrs(_file);
      h.sftp.entries['/srv/dir'] = _attrs(_directory);
      h.sftp.entries['/srv/link'] = _attrs(_symlink);

      final wrongDir = await h.call('sftp_remove', {
        'session_id': 's1',
        'path': '/srv/dir',
        'type': 'file',
      });
      expect(wrongDir['error'], 'type_mismatch');
      final wrongFile = await h.call('sftp_remove', {
        'session_id': 's1',
        'path': '/srv/file',
        'type': 'directory',
      });
      expect(wrongFile['error'], 'type_mismatch');
      expect(
        h.sftp.calls.where(
          (c) => c.startsWith('remove') || c.startsWith('rmdir'),
        ),
        isEmpty,
      );

      // A symbolic link is a "file": the link goes, never its target.
      expect(
        await h.call('sftp_remove', {
          'session_id': 's1',
          'path': '/srv/link',
          'type': 'file',
        }),
        {'removed': true, 'path': '/srv/link', 'type': 'file'},
      );
      expect(h.sftp.calls.last, 'remove /srv/link');

      h.sftp.removeError = SftpStatusCode.failure;
      expect(
        (await h.call('sftp_remove', {
          'session_id': 's1',
          'path': '/srv/dir',
          'type': 'directory',
        }))['error'],
        'directory_not_empty',
      );
      h.sftp.removeError = SftpStatusCode.permissionDenied;
      expect(
        (await h.call('sftp_remove', {
          'session_id': 's1',
          'path': '/srv/file',
          'type': 'file',
        }))['error'],
        'permission_denied',
      );
      h.sftp.removeError = null;
      expect(
        (await h.call('sftp_remove', {
          'session_id': 's1',
          'path': '/srv/dir',
          'type': 'directory',
        }))['removed'],
        isTrue,
      );
      expect(h.sftp.calls.last, 'rmdir /srv/dir');
      expect(
        (await h.call('sftp_remove', {
          'session_id': 's1',
          'path': '/srv/gone',
          'type': 'file',
        }))['error'],
        'not_found',
      );
    });

    test(
      'read-only machines and non-SSH sessions cannot change files',
      () async {
        final h = _Harness();
        h.sftp.entries['/srv/a'] = _attrs(_file);
        h.modes['h1'] = McpAccessMode.readOnly;
        for (final (tool, args) in [
          ('sftp_mkdir', {'path': '/srv/x'}),
          ('sftp_rename', {'from': '/srv/a', 'to': '/srv/b'}),
          ('sftp_remove', {'path': '/srv/a', 'type': 'file'}),
        ]) {
          final result = await h.call(tool, {'session_id': 's1', ...args});
          expect(result['error'], 'read_only', reason: tool);
        }
        expect((h.connection.client as _Client).opened, 0);
        expect(h.sftp.calls, isEmpty);
        h.modes.remove('h1');
        expect(
          (await h.call('sftp_mkdir', {
            'session_id': 'c1',
            'path': '/x',
          }))['error'],
          'ssh_required',
        );
      },
    );
  });

  group('ui_notify', () {
    test(
      'posts a notice, is rate limited and needs no machine access',
      () async {
        final h = _Harness();
        final received = <McpNotice>[];
        final subscription = McpNotices.stream.listen(received.add);
        addTearDown(subscription.cancel);
        // No machine is available at all.
        h.modes
          ..['h1'] = McpAccessMode.denied
          ..['h3'] = McpAccessMode.denied
          ..['h4'] = McpAccessMode.denied;
        final now = DateTime(2026, 11, 26, 12);
        final first = await withClock(
          Clock.fixed(now),
          () => h.call('ui_notify', {
            'message': 'Build finished',
            'level': 'success',
          }),
        );
        expect(first, {'posted': true, 'shown': true});
        await pumpEventQueue();
        expect(received.single.message, 'Build finished');
        expect(received.single.level, McpNoticeLevel.success);
        expect(received.single.source, isNull);

        final limited = await withClock(
          Clock.fixed(now.add(const Duration(milliseconds: 1500))),
          () => h.call('ui_notify', {'message': 'again'}),
        );
        expect(limited['error'], 'rate_limited');
        final later = await withClock(
          Clock.fixed(now.add(const Duration(seconds: 2))),
          () => h.call('ui_notify', {'message': 'again'}),
        );
        expect(later['posted'], isTrue);
        await pumpEventQueue();
        expect(received.last.level, McpNoticeLevel.info);
      },
    );

    test('a named session must be visible and shows the message', () async {
      final h = _Harness();
      final received = <McpNotice>[];
      final subscription = McpNotices.stream.listen(received.add);
      addTearDown(subscription.cancel);
      expect(
        (await h.call('ui_notify', {
          'message': 'hi',
          'session_id': 's2',
        }))['error'],
        'session_unavailable',
      );
      expect(
        (await h.call('ui_notify', {
          'message': 'hi',
          'session_id': 'unknown',
        }))['error'],
        'session_unavailable',
      );
      h.modes['h1'] = McpAccessMode.readOnly;
      final shown = await h.call('ui_notify', {
        'message': 'Check\x1b[2J this',
        'level': 'warning',
        'session_id': 's1',
      });
      expect(shown['posted'], isTrue);
      expect(h.screen.last, r'[MCP] ui_notify warning: Check\e[2J this');
      await pumpEventQueue();
      expect(received.single.source, 's1');
      expect(received.single.level, McpNoticeLevel.warning);
    });
  });
}
