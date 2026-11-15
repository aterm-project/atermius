import 'dart:typed_data';

import 'codec_pure.dart' if (dart.library.io) 'codec_io.dart' as platform;

/// Compresses the serialized blocks of the scrollback archive.
///
/// The default is [ScrollbackCodec.platform]: `dart:io` zlib on native
/// platforms and a pure-Dart deflate where `dart:io` does not exist (the
/// Web). Both produce and read raw deflate streams.
abstract class ScrollbackCodec {
  const ScrollbackCodec();

  /// The codec used when none is configured.
  static ScrollbackCodec get platform => platform_;

  /// Stores blocks without compressing them.
  static const ScrollbackCodec none = _StoredCodec();

  /// Returns [data] compressed.
  Uint8List compress(Uint8List data);

  /// Returns the [rawLength] bytes that [compress] was given.
  Uint8List decompress(Uint8List data, int rawLength);
}

final ScrollbackCodec platform_ = platform.createPlatformScrollbackCodec();

class _StoredCodec extends ScrollbackCodec {
  const _StoredCodec();

  @override
  Uint8List compress(Uint8List data) => data;

  @override
  Uint8List decompress(Uint8List data, int rawLength) => data;
}
