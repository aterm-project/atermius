import 'dart:io';

/// Stands in for a second application process in
/// `scrollback_spill_store_test.dart`: holds the exclusive lock of the
/// process folder given as the only argument until stdin closes or the
/// process is killed.
Future<void> main(List<String> arguments) async {
  final lock = await File('${arguments.single}${Platform.pathSeparator}lock')
      .open(mode: FileMode.append);
  await lock.lock(FileLock.exclusive);
  stdout.writeln('ready');
  await stdout.flush();
  await stdin.drain<void>();
  exit(0);
}
