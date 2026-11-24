import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/app_update/release_marker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finds a tag anywhere in a compiled program', () {
    Uint8List bytes(String s) => Uint8List.fromList(latin1.encode(s));
    const tag = 'local-20261124.6-0123456789ab';
    expect(bytesContain(bytes('xx${tag}yy'), ascii.encode(tag)), isTrue);
    expect(bytesContain(bytes(tag), ascii.encode(tag)), isTrue);
    expect(bytesContain(bytes('lllocal-20261124.6-0123456789ab'), ascii.encode(tag)), isTrue);
    expect(bytesContain(bytes('local-20261124.6-0123456789a'), ascii.encode(tag)), isFalse);
    expect(bytesContain(bytes('local-20261124.5-0123456789ab'), ascii.encode(tag)), isFalse);
    expect(bytesContain(Uint8List(0), ascii.encode(tag)), isFalse);
  });
}
