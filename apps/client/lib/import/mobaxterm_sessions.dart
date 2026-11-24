/// MobaXterm session import: `.mxtsessions` exports and `MobaXterm.ini`.
///
/// Format (reverse-engineered, no public specification):
/// * INI file in the Windows ANSI code page (see [decodeWindowsText]).
/// * Sessions live in `[Bookmarks]` and `[Bookmarks_N]` sections. `SubRep` is
///   the folder path with `\` between levels (empty for the root);
///   `ImgNum` is the folder icon. Every other `name=value` line is a session.
/// * A session value is `prefix#icon#connection#terminal#startMode#comment#
///   tabColour`. The connection part is `%`-separated and starts with the
///   session type: 0 SSH, 1 Telnet, 2 Rsh, 3 XDMCP, 4 RDP, 5 VNC, 6 FTP,
///   7 SFTP, 8 Serial, 9 File, 10 Shell, 11 Browser, 12 Mosh, 13 AWS S3,
///   14 WSL.
/// * SSH: 1 host, 2 port, 3 user, 7 remote command, 8/9/10 SSH gateway hosts,
///   ports and users, 14 private key file, 15 gateway key files, 19 proxy
///   type. RDP: 1 host, 2 port, 3 user, 13/14/15 gateways, 18 gateway keys.
///   VNC: 1 host, 2 port, 5/6/7 gateways, 8 gateway keys. SFTP: 1 host,
///   2 port, 3 user, 9 private key file. Telnet: 1 host, 2 port.
/// * Several gateways are joined with `__PIPE__`; the first one is the first
///   hop. Paths use `_CurrentDrive_` and `_ProfileDir_` placeholders.
///
/// Passwords are not part of a session export. `MobaXterm.ini` keeps them in
/// `[Passwords]` / `[Credentials]`, encrypted with the MobaXterm master
/// password, and they are never read. Private key files are referenced by
/// path only and are never opened.
library;

import 'dart:convert';

import '../domain/models.dart';
import 'legacy_text_decoder.dart';
import 'termius_transfer.dart';

/// Upper bound for a picked MobaXterm file. `MobaXterm.ini` also carries
/// history and settings, so it is larger than a plain session export.
const maxMobaXtermFileBytes = 8 * 1024 * 1024;

const _maxLabelBytes = 512;
const _maxGroupNameBytes = 256;
const _maxGroupDepth = 16;
const _maxUsernameBytes = 256;
const _pipe = '__PIPE__';

/// True when [bytes] contain a `[Bookmarks…]` section header at the start of
/// a line, which every MobaXterm session file has.
bool looksLikeMobaXtermSessions(List<int> bytes) {
  final limit = bytes.length < 1 << 20 ? bytes.length : 1 << 20;
  const header = '[bookmarks';
  var lineStart = true;
  for (var index = 0; index < limit; index++) {
    final byte = bytes[index];
    if (byte == 0x0A || byte == 0x0D) {
      lineStart = true;
      continue;
    }
    if (lineStart && byte == 0x5B && index + header.length <= limit) {
      var match = true;
      for (var offset = 1; offset < header.length; offset++) {
        final value = bytes[index + offset] | 0x20;
        if (value != header.codeUnitAt(offset)) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    if (lineStart && (byte == 0xEF || byte == 0xBB || byte == 0xBF)) continue;
    if (byte != 0x20 && byte != 0x09) lineStart = false;
  }
  return false;
}

/// MobaXterm session types Atermius can't open, by type number.
const _unsupportedTypes = {
  2: 'Rsh',
  3: 'XDMCP',
  6: 'FTP',
  8: 'Serial',
  9: 'File',
  10: 'Shell',
  11: 'Browser',
  12: 'Mosh',
  13: 'AWS S3',
  14: 'WSL',
};

/// Unsupported types whose field 1 is a remote host name.
const _networkTypes = {2, 3, 6, 11, 12, 13};

class _Gateway {
  _Gateway({
    required this.host,
    required this.portText,
    required this.user,
    this.keyPath,
  });

  final String host;
  final String portText;
  final String user;
  final String? keyPath;

  int? get port {
    final text = portText.trim();
    if (text.isEmpty) return 22;
    final value = RegExp(r'^[0-9]{1,5}$').hasMatch(text) ? int.parse(text) : null;
    return value != null && value >= 1 && value <= 65535 ? value : null;
  }

  String get endpointKey =>
      jsonEncode([host.toLowerCase(), port ?? portText, user]);
}

class _Session {
  _Session({required this.row, required this.gateways});

  final TermiusImportRow row;

  /// SSH gateways, first hop first.
  final List<_Gateway> gateways;
}

class MobaXtermImporter {
  const MobaXtermImporter._();

  /// Decodes and parses a picked file. [languageCode] (the app language)
  /// picks the likely Windows code page when the file isn't UTF-8.
  static TermiusImportDocument parseBytes(
    List<int> bytes, {
    String? languageCode,
  }) {
    if (bytes.length > maxMobaXtermFileBytes) {
      return _failure(TermiusIssueCode.fileTooLarge);
    }
    final decoded = decodeWindowsText(bytes, languageCode: languageCode);
    return parse(decoded.text);
  }

  static TermiusImportDocument _failure(TermiusIssueCode code, {int? count}) =>
      TermiusImportDocument(
        format: TermiusSourceFormat.mobaXterm,
        headers: const [],
        rows: const [],
        fileIssues: [
          TermiusIssue(
            code,
            severity: TermiusIssueSeverity.blocking,
            line: count == null ? 1 : null,
            count: count,
          ),
        ],
      );

  static TermiusImportDocument parse(String source) {
    if (source.trim().isEmpty) return _failure(TermiusIssueCode.emptyFile);
    final lines = const LineSplitter().convert(
      source.startsWith('﻿') ? source.substring(1) : source,
    );
    final sessions = <_Session>[];
    final fileIssues = <TermiusIssue>[];
    var inBookmarks = false;
    var inSecrets = false;
    var secretEntries = 0;
    var folder = <String>[];
    var folderIssue = <TermiusIssue>[];
    var ordinal = 0;
    for (var index = 0; index < lines.length; index++) {
      final lineNumber = index + 1;
      final line = lines[index].trim();
      if (line.isEmpty || line.startsWith(';')) continue;
      if (line.startsWith('[') && line.endsWith(']')) {
        final name = line.substring(1, line.length - 1).trim().toLowerCase();
        inBookmarks = RegExp(r'^bookmarks(_[0-9]+)?$').hasMatch(name);
        inSecrets = name == 'passwords' || name == 'credentials';
        folder = <String>[];
        folderIssue = <TermiusIssue>[];
        continue;
      }
      final equals = line.indexOf('=');
      if (equals <= 0) continue;
      if (inSecrets) {
        secretEntries++;
        continue;
      }
      if (!inBookmarks) continue;
      final key = line.substring(0, equals).trim();
      final value = lines[index].substring(lines[index].indexOf('=') + 1);
      switch (key.toLowerCase()) {
        case 'subrep':
          final parsed = _folderPath(value, lineNumber);
          folder = parsed.path;
          folderIssue = parsed.issues;
          continue;
        case 'imgnum':
          continue;
      }
      ordinal++;
      if (ordinal > maxTermiusImportRows) {
        return _failure(
          TermiusIssueCode.tooManyRows,
          count: maxTermiusImportRows,
        );
      }
      sessions.add(
        _parseSession(
          key,
          value,
          line: lineNumber,
          row: ordinal,
          folder: folder,
          folderIssues: folderIssue,
        ),
      );
    }
    if (secretEntries > 0) {
      fileIssues.add(
        const TermiusIssue(TermiusIssueCode.mobaPasswordsNotImported),
      );
    }
    if (sessions.isEmpty) {
      return TermiusImportDocument(
        format: TermiusSourceFormat.mobaXterm,
        headers: const [],
        rows: const [],
        fileIssues: [
          ...fileIssues,
          const TermiusIssue(
            TermiusIssueCode.mobaNoSessions,
            severity: TermiusIssueSeverity.blocking,
          ),
        ],
      );
    }
    final rows = _withGateways(sessions);
    if (rows.length > maxTermiusImportRows) {
      return _failure(TermiusIssueCode.tooManyRows, count: maxTermiusImportRows);
    }
    return TermiusImportDocument(
      format: TermiusSourceFormat.mobaXterm,
      headers: const [],
      rows: List.unmodifiable(rows),
      fileIssues: List.unmodifiable(fileIssues),
    );
  }

  static ({List<String> path, List<TermiusIssue> issues}) _folderPath(
    String value,
    int line,
  ) {
    final path = <String>[];
    final issues = <TermiusIssue>[];
    for (final raw in value.split('\\')) {
      final segment = raw.trim();
      if (segment.isEmpty) continue;
      if (_hasControl(segment) ||
          utf8.encode(segment).length > _maxGroupNameBytes) {
        issues.add(
          TermiusIssue(
            TermiusIssueCode.invalidGroup,
            severity: TermiusIssueSeverity.blocking,
            line: line,
          ),
        );
        return (path: const [], issues: issues);
      }
      path.add(segment);
    }
    if (path.length > _maxGroupDepth) {
      issues.add(
        TermiusIssue(
          TermiusIssueCode.groupTooDeep,
          severity: TermiusIssueSeverity.blocking,
          line: line,
          count: _maxGroupDepth,
        ),
      );
    }
    return (path: List.unmodifiable(path), issues: issues);
  }

  static _Session _parseSession(
    String name,
    String value, {
    required int line,
    required int row,
    required List<String> folder,
    required List<TermiusIssue> folderIssues,
  }) {
    final issues = <TermiusIssue>[];
    void issue(
      TermiusIssueCode code, {
      bool blocking = false,
      String? detail,
    }) => issues.add(
      TermiusIssue(
        code,
        severity: blocking
            ? TermiusIssueSeverity.blocking
            : TermiusIssueSeverity.warning,
        line: line,
        row: row,
        detail: detail,
      ),
    );
    for (final folderIssue in folderIssues) {
      issues.add(
        TermiusIssue(
          folderIssue.code,
          severity: folderIssue.severity,
          line: line,
          row: row,
          count: folderIssue.count,
        ),
      );
    }

    final label = name.trim();
    if (label.isEmpty ||
        RegExp(r'[\u0000-\u001F\u007F]').hasMatch(label) ||
        utf8.encode(label).length > _maxLabelBytes) {
      issue(TermiusIssueCode.invalidLabel, blocking: true);
    }

    TermiusImportRow build({
      String address = '',
      HostProtocol? protocol,
      int? port,
      String username = '',
    }) => TermiusImportRow(
      row: row,
      line: line,
      label: label,
      address: address,
      protocol: protocol,
      port: port,
      username: username,
      groupPath: folder,
      tags: const [],
      issues: issues,
    );

    final parts = value.split('#');
    final connection = parts.length >= 3 ? parts[2] : '';
    final fields = connection.split('%');
    final type = int.tryParse(fields.first.trim());
    if (type == null || fields.length < 2) {
      issue(TermiusIssueCode.mobaInvalidSession, blocking: true);
      return _Session(row: build(), gateways: const []);
    }
    String field(int index) => index < fields.length ? fields[index] : '';

    final HostProtocol protocol;
    var userIndex = 3;
    int? keyIndex;
    var gatewayIndexes = const <int>[];
    switch (type) {
      case 0:
        protocol = HostProtocol.ssh;
        keyIndex = 14;
        gatewayIndexes = const [8, 9, 10, 15];
        if (field(7).trim().isNotEmpty) {
          issue(TermiusIssueCode.sshOptionIgnored, detail: 'RemoteCommand');
        }
        final proxy = field(19).trim();
        if (proxy.isNotEmpty && proxy != '0') {
          issue(TermiusIssueCode.sshOptionIgnored, detail: 'Proxy');
        }
      case 1:
        protocol = HostProtocol.telnet;
        userIndex = -1;
      case 4:
        protocol = HostProtocol.rdp;
        gatewayIndexes = const [13, 14, 15, 18];
      case 5:
        protocol = HostProtocol.vnc;
        userIndex = -1;
        gatewayIndexes = const [5, 6, 7, 8];
      case 7:
        protocol = HostProtocol.ssh;
        keyIndex = 9;
        issue(TermiusIssueCode.mobaSftpAsSsh);
      default:
        issue(
          TermiusIssueCode.mobaUnsupportedSession,
          blocking: true,
          detail: _unsupportedTypes[type] ?? '$type',
        );
        // Serial, Shell, File and WSL keep a device or shell name here.
        final host = _networkTypes.contains(type) ? field(1).trim() : '';
        return _Session(
          row: build(address: _isValidAddress(host) ? host : ''),
          gateways: const [],
        );
    }

    final address = field(1).trim();
    if (address.isEmpty) {
      issue(TermiusIssueCode.missingAddress, blocking: true);
    } else if (!_isValidAddress(address)) {
      issue(TermiusIssueCode.invalidAddress, blocking: true);
    }

    final port = _parsePort(field(2), protocol.defaultPort);
    if (port == null) issue(TermiusIssueCode.invalidPort, blocking: true);

    var username = userIndex < 0 ? '' : _username(field(userIndex), issue);
    if (username.isNotEmpty && !_isValidUsername(username)) {
      issue(TermiusIssueCode.invalidUsername, blocking: true);
      username = '';
    } else if (username.isEmpty && protocol == HostProtocol.ssh) {
      issue(TermiusIssueCode.missingUsername, blocking: true);
    }

    if (keyIndex != null) {
      final keyFile = _fileName(field(keyIndex));
      if (keyFile != null) {
        issue(TermiusIssueCode.mobaKeyFileNotRead, detail: keyFile);
      }
    }

    final gateways = <_Gateway>[];
    if (gatewayIndexes.isNotEmpty) {
      final hosts = field(gatewayIndexes[0]).split(_pipe);
      final ports = field(gatewayIndexes[1]).split(_pipe);
      final users = field(gatewayIndexes[2]).split(_pipe);
      final keys = field(gatewayIndexes[3]).split(_pipe);
      String at(List<String> list, int index) =>
          index < list.length ? list[index].trim() : '';
      for (var index = 0; index < hosts.length; index++) {
        final host = at(hosts, index);
        if (host.isEmpty) continue;
        gateways.add(
          _Gateway(
            host: host,
            portText: at(ports, index),
            user: _gatewayUser(at(users, index)),
            keyPath: at(keys, index),
          ),
        );
      }
      if (gateways.length > maxJumpHostHops) {
        issue(TermiusIssueCode.sshJumpCycle, blocking: true);
      }
    }

    return _Session(
      row: build(
        address: address,
        protocol: protocol,
        port: port,
        username: username,
      ),
      gateways: gateways,
    );
  }

  /// Adds one SSH Host per gateway hop that the file doesn't already define
  /// and links every session to its last hop by label.
  static List<TermiusImportRow> _withGateways(List<_Session> sessions) {
    String endpoint(TermiusImportRow row) => jsonEncode([
      row.address.toLowerCase(),
      row.port,
      row.username,
    ]);

    // Sessions that can stand in for a gateway hop: SSH, importable, and
    // reached through exactly the hops before it.
    final labelCounts = <String, int>{};
    for (final session in sessions) {
      final key = session.row.label.trim().toLowerCase();
      labelCounts[key] = (labelCounts[key] ?? 0) + 1;
    }
    final aliasByChain = <String, String>{};
    for (final session in sessions) {
      final row = session.row;
      if (row.protocol != HostProtocol.ssh ||
          row.blocked ||
          labelCounts[row.label.trim().toLowerCase()] != 1) {
        continue;
      }
      final chain = jsonEncode([
        for (final gateway in session.gateways) gateway.endpointKey,
        endpoint(row),
      ]);
      aliasByChain.putIfAbsent(chain, () => row.label);
    }
    final usedLabels = labelCounts.keys.toSet();

    final output = <TermiusImportRow>[];
    var nextRow = 0;
    TermiusImportRow renumber(TermiusImportRow row, {String? jumpAlias}) {
      nextRow++;
      return TermiusImportRow(
        row: nextRow,
        line: row.line,
        label: row.label,
        address: row.address,
        protocol: row.protocol,
        port: row.port,
        username: row.username,
        groupPath: row.groupPath,
        tags: row.tags,
        jumpAlias: jumpAlias ?? row.jumpAlias,
        issues: [
          for (final issue in row.issues)
            TermiusIssue(
              issue.code,
              severity: issue.severity,
              line: issue.line,
              row: issue.row == null ? null : nextRow,
              detail: issue.detail,
              count: issue.count,
            ),
        ],
      );
    }

    for (final session in sessions) {
      String? previousAlias;
      final chain = <String>[];
      for (final gateway in session.gateways) {
        chain.add(gateway.endpointKey);
        final chainKey = jsonEncode(chain);
        var alias = aliasByChain[chainKey];
        if (alias == null) {
          alias = _gatewayLabel(gateway, usedLabels);
          usedLabels.add(alias.toLowerCase());
          aliasByChain[chainKey] = alias;
          output.add(
            renumber(
              _gatewayRow(
                gateway,
                label: alias,
                line: session.row.line,
                groupPath: session.row.groupPath,
              ),
              jumpAlias: previousAlias,
            ),
          );
        }
        previousAlias = alias;
      }
      output.add(renumber(session.row, jumpAlias: previousAlias));
    }
    return output;
  }

  static TermiusImportRow _gatewayRow(
    _Gateway gateway, {
    required String label,
    required int line,
    required List<String> groupPath,
  }) {
    final issues = <TermiusIssue>[
      TermiusIssue(TermiusIssueCode.mobaGatewayAdded, line: line, row: 0),
    ];
    void blocking(TermiusIssueCode code) => issues.add(
      TermiusIssue(
        code,
        severity: TermiusIssueSeverity.blocking,
        line: line,
        row: 0,
      ),
    );
    if (!_isValidAddress(gateway.host)) blocking(TermiusIssueCode.invalidAddress);
    final port = gateway.port;
    if (port == null) blocking(TermiusIssueCode.invalidPort);
    var username = gateway.user;
    if (username.isNotEmpty && !_isValidUsername(username)) {
      blocking(TermiusIssueCode.invalidUsername);
      username = '';
    } else if (username.isEmpty) {
      blocking(TermiusIssueCode.missingUsername);
    }
    final keyFile = _fileName(gateway.keyPath ?? '');
    if (keyFile != null) {
      issues.add(
        TermiusIssue(
          TermiusIssueCode.mobaKeyFileNotRead,
          line: line,
          row: 0,
          detail: keyFile,
        ),
      );
    }
    return TermiusImportRow(
      row: 0,
      line: line,
      label: label,
      address: gateway.host,
      protocol: HostProtocol.ssh,
      port: port,
      username: username,
      groupPath: groupPath,
      tags: const [],
      issues: issues,
    );
  }

  /// `user@host` (with `:port` when not 22), unique among [used] labels.
  static String _gatewayLabel(_Gateway gateway, Set<String> used) {
    final port = gateway.port;
    final host = gateway.host.contains(':') && port != 22
        ? '[${gateway.host}]'
        : gateway.host;
    var base = gateway.user.isEmpty ? host : '${gateway.user}@$host';
    if (port != null && port != 22) base = '$base:$port';
    var label = base;
    var suffix = 2;
    while (used.contains(label.toLowerCase())) {
      label = '$base #${suffix++}';
    }
    return label;
  }

  /// Session username. `[name]` refers to a saved MobaXterm credential whose
  /// username isn't in the file; `<…>` placeholders mean "not set".
  static String _username(
    String raw,
    void Function(TermiusIssueCode code, {bool blocking, String? detail}) issue,
  ) {
    final value = raw.trim();
    if (value.startsWith('<') && value.endsWith('>')) return '';
    if (value.length > 2 && value.startsWith('[') && value.endsWith(']')) {
      issue(
        TermiusIssueCode.mobaCredentialUsername,
        detail: _safeDetail(value.substring(1, value.length - 1)),
      );
      return '';
    }
    return value;
  }

  static String _gatewayUser(String raw) {
    final value = raw.trim();
    if (value.startsWith('<') && value.endsWith('>')) return '';
    if (value.startsWith('[') && value.endsWith(']')) return '';
    return value;
  }

  static int? _parsePort(String raw, int fallback) {
    final text = raw.trim();
    if (text.isEmpty) return fallback;
    final value = RegExp(r'^[0-9]{1,5}$').hasMatch(text) ? int.parse(text) : null;
    return value != null && value >= 1 && value <= 65535 ? value : null;
  }

  /// Display name of a key file path, or null when no file is set.
  static String? _fileName(String raw) {
    final path = raw
        .replaceAll('_CurrentDrive_', 'C')
        .replaceAll('_ProfileDir_', '~')
        .trim();
    if (path.isEmpty) return null;
    final name = path.split(RegExp(r'[\\/]')).lastWhere(
      (part) => part.isNotEmpty,
      orElse: () => path,
    );
    return _safeDetail(name);
  }
}

bool _hasControl(String value) =>
    RegExp(r'[\u0000-\u001F\u007F]').hasMatch(value);

bool _isValidAddress(String value) =>
    value.isNotEmpty &&
    value.length <= 253 &&
    !value.contains(RegExp(r'[\s\u0000-\u001F\u007F,/\\"\x27`$;|&<>()%#]')) &&
    !value.startsWith('-');

bool _isValidUsername(String value) =>
    !_hasControl(value) &&
    !value.contains(RegExp(r'\s')) &&
    utf8.encode(value).length <= _maxUsernameBytes;

String _safeDetail(String value) {
  final cleaned = value.replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), '?');
  return cleaned.length > 40 ? '${cleaned.substring(0, 40)}…' : cleaned;
}
