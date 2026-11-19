import 'dart:async';
import 'dart:convert';

import '../credential_visibility/sensitive_clipboard.dart';
import '../l10n/l10n.dart';
import '../platform/local_clipboard.dart';

/// Largest clipboard text exchanged with a remote desktop, in UTF-8 bytes:
/// the limit of the RDP engine, the VNC client and the detached-window
/// transport.
const desktopClipboardMaxBytes = 65536;

/// Automatic text clipboard sync between this device and one direct remote
/// desktop session (built-in RDP engine or VNC) while [active]: connected,
/// with the Host's "Clipboard text" option on.
///
/// * Remote → local: text the remote copies is written to this device's
///   clipboard (never empty text, at most [maxBytes]).
/// * Local → remote: when the desktop gains focus, the app returns to the
///   foreground or (Android) the clip changes while Atermius is focused,
///   [localMayHaveChanged] offers local text that differs from the last
///   synced text to the remote.
///
/// The text last synced in either direction is remembered, so neither side
/// echoes it back. Where the platform tells that the clip did not change
/// (Android's clip timestamp) the clipboard is not read at all, so Android
/// 12+ shows its "pasted from your clipboard" toast only for a real change.
/// Secrets Atermius copied ([SensitiveClipboard.isSecret], also in an
/// earlier run) and clips the copying app marked sensitive are never sent
/// automatically; the session menu's paste still sends them on request.
/// Where an unprompted read asks
/// the user ([LocalClipboard.readsQuietly] false: web, iOS, macOS) only
/// remote → local is automatic. Work runs one operation at a time, so a
/// local read never races a remote write.
class DesktopClipboardSync {
  DesktopClipboardSync({
    required this.clipboard,
    required this.active,
    required this.send,
    required this.notice,
    this.writesLocal = true,
    this.maxBytes = desktopClipboardMaxBytes,
    bool Function(String text)? isSecret,
    Future<void> Function()? secretsReady,
  }) : _isSecret = isSecret ?? SensitiveClipboard.isSecret,
       _secretsReady =
           secretsReady ??
           (isSecret == null ? SensitiveClipboard.ready : _noWait);

  final LocalClipboard clipboard;
  final bool Function() active;

  /// Offers text to the remote. Throws [FormatException] (with a message for
  /// the user) when the remote cannot take it.
  final void Function(String text) send;
  final void Function(String message) notice;

  /// False in a detached window: the parent process owns the session and
  /// writes remote text, so this device's clipboard is written only once.
  final bool writesLocal;
  final int maxBytes;
  final bool Function(String text) _isSecret;

  /// Completes once [_isSecret] also knows what an earlier run copied.
  final Future<void> Function() _secretsReady;
  static Future<void> _noWait() async {}

  String? _synced, _rejected;
  int? _seenStamp;
  bool _refused = false;
  final _reported = <String>{};
  Future<void> _tail = Future.value();
  bool _localQueued = false;
  int _generation = 0;

  /// A new connection starts without the local text: offer it again and
  /// allow each notice once more.
  void reset() {
    _generation++;
    _localQueued = false;
    _synced = null;
    _rejected = null;
    _seenStamp = null;
    _refused = false;
    _reported.clear();
  }

  /// The user's explicit paste sent [text]; it is not offered again.
  void sent(String text) => _synced = text;

  /// The user copied remote [text] to this device by hand.
  void copiedLocally(String text) => _synced = text;

  /// The remote refused text (its clipboard channel is off). Automatic
  /// local → remote stops until the next connection; one notice says why.
  void refused(String message) {
    _refused = true;
    _noticeOnce('refused', message);
  }

  Future<void> remoteChanged(String text) => _serial(() async {
    final generation = _generation;
    if (text.isEmpty || text == _synced) return;
    if (!writesLocal) {
      // Remembered only, so this window does not offer it back.
      _synced = text;
      return;
    }
    if (!active()) return;
    if (_tooLarge(text)) {
      _noticeOnce(
        'remote-large:${text.hashCode}',
        currentL10n.desktopClipboardRemoteTooLarge,
      );
      return;
    }
    if (!await clipboard.writeText(text)) {
      _noticeOnce('write-failed', currentL10n.desktopClipboardWriteFailed);
      return;
    }
    if (generation != _generation || !active()) return;
    _synced = text;
    // Our own write changed the clip; it needs no read.
    final stamp = (await clipboard.state())?.stamp;
    if (generation == _generation && stamp != null) _seenStamp = stamp;
  });

  Future<void> localMayHaveChanged() {
    // Focus, resume and change events often arrive together: one pending
    // check covers them all.
    if (_localQueued) return _tail;
    _localQueued = true;
    return _serial(() async {
      _localQueued = false;
      await _syncLocal();
    });
  }

  /// Local → remote for text a detached window read itself. The parent's
  /// state decides, so the parent and its windows never send it twice.
  /// Notices about this text go to [notice] (the window) when given.
  Future<void> offerLocal(String text, {void Function(String)? notice}) =>
      _serial(() async {
        final generation = _generation;
        await _secretsReady();
        if (generation == _generation && active() && !_refused) {
          _offer(text, flagged: false, notice: notice);
        }
      });

  Future<void> _serial(Future<void> Function() operation) {
    final generation = _generation;
    return _tail = _tail
        .then((_) async {
          if (generation == _generation) await operation();
        })
        .catchError((Object _) {});
  }

  Future<void> _syncLocal() async {
    final generation = _generation;
    if (!active() || _refused || !clipboard.readsQuietly) return;
    await _secretsReady();
    if (generation != _generation || !active()) return;
    final state = await clipboard.state();
    if (generation != _generation || !active()) return;
    if (state != null) {
      // Android hands out clips only to the focused app: the next focus
      // event tries again.
      if (!state.focused) return;
      if (!state.allowed) {
        _noticeOnce('denied', currentL10n.desktopClipboardReadDenied);
        return;
      }
      if (!state.hasClip) return;
      if (state.stamp != null && state.stamp == _seenStamp) return;
      if (state.sensitive) {
        // Marked by the copying app: not even read.
        _seenStamp = state.stamp;
        _noticeOnce(
          'flagged:${state.stamp}',
          currentL10n.desktopClipboardSecretSkipped,
        );
        return;
      }
    }
    final read = await clipboard.readText(maxBytes: maxBytes, automatic: true);
    if (generation != _generation || !active() || _refused) return;
    final stamp = read.stamp ?? state?.stamp;
    switch (read.status) {
      case LocalClipboardStatus.unfocused:
        return;
      case LocalClipboardStatus.denied:
        _noticeOnce('denied', currentL10n.desktopClipboardReadDenied);
        return;
      case LocalClipboardStatus.empty || LocalClipboardStatus.noText:
        _seenStamp = stamp;
        return;
      case LocalClipboardStatus.tooLarge:
        _seenStamp = stamp;
        _noticeOnce(
          'local-large:$stamp',
          currentL10n.desktopClipboardLocalTooLarge,
        );
        return;
      case LocalClipboardStatus.text:
        _seenStamp = stamp;
        _offer(read.text ?? '', flagged: read.sensitive);
    }
  }

  void _offer(
    String text, {
    required bool flagged,
    void Function(String)? notice,
  }) {
    if (text.isEmpty || text == _synced || text == _rejected) return;
    if (flagged || _isSecret(text)) {
      _noticeOnce(
        'secret:${text.hashCode}',
        currentL10n.desktopClipboardSecretSkipped,
        notice,
      );
      return;
    }
    if (_tooLarge(text)) {
      _noticeOnce(
        'local-large:${text.hashCode}',
        currentL10n.desktopClipboardLocalTooLarge,
        notice,
      );
      return;
    }
    try {
      send(text);
      _synced = text;
      _rejected = null;
    } on FormatException catch (error) {
      // Offered again only after the local text changes. Every offer here
      // is automatic, so one notice per connection says why (VNC carries
      // only Latin-1: each Cyrillic or CJK copy would repeat it); the
      // session menu's paste reports each attempt itself.
      _rejected = text;
      _noticeOnce('rejected', error.message, notice);
    }
  }

  bool _tooLarge(String text) =>
      text.length > maxBytes || utf8.encode(text).length > maxBytes;

  void _noticeOnce(
    String key,
    String message, [
    void Function(String)? target,
  ]) {
    if (_reported.length >= 64) _reported.clear();
    if (_reported.add(key)) (target ?? notice)(message);
  }
}
