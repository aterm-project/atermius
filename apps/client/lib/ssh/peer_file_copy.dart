import 'dart:convert';
import 'dart:typed_data';

import 'scp_transfer_types.dart';

enum FileCopyRoute { local, direct }

/// Runs on the source. The destination directory is an operation-owned,
/// private SFTP directory. Only the pinned peer can receive file bytes.
String peerFileCopyCommand({
  required String from,
  required String stage,
  required String address,
  required int port,
  required String username,
  required Uint8List hostKey,
  required int size,
}) {
  if (!RegExp(r'^[a-zA-Z0-9.:_%\-]+$').hasMatch(address) ||
      address.startsWith('-') ||
      !RegExp(r'^[a-zA-Z0-9_.@\\-]+$').hasMatch(username) ||
      port < 1 ||
      port > 65535 ||
      size < 0 ||
      size > sshTransferMaximumBytes ||
      hostKey.length < 5) {
    throw const FormatException('Unsupported SSH peer');
  }
  final length = ByteData.sublistView(hostKey).getUint32(0);
  if (length == 0 || length > 128 || length + 4 >= hostKey.length) {
    throw const FormatException('Invalid SSH host key');
  }
  final type = ascii.decode(hostKey.sublist(4, 4 + length));
  if (!RegExp(r'^[a-zA-Z0-9@._-]+$').hasMatch(type)) {
    throw const FormatException('Invalid SSH host key type');
  }
  final input = quoteSshTransferPath(validateSshTransferPath(from));
  final directory = quoteSshTransferPath(validateSshTransferPath(stage));
  final knownHosts =
      'KnownHostsCommand=/bin/echo atermius-peer $type '
      '${base64Encode(hostKey)}';
  // Read one extra byte so a source that grows cannot silently be truncated.
  final receiveScript =
      'cd $directory && umask 077 && set -C && '
      'exec head -c ${size + 1} > payload';
  // The login shell may be cmd or PowerShell. Give it only fixed syntax and
  // an ASCII token; interpret the validated, quoted path exclusively in sh.
  final encoded = base64Encode(utf8.encode(receiveScript));
  final receive = 'sh -c "\$(echo $encoded | base64 -d)"';
  final ssh = [
    'ssh',
    '-F',
    '/dev/null',
    '-T',
    '-oBatchMode=yes',
    '-oConnectTimeout=8',
    '-oConnectionAttempts=1',
    '-oForwardAgent=no',
    '-oClearAllForwardings=yes',
    '-oStrictHostKeyChecking=yes',
    '-oHostKeyAlias=atermius-peer',
    '-oUserKnownHostsFile=/dev/null',
    '-oGlobalKnownHostsFile=/dev/null',
    '-oCheckHostIP=no',
    '-oUpdateHostKeys=no',
    '-o',
    knownHosts,
    '-p',
    '$port',
    '-l',
    username,
    '--',
    address,
    receive,
  ].map(quoteSshTransferPath).join(' ');
  return 'test -f $input && test ! -L $input && exec $ssh < $input';
}
