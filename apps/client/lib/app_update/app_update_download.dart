import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class AppUpdateDownloadException implements Exception {
  const AppUpdateDownloadException(this.message);
  final String message;
  @override
  String toString() => 'AppUpdateDownloadException: $message';
}

/// The HTTP client the updater uses on native platforms: honours the usual
/// proxy environment variables and never sends anything identifying.
http.Client createAppUpdateHttpClient() => IOClient(
  HttpClient()
    ..findProxy = HttpClient.findProxyFromEnvironment
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'Atermius-Updater',
);

/// Downloads [url] to [target] and accepts it only when it has exactly
/// [size] bytes and the SHA-256 digest [sha256Hex].
///
/// The data goes to `<target>.part` first. An interrupted download is kept
/// and continued on the next call when the server supports ranges; a file
/// that fails verification is deleted.
Future<void> downloadVerified({
  required http.Client client,
  required Uri url,
  required File target,
  required int size,
  required String sha256Hex,
  void Function(int received)? onProgress,
  Duration idleTimeout = const Duration(seconds: 60),
}) async {
  final part = File('${target.path}.part');
  await target.parent.create(recursive: true);
  var have = await part.exists() ? await part.length() : 0;
  if (have > size) {
    await part.delete();
    have = 0;
  }
  if (have < size) {
    final request = http.Request('GET', url);
    if (have > 0) request.headers['range'] = 'bytes=$have-';
    final response = await client.send(request).timeout(idleTimeout);
    final resumed =
        have > 0 &&
        response.statusCode == 206 &&
        (response.headers['content-range'] ?? '').startsWith('bytes $have-');
    if (!resumed && response.statusCode != 200) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      // A stale partial file can make every later range request fail.
      if (response.statusCode == 416 && have > 0) await part.delete();
      throw AppUpdateDownloadException('HTTP ${response.statusCode}');
    }
    if (!resumed) have = 0;
    final sink = part.openWrite(
      mode: resumed ? FileMode.writeOnlyAppend : FileMode.writeOnly,
    );
    var overflow = false;
    try {
      onProgress?.call(have);
      await for (final chunk in response.stream.timeout(idleTimeout)) {
        have += chunk.length;
        if (have > size) {
          overflow = true;
          break;
        }
        sink.add(chunk);
        onProgress?.call(have);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (overflow) {
      await part.delete();
      throw const AppUpdateDownloadException('more data than announced');
    }
    if (have != size) {
      // Kept for the next attempt to continue.
      throw const AppUpdateDownloadException('download ended early');
    }
  }
  final digest = (await sha256.bind(part.openRead()).first).toString();
  if (digest != sha256Hex.toLowerCase()) {
    await part.delete();
    throw const AppUpdateDownloadException('digest mismatch');
  }
  if (await target.exists()) await target.delete();
  await part.rename(target.path);
}
