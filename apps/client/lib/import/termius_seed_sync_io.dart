import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show visibleForTesting;
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

  final envUser = _nonEmptyEnv(Platform.environment, 'USER') ??
      _nonEmptyEnv(Platform.environment, 'USERNAME');
  final defaultUser =
      (fallbackUsername?.trim().isNotEmpty == true
          ? fallbackUsername!.trim()
          : (envUser ?? 'root'));

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

String? _nonEmptyEnv(Map<String, String> env, String key) {
  final value = env[key]?.trim();
  return value == null || value.isEmpty ? null : value;
}

/// 解析跨平台候选预置种子文件路径（依次覆盖 Windows / macOS / iOS / Linux）。
@visibleForTesting
List<String> termiusSeedCandidatePaths({
  required bool isWindows,
  required bool isMacOS,
  bool isIOS = false,
  required Map<String, String> env,
  String? executableDir,
  String? currentDir,
}) {
  final ctx = isWindows ? p.windows : p.posix;
  final out = <String>[];
  final seen = <String>{};
  void add(String candidate) {
    final normalized = candidate.trim();
    if (normalized.isNotEmpty && seen.add(normalized)) {
      out.add(normalized);
    }
  }

  final override = _nonEmptyEnv(env, 'ATERMIUS_SEED_FILE');
  if (override != null) add(override);

  final home = _nonEmptyEnv(env, 'HOME') ?? _nonEmptyEnv(env, 'USERPROFILE');
  if (isWindows) {
    final appData = _nonEmptyEnv(env, 'APPDATA');
    final localAppData = _nonEmptyEnv(env, 'LOCALAPPDATA');
    final profile = _nonEmptyEnv(env, 'USERPROFILE') ?? home;
    if (appData != null) {
      add(ctx.join(appData, 'Atermius', 'atermius-local-seed.json'));
      add(
        ctx.join(appData, 'com.atermius.atermClient', 'atermius-auto-import.json'),
      );
    }
    if (localAppData != null) {
      add(ctx.join(localAppData, 'Atermius', 'atermius-local-seed.json'));
    }
    if (profile != null) {
      add(ctx.join(profile, 'Documents', 'atermius-auto-import.json'));
      add(
        ctx.join(
          profile,
          'Downloads',
          'aterm-project',
          'atermius-local-seed.json',
        ),
      );
    }
  } else {
    if (home != null) {
      // iOS sandbox Documents/ or macOS ~/Documents
      add(ctx.join(home, 'Documents', 'atermius-auto-import.json'));
      if (isIOS || isMacOS) {
        add(
          ctx.join(
            home,
            'Library',
            'Application Support',
            'com.atermius.atermClient',
            'atermius-auto-import.json',
          ),
        );
      } else {
        final xdgConfig =
            _nonEmptyEnv(env, 'XDG_CONFIG_HOME') ?? ctx.join(home, '.config');
        add(ctx.join(xdgConfig, 'Atermius', 'atermius-auto-import.json'));
      }
    }
  }

  if (executableDir != null && executableDir.trim().isNotEmpty) {
    final exe = executableDir.trim();
    // Runner.app/atermius-local-seed.json or Windows exe dir
    add(ctx.join(exe, 'atermius-local-seed.json'));
    if (isWindows) {
      add(ctx.join(exe, 'data', 'flutter_assets', 'atermius-local-seed.json'));
    } else if (isMacOS || isIOS) {
      // macOS Atermius.app/Contents/Resources/atermius-local-seed.json
      add(ctx.join(ctx.dirname(exe), 'Resources', 'atermius-local-seed.json'));
    }
  }
  if (currentDir != null && currentDir.trim().isNotEmpty) {
    add(ctx.join(currentDir.trim(), 'atermius-local-seed.json'));
  }
  return out;
}

/// 解析跨平台已导入摘要标记文件路径，避免重复导入相同种子。
@visibleForTesting
String? termiusSeedMarkerPath({
  required bool isWindows,
  required bool isMacOS,
  required bool isIOS,
  required Map<String, String> env,
  required String profileId,
}) {
  final ctx = isWindows ? p.windows : p.posix;
  final safeProfile = profileId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  final fileName = '.seed-applied-$safeProfile.sha256';
  String? baseDir;
  if (isWindows) {
    final appData = _nonEmptyEnv(env, 'APPDATA');
    final localAppData = _nonEmptyEnv(env, 'LOCALAPPDATA');
    final profile = _nonEmptyEnv(env, 'USERPROFILE') ?? _nonEmptyEnv(env, 'HOME');
    if (appData != null) {
      baseDir = ctx.join(appData, 'Atermius');
    } else if (localAppData != null) {
      baseDir = ctx.join(localAppData, 'Atermius');
    } else if (profile != null) {
      baseDir = ctx.join(profile, '.atermius');
    }
  } else {
    final home = _nonEmptyEnv(env, 'HOME');
    if (home != null) {
      if (isIOS) {
        baseDir = ctx.join(home, 'Library', 'Application Support');
      } else if (isMacOS) {
        baseDir = ctx.join(
          home,
          'Library',
          'Application Support',
          'com.atermius.atermClient',
        );
      } else {
        final xdgConfig =
            _nonEmptyEnv(env, 'XDG_CONFIG_HOME') ?? ctx.join(home, '.config');
        baseDir = ctx.join(xdgConfig, 'atermius');
      }
    }
  }
  if (baseDir == null) return null;
  return ctx.join(baseDir, fileName);
}

List<File> _candidateSeedFiles() {
  String? exeDir;
  try {
    exeDir = File(Platform.resolvedExecutable).parent.path;
  } on Object {
    exeDir = null;
  }
  String? currentDir;
  try {
    currentDir = Directory.current.path;
  } on Object {
    currentDir = null;
  }
  return [
    for (final path in termiusSeedCandidatePaths(
      isWindows: Platform.isWindows,
      isMacOS: Platform.isMacOS,
      isIOS: Platform.isIOS,
      env: Platform.environment,
      executableDir: exeDir,
      currentDir: currentDir,
    ))
      File(path),
  ];
}

File? _markerFileForProfile(String profileId) {
  final path = termiusSeedMarkerPath(
    isWindows: Platform.isWindows,
    isMacOS: Platform.isMacOS,
    isIOS: Platform.isIOS,
    env: Platform.environment,
    profileId: profileId,
  );
  return path == null ? null : File(path);
}

/// Automatically imports/updates pre-staged labeled Termius SSH hosts once per
/// seed digest for [profileId].
Future<TermiusUpsertReport?> syncPendingTermiusSeedIfPresent(
  LocalHostRepository repository, {
  required String profileId,
}) async {
  final isFlutterTest = Platform.environment['FLUTTER_TEST'] == 'true';
  final hasExplicitOverride =
      _nonEmptyEnv(Platform.environment, 'ATERMIUS_SEED_FILE') != null;
  if (isFlutterTest && !hasExplicitOverride) {
    return null;
  }
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
