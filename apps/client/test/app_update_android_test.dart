import 'dart:io';

import 'package:aterm_client/app_update/app_update_android.dart';
import 'package:aterm_client/app_update/app_update_backend.dart';
import 'package:aterm_client/app_update/app_update_channel.dart';
import 'package:aterm_client/app_update/release_marker.dart';
import 'package:archive/archive.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

const _current = 'local-20261124.2-178e1a78f57b';
const _next = 'local-20261124.3-0123456789ab';

/// A minimal APK: the compiled program of each ABI carries [tag].
List<int> _apk(String tag) => ZipEncoder().encodeBytes(
  Archive()
    ..add(ArchiveFile.bytes('AndroidManifest.xml', List<int>.filled(300, 1)))
    ..add(
      ArchiveFile.bytes(
        'lib/x86_64/libapp.so',
        [...List<int>.generate(40000, (i) => i % 199), ...utf8.encode(tag)],
      ),
    )
    ..add(
      ArchiveFile.bytes(
        'lib/arm64-v8a/libapp.so',
        [...utf8.encode(tag), ...List<int>.generate(30000, (i) => i % 97)],
      ),
    ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('atermius/app_update');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory cache;
  late List<int> apk;
  final calls = <MethodCall>[];
  Object? Function(MethodCall call)? native;
  var downloads = 0;

  AndroidAppUpdateBackend backend() => AndroidAppUpdateBackend(
    client: MockClient((request) async {
      downloads++;
      return http.Response.bytes(apk, 200);
    }),
    cacheDirectory: () async => cache,
    doneNotice: () => (title: 'Atermius was updated', body: 'Tap to open.'),
  );

  AppUpdateRelease release() => AppUpdateRelease(
    tag: _next,
    title: 'Atermius $_next',
    page: Uri.parse('https://example.invalid/'),
    assetName: 'atermius-android-1.0.4-$_next-arm64-x86_64.apk',
    assetUrl: Uri.parse('https://example.invalid/app.apk'),
    size: apk.length,
    sha256: sha256.convert(apk).toString(),
  );

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('atermius-android-update-');
    apk = _apk(_next);
    calls.clear();
    downloads = 0;
    native = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return native?.call(call);
    });
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await cache.delete(recursive: true);
  });

  test('the verified package waits in the cache and survives a restart',
      () async {
    final update = backend();
    expect(await update.staged(_current), isNull);
    final staged = await update.stage(release(), onProgress: (_) {});
    expect(
      staged!.path,
      p.join(cache.path, 'app-updates', _next, release().assetName),
    );
    expect(await File(staged.path).readAsBytes(), apk);
    // A new process finds it without downloading again.
    final later = backend();
    expect((await later.staged(_current))!.release.tag, _next);
    expect(downloads, 1);
    // Once that release runs, the package is removed.
    expect(await later.staged(_next), isNull);
    await later.cleanup(_next);
    expect(Directory(p.join(cache.path, 'app-updates', _next)).existsSync(), isFalse);
  });

  test('a cache the system cleared means downloading again', () async {
    final update = backend();
    final staged = await update.stage(release(), onProgress: (_) {});
    File(staged!.path).deleteSync();
    expect(await update.staged(_current), isNull);
    expect(await update.apply(staged), AppUpdateApplyProblem.stagedMissing);
  });

  test('a tampered download is not kept', () async {
    final update = AndroidAppUpdateBackend(
      client: MockClient(
        (_) async => http.Response.bytes(List<int>.filled(apk.length, 1), 200),
      ),
      cacheDirectory: () async => cache,
      doneNotice: () => (title: 't', body: 'b'),
    );
    await expectLater(
      update.stage(release(), onProgress: (_) {}),
      throwsA(anything),
    );
    expect(await update.staged(_current), isNull);
  });

  test('install hands the package and the notice text to the system',
      () async {
    final update = backend();
    final staged = await update.stage(release(), onProgress: (_) {});
    expect(await update.apply(staged!), isNull);
    final install = calls.singleWhere((call) => call.method == 'install');
    expect(install.arguments, {
      'path': staged.path,
      'doneTitle': 'Atermius was updated',
      'doneBody': 'Tap to open.',
    });
  });

  test('a cancelled system prompt is reported and the package kept', () async {
    final update = backend();
    final staged = await update.stage(release(), onProgress: (_) {});
    final problems = <AppUpdateApplyProblem>[];
    final subscription = update.problems.listen(problems.add);
    addTearDown(subscription.cancel);
    await update.apply(staged!);
    // What AppUpdateInstaller.kt sends when the user dismisses the prompt.
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('installStatus', 'cancelled'),
      ),
      (_) {},
    );
    expect(problems, [AppUpdateApplyProblem.cancelled]);
    expect((await update.staged(_current))!.release.tag, _next);
  });

  test('a package the system can never install is dropped for good',
      () async {
    native = (call) => call.method == 'install'
        ? throw PlatformException(code: 'not_newer')
        : null;
    final update = backend();
    final staged = await update.stage(release(), onProgress: (_) {});
    expect(await update.apply(staged!), AppUpdateApplyProblem.stagedMissing);
    expect(await update.blockedTags(), {_next});
    expect(await update.staged(_current), isNull);
  });

  test('a build without its own release tag is never installed', () async {
    apk = _apk('local-20261124.1-000000000000');
    final update = backend();
    await expectLater(
      update.stage(release(), onProgress: (_) {}),
      throwsA(isA<AppUpdateDeadEndRelease>()),
    );
    expect(await update.staged(_current), isNull);
    expect(await update.blockedTags(), {_next});
    expect(Directory(p.join(cache.path, 'app-updates', _next)).existsSync(), isFalse);
  });

  test('metered and support checks come from the platform', () async {
    native = (call) => switch (call.method) {
      'metered' => true,
      'supported' => true,
      _ => null,
    };
    final update = backend();
    expect(await update.metered(), isTrue);
    expect(await update.canInstall(), isTrue);
  });
}
