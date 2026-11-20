// Automatic remote-desktop text clipboard sync: loop prevention, the 64 KiB
// limit, the Host option, secrets and Android's focus/timestamp rules.
import 'dart:async';

import 'package:aterm_client/desktop/desktop_clipboard_sync.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_local_clipboard.dart';

class _Harness {
  _Harness({
    bool android = true,
    bool readsQuietly = true,
    bool writesLocal = true,
    Set<String> secrets = const {},
    Future<void> Function()? secretsReady,
    FakeLocalClipboard? device,
  }) : clipboard =
           device ??
           FakeLocalClipboard(android: android, readsQuietly: readsQuietly) {
    sync = DesktopClipboardSync(
      clipboard: clipboard,
      active: () => active,
      send: (text) {
        final error = rejectWith;
        if (error != null) throw FormatException(error);
        sent.add(text);
      },
      notice: notices.add,
      writesLocal: writesLocal,
      isSecret: secrets.contains,
      secretsReady: secretsReady,
    );
  }

  final FakeLocalClipboard clipboard;
  late final DesktopClipboardSync sync;
  bool active = true;
  String? rejectWith;
  final sent = <String>[];
  final notices = <String>[];
}

class _CopyDuringWrite extends FakeLocalClipboard {
  @override
  Future<({bool written, int? stamp})> writeText(String text) async {
    final result = await super.writeText(text);
    copy('new local');
    return result;
  }
}

void main() {
  final l10n = appLocalizationsFor(fallbackAppLocale);

  test(
    'a reconnect discards reads and remote writes queued by the old session',
    () async {
      final ready = Completer<void>();
      final h = _Harness(secretsReady: () => ready.future);
      h.clipboard.copy('old local');
      final reading = h.sync.localMayHaveChanged();
      await pumpEventQueue();
      final writing = h.sync.remoteChanged('old remote');
      h.sync.reset();
      h.clipboard.copy('new local');
      ready.complete();
      await Future.wait([reading, writing]);
      expect(h.sent, isEmpty);
      expect(h.clipboard.writes, isEmpty);
      await h.sync.localMayHaveChanged();
      expect(h.sent, ['new local']);
    },
  );

  test('remote text reaches this device once and is not sent back', () async {
    final h = _Harness();
    await h.sync.remoteChanged('from remote');
    await h.sync.remoteChanged('from remote');
    expect(h.clipboard.writes, ['from remote']);
    // Focus right after: the clip is our own write, so nothing is read or
    // offered (no Android 12+ paste toast either).
    final reads = h.clipboard.reads;
    await h.sync.localMayHaveChanged();
    expect(h.clipboard.reads, reads);
    expect(h.sent, isEmpty);
  });

  test('local text copied elsewhere is offered on focus, once', () async {
    final h = _Harness();
    h.clipboard.copy('local');
    await h.sync.localMayHaveChanged();
    await h.sync.localMayHaveChanged();
    expect(h.sent, ['local']);
    expect(h.clipboard.automaticReads, [true]);
    // The remote copying the same text back does not rewrite the clipboard.
    await h.sync.remoteChanged('local');
    expect(h.clipboard.writes, isEmpty);
  });

  test('a repeated remote copy replaces a newer private local clip', () async {
    final h = _Harness();
    await h.sync.remoteChanged('remote');
    h.clipboard.copy('private', sensitive: true);
    await h.sync.localMayHaveChanged();
    await h.sync.remoteChanged('remote');
    expect(h.clipboard.writes, ['remote', 'remote']);
    expect(h.sent, isEmpty);
    expect(h.clipboard.reads, 0);
  });

  test(
    'a local copy racing the remote write acknowledgement is offered',
    () async {
      final h = _Harness(device: _CopyDuringWrite());
      await h.sync.remoteChanged('remote');
      await h.sync.localMayHaveChanged();
      expect(h.sent, ['new local']);
    },
  );

  test('an unchanged Android clip is not read again', () async {
    final h = _Harness();
    h.clipboard.copy('one');
    await h.sync.localMayHaveChanged();
    await h.sync.localMayHaveChanged();
    await h.sync.localMayHaveChanged();
    expect(h.clipboard.reads, 1);
    h.clipboard.copy('two');
    await h.sync.localMayHaveChanged();
    expect(h.clipboard.reads, 2);
    expect(h.sent, ['one', 'two']);
  });

  test('without focus Android is not read; the next focus is', () async {
    final h = _Harness();
    h.clipboard.copy('later');
    h.clipboard.focused = false;
    await h.sync.localMayHaveChanged();
    expect(h.clipboard.reads, 0);
    expect(h.sent, isEmpty);
    h.clipboard.focused = true;
    await h.sync.localMayHaveChanged();
    expect(h.sent, ['later']);
  });

  test('platforms without a timestamp compare the text', () async {
    final h = _Harness(android: false);
    h.clipboard.copy('desktop');
    await h.sync.localMayHaveChanged();
    await h.sync.localMayHaveChanged();
    expect(h.clipboard.reads, 2);
    expect(h.sent, ['desktop']);
  });

  test('prompting platforms only sync remote to local', () async {
    final h = _Harness(android: false, readsQuietly: false);
    h.clipboard.copy('private');
    await h.sync.localMayHaveChanged();
    expect(h.clipboard.reads, 0);
    expect(h.sent, isEmpty);
    await h.sync.remoteChanged('remote');
    expect(h.clipboard.writes, ['remote']);
  });

  test('nothing moves while the option is off or disconnected', () async {
    final h = _Harness()..active = false;
    h.clipboard.copy('local');
    await h.sync.remoteChanged('remote');
    await h.sync.localMayHaveChanged();
    await h.sync.offerLocal('window');
    expect(h.clipboard.writes, isEmpty);
    expect(h.clipboard.reads, 0);
    expect(h.sent, isEmpty);
  });

  test('64 KiB limit in both directions, with one notice each', () async {
    final h = _Harness();
    final large = 'é' * 40000; // 80,000 UTF-8 bytes, 40,000 code units
    await h.sync.remoteChanged(large);
    await h.sync.remoteChanged(large);
    expect(h.clipboard.writes, isEmpty);
    expect(h.notices, [l10n.desktopClipboardRemoteTooLarge]);
    h.clipboard.copy(large);
    await h.sync.localMayHaveChanged();
    expect(h.sent, isEmpty);
    expect(h.notices.last, l10n.desktopClipboardLocalTooLarge);
    final exact = 'a' * desktopClipboardMaxBytes;
    h.clipboard.copy(exact);
    await h.sync.localMayHaveChanged();
    expect(h.sent, [exact]);
  });

  test(
    'secrets Atermius copied are skipped; explicit paste stays possible',
    () async {
      final h = _Harness(secrets: {'hunter2'});
      h.clipboard.copy('hunter2');
      await h.sync.localMayHaveChanged();
      expect(h.sent, isEmpty);
      expect(h.notices, [l10n.desktopClipboardSecretSkipped]);
      // A manual paste of other text is remembered; the secret still is not
      // offered on the next focus.
      h.sync.sent('typed by hand');
      await h.sync.localMayHaveChanged();
      expect(h.sent, isEmpty);
      expect(h.notices, hasLength(1));
    },
  );

  test('clips the copying app marked sensitive are not even read', () async {
    final h = _Harness();
    h.clipboard.copy('password-manager', sensitive: true);
    await h.sync.localMayHaveChanged();
    expect(h.clipboard.reads, 0);
    expect(h.sent, isEmpty);
    expect(h.notices, [l10n.desktopClipboardSecretSkipped]);
  });

  test('a refused read is reported once and sends nothing', () async {
    final h = _Harness();
    h.clipboard
      ..copy('blocked')
      ..allowed = false;
    await h.sync.localMayHaveChanged();
    h.clipboard.copy('blocked again');
    await h.sync.localMayHaveChanged();
    expect(h.sent, isEmpty);
    expect(h.notices, [l10n.desktopClipboardReadDenied]);
  });

  test('text the remote rejects is not retried until it changes', () async {
    final h = _Harness()..rejectWith = 'Latin-1 only';
    h.clipboard.copy('中文');
    await h.sync.localMayHaveChanged();
    h.clipboard.copy('中文');
    await h.sync.localMayHaveChanged();
    expect(h.sent, isEmpty);
    expect(h.notices, ['Latin-1 only']);
    h.rejectWith = null;
    h.clipboard.copy('latin');
    await h.sync.localMayHaveChanged();
    expect(h.sent, ['latin']);
  });

  test('automatic offers the remote rejects are reported once per '
      'connection, not once per text', () async {
    final h = _Harness()..rejectWith = 'Latin-1 only';
    for (final text in ['привет', '你好', 'こんにちは']) {
      h.clipboard.copy(text);
      await h.sync.localMayHaveChanged();
    }
    await h.sync.offerLocal('другой текст');
    expect(h.sent, isEmpty);
    expect(h.notices, ['Latin-1 only']);
    // A new connection explains it once more.
    h.sync.reset();
    h.clipboard.copy('ещё');
    await h.sync.localMayHaveChanged();
    expect(h.notices, ['Latin-1 only', 'Latin-1 only']);
  });

  test('nothing is read or offered before the secret registry knows what '
      'an earlier run copied', () async {
    final ready = Completer<void>();
    final secrets = <String>{};
    final h = _Harness(secrets: secrets, secretsReady: () => ready.future);
    h.clipboard.copy('left by an earlier run');
    final pending = h.sync.localMayHaveChanged();
    final offered = h.sync.offerLocal('left by an earlier run');
    await pumpEventQueue();
    expect(h.clipboard.reads, 0);
    expect(h.sent, isEmpty);
    secrets.add('left by an earlier run');
    ready.complete();
    await pending;
    await offered;
    expect(h.sent, isEmpty);
    expect(h.notices, [l10n.desktopClipboardSecretSkipped]);
  });

  test('a refusing remote stops automatic offers until reset', () async {
    final h = _Harness();
    h.sync.refused('no clipboard channel');
    h.sync.refused('no clipboard channel');
    h.clipboard.copy('local');
    await h.sync.localMayHaveChanged();
    expect(h.sent, isEmpty);
    expect(h.notices, ['no clipboard channel']);
    h.sync.reset();
    await h.sync.localMayHaveChanged();
    expect(h.sent, ['local']);
  });

  test('reset offers the local text again to a new connection', () async {
    final h = _Harness();
    h.clipboard.copy('same');
    await h.sync.localMayHaveChanged();
    h.sync.reset();
    await h.sync.localMayHaveChanged();
    expect(h.sent, ['same', 'same']);
  });

  test('text copied from the remote by hand is not offered back', () async {
    final h = _Harness();
    h.sync.copiedLocally('remote by hand');
    h.clipboard.copy('remote by hand');
    await h.sync.localMayHaveChanged();
    expect(h.sent, isEmpty);
  });

  test(
    'a detached window leaves writes and duplicate offers to its parent',
    () async {
      final h = _Harness(writesLocal: false);
      await h.sync.remoteChanged('parent wrote it');
      expect(h.clipboard.writes, isEmpty);
      h.clipboard.copy('parent wrote it');
      await h.sync.localMayHaveChanged();
      expect(h.sent, ['parent wrote it']);
    },
  );

  test('window offers pass the parent checks and are sent once', () async {
    final h = _Harness(secrets: {'secret'});
    await h.sync.offerLocal('from window');
    await h.sync.offerLocal('from window');
    await h.sync.offerLocal('secret');
    expect(h.sent, ['from window']);
    // The parent's own focus check does not send it a second time.
    h.clipboard.copy('from window');
    await h.sync.localMayHaveChanged();
    expect(h.sent, ['from window']);
  });

  test('a failing local write is reported and retried later', () async {
    final h = _Harness();
    h.clipboard.failWrites = true;
    await h.sync.remoteChanged('remote');
    expect(h.notices, [l10n.desktopClipboardWriteFailed]);
    h.clipboard.failWrites = false;
    await h.sync.remoteChanged('remote');
    expect(h.clipboard.writes, ['remote']);
  });

  test('simultaneous focus, resume and change events read once', () async {
    final h = _Harness();
    h.clipboard.copy('burst');
    await Future.wait([
      h.sync.localMayHaveChanged(),
      h.sync.localMayHaveChanged(),
      h.sync.localMayHaveChanged(),
    ]);
    expect(h.clipboard.reads, 1);
    expect(h.sent, ['burst']);
  });
}
