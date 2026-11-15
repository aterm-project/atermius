import 'dart:io';
import 'dart:typed_data';

import 'codec.dart';

/// Raw deflate through the zlib that ships with the Dart VM.
class ZLibScrollbackCodec extends ScrollbackCodec {
  ZLibScrollbackCodec({int level = defaultLevel})
      : _codec = ZLibCodec(level: level, raw: true);

  /// A fast level: archiving runs on the output path, and the serialized
  /// blocks are already compact, so higher levels buy little.
  static const defaultLevel = 3;

  final ZLibCodec _codec;

  @override
  Uint8List compress(Uint8List data) => _bytes(_codec.encoder.convert(data));

  @override
  Uint8List decompress(Uint8List data, int rawLength) =>
      _bytes(_codec.decoder.convert(data));

  static Uint8List _bytes(List<int> bytes) =>
      bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
}

ScrollbackCodec createPlatformScrollbackCodec() => ZLibScrollbackCodec();
