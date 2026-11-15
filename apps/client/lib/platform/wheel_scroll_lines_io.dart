import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Windows' "lines to scroll per wheel notch" (0xFFFFFFFF for a page at a
/// time); null on every other platform or when it cannot be read.
///
/// Flutter's Windows embedder multiplies every wheel notch by this setting,
/// as it was when the window was created. It is read once per process here
/// as well, so both use the same value and a scroll delta can be turned back
/// into notches exactly.
final int? systemWheelScrollLines = _read();

int? _read() {
  if (!Platform.isWindows) return null;
  const spiGetWheelScrollLines = 0x0068;
  try {
    final lines = calloc<Uint32>();
    try {
      return SystemParametersInfo(spiGetWheelScrollLines, 0, lines, 0) != 0
          ? lines.value
          : null;
    } finally {
      calloc.free(lines);
    }
  } on Object {
    return null;
  }
}
