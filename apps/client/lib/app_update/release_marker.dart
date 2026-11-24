import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

/// A downloaded release that could not update itself any further: it was
/// built without its own release tag (`--dart-define=ATERMIUS_RELEASE_TAG`),
/// or from code without the updater. Installing it would leave the device on
/// that build for good, so it is skipped and never offered again.
class AppUpdateDeadEndRelease implements Exception {
  const AppUpdateDeadEndRelease(this.tag);
  final String tag;
  @override
  String toString() => 'AppUpdateDeadEndRelease: $tag';
}

/// Whether [haystack] contains [needle].
bool bytesContain(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  final first = needle.first, last = haystack.length - needle.length;
  outer:
  for (var i = 0; i <= last; i++) {
    if (haystack[i] != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// The compiled Dart program of a desktop bundle ([program], e.g.
/// `data/app.so`) carries [tag] as a string constant exactly when the build
/// passed it as its release tag; the updater of that build reads it.
Future<bool> programCarriesTag(String program, String tag) =>
    Isolate.run(() {
      final file = File(program);
      if (!file.existsSync()) return false;
      return bytesContain(file.readAsBytesSync(), ascii.encode(tag));
    });

/// The same for an Android package: every `lib/<abi>/libapp.so` in the APK
/// must carry [tag].
Future<bool> apkCarriesTag(String apk, String tag) => Isolate.run(() {
  final input = InputFileStream(apk);
  try {
    final archive = ZipDecoder().decodeStream(input);
    var programs = 0;
    for (final entry in archive) {
      if (!entry.isFile || !RegExp(r'^lib/[^/]+/libapp\.so$').hasMatch(entry.name)) {
        continue;
      }
      programs++;
      if (!bytesContain(entry.content, ascii.encode(tag))) return false;
    }
    return programs > 0;
  } on Object {
    return false;
  } finally {
    input.closeSync();
  }
});
