import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'release_tag.dart';

/// The package an installed copy of Atermius can replace itself with.
enum AppUpdateTarget {
  windowsX64,
  linuxX64,
  android;

  /// Whether [name] is this platform's package in a release.
  bool matchesAsset(String name) => switch (this) {
    // The portable ZIP: the installer of the same release is skipped.
    windowsX64 =>
      name.startsWith('atermius-desktop-windows-x64-') && name.endsWith('.zip'),
    linuxX64 =>
      name.startsWith('atermius-desktop-linux-x64-') &&
          name.endsWith('.tar.gz'),
    android =>
      name.startsWith('atermius-android-') &&
          name.endsWith('.apk') &&
          !name.contains('intermediate'),
  };
}

/// One published release that is newer than the running build, with the
/// package for this platform and the digest that package must have.
class AppUpdateRelease {
  const AppUpdateRelease({
    required this.tag,
    required this.title,
    required this.page,
    required this.assetName,
    required this.assetUrl,
    required this.size,
    required this.sha256,
  });

  final String tag;
  final String title;

  /// The release's page, for "what's new".
  final Uri page;
  final String assetName;
  final Uri assetUrl;
  final int size;

  /// Lower-case hex.
  final String sha256;

  Map<String, Object?> toJson() => {
    'tag': tag,
    'title': title,
    'page': page.toString(),
    'asset': assetName,
    'url': assetUrl.toString(),
    'size': size,
    'sha256': sha256,
  };

  static AppUpdateRelease? fromJson(Object? json) {
    if (json is! Map) return null;
    final tag = json['tag'],
        title = json['title'],
        page = json['page'],
        asset = json['asset'],
        url = json['url'],
        size = json['size'],
        digest = json['sha256'];
    if (tag is! String ||
        title is! String ||
        page is! String ||
        asset is! String ||
        url is! String ||
        size is! int ||
        digest is! String) {
      return null;
    }
    final pageUri = Uri.tryParse(page), assetUri = Uri.tryParse(url);
    if (pageUri == null || assetUri == null) return null;
    return AppUpdateRelease(
      tag: tag,
      title: title,
      page: pageUri,
      assetName: asset,
      assetUrl: assetUri,
      size: size,
      sha256: digest,
    );
  }
}

/// Where new releases are published. GitHub Releases today; the rest of the
/// updater only sees this interface.
abstract interface class AppUpdateChannel {
  /// The newest published release after [currentTag] that has a package for
  /// [target], or null when the running build is current. Throws when the
  /// channel could not be read.
  Future<AppUpdateRelease?> latest({
    required String currentTag,
    required AppUpdateTarget target,
  });
}

class AppUpdateChannelException implements Exception {
  const AppUpdateChannelException(this.message);
  final String message;
  @override
  String toString() => 'AppUpdateChannelException: $message';
}

/// Reads the public release list of a GitHub repository. No account and no
/// token: one anonymous request per check (GitHub allows 60 an hour per
/// address) plus one small request for the digest list of a newer release.
class GitHubReleaseChannel implements AppUpdateChannel {
  GitHubReleaseChannel({
    required http.Client client,
    this.repository = 'aterm-project/atermius',
    Uri? api,
    this.timeout = const Duration(seconds: 30),
  }) : _client = client,
       _api = api ?? Uri.parse('https://api.github.com');

  final http.Client _client;
  final String repository;
  final Uri _api;
  final Duration timeout;

  static const _maxListBytes = 4 * 1024 * 1024;
  static const _maxSumsBytes = 256 * 1024;
  static const _sumsName = 'SHA256SUMS';
  static final _digest = RegExp(r'^[0-9a-f]{64}$');

  @override
  Future<AppUpdateRelease?> latest({
    required String currentTag,
    required AppUpdateTarget target,
  }) async {
    final current = ReleaseStamp.tryParse(currentTag);
    if (current == null) return null;
    final list = jsonDecode(
      await _get(
        _api.replace(
          path: '${_api.path}/repos/$repository/releases'.replaceAll('//', '/'),
          queryParameters: const {'per_page': '30'},
        ),
        _maxListBytes,
      ),
    );
    if (list is! List) {
      throw const AppUpdateChannelException('unexpected release list');
    }
    final candidates = <(ReleaseStamp, Map<Object?, Object?>)>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      // Drafts are unpublished; pre-releases are the daily test builds.
      if (entry['draft'] == true || entry['prerelease'] == true) continue;
      final tag = entry['tag_name'];
      if (tag is! String) continue;
      final stamp = ReleaseStamp.tryParse(tag);
      if (stamp == null || !(stamp > current)) continue;
      candidates.add((stamp, entry));
    }
    candidates.sort((a, b) => b.$1.compareTo(a.$1));
    for (final (_, entry) in candidates) {
      final release = await _releaseFor(entry, target);
      if (release != null) return release;
    }
    return null;
  }

  /// Null when the release has no usable package for [target]: an older
  /// candidate may still have one.
  Future<AppUpdateRelease?> _releaseFor(
    Map<Object?, Object?> entry,
    AppUpdateTarget target,
  ) async {
    final assets = entry['assets'];
    if (assets is! List) return null;
    Map<Object?, Object?>? package, sums;
    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name'];
      if (name is! String || asset['state'] == 'starter') continue;
      if (name == _sumsName) sums = asset;
      if (package == null && target.matchesAsset(name)) package = asset;
    }
    if (package == null || sums == null) return null;
    final name = package['name'] as String;
    final size = package['size'];
    final url = _downloadUrl(package), sumsUrl = _downloadUrl(sums);
    if (size is! int || size <= 0 || url == null || sumsUrl == null) {
      return null;
    }
    final digest = _digestFor(await _get(sumsUrl, _maxSumsBytes), name);
    if (digest == null) return null;
    // GitHub also publishes a digest per file; when present it must agree.
    final published = package['digest'];
    if (published is String &&
        published.startsWith('sha256:') &&
        published.substring(7).toLowerCase() != digest) {
      return null;
    }
    final tag = entry['tag_name'] as String;
    final title = entry['name'];
    final page = Uri.tryParse('${entry['html_url']}');
    return AppUpdateRelease(
      tag: tag,
      title: title is String && title.trim().isNotEmpty ? title.trim() : tag,
      page: page != null && page.isScheme('https')
          ? page
          : Uri.parse('https://github.com/$repository/releases/tag/$tag'),
      assetName: name,
      assetUrl: url,
      size: size,
      sha256: digest,
    );
  }

  /// Packages are only ever fetched from this repository's release
  /// downloads over HTTPS (or from the configured test origin).
  Uri? _downloadUrl(Map<Object?, Object?> asset) {
    final uri = Uri.tryParse('${asset['browser_download_url']}');
    if (uri == null || !uri.hasAuthority) return null;
    final official =
        uri.isScheme('https') &&
        uri.host == 'github.com' &&
        uri.path.startsWith('/$repository/releases/download/');
    final test = _api.host != 'api.github.com' && uri.host == _api.host;
    return official || test ? uri : null;
  }

  static String? _digestFor(String sums, String name) {
    for (final line in const LineSplitter().convert(sums)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length != 2) continue;
      final file = parts[1].startsWith('*') ? parts[1].substring(1) : parts[1];
      final digest = parts[0].toLowerCase();
      if (file == name && _digest.hasMatch(digest)) return digest;
    }
    return null;
  }

  Future<String> _get(Uri uri, int maxBytes) async {
    final request = http.Request('GET', uri)
      ..headers['accept'] = 'application/vnd.github+json'
      ..headers['x-github-api-version'] = '2022-11-28'
      // GitHub rejects requests without a client name; nothing identifying.
      ..headers['user-agent'] = 'Atermius-Updater';
    final response = await _client.send(request).timeout(timeout);
    if (response.statusCode != 200) {
      // Drain so the connection can be reused.
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw AppUpdateChannelException('HTTP ${response.statusCode}');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(timeout)) {
      bytes.add(chunk);
      if (bytes.length > maxBytes) {
        throw const AppUpdateChannelException('response too large');
      }
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }
}
