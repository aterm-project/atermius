import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:aterm_client/domain/host_sort.dart';

import 'package:aterm_client/credential_visibility/sensitive_clipboard.dart';

import 'support/native_test_coordination_stub.dart'
    if (dart.library.io) 'support/native_test_coordination.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  configureNativeTestCoordination();
  setUp(() => HostSortController.debugInstance = HostSortController());
  tearDown(() => HostSortController.debugInstance = null);
  // An in-memory "a secret was copied" marker: tests never read or write the
  // device-local one, and none starts with a secret from an earlier run.
  SensitiveClipboard.debugForgetSecrets();
  await testMain();
}
