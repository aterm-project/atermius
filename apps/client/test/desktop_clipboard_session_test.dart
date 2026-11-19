// DesktopSession wiring of automatic clipboard sync for direct RDP and VNC
// sessions: the Host option, the first local offer per connection and how a
// refusing remote is reported.
import 'dart:async';
import 'dart:typed_data';

import 'package:aterm_client/desktop/desktop_resolution.dart';
import 'package:aterm_client/desktop/desktop_session.dart';
import 'package:aterm_client/desktop/direct/connection.dart';
import 'package:aterm_client/desktop/rdp_settings.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_local_clipboard.dart';

class _Connection implements DirectDesktopConnection {
  final controller = StreamController<DesktopEvent>();
  final pasted = <String>[];
  @override
  Stream<DesktopEvent> get events => controller.stream;
  @override
  void send(List<Object> command) {}
  @override
  void paste(String text) => pasted.add(text);
  @override
  Future<void> close() async {
    if (!controller.isClosed) await controller.close();
  }
}

Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Fixture {
  _Fixture(this.clipboard) {
    session = DesktopSession(
      directConnectionForTesting: (_) => connection,
      localClipboard: clipboard,
    )..onNotice = notices.add;
  }
  final FakeLocalClipboard clipboard;
  final connection = _Connection();
  late final DesktopSession session;
  final notices = <String>[];

  Future<void> connect(HostRecord host, {bool userStarted = true}) async {
    await session.connectLocal(host, userStarted: userStarted);
    var consumed = false;
    connection.controller.add(
      DesktopFrame(2, 2, Uint8List(16), onConsumed: () => consumed = true),
    );
    await _until(() => consumed && session.state == 'connected', 'connect');
    await _settle();
  }

  Future<void> remote(String text) async {
    connection.controller.add(DesktopClipboard(text));
    await _settle();
  }

  Future<void> dispose() async {
    await session.close();
    session.dispose();
  }
}

HostRecord _host(HostProtocol protocol, {Map<String, Object?>? manifest}) =>
    HostRecord(
      id: 'h-${protocol.name}',
      name: 'Desktop',
      address: 'desktop.example',
      protocol: protocol,
      manifest: manifest,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = appLocalizationsFor(fallbackAppLocale);

  for (final protocol in [HostProtocol.rdp, HostProtocol.vnc]) {
    test(
      '$protocol: offers local text on connect and mirrors remote text',
      () async {
        final f = _Fixture(FakeLocalClipboard(text: 'copied before'));
        try {
          // Remote text from before the connection is up never replaces the
          // local clipboard.
          await f.session.connectLocal(_host(protocol));
          await f.remote('stale remote');
          expect(f.clipboard.writes, isEmpty);
          var consumed = false;
          f.connection.controller.add(
            DesktopFrame(
              2,
              2,
              Uint8List(16),
              onConsumed: () => consumed = true,
            ),
          );
          await _until(() => consumed && f.session.state == 'connected', 'up');
          await _settle();
          expect(f.connection.pasted, ['copied before']);
          expect(f.session.display.clipboard, 'stale remote');

          await f.remote('copied remotely');
          expect(f.clipboard.writes, ['copied remotely']);
          expect(f.session.display.clipboard, 'copied remotely');
          // Focus after the remote copy sends nothing back.
          await f.session.clipboardSync.localMayHaveChanged();
          expect(f.connection.pasted, ['copied before']);
        } finally {
          await f.dispose();
        }
      },
    );
  }

  for (final protocol in [HostProtocol.rdp, HostProtocol.vnc]) {
    test('$protocol: a connection an external AI starts reads no local text '
        'until the user focuses it', () async {
      final f = _Fixture(FakeLocalClipboard(text: 'copied before'));
      try {
        await f.connect(_host(protocol), userStarted: false);
        expect(f.connection.pasted, isEmpty);
        expect(f.clipboard.reads, 0);
        expect(f.clipboard.stateChecks, 0);
        // Remote → local still works.
        await f.remote('copied remotely');
        expect(f.clipboard.writes, ['copied remotely']);
        // The view reports the user's focus (or the app's resume).
        f.clipboard.copy('copied by the user');
        await f.session.clipboardSync.localMayHaveChanged();
        expect(f.connection.pasted, ['copied by the user']);
      } finally {
        await f.dispose();
      }
    });
  }

  test('the Host option off keeps both directions manual-only', () async {
    for (final host in [
      _host(
        HostProtocol.rdp,
        manifest: RdpSettings.defaults
            .copyWith(clipboardText: false)
            .applyTo(null),
      ),
      _host(
        HostProtocol.vnc,
        manifest: VncSettings.defaults
            .copyWith(clipboardText: false)
            .applyTo(null),
      ),
    ]) {
      final f = _Fixture(FakeLocalClipboard(text: 'local'));
      try {
        await f.connect(host);
        await f.remote('remote');
        await f.session.clipboardSync.localMayHaveChanged();
        expect(f.session.clipboardSyncActive, isFalse);
        expect(f.connection.pasted, isEmpty);
        expect(f.clipboard.writes, isEmpty);
        expect(f.clipboard.reads, 0);
        expect(f.session.display.clipboard, isEmpty);
        expect(
          () => f.session.paste('manual'),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              l10n.clipboardTextIsTurnedOffFor,
            ),
          ),
        );
      } finally {
        await f.dispose();
      }
    }
  });

  test('a refusing remote is reported once for automatic offers', () async {
    final f = _Fixture(FakeLocalClipboard(text: 'first'));
    try {
      await f.connect(_host(HostProtocol.rdp));
      expect(f.connection.pasted, ['first']);
      f.connection.controller.add(DesktopClipboardRefused());
      await _settle();
      expect(f.notices, [l10n.theTargetRdpSessionDoesntHave2]);
      // Automatic offers stop for this connection.
      f.clipboard.copy('second');
      await f.session.clipboardSync.localMayHaveChanged();
      expect(f.connection.pasted, ['first']);
      // An explicit paste is still tried and reported every time.
      f.session.paste('by hand');
      f.connection.controller.add(DesktopClipboardRefused());
      await _settle();
      f.session.paste('by hand');
      f.connection.controller.add(DesktopClipboardRefused());
      await _settle();
      expect(f.notices, hasLength(3));
    } finally {
      await f.dispose();
    }
  });

  test('an explicit paste is not offered again automatically', () async {
    final f = _Fixture(FakeLocalClipboard());
    try {
      await f.connect(_host(HostProtocol.rdp));
      expect(f.connection.pasted, isEmpty);
      f.clipboard.copy('pasted by hand');
      f.session.paste('pasted by hand');
      await f.session.clipboardSync.localMayHaveChanged();
      expect(f.connection.pasted, ['pasted by hand']);
    } finally {
      await f.dispose();
    }
  });

  test('VNC clipboard option round-trips and defaults on', () {
    expect(VncSettings.defaults.clipboardText, isTrue);
    expect(VncSettings.defaults.toJson().containsKey('clipboard_text'), false);
    final off = VncSettings.defaults.copyWith(clipboardText: false);
    expect(VncSettings.fromJson(off.toJson()), off);
    expect(off == VncSettings.defaults, isFalse);
    expect(
      VncSettings.of(_host(HostProtocol.vnc, manifest: off.applyTo(null)))
          .clipboardText,
      isFalse,
    );
    expect(
      () => VncSettings.fromJson({'version': 1, 'clipboard_text': 'no'}),
      throwsFormatException,
    );
  });
}
