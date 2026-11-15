import 'dart:typed_data';

import 'package:archive/archive.dart' show Deflate, Inflate;

import 'codec.dart';

/// Raw deflate in pure Dart, for platforms without `dart:io` (the Web).
class PureDartScrollbackCodec extends ScrollbackCodec {
  const PureDartScrollbackCodec({this.level = defaultLevel});

  /// Pure-Dart deflate is several times slower than native zlib, so the Web
  /// trades a little ratio for speed.
  static const defaultLevel = 1;

  final int level;

  @override
  Uint8List compress(Uint8List data) =>
      _bytes(Deflate(data, level: level).getBytes());

  @override
  Uint8List decompress(Uint8List data, int rawLength) =>
      _bytes(Inflate(data, uncompressedSize: rawLength).getBytes());

  static Uint8List _bytes(List<int> bytes) =>
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}

ScrollbackCodec createPlatformScrollbackCodec() =>
    const PureDartScrollbackCodec();
