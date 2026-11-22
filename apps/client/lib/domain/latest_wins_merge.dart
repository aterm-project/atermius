// Field-level "latest version wins": what a stale device's edit becomes when
// it is put on top of a revision another device committed first.
import '../crypto/jcs.dart';

/// Plaintext keys that are only meaningful together, per record type. Each
/// set is merged as one field: if the local edit changed any key of a unit,
/// the whole unit is the local one; otherwise the whole unit is the remote
/// one. Halves of two devices' units are never combined.
///
/// A type that is not listed (workspace, preference, shell history, wallpaper,
/// KnownHost, anything unknown) is not merged field by field at all.
const latestWinsMergeUnits = <String, List<Set<String>>>{
  'host': [
    // Where the connection goes and the certificate pinned for that endpoint.
    {'protocol', 'address', 'port', 'rdp_cert_sha256'},
    // Who signs in and with what.
    {'username', 'auth_kind', 'credential_id', 'login'},
  ],
  'credential': [
    // One identity: the account, the kind of secret and the secret itself.
    {
      'username',
      'kind',
      'secret',
      'private_key',
      'passphrase',
      'fingerprint',
      'certificate',
    },
  ],
  'group': [],
  'snippet': [
    // What is executed: parameters and arguments belong to their body.
    {
      'body',
      'shell_kind',
      'execution_mode',
      'program',
      'arguments',
      'parameters',
    },
  ],
};

/// Inside `_manifest`, an attachment list and the object references it needs.
const latestWinsManifestUnit = {'attachments', 'object_refs'};

/// The keys this client reads and writes for each mergeable type. A key that
/// is not listed was written by a newer client; this client's models do not
/// carry it, so its absence from a local edit is not a deletion.
const _knownKeys = <String, Set<String>>{
  'host': {
    'id',
    'type',
    'name',
    'address',
    'port',
    'protocol',
    'rdp_cert_sha256',
    'username',
    'group_id',
    'credential_id',
    'login',
    'jump_host_id',
    'auth_kind',
    'color',
    'tags',
    'port_forward_profiles',
    'is_favorite',
    '_manifest',
  },
  'credential': {
    'id',
    'type',
    'name',
    'username',
    'kind',
    'secret',
    'private_key',
    'passphrase',
    'fingerprint',
    'certificate',
    '_manifest',
  },
  'group': {
    'id',
    'type',
    'name',
    'color',
    'parent_id',
    'default_credential_id',
    '_manifest',
  },
  'snippet': {
    'id',
    'type',
    'title',
    'body',
    'shell_kind',
    'execution_mode',
    'program',
    'arguments',
    'parameters',
    'tags',
    '_manifest',
  },
};

/// Whether [key] has the same value on both sides. A missing key and an
/// explicit null are the same value here: some writers omit a null field
/// and others write it, and that difference is not an edit.
bool _sameKey(
  Map<String, Object?> left,
  Map<String, Object?> right,
  String key,
) => canonicalJson(left[key]) == canonicalJson(right[key]);

/// Three-way merge of a [local] edit and a [remote] revision that were both
/// made from [base], where the local edit is the later writer:
///
/// * a field only the remote changed keeps the remote value;
/// * a field only the local edit changed keeps the local value;
/// * a field both changed takes the local value.
///
/// "Field" is a unit of [latestWinsMergeUnits], the attachment unit inside
/// `_manifest`, or a single key. Lists and maps (tags, port forwards, jump
/// host, every other manifest entry) are whole values. A key this client
/// does not know is carried as an opaque value: three-way when the local
/// edit has it, the remote state when it does not.
///
/// Returns null when the records cannot be merged field by field (a type
/// without a unit list, a tombstone, or records that disagree on id or
/// type); the caller then keeps the whole local record. The result is not
/// validated here.
Map<String, Object?>? mergeLatestWinsFields({
  required Map<String, Object?> base,
  required Map<String, Object?> local,
  required Map<String, Object?> remote,
}) {
  final type = base['type'];
  final units = latestWinsMergeUnits[type];
  final known = _knownKeys[type];
  if (units == null || known == null) return null;
  for (final record in [base, local, remote]) {
    if (record['type'] != type ||
        record['id'] is! String ||
        record['id'] != base['id'] ||
        record['deleted'] == true) {
      return null;
    }
  }

  final result = <String, Object?>{};
  void take(Map<String, Object?> source, String key) {
    if (source.containsKey(key)) result[key] = source[key];
  }

  final inUnit = <String>{};
  for (final unit in units) {
    inUnit.addAll(unit);
    final source = unit.any((key) => !_sameKey(base, local, key))
        ? local
        : remote;
    for (final key in unit) {
      take(source, key);
    }
  }
  final keys = <String>{...base.keys, ...local.keys, ...remote.keys}
    ..removeAll(inUnit);
  for (final key in keys) {
    if (key == '_manifest' &&
        [base, local, remote].every(
          (record) => !record.containsKey(key) || record[key] is Map,
        )) {
      final manifest = _mergeManifest(
        base: base[key] as Map?,
        local: local[key] as Map?,
        remote: remote[key] as Map?,
      );
      if (manifest != null) result[key] = manifest;
      continue;
    }
    if (!known.contains(key) && !local.containsKey(key)) {
      take(remote, key);
      continue;
    }
    take(_sameKey(base, local, key) ? remote : local, key);
  }
  return result;
}

/// The same rule one level down. Null means the merged record has no
/// manifest.
Map<String, Object?>? _mergeManifest({
  required Map<Object?, Object?>? base,
  required Map<Object?, Object?>? local,
  required Map<Object?, Object?>? remote,
}) {
  Map<String, Object?> entries(Map<Object?, Object?>? value) => {
    for (final entry in (value ?? const {}).entries)
      if (entry.key case final String key) key: entry.value,
  };
  final b = entries(base);
  final l = entries(local);
  final r = entries(remote);
  final result = <String, Object?>{};
  final attachments = latestWinsManifestUnit.any((key) => !_sameKey(b, l, key))
      ? l
      : r;
  for (final key in latestWinsManifestUnit) {
    if (attachments.containsKey(key)) result[key] = attachments[key];
  }
  final keys = <String>{...b.keys, ...l.keys, ...r.keys}
    ..removeAll(latestWinsManifestUnit);
  for (final key in keys) {
    final source = _sameKey(b, l, key) ? r : l;
    if (source.containsKey(key)) result[key] = source[key];
  }
  if (result.isNotEmpty) return result;
  // Empty either way: keep the key only where the winning side has one.
  final localChanged =
      (base == null) != (local == null) ||
      canonicalJson(b) != canonicalJson(l);
  return (localChanged ? local : remote) == null ? null : result;
}
