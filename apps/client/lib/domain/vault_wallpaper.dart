import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../crypto/host_attachment_crypto.dart';

/// Largest wallpaper image (plaintext bytes) that is synchronized. Equal to
/// the device-local limit, so every local wallpaper can be uploaded.
const vaultWallpaperMaxImageBytes = 16 * 1024 * 1024;

/// Longest accepted encoded `workspace/wallpaper/all` preference value.
const vaultWallpaperMaxValueLength = 16 * 1024;

/// File name written into the encrypted attachment manifest. The original
/// file name or path of the picked image is never synchronized.
const vaultWallpaperFileName = 'wallpaper';

const vaultWallpaperMediaTypes = {'image/png', 'image/jpeg', 'image/webp'};

const _modes = {'window', 'panes'};
const _maxBlur = 24.0;

/// The account wallpaper as stored in an encrypted Vault preference.
///
/// The image itself is not in the record: it is an encrypted attachment
/// (format `atermius-host-attachment-v1`, random per-image key, 4 MiB
/// AES-GCM chunks) whose ciphertext objects live in the Vault object store.
/// The record carries that manifest entry (with the image key) inside its
/// encrypted payload and lists the object IDs in `_manifest.object_refs`, so
/// the server keeps the objects alive while the record references them and
/// only ever sees ciphertext.
class VaultWallpaperValue {
  VaultWallpaperValue._(
    this._image, {
    required this.updatedAtMs,
    required this.mode,
    required this.blur,
    required this.overlay,
    required this.blobId,
    required List<String> objectIds,
  }) : objectIds = List.unmodifiable(objectIds);

  /// Builds a value; [image] is a v1 attachment manifest entry or null when
  /// the account has no wallpaper image.
  factory VaultWallpaperValue({
    required int updatedAtMs,
    required String mode,
    required double blur,
    required double? overlay,
    required Map<String, Object?>? image,
  }) => _validated({
    'v': 1,
    'updated_at': updatedAtMs,
    'mode': mode,
    'blur': blur,
    'overlay': ?overlay,
    'image': ?image,
  });

  /// Strict parse of an encoded value. Throws [FormatException].
  factory VaultWallpaperValue.parse(String value) {
    if (value.length > vaultWallpaperMaxValueLength) {
      throw const FormatException('Wallpaper preference value is too large');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      throw const FormatException('Wallpaper preference value is not JSON');
    }
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw const FormatException('Wallpaper preference value is invalid');
    }
    return _validated(Map<String, Object?>.from(decoded));
  }

  static VaultWallpaperValue _validated(Map<String, Object?> json) {
    const required = {'v', 'updated_at', 'mode', 'blur'};
    const optional = {'overlay', 'image'};
    final keys = json.keys.toSet();
    if (!keys.containsAll(required) ||
        keys.any((key) => !required.contains(key) && !optional.contains(key)) ||
        json['v'] != 1) {
      throw const FormatException('Wallpaper preference fields are invalid');
    }
    final updatedAt = json['updated_at'];
    final mode = json['mode'];
    final blur = json['blur'];
    final overlay = json['overlay'];
    if (updatedAt is! int || updatedAt < 0) {
      throw const FormatException('Wallpaper preference time is invalid');
    }
    if (mode is! String || !_modes.contains(mode)) {
      throw const FormatException('Wallpaper layout mode is invalid');
    }
    if (blur is! num || !blur.isFinite || blur < 0 || blur > _maxBlur) {
      throw const FormatException('Wallpaper blur is invalid');
    }
    if (json.containsKey('overlay') &&
        (overlay is! num || !overlay.isFinite || overlay < 0 || overlay > 1)) {
      throw const FormatException('Wallpaper overlay is invalid');
    }
    Map<String, Object?>? image;
    String? blobId;
    var objectIds = const <String>[];
    if (json.containsKey('image')) {
      final raw = json['image'];
      if (raw is! Map) {
        throw const FormatException('Wallpaper image manifest is invalid');
      }
      final entry = HostAttachmentManifestEntry.parse(raw);
      try {
        if (entry.fileName != vaultWallpaperFileName ||
            !vaultWallpaperMediaTypes.contains(entry.mediaType) ||
            entry.totalSize < 1 ||
            entry.totalSize > vaultWallpaperMaxImageBytes) {
          throw const FormatException('Wallpaper image manifest is invalid');
        }
        image = Map<String, Object?>.unmodifiable(entry.raw);
        blobId = entry.blobId;
        objectIds = entry.objectIds.toList()..sort();
      } finally {
        entry.clearKey();
        for (final chunk in entry.chunks) {
          chunk.clearNonce();
        }
      }
    }
    return VaultWallpaperValue._(
      image,
      updatedAtMs: updatedAt,
      mode: mode,
      blur: blur.toDouble(),
      overlay: json.containsKey('overlay') ? (overlay! as num).toDouble() : null,
      blobId: blobId,
      objectIds: objectIds,
    );
  }

  /// Milliseconds since the epoch of the user change this value carries.
  /// The newer of the local and account values wins.
  final int updatedAtMs;
  final String mode;
  final double blur;
  final double? overlay;
  final Map<String, Object?>? _image;

  /// Random ID of the encrypted image, or null without an image.
  final String? blobId;

  /// Sorted ciphertext object IDs of the image (the record's object refs).
  final List<String> objectIds;

  bool get hasImage => _image != null;

  /// The encrypted-attachment manifest entry (includes the image key).
  Map<String, Object?>? get imageManifest =>
      _image == null ? null : Map<String, Object?>.from(_image);

  /// The value fields (also the wallpaper record's payload fields).
  Map<String, Object?> toJson() => {
    'v': 1,
    'updated_at': updatedAtMs,
    'mode': mode,
    'blur': blur,
    'overlay': ?overlay,
    'image': ?_image,
  };

  String encode() {
    final encoded = jsonEncode(toJson());
    if (encoded.length > vaultWallpaperMaxValueLength) {
      throw const FormatException('Wallpaper preference value is too large');
    }
    return encoded;
  }
}

final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// The encrypted Vault record (type `wallpaper`) holding the account
/// wallpaper. Its own record type (not a Vault preference key) because
/// clients that predate it keep unknown record types encrypted and aside,
/// while an unknown preference key would block their preference editing.
///
/// Payload: `{id, type: "wallpaper", v, updated_at, mode, blur, overlay?,
/// image?, _manifest?: {object_refs}}`; `object_refs` lists exactly the
/// image's ciphertext objects, so the signed header references them.
class VaultWallpaperRecord {
  VaultWallpaperRecord._({
    required this.id,
    required this.value,
    required this.revisionId,
  });

  /// A record for [value]; pass [id] to replace an existing record.
  factory VaultWallpaperRecord.create({
    required VaultWallpaperValue value,
    String? id,
  }) {
    final resolved = id ?? const Uuid().v4();
    if (!_uuidV4.hasMatch(resolved)) {
      throw const FormatException('Wallpaper record id must be a UUIDv4');
    }
    return VaultWallpaperRecord._(id: resolved, value: value, revisionId: null);
  }

  /// Strict parse of a decrypted record row (repository metadata allowed).
  factory VaultWallpaperRecord.fromJson(Map<String, dynamic> json) {
    const recordFields = {'id', 'type'};
    const repositoryFields = {'_record_id', '_revision_id', '_manifest'};
    if (json['type'] != recordType) {
      throw const FormatException('Record type must be wallpaper');
    }
    final id = json['id'];
    if (id is! String || !_uuidV4.hasMatch(id)) {
      throw const FormatException('Wallpaper record id is invalid');
    }
    final recordId = json['_record_id'];
    if (json.containsKey('_record_id') && recordId != id) {
      throw const FormatException('Wallpaper record id does not match');
    }
    final revision = json['_revision_id'];
    if (revision != null && (revision is! String || !_uuidV4.hasMatch(revision))) {
      throw const FormatException('Wallpaper record revision is invalid');
    }
    final fields = <String, Object?>{
      for (final entry in json.entries)
        if (!recordFields.contains(entry.key) &&
            !repositoryFields.contains(entry.key))
          entry.key: entry.value,
    };
    final value = VaultWallpaperValue._validated(fields);
    final manifest = json['_manifest'];
    final refs = manifest is Map ? manifest['object_refs'] : null;
    final listed = refs is List ? refs : const <Object?>[];
    if ((json.containsKey('_manifest') &&
            (manifest is! Map ||
                manifest.keys.any((key) => key != 'object_refs'))) ||
        listed.length != value.objectIds.length ||
        !Iterable<int>.generate(
          listed.length,
        ).every((index) => listed[index] == value.objectIds[index])) {
      throw const FormatException('Wallpaper record object refs are invalid');
    }
    return VaultWallpaperRecord._(
      id: id,
      value: value,
      revisionId: revision as String?,
    );
  }

  static const recordType = 'wallpaper';

  final String id;
  final VaultWallpaperValue value;

  /// Current server revision, from `_revision_id` metadata.
  final String? revisionId;

  VaultWallpaperRecord copyWith({String? revisionId}) => VaultWallpaperRecord._(
    id: id,
    value: value,
    revisionId: revisionId ?? this.revisionId,
  );

  /// The encrypted payload; repository metadata is omitted.
  Map<String, Object?> toJson() {
    if (value.encode().length > vaultWallpaperMaxValueLength) {
      throw const FormatException('Wallpaper record is too large');
    }
    return {
      'id': id,
      'type': recordType,
      ...value.toJson(),
      if (value.objectIds.isNotEmpty)
        '_manifest': {'object_refs': value.objectIds},
    };
  }
}

/// Whether the account wallpaper can be read and saved right now (see
/// `AppController.wallpaperSyncAvailability`).
enum WallpaperSyncAvailability {
  available,
  signedOut,
  locked,
  noVault,

  /// The active Vault is a team Vault or has (or invited) other members.
  sharedVault,
  readOnly,
  loading,
}
