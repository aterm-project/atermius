// Writes `atermius-cache-manifest.json` into a built Web bundle: the build
// identifier and the SHA-256 of every file. The cache worker
// (web/atermius-sw.js) stores a build only from this list and checks each
// download against it. Run after `flutter build web`:
//
//   dart run tool/web_cache_manifest.dart build/web
//
// A bundle without the manifest still works; it is just not cached.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const manifestName = 'atermius-cache-manifest.json';

void main(List<String> arguments) {
  final root = Directory(arguments.isEmpty ? 'build/web' : arguments.first);
  final bootstrap = File('${root.path}/flutter_bootstrap.js');
  if (!bootstrap.existsSync()) {
    stderr.writeln('${bootstrap.path} not found; build the Web bundle first.');
    exitCode = 2;
    return;
  }
  final match = RegExp(
    r'''globalThis\.atermiusWebBuildId\s*=\s*['"]([A-Za-z0-9_-]{1,64})['"]''',
  ).firstMatch(bootstrap.readAsStringSync());
  if (match == null) {
    stderr.writeln('No build identifier in ${bootstrap.path}.');
    exitCode = 2;
    return;
  }
  final prefix = root.absolute.path.endsWith(Platform.pathSeparator)
      ? root.absolute.path
      : '${root.absolute.path}${Platform.pathSeparator}';
  final files = <String, String>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relative = entity.absolute.path
        .substring(prefix.length)
        .replaceAll(Platform.pathSeparator, '/');
    if (relative == manifestName) continue;
    files[relative] = sha256.convert(entity.readAsBytesSync()).toString();
  }
  final sorted = {
    for (final key in files.keys.toList()..sort()) key: files[key],
  };
  File('${root.path}/$manifestName').writeAsStringSync(
    jsonEncode({'version': 1, 'build_id': match.group(1), 'files': sorted}),
  );
  stdout.writeln(
    'Wrote $manifestName: build ${match.group(1)}, ${sorted.length} files.',
  );
}
