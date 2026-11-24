import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

// shellapi.h; not exported by package:win32 5.15.
const _seeMaskNoAsync = 0x00000100;

/// Errors are returned, not shown; the UAC prompt itself still appears.
const _seeMaskFlagNoUi = 0x00000400;

/// How starting a program with administrator rights ended.
enum ElevatedStart { started, cancelled, failed }

/// Quotes one argument for a Windows command line (CommandLineToArgvW rules).
String quoteWindowsArgument(String value) {
  if (value.isNotEmpty && !value.contains(RegExp(r'[\s"]'))) return value;
  final out = StringBuffer('"');
  var backslashes = 0;
  for (final unit in value.runes) {
    final char = String.fromCharCode(unit);
    if (char == r'\') {
      backslashes++;
      continue;
    }
    if (char == '"') {
      out.write(r'\' * (backslashes * 2 + 1));
    } else {
      out.write(r'\' * backslashes);
    }
    backslashes = 0;
    out.write(char);
  }
  out
    ..write(r'\' * (backslashes * 2))
    ..write('"');
  return out.toString();
}

/// Starts [executable] through the UAC prompt ("runas"). Runs in its own
/// isolate: the call returns only once the user has answered the prompt,
/// and the app's window must keep drawing meanwhile.
Future<ElevatedStart> startElevated(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) {
  final parameters = arguments.map(quoteWindowsArgument).join(' ');
  return Isolate.run(
    () => _shellExecuteRunAs(executable, parameters, workingDirectory),
  );
}

ElevatedStart _shellExecuteRunAs(
  String executable,
  String parameters,
  String directory,
) => using((arena) {
  final info = arena<SHELLEXECUTEINFO>()
    ..ref.cbSize = sizeOf<SHELLEXECUTEINFO>()
    ..ref.fMask = _seeMaskNoAsync | _seeMaskFlagNoUi
    ..ref.lpVerb = 'runas'.toNativeUtf16(allocator: arena)
    ..ref.lpFile = executable.toNativeUtf16(allocator: arena)
    ..ref.lpParameters = parameters.toNativeUtf16(allocator: arena)
    ..ref.lpDirectory = directory.toNativeUtf16(allocator: arena)
    ..ref.nShow = SW_SHOWNORMAL;
  if (ShellExecuteEx(info) != 0) return ElevatedStart.started;
  return GetLastError() == ERROR_CANCELLED
      ? ElevatedStart.cancelled
      : ElevatedStart.failed;
});
