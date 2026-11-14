// The device-local "a secret was copied" marker behind SensitiveClipboard.
import 'dart:io';

import 'package:aterm_client/storage/clipboard_secret_marker_native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the file holds no content and round-trips', () async {
    final directory = await Directory.systemTemp.createTemp('marker-test-');
    addTearDown(() => directory.delete(recursive: true));
    final marker = FileClipboardSecretMarker(directory: () async => directory);
    expect(await marker.read(), isFalse);
    await marker.write();
    await marker.write();
    expect(await marker.read(), isTrue);
    final file = File('${directory.path}/clipboard-secret-v1');
    expect(await file.readAsString(), '1\n');
    await marker.clear();
    await marker.clear();
    expect(await marker.read(), isFalse);
  });

  test('without platform storage nothing is kept or found', () async {
    final marker = FileClipboardSecretMarker(
      directory: () async => throw MissingPluginException(),
    );
    await marker.write();
    expect(await marker.read(), isFalse);
    await marker.clear();
  });

  test('other storage failures are reported, not hidden', () async {
    final marker = FileClipboardSecretMarker(
      directory: () async => throw const FileSystemException('denied'),
    );
    await expectLater(marker.read(), throwsA(isA<FileSystemException>()));
  });
}
