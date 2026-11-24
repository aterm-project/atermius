import 'dart:convert';

import 'package:aterm_client/app_update/app_update_channel.dart';
import 'package:aterm_client/app_update/release_tag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _repo = 'aterm-project/atermius';
const _hash = 'bd524996231143d436539cc29c9f90581211bbbeddedfaa54ee3dd3787a1388a';

Map<String, Object?> _asset(String tag, String name, {int size = 10}) => {
  'name': name,
  'size': size,
  'state': 'uploaded',
  'browser_download_url':
      'https://github.com/$_repo/releases/download/$tag/$name',
};

Map<String, Object?> _release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  List<String>? assets,
}) {
  final label = tag.replaceFirst('local-', '');
  final names =
      assets ??
      [
        'atermius-android-1.0.4-$tag-arm64-x86_64.apk',
        'atermius-desktop-linux-x64-1.0.4-$tag.tar.gz',
        'atermius-desktop-windows-x64-1.0.4-$tag-setup.exe',
        'atermius-desktop-windows-x64-1.0.4-$tag.zip',
        'SHA256SUMS',
      ];
  return {
    'tag_name': tag,
    'name': 'Atermius $label',
    'draft': draft,
    'prerelease': prerelease,
    'html_url': 'https://github.com/$_repo/releases/tag/$tag',
    'assets': [for (final name in names) _asset(tag, name)],
  };
}

GitHubReleaseChannel _channel(
  List<Map<String, Object?>> releases, {
  Map<String, String> sums = const {},
  List<Uri>? requests,
}) => GitHubReleaseChannel(
  client: MockClient((request) async {
    requests?.add(request.url);
    if (request.url.host == 'api.github.com') {
      expect(request.url.path, '/repos/$_repo/releases');
      expect(request.headers['user-agent'], 'Atermius-Updater');
      return http.Response(jsonEncode(releases), 200);
    }
    final tag = request.url.pathSegments[4];
    final body = sums[tag];
    if (request.url.pathSegments.last != 'SHA256SUMS' || body == null) {
      return http.Response('missing', 404);
    }
    return http.Response(body, 200);
  }),
);

String _sums(String tag, {String hash = _hash}) =>
    '$hash  atermius-android-1.0.4-$tag-arm64-x86_64.apk\n'
    '$hash  atermius-desktop-linux-x64-1.0.4-$tag.tar.gz\n'
    '${'0' * 64}  atermius-desktop-windows-x64-1.0.4-$tag-setup.exe\n'
    '$hash  atermius-desktop-windows-x64-1.0.4-$tag.zip\n';

void main() {
  const current = 'local-20261124.2-178e1a78f57b';
  const next = 'local-20261124.3-0123456789ab';
  const later = 'local-20261125.1-abcdef012345';

  test('release tags order by day and number, whatever the prefix', () {
    expect(ReleaseStamp.tryParse(current), const ReleaseStamp(20261124, 2));
    expect(releaseLabel(current), '20261124.2');
    expect(isNewerRelease(next, current), isTrue);
    expect(isNewerRelease(later, next), isTrue);
    expect(isNewerRelease(current, current), isFalse);
    expect(isNewerRelease('local-20261124.10-0123456789ab', next), isTrue);
    expect(
      isNewerRelease('desktop-daily-20261124.3-fe7094706ed7', current),
      isTrue,
    );
    expect(isNewerRelease('desktop-v1.0.5', current), isFalse);
    expect(isNewerRelease(next, ''), isFalse);
    expect(ReleaseStamp.tryParse('20261124.2'), isNull);
  });

  test('picks the newest published release and this platform\'s package',
      () async {
    final channel = _channel(
      [_release(current), _release(later), _release(next)],
      sums: {later: _sums(later), next: _sums(next)},
    );
    final windows = await channel.latest(
      currentTag: current,
      target: AppUpdateTarget.windowsX64,
    );
    expect(windows!.tag, later);
    expect(
      windows.assetName,
      'atermius-desktop-windows-x64-1.0.4-$later.zip',
    );
    expect(windows.sha256, _hash);
    expect(windows.size, 10);
    expect(windows.assetUrl.host, 'github.com');
    expect(windows.page.path, '/$_repo/releases/tag/$later');
    final android = await channel.latest(
      currentTag: current,
      target: AppUpdateTarget.android,
    );
    expect(android!.assetName, endsWith('-arm64-x86_64.apk'));
    final linux = await channel.latest(
      currentTag: current,
      target: AppUpdateTarget.linuxX64,
    );
    expect(linux!.assetName, endsWith('.tar.gz'));
    expect(AppUpdateRelease.fromJson(linux.toJson())!.sha256, _hash);
  });

  test('the running release and older ones are not updates', () async {
    final requests = <Uri>[];
    final channel = _channel([
      _release(current),
      _release('local-20261123.4-fe7094706ed7'),
    ], requests: requests);
    expect(
      await channel.latest(
        currentTag: current,
        target: AppUpdateTarget.linuxX64,
      ),
      isNull,
    );
    expect(requests, hasLength(1));
  });

  test('drafts and pre-release daily builds are ignored', () async {
    final channel = _channel(
      [
        _release(later, draft: true),
        _release('desktop-daily-20261126.1-fe7094706ed7', prerelease: true),
        _release(next),
      ],
      sums: {later: _sums(later), next: _sums(next)},
    );
    final found = await channel.latest(
      currentTag: current,
      target: AppUpdateTarget.linuxX64,
    );
    expect(found!.tag, next);
  });

  test('a release without this platform\'s package falls back to an older one',
      () async {
    final channel = _channel(
      [
        _release(
          later,
          assets: ['atermius-web-1.0.4-$later.tar.gz', 'SHA256SUMS'],
        ),
        _release(next),
      ],
      sums: {later: _sums(later), next: _sums(next)},
    );
    final found = await channel.latest(
      currentTag: current,
      target: AppUpdateTarget.windowsX64,
    );
    expect(found!.tag, next);
  });

  test('a package without a published digest is never offered', () async {
    final noLine = _channel([_release(next)], sums: {next: 'nothing here\n'});
    expect(
      await noLine.latest(
        currentTag: current,
        target: AppUpdateTarget.windowsX64,
      ),
      isNull,
    );
    final noSums = _channel([
      _release(next, assets: ['atermius-desktop-windows-x64-1.0.4-$next.zip']),
    ]);
    expect(
      await noSums.latest(
        currentTag: current,
        target: AppUpdateTarget.windowsX64,
      ),
      isNull,
    );
  });

  test('GitHub\'s own digest must agree with the published list', () async {
    final release = _release(next);
    for (final asset in release['assets']! as List) {
      (asset as Map)['digest'] = 'sha256:${'f' * 64}';
    }
    final channel = _channel([release], sums: {next: _sums(next)});
    expect(
      await channel.latest(
        currentTag: current,
        target: AppUpdateTarget.windowsX64,
      ),
      isNull,
    );
  });

  test('packages hosted anywhere else are refused', () async {
    final release = _release(next);
    for (final asset in release['assets']! as List) {
      final map = asset as Map;
      map['browser_download_url'] = '${map['browser_download_url']}'
          .replaceFirst('github.com', 'example.com');
    }
    final channel = _channel([release], sums: {next: _sums(next)});
    expect(
      await channel.latest(
        currentTag: current,
        target: AppUpdateTarget.windowsX64,
      ),
      isNull,
    );
  });

  test('a failing channel throws instead of reporting "current"', () async {
    final channel = GitHubReleaseChannel(
      client: MockClient((_) async => http.Response('rate limited', 403)),
    );
    await expectLater(
      channel.latest(currentTag: current, target: AppUpdateTarget.linuxX64),
      throwsA(isA<AppUpdateChannelException>()),
    );
  });

  test('a development build without a release tag finds nothing', () async {
    final requests = <Uri>[];
    final channel = _channel([_release(next)], requests: requests);
    expect(
      await channel.latest(currentTag: '', target: AppUpdateTarget.linuxX64),
      isNull,
    );
    expect(requests, isEmpty);
  });
}
