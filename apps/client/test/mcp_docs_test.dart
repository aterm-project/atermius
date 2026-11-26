import 'dart:io';

import 'package:aterm_client/mcp/mcp_docs.dart';
import 'package:aterm_client/mcp/mcp_protocol.dart';
import 'package:aterm_client/mcp/mcp_service.dart';
import 'package:aterm_client/mcp/mcp_tools.dart';
import 'package:aterm_client/mcp/mcp_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> rpc(
  String method, {
  Object id = 1,
  Map<String, dynamic> params = const {},
}) => {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params};
Map result(McpReply reply) => reply.body!['result'] as Map;
Map error(McpReply reply) => reply.body!['error'] as Map;

McpProtocol _protocol({bool unlocked = true}) => McpProtocol(
  workspace: McpWorkspace(
    scope: () => 'fixture',
    describe: () => {'mode': 'fixture'},
    hosts: () => const [],
    sessions: () => const [],
    connect: (_) async {},
    openConsole: () async {},
  ),
  validateAccess: () {
    if (!unlocked) throw const McpToolException('locked', 'Locked');
  },
  access: (_) => McpAccessMode.denied,
);

/// Backticked snake_case words that name tools in prose.
final _toolMention = RegExp(
  r'`((?:docs|workspace|hosts?|groups|sessions?|console|terminal|ssh|sftp|ui)_[a-z_]+)`',
);

void main() {
  test(
    'initialize and discovery advertise tools, resources and prompts',
    () async {
      final p = _protocol();
      final init = result(
        await p.handle(
          rpc(
            'initialize',
            params: {
              'protocolVersion': '2025-11-25',
              'capabilities': {},
              'clientInfo': {'name': 't', 'version': '1'},
            },
          ),
        ),
      );
      final caps = init['capabilities'] as Map;
      expect(caps.keys, containsAll(['tools', 'resources', 'prompts']));
      expect(init['instructions'], contains('atermius://docs/index'));
      expect(init['instructions'], contains('docs_read'));
    },
  );

  test(
    'resources/list names every topic; each one reads as Markdown',
    () async {
      final p = _protocol();
      final list = result(await p.handle(rpc('resources/list')));
      final uris = [
        for (final r in list['resources'] as List) (r as Map)['uri'],
      ];
      expect(uris, [for (final t in McpDocs.topics) 'atermius://docs/$t']);
      for (final r in list['resources'] as List) {
        final entry = r as Map;
        expect(entry['mimeType'], 'text/markdown');
        expect(entry['title'], isA<String>());
        expect(entry['description'], isA<String>());
        final read = result(
          await p.handle(rpc('resources/read', params: {'uri': entry['uri']})),
        );
        final contents = read['contents'] as List;
        expect(contents, hasLength(1));
        expect((contents.single as Map)['uri'], entry['uri']);
        expect((contents.single as Map)['mimeType'], 'text/markdown');
        expect(((contents.single as Map)['text'] as String).trim(), isNotEmpty);
      }
    },
  );

  test(
    'every tool has a reference page through the resource template',
    () async {
      final p = _protocol();
      final templates = result(await p.handle(rpc('resources/templates/list')));
      expect(
        ((templates['resourceTemplates'] as List).single as Map)['uriTemplate'],
        'atermius://docs/tools/{name}',
      );
      final reference = McpDocs.topicText('tools');
      for (final tool in mcpTools) {
        expect(reference, contains('## ${tool.name}'));
        final read = result(
          await p.handle(
            rpc(
              'resources/read',
              params: {'uri': 'atermius://docs/tools/${tool.name}'},
            ),
          ),
        );
        final text =
            ((read['contents'] as List).single as Map)['text'] as String;
        expect(text, startsWith('# ${tool.name}'));
        expect(text, contains(tool.title));
        expect(text, contains('Access:'));
        for (final parameter in tool.properties.keys) {
          expect(text, contains('`$parameter`'), reason: tool.name);
        }
      }
    },
  );

  test('unknown resources are JSON-RPC -32002; bad URIs are -32602', () async {
    final p = _protocol();
    final missing = await p.handle(
      rpc('resources/read', params: {'uri': 'atermius://docs/nope'}),
    );
    expect(error(missing)['code'], -32002);
    final missingTool = await p.handle(
      rpc('resources/read', params: {'uri': 'atermius://docs/tools/nope'}),
    );
    expect(error(missingTool)['code'], -32002);
    final bad = await p.handle(rpc('resources/read', params: {'uri': 7}));
    expect(error(bad)['code'], -32602);
  });

  test('documentation needs the same authorization as tools', () async {
    final p = _protocol(unlocked: false);
    final reply = await p.handle(
      rpc('resources/read', params: {'uri': 'atermius://docs/index'}),
    );
    expect(reply.status, 403);
  });

  test('prose only mentions tools that exist', () {
    final names = {for (final t in mcpTools) t.name};
    for (final topic in McpDocs.topics) {
      final text = McpDocs.topicText(topic);
      for (final match in _toolMention.allMatches(text)) {
        expect(names, contains(match.group(1)), reason: 'docs topic $topic');
      }
    }
    for (final prompt in McpPrompts.all) {
      final args = {for (final a in prompt.arguments) a.name: 'x'};
      final text =
          ((prompt.render(args)['messages'] as List).single as Map)['content']
              as Map;
      for (final word in RegExp(
        r'\b((?:hosts?|sessions?|terminal|ssh|sftp|ui)_[a-z_]+)\b',
      ).allMatches(text['text'] as String)) {
        expect(names, contains(word.group(1)), reason: prompt.name);
      }
    }
  });

  test('every error code the tools can raise is documented', () {
    final documented = McpDocs.topicText('errors');
    final code = RegExp(r"McpToolException\(\s*'([a-z_]+)'");
    final found = <String>{};
    for (final file in Directory('lib/mcp').listSync().whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final m in code.allMatches(file.readAsStringSync())) {
        found.add(m.group(1)!);
      }
    }
    // `locked` only guards enabling MCP; it never reaches a client.
    found.remove('locked');
    expect(found, isNotEmpty);
    for (final c in found) {
      expect(documented, contains('`$c`'), reason: c);
    }
  });

  test(
    'prompts list with arguments; get renders, validates and quotes',
    () async {
      final p = _protocol();
      final list = result(await p.handle(rpc('prompts/list')));
      final prompts = list['prompts'] as List;
      expect(prompts.map((e) => (e as Map)['name']), [
        for (final prompt in McpPrompts.all) prompt.name,
      ]);
      for (final entry in prompts) {
        expect((entry as Map)['title'], isA<String>());
        expect(entry['arguments'], isA<List>());
      }
      final ok = result(
        await p.handle(
          rpc(
            'prompts/get',
            params: {
              'name': 'run_command',
              'arguments': {'host': 'web "01"', 'command': 'uptime'},
            },
          ),
        ),
      );
      final message = (ok['messages'] as List).single as Map;
      expect(message['role'], 'user');
      final text = (message['content'] as Map)['text'] as String;
      expect(text, contains(r'"web \"01\""'));
      expect(text, contains('"uptime"'));
      expect(text, contains('terminal_run'));

      Future<int> code(Map<String, dynamic> params) async =>
          error(await p.handle(rpc('prompts/get', params: params)))['code']
              as int;
      expect(await code({'name': 'nope'}), -32602);
      expect(
        await code({
          'name': 'run_command',
          'arguments': {'host': 'a'},
        }),
        -32602,
      );
      expect(
        await code({
          'name': 'run_command',
          'arguments': {'host': 'a', 'command': 'b', 'extra': 'c'},
        }),
        -32602,
      );
      expect(
        await code({
          'name': 'diagnose_host',
          'arguments': {'host': 'x' * 2001},
        }),
        -32602,
      );
      // Optional arguments may be left out.
      final diagnose = await p.handle(
        rpc(
          'prompts/get',
          params: {
            'name': 'diagnose_host',
            'arguments': {'host': 'db'},
          },
        ),
      );
      expect(diagnose.body!['result'], isNotNull);
    },
  );

  test('docs_read serves the same documents to tool-only clients', () async {
    final p = _protocol();
    Future<Map> callDocs(Map<String, dynamic> args) async => result(
      await p.handle(
        rpc('tools/call', params: {'name': 'docs_read', 'arguments': args}),
      ),
    );
    final index = await callDocs({});
    expect(index['isError'], isFalse);
    final structured = index['structuredContent'] as Map;
    expect(structured['topic'], 'index');
    expect(structured['text'], McpDocs.topicText('index'));
    expect(structured['topics'], McpDocs.topics);

    final one = (await callDocs({'tool': 'ssh_exec'}))['structuredContent'];
    expect((one as Map)['uri'], 'atermius://docs/tools/ssh_exec');
    expect(one['text'], startsWith('# ssh_exec'));

    final unknown = await callDocs({'tool': 'nope'});
    expect(unknown['isError'], isTrue);
    expect((unknown['structuredContent'] as Map)['error'], 'invalid_arguments');

    final badTopic = await p.handle(
      rpc(
        'tools/call',
        params: {
          'name': 'docs_read',
          'arguments': {'topic': 'secrets'},
        },
      ),
    );
    expect(error(badTopic)['code'], -32602);
  });

  test('tools carry titles and consistent hints', () {
    for (final tool in mcpTools) {
      final json = tool.toJson();
      expect(json['title'], isNotEmpty, reason: tool.name);
      final hints = json['annotations'] as Map;
      expect(hints['title'], json['title']);
      expect(hints['readOnlyHint'], !tool.mutating, reason: tool.name);
      if (!tool.mutating) {
        expect(hints['destructiveHint'], isFalse, reason: tool.name);
      }
    }
    final docs = mcpTools.firstWhere((t) => t.name == 'docs_read');
    expect(docs.mutating, isFalse);
    expect(McpDocs.accessOf(docs), startsWith('none'));
  });
}
