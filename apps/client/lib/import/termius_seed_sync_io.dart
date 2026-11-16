import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../storage/local_host_repository.dart';
import 'termius_json.dart';
import 'termius_transfer.dart';
import 'termius_transfer_target.dart';

const _uuid = Uuid();

class TermiusUpsertReport {
  const TermiusUpsertReport({
    this.createdHosts = 0,
    this.updatedHosts = 0,
    this.createdGroups = 0,
  });

  final int createdHosts;
  final int updatedHosts;
  final int createdGroups;

  int get totalTouched => createdHosts + updatedHosts;
}

bool _sameLogin(HostLogin? a, HostLogin? b) => a == b;

bool _sameStringList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Imports new hosts and updates existing matching hosts (remarks/labels,
/// groups, ports, passwords, private keys, and passphrases) in [repository].
Future<TermiusUpsertReport> upsertTermiusDocumentToLocalRepository(
  LocalHostRepository repository,
  TermiusImportDocument document, {
  String? fallbackUsername,
}) async {
  if (document.blocksWholeFile || document.rows.isEmpty) {
    return const TermiusUpsertReport();
  }

  final existingHosts = await repository.listHosts();
  final existingGroupSnapshots = await repository.listGroups();
  final existingGroups = [for (final g in existingGroupSnapshots) g.group];

  // Build parent-indexed group lookup and create any missing nested groups.
  final groupsByParent = <String?, Map<String, GroupRecord>>{};
  for (final group in existingGroups) {
    groupsByParent.putIfAbsent(group.parentId, () => {})[
      normalizeGroupName(group.name)
    ] = group;
  }

  var createdGroups = 0;
  Future<String?> ensureGroupPath(List<String> segments) async {
    String? parent;
    for (final rawSeg in segments) {
      final trimmed = rawSeg.trim();
      if (trimmed.isEmpty) continue;
      final siblings = groupsByParent.putIfAbsent(parent, () => {});
      final key = normalizeGroupName(trimmed);
      var group = siblings[key];
      if (group == null) {
        final draft = GroupRecord(
          id: _uuid.v4(),
          name: trimmed,
          parentId: parent,
        );
        await repository.createGroup(draft);
        group = draft;
        siblings[key] = group;
        createdGroups++;
      }
      parent = group.id;
    }
    return parent;
  }

  final defaultUser =
      (fallbackUsername?.trim().isNotEmpty == true
          ? fallbackUsername!.trim()
          : (Platform.environment['USER']?.trim().isNotEmpty == true
                ? Platform.environment['USER']!.trim()
                : 'root'));

  // Index existing hosts by exact endpoint and by (protocol, address, username)
  // so previously imported bare-IP rows get upgraded with their Termius remark.
  String exactEndpoint(HostProtocol proto, String addr, int port, String user) =>
      '${proto.name}|${addr.trim().toLowerCase()}|$port|${user.trim()}';
  String hostUserKey(HostProtocol proto, String addr, String user) =>
      '${proto.name}|${addr.trim().toLowerCase()}|${user.trim()}';

  final byExactEndpoint = <String, List<HostRecord>>{};
  final byHostUser = <String, List<HostRecord>>{};
  for (final h in existingHosts) {
    byExactEndpoint
        .putIfAbsent(
          exactEndpoint(h.protocol, h.address, h.port, h.username),
          () => [],
        )
        .add(h);
    byHostUser
        .putIfAbsent(hostUserKey(h.protocol, h.address, h.username), () => [])
        .add(h);
  }

  final consumedExistingIds = <String>{};
  final seenNewIdentities = <String>{};
  var createdHosts = 0;
  var updatedHosts = 0;

  for (final row in document.rows) {
    final nonMissingUserBlocking = row.issues.any(
      (i) => i.blocking && i.code != TermiusIssueCode.missingUsername,
    );
    if (nonMissingUserBlocking || row.protocol == null || row.address.isEmpty) {
      continue;
    }

    final protocol = row.protocol!;
    final port = row.port ?? protocol.defaultPort;
    final username = row.username.trim().isNotEmpty
        ? row.username.trim()
        : (protocol == HostProtocol.ssh ? defaultUser : '');
    final label = row.label.trim().isEmpty ? row.address.trim() : row.label.trim();
    final dedupKey =
        '${label.toLowerCase()}|${exactEndpoint(protocol, row.address, port, username)}';
    if (!seenNewIdentities.add(dedupKey)) continue;

    final groupId = row.groupPath.isEmpty
        ? null
        : await ensureGroupPath(row.groupPath);

    HostLogin? login;
    if (row.privateKey != null && row.privateKey!.isNotEmpty) {
      login = HostLogin(
        kind: AuthKind.privateKey,
        privateKey: row.privateKey,
        passphrase: row.passphrase,
      );
    } else if (row.password != null && row.password!.isNotEmpty) {
      login = HostLogin(kind: AuthKind.password, password: row.password);
    }

    // Match existing host:
    // 1. Same label + exact endpoint
    // 2. Exact endpoint where old name was bare IP or matches label
    // 3. Single bare-IP host on same (protocol, address, username) whose port updated
    HostRecord? matched;
    final exactCandidates =
        byExactEndpoint[exactEndpoint(protocol, row.address, port, username)] ??
        const [];
    for (final c in exactCandidates) {
      if (consumedExistingIds.contains(c.id)) continue;
      if (c.name.trim().toLowerCase() == label.toLowerCase()) {
        matched = c;
        break;
      }
    }
    if (matched == null) {
      for (final c in exactCandidates) {
        if (consumedExistingIds.contains(c.id)) continue;
        if (c.name.trim().toLowerCase() == c.address.trim().toLowerCase()) {
          matched = c;
          break;
        }
      }
    }
    if (matched == null) {
      final loose =
          (byHostUser[hostUserKey(protocol, row.address, username)] ?? const [])
              .where((c) => !consumedExistingIds.contains(c.id))
              .toList();
      if (loose.length == 1 &&
          (loose.single.name.trim().toLowerCase() == label.toLowerCase() ||
              loose.single.name.trim().toLowerCase() ==
                  loose.single.address.trim().toLowerCase())) {
        matched = loose.single;
      }
    }

    if (matched != null && matched.revisionId != null) {
      consumedExistingIds.add(matched.id);
      final effectiveLogin = login ?? matched.login;
      final effectiveAuthKind = effectiveLogin?.kind ?? matched.authKind;
      final effectiveGroupId = groupId ?? matched.groupId;
      final effectiveTags = row.tags.isNotEmpty ? row.tags : matched.tags;
      final effectiveForwards = row.forwards.isNotEmpty
          ? row.forwards
          : matched.portForwardProfiles;

      final changed =
          matched.name != label ||
          matched.port != port ||
          matched.username != username ||
          matched.groupId != effectiveGroupId ||
          matched.authKind != effectiveAuthKind ||
          !_sameLogin(matched.login, effectiveLogin) ||
          !_sameStringList(matched.tags, effectiveTags);

      if (changed) {
        final updatedDraft = matched.copyWith(
          name: label,
          port: port,
          username: username,
          groupId: effectiveGroupId,
          login: effectiveLogin,
          authKind: effectiveAuthKind,
          tags: effectiveTags,
          portForwardProfiles: effectiveForwards,
        );
        if (updatedDraft.validate() == null) {
          await repository.updateHost(
            host: updatedDraft,
            baseRevisionId: matched.revisionId!,
          );
          updatedHosts++;
        }
      }
      continue;
    }

    final newHost = HostRecord(
      id: _uuid.v4(),
      name: label,
      address: row.address.trim(),
      port: port,
      protocol: protocol,
      username: username,
      groupId: groupId,
      login: login,
      authKind: login?.kind ?? AuthKind.password,
      tags: row.tags,
      portForwardProfiles: protocol == HostProtocol.ssh
          ? row.forwards
          : const [],
    );
    if (newHost.validate() != null) continue;
    final saved = await repository.createHost(newHost, recordId: newHost.id);
    consumedExistingIds.add(saved.id);
    createdHosts++;
  }

  // Trigger target refresh hook if needed.
  await LocalTermiusTransferTarget(repository).afterApply();

  return TermiusUpsertReport(
    createdHosts: createdHosts,
    updatedHosts: updatedHosts,
    createdGroups: createdGroups,
  );
}

List<File> _candidateSeedFiles() {
  final out = <File>[];
  final home = Platform.environment['HOME']?.trim();
  if (home != null && home.isNotEmpty) {
    // iOS sandbox Documents/ or macOS ~/Documents
    out.add(File(p.join(home, 'Documents', 'atermius-auto-import.json')));
    out.add(
      File(
        p.join(
          home,
          'Library',
          'Application Support',
          'com.atermius.atermClient',
          'atermius-auto-import.json',
        ),
      ),
    );
  }
  try {
    final exeDir = File(Platform.resolvedExecutable).parent;
    // iOS Runner.app/atermius-local-seed.json (injected only into private local signed builds)
    out.add(File(p.join(exeDir.path, 'atermius-local-seed.json')));
    // macOS Atermius.app/Contents/Resources/atermius-local-seed.json
    out.add(
      File(p.join(exeDir.parent.path, 'Resources', 'atermius-local-seed.json')),
    );
  } on Object {
    // Ignore executable resolution errors in unit tests.
  }
  return out;
}

File? _markerFileForProfile(String profileId) {
  final home = Platform.environment['HOME']?.trim();
  if (home == null || home.isEmpty) return null;
  final baseDir = Platform.isIOS
      ? p.join(home, 'Library', 'Application Support')
      : p.join(
          home,
          'Library',
          'Application Support',
          'com.atermius.atermClient',
        );
  final safeProfile = profileId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  return File(p.join(baseDir, '.seed-applied-$safeProfile.sha256'));
}

/// Automatically imports/updates pre-staged labeled Termius SSH hosts once per
/// seed digest for [profileId].
Future<TermiusUpsertReport?> syncPendingTermiusSeedIfPresent(
  LocalHostRepository repository, {
  required String profileId,
}) async {
  File? seedFile;
  for (final candidate in _candidateSeedFiles()) {
    try {
      if (candidate.existsSync() && candidate.lengthSync() > 2) {
        seedFile = candidate;
        break;
      }
    } on Object {
      continue;
    }
  }
  if (seedFile == null) return null;

  Uint8List? bytes;
  try {
    bytes = await seedFile.readAsBytes();
    final digest = crypto.sha256.convert(bytes).toString();
    final marker = _markerFileForProfile(profileId);
    if (marker != null && marker.existsSync()) {
      final applied = marker.readAsStringSync().trim();
      if (applied == digest) return null;
    }

    final document = TermiusJsonImporter.parseBytes(bytes);
    if (document.blocksWholeFile || document.rows.isEmpty) return null;

    final report = await upsertTermiusDocumentToLocalRepository(
      repository,
      document,
    );

    if (marker != null) {
      marker.parent.createSync(recursive: true);
      marker.writeAsStringSync('$digest\n', flush: true);
    }
    return report;
  } on Object {
    return null;
  } finally {
    bytes?.fillRange(0, bytes.length, 0);
  }
}
