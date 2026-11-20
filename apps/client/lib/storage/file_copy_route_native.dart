import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<File> _file() async =>
    File('${(await getApplicationSupportDirectory()).path}/file-copy-route-v1');

Future<String?> readFileCopyRoute() async {
  final file = await _file();
  if (!await file.exists() || await file.length() > 16) return null;
  return file.readAsString();
}

Future<void> writeFileCopyRoute(String route) async {
  final file = await _file();
  await file.parent.create(recursive: true);
  final temporary = await file.parent.createTemp('.file-copy-route-');
  try {
    final candidate = File('${temporary.path}/value');
    await candidate.writeAsString(route, flush: true);
    await candidate.rename(file.path);
  } finally {
    await temporary.delete(recursive: true);
  }
}
