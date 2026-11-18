import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'window_combination.dart';
import 'workspace_layout.dart';

/// The tabs that are open in the browser client, as it remembers them by
/// itself so that a reload, or signing in from another browser, brings them
/// back.
///
/// It holds what a window set holds and nothing else: Host references, the
/// kind of each tab, their order, the split tree with its ratios and the
/// active pane. No terminal output, no credentials, no runtime identifiers.
class OpenWorkspaceSnapshot {
  OpenWorkspaceSnapshot({required this.savedAtMs, required this.layout}) {
    final layout = this.layout;
    if (savedAtMs < 0 ||
        savedAtMs > _maxTimestampMs ||
        (layout != null &&
            (layout.id != layoutId ||
                layout.name != layoutId ||
                layout.mainPlacement != null ||
                layout.windows.isNotEmpty ||
                layout.panes.any(
                  (pane) =>
                      !tabKinds.contains(pane.kind) ||
                      pane.remotePath != null ||
                      pane.ownerPane != null,
                )))) {
      throw const FormatException('Invalid open workspace snapshot.');
    }
  }

  /// A snapshot of [layout] (null: the last tab was closed), taken at [at].
  factory OpenWorkspaceSnapshot.capture(
    WindowCombination? layout, {
    required DateTime at,
  }) => OpenWorkspaceSnapshot(
    savedAtMs: at.millisecondsSinceEpoch,
    layout: layout,
  );

  /// When it was taken. Of two copies, the later one is used.
  final int savedAtMs;

  /// The open tabs, or null when the user closed the last one.
  final WindowCombination? layout;

  /// Identifier and name of every [layout]; it is not a named window set.
  static const layoutId = 'open-workspace';

  /// Tab kinds a snapshot may hold: sessions of a saved Host.
  static const tabKinds = {'ssh', 'telnet', 'rdp', 'vnc'};

  static const _version = 1;
  static const _maxBytes = 30000;
  static const _maxTimestampMs = 8640000000000000;

  /// Everything but the time: two snapshots with the same key show the same
  /// tabs.
  String get contentKey => contentKeyOf(layout);

  static String contentKeyOf(WindowCombination? layout) =>
      jsonEncode(layout?.toJson());

  bool isNewerThan(OpenWorkspaceSnapshot? other) =>
      other == null || savedAtMs > other.savedAtMs;

  String encode() {
    final value = jsonEncode({
      'version': _version,
      'saved_at_ms': savedAtMs,
      'layout': layout?.toJson(),
    });
    if (utf8.encode(value).length > _maxBytes) {
      throw const FormatException('Open workspace snapshot is too large.');
    }
    return value;
  }

  static OpenWorkspaceSnapshot decode(String value) {
    if (utf8.encode(value).length > _maxBytes) {
      throw const FormatException('Open workspace snapshot is too large.');
    }
    final raw = jsonDecode(value);
    if (raw is! Map ||
        raw.length != 3 ||
        raw['version'] != _version ||
        raw['saved_at_ms'] is! int ||
        !raw.containsKey('layout') ||
        (raw['layout'] != null &&
            (raw['layout'] is! Map ||
                (raw['layout'] as Map).keys.any((key) => key is! String)))) {
      throw const FormatException('Invalid open workspace snapshot.');
    }
    return OpenWorkspaceSnapshot(
      savedAtMs: raw['saved_at_ms'] as int,
      layout: raw['layout'] == null
          ? null
          : WindowCombination.fromJson(
              Map<String, Object?>.from(raw['layout'] as Map),
            ),
    );
  }

  /// [decode], or null for anything that is not a valid snapshot.
  static OpenWorkspaceSnapshot? tryDecode(String? value) {
    if (value == null) return null;
    try {
      return decode(value);
    } on Object {
      return null;
    }
  }
}

/// The later of two copies of the snapshot (the synced one and the one this
/// browser kept); null when there is neither.
OpenWorkspaceSnapshot? newerOpenWorkspaceSnapshot(
  OpenWorkspaceSnapshot? first,
  OpenWorkspaceSnapshot? second,
) => first == null
    ? second
    : first.isNewerThan(second)
    ? first
    : second;

// -- The synced copy ---------------------------------------------------------
//
// It travels as an ordinary encrypted `workspace` record whose manifest holds
// the snapshot. Clients that predate it refuse to verify SSH host keys while a
// Vault holds a record type they do not know, and lock every preference while
// it holds a preference key they do not know; a `workspace` record with an
// extra manifest entry they read without complaint (as a saved workspace of
// the same Hosts). Clients that know the entry keep it out of the saved
// workspaces.

/// Manifest entry of the `workspace` record that carries a snapshot.
const openWorkspaceManifestKey = 'open_workspace_snapshot_v1';

final RegExp _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// The one record that carries the snapshot of [accountId] in [vaultId].
/// Every browser derives the same identifier, so they update one record
/// instead of creating one each.
String openWorkspaceRecordId({
  required String accountId,
  required String vaultId,
}) {
  final hex = sha256
      .convert(utf8.encode('atermius-open-workspace-v1|$accountId|$vaultId'))
      .toString();
  final variant = '89ab'[int.parse(hex[16], radix: 16) & 3];
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '4${hex.substring(13, 16)}-$variant${hex.substring(17, 20)}-'
      '${hex.substring(20, 32)}';
}

/// Whether [record] carries a snapshot rather than a workspace the user saved.
bool isOpenWorkspaceRecord(WorkspaceRecord record) =>
    record.manifest?.containsKey(openWorkspaceManifestKey) ?? false;

/// The snapshot [record] carries; null when it carries none that is valid.
OpenWorkspaceSnapshot? openWorkspaceSnapshotOf(WorkspaceRecord? record) {
  final value = record?.manifest?[openWorkspaceManifestKey];
  return value is String ? OpenWorkspaceSnapshot.tryDecode(value) : null;
}

/// The record that carries [snapshot], replacing [previous].
///
/// A `workspace` record lists at least one Host: those of the snapshot or,
/// once the last tab was closed, those [previous] listed. Returns null when
/// there is no such Host, which leaves nothing to store.
WorkspaceRecord? openWorkspaceRecord({
  required String id,
  required String name,
  required OpenWorkspaceSnapshot snapshot,
  required WorkspaceRecord? previous,
}) {
  final hostIds = [
    for (final pane in snapshot.layout?.panes ?? const <CombinationPane>[])
      if (pane.hostId != null && _uuidV4.hasMatch(pane.hostId!)) pane.hostId!,
  ];
  if (hostIds.isEmpty) {
    hostIds.addAll(previous?.panes.map((pane) => pane.hostId) ?? const []);
  }
  if (hostIds.isEmpty) return null;
  return WorkspaceRecord.fromHostIds(
    id: id,
    name: name,
    hostIds: hostIds.take(maxWorkspacePanes).toList(),
    manifest: {openWorkspaceManifestKey: snapshot.encode()},
  );
}
