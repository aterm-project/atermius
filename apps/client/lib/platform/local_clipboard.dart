import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'local_clipboard_platform_stub.dart'
    if (dart.library.io) 'local_clipboard_platform_io.dart'
    as platform_bridge;

/// Outcome of reading this device's clipboard as text.
enum LocalClipboardStatus {
  /// [LocalClipboardRead.text] holds the text.
  text,

  /// Nothing is on the clipboard.
  empty,

  /// There is a clip, but no text Atermius may read from it (an image, a
  /// file, or a document the copying app did not share).
  noText,

  /// The system refused: Android's READ_CLIPBOARD app-op, which several
  /// phones show as a "clipboard" permission, is off for Atermius.
  denied,

  /// Android only lets the focused app read (API 29+); try again once
  /// Atermius is in front.
  unfocused,

  /// The text is larger than the caller's limit.
  tooLarge,
}

class LocalClipboardRead {
  const LocalClipboardRead(
    this.status, {
    this.text,
    this.stamp,
    this.sensitive = false,
  });
  final LocalClipboardStatus status;

  /// Only for [LocalClipboardStatus.text].
  final String? text;

  /// Android's clip timestamp (API 26+): equal stamps mean the same clip.
  final int? stamp;

  /// The copying app marked the clip sensitive (Android's
  /// ClipDescription.EXTRA_IS_SENSITIVE, used by password managers).
  final bool sensitive;
}

/// What the platform can tell about the clipboard without reading its
/// content (so Android 12+ shows no "pasted from your clipboard" toast).
class LocalClipboardState {
  const LocalClipboardState({
    required this.focused,
    required this.allowed,
    required this.hasClip,
    this.stamp,
    this.sensitive = false,
  });

  /// Atermius has window focus; Android hands out clips only then.
  final bool focused;

  /// False when the READ_CLIPBOARD app-op is off for Atermius.
  final bool allowed;
  final bool hasClip;
  final int? stamp;
  final bool sensitive;
}

/// This device's text clipboard.
abstract class LocalClipboard {
  static LocalClipboard? _instance;
  static LocalClipboard get instance => _instance ??= SystemLocalClipboard();
  @visibleForTesting
  static set debugInstance(LocalClipboard? value) => _instance = value;

  /// Whether reading without a user gesture is silent. Browsers, iOS and
  /// macOS ask the user (or refuse) for an unprompted read, so there
  /// Atermius reads only when the user pastes.
  bool get readsQuietly;

  /// Reads the clipboard as text of at most [maxBytes] UTF-8 bytes.
  /// [automatic] reads (no user gesture) never open a document a URI on the
  /// clipboard points to; only plain text, HTML and links are taken.
  Future<LocalClipboardRead> readText({
    required int maxBytes,
    bool automatic = false,
  });

  /// Null where the platform cannot tell without reading (everything but
  /// Android).
  Future<LocalClipboardState?> state();

  /// Returns false when the platform refused the write.
  Future<bool> writeText(String text);

  /// Android: the primary clip changed while Atermius had focus. Silent
  /// elsewhere.
  Stream<void> get changes;

  /// Opens Atermius' page in the system settings (Android), where a phone's
  /// clipboard permission lives. False where there is none.
  Future<bool> openSettings();

  /// Whether [openSettings] can do anything on this platform.
  bool get hasSettings;
}

/// Android goes through the "atermius/clipboard" bridge (MainActivity's
/// ClipboardBridge); every other platform, and an Android build without the
/// bridge, uses Flutter's [Clipboard].
class SystemLocalClipboard implements LocalClipboard {
  SystemLocalClipboard({
    this.channel = const MethodChannel('atermius/clipboard'),
    this.platform,
    this.web = kIsWeb,
    bool? bridge,
  }) : _bridgeAvailable = bridge ?? platform_bridge.hasAndroidClipboardBridge;

  /// The Android bridge; tests replace it, [platform], [web] and whether the
  /// bridge exists (the real OS decides by default).
  final MethodChannel channel;
  final TargetPlatform? platform;
  final bool web;
  final bool _bridgeAvailable;
  bool _bridgeMissing = false;
  StreamController<void>? _changes;

  TargetPlatform get _target => platform ?? defaultTargetPlatform;
  bool get _bridge => !web && _bridgeAvailable && !_bridgeMissing;

  @override
  bool get readsQuietly =>
      !web && _target != TargetPlatform.iOS && _target != TargetPlatform.macOS;

  @override
  bool get hasSettings => _bridge;

  @override
  Future<LocalClipboardRead> readText({
    required int maxBytes,
    bool automatic = false,
  }) async {
    if (_bridge) {
      try {
        final raw = await channel
            .invokeMapMethod<String, Object?>('read', {
              'maxBytes': maxBytes,
              'uris': !automatic,
            })
            .timeout(const Duration(seconds: 5));
        if (raw != null) return _parseRead(raw, maxBytes);
      } on MissingPluginException {
        _bridgeMissing = true;
      } on PlatformException {
        // Fall back to Flutter's reader below.
      } on TimeoutException {
        // A content provider that does not answer has no text for us.
        return const LocalClipboardRead(LocalClipboardStatus.noText);
      }
    }
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } on PlatformException {
      return const LocalClipboardRead(LocalClipboardStatus.noText);
    }
    // Flutter cannot tell an empty clipboard from one without text.
    if (text == null || text.isEmpty) {
      return const LocalClipboardRead(LocalClipboardStatus.empty);
    }
    return _checked(text, maxBytes);
  }

  static LocalClipboardRead _checked(
    String text,
    int maxBytes, {
    int? stamp,
    bool sensitive = false,
  }) {
    if (text.length > maxBytes || utf8.encode(text).length > maxBytes) {
      return LocalClipboardRead(
        LocalClipboardStatus.tooLarge,
        stamp: stamp,
        sensitive: sensitive,
      );
    }
    return LocalClipboardRead(
      LocalClipboardStatus.text,
      text: text,
      stamp: stamp,
      sensitive: sensitive,
    );
  }

  static LocalClipboardRead _parseRead(Map<String, Object?> raw, int maxBytes) {
    final stamp = raw['stamp'] is int ? raw['stamp'] as int : null;
    final sensitive = raw['sensitive'] == true;
    final status = switch (raw['status']) {
      'text' => LocalClipboardStatus.text,
      'empty' => LocalClipboardStatus.empty,
      'denied' => LocalClipboardStatus.denied,
      'unfocused' => LocalClipboardStatus.unfocused,
      'tooLarge' => LocalClipboardStatus.tooLarge,
      _ => LocalClipboardStatus.noText,
    };
    if (status != LocalClipboardStatus.text) {
      return LocalClipboardRead(status, stamp: stamp, sensitive: sensitive);
    }
    final text = raw['text'];
    if (text is! String || text.isEmpty) {
      return LocalClipboardRead(
        LocalClipboardStatus.empty,
        stamp: stamp,
        sensitive: sensitive,
      );
    }
    return _checked(text, maxBytes, stamp: stamp, sensitive: sensitive);
  }

  @override
  Future<LocalClipboardState?> state() async {
    if (!_bridge) return null;
    try {
      final raw = await channel
          .invokeMapMethod<String, Object?>('state')
          .timeout(const Duration(seconds: 2));
      if (raw == null) return null;
      return LocalClipboardState(
        focused: raw['focused'] != false,
        allowed: raw['allowed'] != false,
        hasClip: raw['hasClip'] == true,
        stamp: raw['stamp'] is int ? raw['stamp'] as int : null,
        sensitive: raw['sensitive'] == true,
      );
    } on MissingPluginException {
      _bridgeMissing = true;
    } on PlatformException {
      // Unknown: the caller reads instead.
    } on TimeoutException {
      // Same.
    }
    return null;
  }

  @override
  Future<bool> writeText(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Stream<void> get changes {
    if (web || !_bridgeAvailable) return const Stream<void>.empty();
    final existing = _changes;
    if (existing != null) return existing.stream;
    final controller = _changes = StreamController<void>.broadcast();
    channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') controller.add(null);
    });
    return controller.stream;
  }

  @override
  Future<bool> openSettings() async {
    if (!_bridge) return false;
    try {
      return await channel.invokeMethod<bool>('openSettings') ?? false;
    } on MissingPluginException {
      _bridgeMissing = true;
    } on PlatformException {
      // Nothing to open.
    }
    return false;
  }
}
