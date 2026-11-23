import 'dart:convert';

import 'package:aterm_client/domain/host_login_export.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const passwordCredential = CredentialRecord(
    id: 'credential-password',
    name: 'Deploy password',
    username: 'deploy',
    secret: 'p@ss "quoted" \\ word',
  );
  const keyCredential = CredentialRecord(
    id: 'credential-key',
    name: 'Deploy key',
    username: '',
    kind: AuthKind.privateKey,
    privateKey:
        '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n',
    passphrase: 'key passphrase',
    certificate: 'ssh-ed25519-cert-v01@openssh.com AAAAcert deploy',
  );

  Future<Map<String, dynamic>> export(
    HostRecord host, {
    Map<String, CredentialRecord> credentials = const {},
    List<HostRecord> others = const [],
    String? temporaryJumpHostId,
    void Function(HostLoginExport export)? inspect,
  }) async {
    final result = await exportHostLogin(
      host: host,
      credentialFor: (host) => credentials[host.id],
      hostById: (id) => others.where((host) => host.id == id).firstOrNull,
      temporaryJumpHostId: temporaryJumpHostId,
    );
    inspect?.call(result);
    return jsonDecode(result.json) as Map<String, dynamic>;
  }

  test('a password Host exports address, user name and password', () async {
    const host = HostRecord(
      id: 'web',
      name: 'web-1',
      address: '203.0.113.10',
      port: 2222,
      username: 'ignored-when-the-credential-names-a-user',
    );
    late HostLoginExport result;
    final json = await export(
      host,
      credentials: {'web': passwordCredential},
      inspect: (export) => result = export,
    );
    expect(json, {
      'name': 'web-1',
      'protocol': 'ssh',
      'host': '203.0.113.10',
      'port': 2222,
      'username': 'deploy',
      'password': 'p@ss "quoted" \\ word',
    });
    expect(json.keys.toList(), [
      'name',
      'protocol',
      'host',
      'port',
      'username',
      'password',
    ]);
    expect(result.hasSecret, isTrue);
    // Readable when pasted: one field per line.
    expect(result.json, startsWith('{\n  "name": "web-1",\n'));
  });

  test('a key Host exports the key with its passphrase and certificate, '
      'and falls back to the Host user name', () async {
    const host = HostRecord(
      id: 'db',
      name: 'db-1',
      address: 'db.example.test',
      username: 'postgres',
      authKind: AuthKind.privateKey,
    );
    late HostLoginExport result;
    final json = await export(
      host,
      credentials: {'db': keyCredential},
      inspect: (export) => result = export,
    );
    expect(json, {
      'name': 'db-1',
      'protocol': 'ssh',
      'host': 'db.example.test',
      'port': 22,
      'username': 'postgres',
      'private_key': keyCredential.privateKey,
      'passphrase': 'key passphrase',
      'certificate': keyCredential.certificate,
    });
    expect(json.containsKey('password'), isFalse);
    expect(result.hasSecret, isTrue);
  });

  test('a key without passphrase or certificate exports the key alone', () async {
    const host = HostRecord(id: 'k', name: 'k', address: 'k.example.test');
    final json = await export(
      host,
      credentials: {
        'k': const CredentialRecord(
          id: 'c',
          name: 'c',
          username: 'root',
          kind: AuthKind.privateKey,
          privateKey: 'KEY',
          passphrase: '',
        ),
      },
    );
    expect(json['private_key'], 'KEY');
    expect(json.containsKey('passphrase'), isFalse);
    expect(json.containsKey('certificate'), isFalse);
  });

  test('nothing saved still exports where and who, and says so', () async {
    const host = HostRecord(
      id: 'typed',
      name: 'typed',
      address: 'typed.example.test',
      username: 'alice',
    );
    late HostLoginExport result;
    final json = await export(host, inspect: (export) => result = export);
    expect(json, {
      'name': 'typed',
      'protocol': 'ssh',
      'host': 'typed.example.test',
      'port': 22,
      'username': 'alice',
    });
    expect(result.hasSecret, isFalse);

    // A lookup that fails (locked store, broken reference) is the same case.
    final failed = await exportHostLogin(
      host: host,
      credentialFor: (_) => throw StateError('locked'),
      hostById: (_) => throw StateError('locked'),
    );
    expect(jsonDecode(failed.json), json);
    expect(failed.hasSecret, isFalse);
  });

  test('Jump Hosts are listed in connection order with their own logins', () async {
    const outer = HostRecord(
      id: 'outer',
      name: 'bastion-outer',
      address: 'outer.example.test',
      username: 'jump',
    );
    const inner = HostRecord(
      id: 'inner',
      name: 'bastion-inner',
      address: '10.0.0.1',
      port: 2200,
      jumpHostId: 'outer',
    );
    const target = HostRecord(
      id: 'target',
      name: 'target',
      address: '10.0.0.9',
      jumpHostId: 'inner',
    );
    final json = await export(
      target,
      credentials: {
        'target': passwordCredential,
        'inner': keyCredential,
        // The outer hop has nothing saved.
      },
      others: const [outer, inner],
    );
    expect(json['password'], passwordCredential.secret);
    expect(json.keys.last, 'jump_hosts');
    expect(json['jump_hosts'], [
      {
        'name': 'bastion-outer',
        'protocol': 'ssh',
        'host': 'outer.example.test',
        'port': 22,
        'username': 'jump',
      },
      {
        'name': 'bastion-inner',
        'protocol': 'ssh',
        'host': '10.0.0.1',
        'port': 2200,
        'private_key': keyCredential.privateKey,
        'passphrase': 'key passphrase',
        'certificate': keyCredential.certificate,
      },
    ]);
  });

  test('a session pointed at another Jump Host exports that route', () async {
    const saved = HostRecord(id: 'saved', name: 'saved', address: 's.test');
    const other = HostRecord(id: 'other', name: 'other', address: 'o.test');
    const target = HostRecord(
      id: 'target',
      name: 'target',
      address: 't.test',
      jumpHostId: 'saved',
    );
    final json = await export(
      target,
      others: const [saved, other],
      temporaryJumpHostId: 'other',
    );
    expect((json['jump_hosts'] as List).single['name'], 'other');
  });

  test('a broken or cyclic Jump Host chain ends the list instead of failing', () async {
    const a = HostRecord(id: 'a', name: 'a', address: 'a.test', jumpHostId: 'b');
    const b = HostRecord(id: 'b', name: 'b', address: 'b.test', jumpHostId: 'a');
    final cyclic = await export(a, others: const [a, b]);
    expect((cyclic['jump_hosts'] as List).map((hop) => hop['name']), ['b']);

    const dangling = HostRecord(
      id: 'd',
      name: 'd',
      address: 'd.test',
      jumpHostId: 'gone',
    );
    expect((await export(dangling)).containsKey('jump_hosts'), isFalse);
  });

  test('Telnet never exports a saved credential or a Jump Host', () async {
    const jump = HostRecord(id: 'jump', name: 'jump', address: 'j.test');
    const host = HostRecord(
      id: 'switch',
      name: 'switch',
      address: '192.0.2.7',
      protocol: HostProtocol.telnet,
      username: 'admin',
      jumpHostId: 'jump',
    );
    late HostLoginExport result;
    final json = await export(
      host,
      credentials: {'switch': passwordCredential},
      others: const [jump],
      inspect: (export) => result = export,
    );
    expect(json, {
      'name': 'switch',
      'protocol': 'telnet',
      'host': '192.0.2.7',
      'port': 23,
      'username': 'admin',
    });
    expect(result.hasSecret, isFalse);
  });

  test('remote desktop Hosts export their protocol, port and password', () async {
    const host = HostRecord(
      id: 'win',
      name: 'win',
      address: 'win.example.test',
      protocol: HostProtocol.rdp,
    );
    final json = await export(
      host,
      credentials: {
        'win': const CredentialRecord(
          id: 'c',
          name: 'c',
          username: r'CORP\admin',
          secret: 'rdp-password',
        ),
      },
    );
    expect(json['protocol'], 'rdp');
    expect(json['port'], 3389);
    expect(json['username'], r'CORP\admin');
    expect(json['password'], 'rdp-password');
  });
}
