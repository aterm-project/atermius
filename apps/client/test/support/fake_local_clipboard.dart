import 'dart:async';
import 'dart:convert';

import 'package:aterm_client/platform/local_clipboard.dart';

/// In-memory [LocalClipboard]. With [android] it reports a clip timestamp
/// and focus like the Android bridge; otherwise [state] is null as on the
/// other platforms.
class FakeLocalClipboard implements LocalClipboard {
  FakeLocalClipboard({
    this.android = true,
    this.readsQuietly = true,
    String? text,
  }) {
    if (text != null) copy(text);
  }

  final bool android;
  @override
  final bool readsQuietly;

  String? text;
  int _stamp = 0;
  bool focused = true;
  bool allowed = true;
  bool sensitive = false;
  bool failWrites = false;
  bool hasSettingsValue = false;
  int reads = 0, stateChecks = 0, settingsOpened = 0;
  final writes = <String>[];
  final automaticReads = <bool>[];
  final _changes = StreamController<void>.broadcast(sync: true);

  /// Another app copied [value] (a new clip with a new timestamp).
  void copy(String value, {bool sensitive = false}) {
    text = value;
    this.sensitive = sensitive;
    _stamp++;
  }

  /// Android's primary-clip listener fired.
  void notifyChanged() => _changes.add(null);

  @override
  Future<LocalClipboardRead> readText({
    required int maxBytes,
    bool automatic = false,
  }) async {
    reads++;
    automaticReads.add(automatic);
    final stamp = android ? _stamp : null;
    if (android && !allowed) {
      return const LocalClipboardRead(LocalClipboardStatus.denied);
    }
    if (android && !focused) {
      return const LocalClipboardRead(LocalClipboardStatus.unfocused);
    }
    final value = text;
    if (value == null || value.isEmpty) {
      return LocalClipboardRead(LocalClipboardStatus.empty, stamp: stamp);
    }
    if (utf8.encode(value).length > maxBytes) {
      return LocalClipboardRead(LocalClipboardStatus.tooLarge, stamp: stamp);
    }
    return LocalClipboardRead(
      LocalClipboardStatus.text,
      text: value,
      stamp: stamp,
      sensitive: android && sensitive,
    );
  }

  @override
  Future<LocalClipboardState?> state() async {
    if (!android) return null;
    stateChecks++;
    return LocalClipboardState(
      focused: focused,
      allowed: allowed,
      hasClip: focused && allowed && text != null,
      stamp: focused && allowed && text != null ? _stamp : null,
      sensitive: sensitive,
    );
  }

  @override
  Future<LocalClipboardWrite> writeText(String value) async {
    if (failWrites) return (written: false, stamp: null);
    writes.add(value);
    copy(value);
    return (written: true, stamp: android ? _stamp : null);
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  bool get hasSettings => hasSettingsValue;

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return hasSettingsValue;
  }
}
