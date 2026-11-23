import 'dart:async';
import 'dart:convert';

import 'models.dart';

/// What [exportHostLogin] produced.
class HostLoginExport {
  const HostLoginExport({required this.json, required this.hasSecret});

  /// Indented JSON object, ready for the clipboard.
  final String json;

  /// Whether a password or private key of the Host itself is in [json]. False
  /// when nothing is saved for it (it is typed at each sign-in), in which
  /// case [json] still carries the address and user name.
  final bool hasSecret;
}

/// The sign-in details of [host] as one JSON object, for handing a session to
/// a script or an agent in a single paste:
///
/// ```json
/// {
///   "name": "web-1",
///   "protocol": "ssh",
///   "host": "203.0.113.10",
///   "port": 22,
///   "username": "deploy",
///   "password": "…",
///   "private_key": "-----BEGIN OPENSSH PRIVATE KEY-----\n…",
///   "passphrase": "…",
///   "certificate": "ssh-ed25519-cert-v01@openssh.com …",
///   "jump_hosts": [{ "name": "bastion", "host": "…", … }]
/// }
/// ```
///
/// Only what applies is present: `password` for password sign-in,
/// `private_key` (with `passphrase` and `certificate` when the key has them)
/// for key sign-in, and `jump_hosts` (in connection order, the first hop
/// first, each with the same fields) when the Host is reached through SSH
/// Jump Hosts.
///
/// [credentialFor] returns what the Host signs in with, or null when nothing
/// is saved; a lookup that throws counts as nothing saved, so the address and
/// user name are still exported. [hostById] finds a Jump Host.
/// [temporaryJumpHostId] replaces the Host's saved Jump Host, as a session
/// that was pointed at another one does.
Future<HostLoginExport> exportHostLogin({
  required HostRecord host,
  required FutureOr<CredentialRecord?> Function(HostRecord host) credentialFor,
  required FutureOr<HostRecord?> Function(String id) hostById,
  String? temporaryJumpHostId,
}) async {
  Future<CredentialRecord?> credentialOf(HostRecord host) async {
    try {
      return await credentialFor(host);
    } on Object {
      return null;
    }
  }

  // Telnet always signs in interactively: a saved credential (a Group default,
  // say) is never what its session used.
  final credential = host.protocol == HostProtocol.telnet
      ? null
      : await credentialOf(host);
  final login = _loginFields(host, credential);

  // Jump Hosts only apply to SSH. Walked from the target outwards, so the
  // list is reversed into connection order afterwards.
  final hops = <Map<String, Object?>>[];
  if (host.protocol == HostProtocol.ssh) {
    final seen = <String>{host.id};
    var nextId = temporaryJumpHostId ?? host.jumpHostId;
    while (nextId != null && hops.length < maxJumpHostHops && seen.add(nextId)) {
      HostRecord? hop;
      try {
        hop = await hostById(nextId);
      } on Object {
        hop = null;
      }
      if (hop == null) break;
      hops.add(_loginFields(hop, await credentialOf(hop)));
      nextId = hop.jumpHostId;
    }
  }

  return HostLoginExport(
    json: const JsonEncoder.withIndent('  ').convert({
      ...login,
      if (hops.isNotEmpty) 'jump_hosts': hops.reversed.toList(),
    }),
    hasSecret: login.containsKey('password') || login.containsKey('private_key'),
  );
}

Map<String, Object?> _loginFields(HostRecord host, CredentialRecord? credential) {
  bool present(String? value) => value != null && value.isNotEmpty;
  // The same choice the connection makes: the credential's user name, and the
  // Host's own when the credential leaves it open.
  final username = present(credential?.username)
      ? credential!.username
      : host.username;
  final usesKey = credential?.kind == AuthKind.privateKey;
  return {
    'name': host.name,
    'protocol': host.protocol.name,
    'host': host.address,
    'port': host.port,
    if (username.isNotEmpty) 'username': username,
    if (credential != null && !usesKey && present(credential.secret))
      'password': credential.secret,
    if (usesKey && present(credential?.privateKey)) ...{
      'private_key': credential!.privateKey,
      if (present(credential.passphrase)) 'passphrase': credential.passphrase,
      if (present(credential.certificate))
        'certificate': credential.certificate,
    },
  };
}
