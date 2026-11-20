// SystemLocalClipboard: the Android bridge ("atermius/clipboard") and the
// fallback to Flutter's reader everywhere else.
import 'package:aterm_client/platform/local_clipboard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('atermius/clipboard-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  String? flutterClipboard;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    flutterClipboard = null;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.getData':
          return flutterClipboard == null ? null : {'text': flutterClipboard};
        case 'Clipboard.setData':
          flutterClipboard = (call.arguments as Map)['text'] as String?;
          return null;
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(channel, null);
  });

  SystemLocalClipboard android() => SystemLocalClipboard(
    channel: channel,
    platform: TargetPlatform.android,
    bridge: true,
  );

  void bridge(Object? Function(MethodCall call) answer) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer(call);
    });
  }

  test('Android reads every status through the bridge', () async {
    final clipboard = android();
    for (final (raw, status) in [
      ({'status': 'empty'}, LocalClipboardStatus.empty),
      ({'status': 'noText', 'stamp': 7}, LocalClipboardStatus.noText),
      ({'status': 'denied'}, LocalClipboardStatus.denied),
      ({'status': 'unfocused'}, LocalClipboardStatus.unfocused),
      ({'status': 'tooLarge'}, LocalClipboardStatus.tooLarge),
      ({'status': 'something new'}, LocalClipboardStatus.noText),
    ]) {
      bridge((_) => raw);
      expect((await clipboard.readText(maxBytes: 10)).status, status);
    }
    bridge(
      (_) => {
        'status': 'text',
        'text': 'héllo',
        'stamp': 42,
        'sensitive': true,
      },
    );
    final read = await clipboard.readText(maxBytes: 10, automatic: true);
    expect(read.status, LocalClipboardStatus.text);
    expect(read.text, 'héllo');
    expect(read.stamp, 42);
    expect(read.sensitive, isTrue);
    // Automatic reads never open documents behind content URIs.
    expect(calls.last.arguments, {'maxBytes': 10, 'uris': false});
    await clipboard.readText(maxBytes: 10);
    expect(calls.last.arguments, {'maxBytes': 10, 'uris': true});
  });

  test('the exact UTF-8 size is checked in Dart', () async {
    final clipboard = android();
    bridge((_) => {'status': 'text', 'text': 'ééé'}); // 6 bytes, 3 units
    expect(
      (await clipboard.readText(maxBytes: 5)).status,
      LocalClipboardStatus.tooLarge,
    );
    expect(
      (await clipboard.readText(maxBytes: 6)).status,
      LocalClipboardStatus.text,
    );
  });

  test('state reports the clip without reading it', () async {
    final clipboard = android();
    bridge(
      (_) => {
        'focused': true,
        'allowed': false,
        'hasClip': true,
        'stamp': 9,
        'sensitive': false,
      },
    );
    final state = await clipboard.state();
    expect(calls.single.method, 'state');
    expect(state!.allowed, isFalse);
    expect(state.hasClip, isTrue);
    expect(state.stamp, 9);
  });

  test('an Android build without the bridge falls back to Flutter', () async {
    final clipboard = android();
    flutterClipboard = 'flutter text';
    final read = await clipboard.readText(maxBytes: 100);
    expect(read.status, LocalClipboardStatus.text);
    expect(read.text, 'flutter text');
    expect(await clipboard.state(), isNull);
    expect(clipboard.hasSettings, isFalse);
  });

  test('other platforms use Flutter and know no state', () async {
    final clipboard = SystemLocalClipboard(
      channel: channel,
      platform: TargetPlatform.windows,
      bridge: false,
    );
    bridge((_) => fail('the bridge is Android only'));
    expect(
      (await clipboard.readText(maxBytes: 100)).status,
      LocalClipboardStatus.empty,
    );
    flutterClipboard = 'x' * 101;
    expect(
      (await clipboard.readText(maxBytes: 100)).status,
      LocalClipboardStatus.tooLarge,
    );
    expect((await clipboard.writeText('written')).written, isTrue);
    expect(flutterClipboard, 'written');
    expect(await clipboard.state(), isNull);
    expect(clipboard.readsQuietly, isTrue);
  });

  test('Windows retries a clipboard still held by the copying app', () async {
    final clipboard = SystemLocalClipboard(
      channel: channel,
      platform: TargetPlatform.windows,
      bridge: true,
    );
    var attempts = 0;
    bridge(
      (_) => ++attempts < 3
          ? {'status': 'busy'}
          : {'status': 'text', 'text': 'new Windows clip', 'stamp': 17},
    );
    final read = await clipboard.readText(maxBytes: 100, automatic: true);
    expect(read.text, 'new Windows clip');
    expect(read.stamp, 17);
    expect(attempts, 3);
    expect(clipboard.hasSettings, isFalse);
    var changes = 0;
    final subscription = clipboard.changes.listen((_) => changes++);
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('changed')),
      (_) {},
    );
    await pumpEventQueue();
    expect(changes, 1);
    await subscription.cancel();
  });

  test(
    'Windows retries a busy write and returns the native write stamp',
    () async {
      final clipboard = SystemLocalClipboard(
        channel: channel,
        platform: TargetPlatform.windows,
        bridge: true,
      );
      var attempts = 0;
      bridge((call) {
        expect(call.method, 'write');
        expect(call.arguments, '中文 😀\r\nline two');
        return ++attempts == 1
            ? {'status': 'busy'}
            : {'status': 'written', 'stamp': 23};
      });
      expect(await clipboard.writeText('中文 😀\r\nline two'), (
        written: true,
        stamp: 23,
      ));
      expect(attempts, 2);
      expect(flutterClipboard, isNull);
    },
  );

  test('reads that would prompt the user are not automatic', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      expect(
        SystemLocalClipboard(platform: platform).readsQuietly,
        isFalse,
        reason: '$platform',
      );
    }
    expect(SystemLocalClipboard(web: true).readsQuietly, isFalse);
    for (final platform in [
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      expect(SystemLocalClipboard(platform: platform).readsQuietly, isTrue);
    }
  });

  test('Android change events arrive on the changes stream', () async {
    final clipboard = android();
    var changes = 0;
    final subscription = clipboard.changes.listen((_) => changes++);
    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('changed')),
      (_) {},
    );
    expect(changes, 1);
    await subscription.cancel();
    expect(await SystemLocalClipboard(bridge: false).changes.isEmpty, isTrue);
  });

  test('only the Android runner has a bridge', () {
    // Tests run on a desktop OS even when the UI platform is Android.
    expect(
      SystemLocalClipboard(platform: TargetPlatform.android).hasSettings,
      isFalse,
    );
  });

  test('openSettings asks the bridge on Android only', () async {
    final clipboard = android();
    bridge((call) => call.method == 'openSettings');
    expect(clipboard.hasSettings, isTrue);
    expect(await clipboard.openSettings(), isTrue);
    expect(await SystemLocalClipboard(bridge: false).openSettings(), isFalse);
  });
}
