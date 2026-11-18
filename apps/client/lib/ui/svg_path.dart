import 'dart:ui';

/// Builds a [Path] from SVG path data (the `d` attribute): every command of
/// the SVG 1.1 grammar, absolute and relative, including implicit repeats and
/// arc flags written without separators. Throws [FormatException] on data it
/// cannot read, so a broken outline never paints as something else.
Path parseSvgPath(String data) {
  final path = Path();
  var at = 0;
  var x = 0.0, y = 0.0; // Current point.
  var startX = 0.0, startY = 0.0; // Start of the current subpath.
  var controlX = 0.0, controlY = 0.0; // Last control point, for S and T.
  String? previous;

  void skip() {
    while (at < data.length) {
      final c = data.codeUnitAt(at);
      if (c == 0x20 || c == 0x2c || c == 0x09 || c == 0x0a || c == 0x0d) {
        at++;
      } else {
        break;
      }
    }
  }

  bool digit(int c) => c >= 0x30 && c <= 0x39;

  double number() {
    skip();
    final start = at;
    if (at < data.length && (data[at] == '-' || data[at] == '+')) at++;
    while (at < data.length && digit(data.codeUnitAt(at))) {
      at++;
    }
    if (at < data.length && data[at] == '.') {
      at++;
      while (at < data.length && digit(data.codeUnitAt(at))) {
        at++;
      }
    }
    if (at < data.length && (data[at] == 'e' || data[at] == 'E')) {
      final mark = at++;
      if (at < data.length && (data[at] == '-' || data[at] == '+')) at++;
      if (at < data.length && digit(data.codeUnitAt(at))) {
        while (at < data.length && digit(data.codeUnitAt(at))) {
          at++;
        }
      } else {
        at = mark;
      }
    }
    final value = double.tryParse(data.substring(start, at));
    if (value == null || !value.isFinite) {
      throw FormatException('Number expected', data, start);
    }
    return value;
  }

  bool flag() {
    skip();
    if (at >= data.length || (data[at] != '0' && data[at] != '1')) {
      throw FormatException('Arc flag expected', data, at);
    }
    return data[at++] == '1';
  }

  bool moreNumbers() {
    skip();
    if (at >= data.length) return false;
    final c = data.codeUnitAt(at);
    return digit(c) || c == 0x2d || c == 0x2b || c == 0x2e;
  }

  while (true) {
    skip();
    if (at >= data.length) break;
    var command = data[at];
    if ('MmLlHhVvCcSsQqTtAaZz'.contains(command)) {
      at++;
    } else if (previous != null && previous != 'Z' && previous != 'z') {
      // Repeated arguments; after a moveto they are linetos.
      command = switch (previous) {
        'M' => 'L',
        'm' => 'l',
        _ => previous,
      };
    } else {
      throw FormatException('Command expected', data, at);
    }
    final relative = command == command.toLowerCase();
    final dx = relative ? x : 0.0, dy = relative ? y : 0.0;
    switch (command.toUpperCase()) {
      case 'M':
        x = number() + dx;
        y = number() + dy;
        path.moveTo(x, y);
        startX = x;
        startY = y;
      case 'L':
        x = number() + dx;
        y = number() + dy;
        path.lineTo(x, y);
      case 'H':
        x = number() + dx;
        path.lineTo(x, y);
      case 'V':
        y = number() + dy;
        path.lineTo(x, y);
      case 'C':
        final x1 = number() + dx, y1 = number() + dy;
        controlX = number() + dx;
        controlY = number() + dy;
        x = number() + dx;
        y = number() + dy;
        path.cubicTo(x1, y1, controlX, controlY, x, y);
      case 'S':
        final smooth = previous != null && 'CcSs'.contains(previous);
        final x1 = smooth ? 2 * x - controlX : x;
        final y1 = smooth ? 2 * y - controlY : y;
        controlX = number() + dx;
        controlY = number() + dy;
        x = number() + dx;
        y = number() + dy;
        path.cubicTo(x1, y1, controlX, controlY, x, y);
      case 'Q':
        controlX = number() + dx;
        controlY = number() + dy;
        x = number() + dx;
        y = number() + dy;
        path.quadraticBezierTo(controlX, controlY, x, y);
      case 'T':
        final smooth = previous != null && 'QqTt'.contains(previous);
        controlX = smooth ? 2 * x - controlX : x;
        controlY = smooth ? 2 * y - controlY : y;
        x = number() + dx;
        y = number() + dy;
        path.quadraticBezierTo(controlX, controlY, x, y);
      case 'A':
        final rx = number().abs(), ry = number().abs();
        final rotation = number();
        final large = flag(), sweep = flag();
        x = number() + dx;
        y = number() + dy;
        if (rx == 0 || ry == 0) {
          path.lineTo(x, y);
        } else {
          path.arcToPoint(
            Offset(x, y),
            radius: Radius.elliptical(rx, ry),
            rotation: rotation,
            largeArc: large,
            clockwise: sweep,
          );
        }
      case 'Z':
        path.close();
        x = startX;
        y = startY;
    }
    previous = command;
    if (command.toUpperCase() == 'Z' && moreNumbers()) {
      throw FormatException('Command expected', data, at);
    }
  }
  return path;
}
