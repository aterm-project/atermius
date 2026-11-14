// Builds assets/fonts/atermius_icons.ttf, the app's own icon font, from the
// outlines in this file. Run from apps/client after changing an outline:
//
//   dart run tool/atermius_icon_font.dart
//
// The font is checked in. test/atermius_icons_test.dart fails when the
// committed file no longer matches this generator, so edit the outlines here
// and regenerate; never edit the binary by hand. The writer is plain Dart on
// purpose: regenerating needs only the SDK the app already builds with.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Output path, relative to apps/client.
const atermiusIconFontPath = 'assets/fonts/atermius_icons.ttf';

/// Glyphs are drawn on Material's 24-unit icon canvas with y pointing down,
/// like SVG; [_toFont] maps them into font units.
const double _grid = 24;
const int unitsPerEm = 2048;

class FontPoint {
  const FontPoint(this.x, this.y, {this.onCurve = true});
  final double x, y;
  final bool onCurve;
}

class IconGlyph {
  const IconGlyph(this.name, this.codePoint, this.contours);
  final String name;
  final int codePoint;

  /// Filled outlines. Outer contours run clockwise as seen on screen and
  /// holes counter-clockwise (TrueType's convention). Contours never overlap,
  /// so every rasterizer fills them the same way under either winding rule.
  final List<List<FontPoint>> contours;
}

/// Every glyph of the font (code points in the Private Use Area).
final List<IconGlyph> atermiusIconGlyphs = [
  IconGlyph('remote_desktop', 0xe000, _remoteDesktopContours()),
];

/// The RDP mark: a rounded monitor frame on a stand with a pointer on the
/// screen — the picture of windows/runner/resources/remote_desktop.ico, so
/// the in-app protocol icon and the remote-desktop taskbar icon read as one.
/// Strokes are 2 units like Material's outlined set, the weight of the icons
/// it sits next to in menus and lists, and the frame and stand sit on whole
/// units so they are crisp at 24 and 48 px. The frame spans the width of
/// Material's monitors; the filled pointer is what tells it apart from VNC's
/// empty screen, so it is as large as the screen allows with a clear gap.
List<List<FontPoint>> _remoteDesktopContours() {
  // Frame and stand are one silhouette: the neck joins the frame and the base
  // without overlapping contours.
  const left = 1.0, right = 23.0, top = 2.0, bottom = 17.0, radius = 3.0;
  const neckLeft = 11.0, neckRight = 13.0;
  const baseLeft = 7.0, baseRight = 17.0, baseTop = 20.0, baseBottom = 22.0;
  const cap = (baseBottom - baseTop) / 2;
  final silhouette = _ContourBuilder(left + radius, top)
    ..lineTo(right - radius, top)
    ..arc(right - radius, top + radius, radius, -90, 0)
    ..lineTo(right, bottom - radius)
    ..arc(right - radius, bottom - radius, radius, 0, 90)
    ..lineTo(neckRight, bottom)
    ..lineTo(neckRight, baseTop)
    ..lineTo(baseRight - cap, baseTop)
    ..arc(baseRight - cap, baseTop + cap, cap, -90, 90)
    ..lineTo(baseLeft + cap, baseBottom)
    ..arc(baseLeft + cap, baseTop + cap, cap, 90, 270)
    ..lineTo(neckLeft, baseTop)
    ..lineTo(neckLeft, bottom)
    ..lineTo(left + radius, bottom)
    ..arc(left + radius, bottom - radius, radius, 90, 180)
    ..lineTo(left, top + radius)
    ..arc(left + radius, top + radius, radius, 180, 270);

  // The screen is the frame's hole; its corner radius is the outer one less
  // the stroke, as a rounded stroke would leave it.
  const stroke = 2.0, inner = radius - stroke;
  const sLeft = left + stroke, sRight = right - stroke;
  const sTop = top + stroke, sBottom = bottom - stroke;
  final screen = _ContourBuilder(sRight - inner, sTop)
    ..lineTo(sLeft + inner, sTop)
    ..arc(sLeft + inner, sTop + inner, inner, 270, 180)
    ..lineTo(sLeft, sBottom - inner)
    ..arc(sLeft + inner, sBottom - inner, inner, 180, 90)
    ..lineTo(sRight - inner, sBottom)
    ..arc(sRight - inner, sBottom - inner, inner, 90, 0)
    ..lineTo(sRight, sTop + inner)
    ..arc(sRight - inner, sTop + inner, inner, 0, -90);

  // A pointer with its tip up-left, symmetric about the diagonal through the
  // tip and notched at the tail, in the proportions of the .ico's pointer
  // but a little fuller, so it still reads as a solid mark at 14-16 px.
  // [length] runs along the diagonal to the wing tips, [halfWidth] across
  // it. Its bounding box is centred on the screen, then nudged right and
  // down: the pointer's mass sits towards the tip, so centred by box alone
  // it looks high and left. The box keeps at least 1.3 units off the frame.
  const length = 7.4, halfWidth = 3.8, notch = 6.2;
  const d = math.sqrt1_2; // the pointer's axis runs at 45°
  const extent = (length + halfWidth) * d;
  const tipX = (sLeft + sRight - extent) / 2 + .3;
  const tipY = (sTop + sBottom - extent) / 2 + .2;
  final pointer = _roundedPolygon(
    [
      (tipX, tipY),
      (tipX + (length + halfWidth) * d, tipY + (length - halfWidth) * d),
      (tipX + notch * d, tipY + notch * d),
      (tipX + (length - halfWidth) * d, tipY + (length + halfWidth) * d),
    ],
    const [0.6, 0.6, 0.3, 0.6],
  );

  return [silhouette.points, screen.points, pointer];
}

class _ContourBuilder {
  _ContourBuilder(double x, double y) : points = [FontPoint(x, y)];
  final List<FontPoint> points;

  void lineTo(double x, double y) => points.add(FontPoint(x, y));

  /// Circular arc around (cx, cy) from the current point at [fromDeg] to
  /// [toDeg]; increasing angles turn clockwise on screen. Each step of at
  /// most 45° is one quadratic whose control point is where the end tangents
  /// meet, which keeps the curve within 0.03% of the circle.
  void arc(double cx, double cy, double r, double fromDeg, double toDeg) {
    final steps = ((toDeg - fromDeg).abs() / 45).ceil();
    final step = (toDeg - fromDeg) / steps * math.pi / 180;
    final reach = r / math.cos(step / 2);
    var angle = fromDeg * math.pi / 180;
    for (var i = 0; i < steps; i++) {
      final middle = angle + step / 2;
      points.add(
        FontPoint(
          cx + reach * math.cos(middle),
          cy + reach * math.sin(middle),
          onCurve: false,
        ),
      );
      angle += step;
      points.add(FontPoint(cx + r * math.cos(angle), cy + r * math.sin(angle)));
    }
  }
}

/// A closed polygon whose corners are rounded by a quadratic with its control
/// point on the corner; a radius of 0 keeps that corner sharp.
List<FontPoint> _roundedPolygon(
  List<(double, double)> vertices,
  List<double> radii,
) {
  FontPoint towards((double, double) from, (double, double) to, double r) {
    final (dx, dy) = (to.$1 - from.$1, to.$2 - from.$2);
    final t = r / math.sqrt(dx * dx + dy * dy);
    return FontPoint(from.$1 + dx * t, from.$2 + dy * t);
  }

  final count = vertices.length;
  return [
    for (var i = 0; i < count; i++)
      if (radii[i] == 0)
        FontPoint(vertices[i].$1, vertices[i].$2)
      else ...[
        towards(vertices[i], vertices[(i + count - 1) % count], radii[i]),
        FontPoint(vertices[i].$1, vertices[i].$2, onCurve: false),
        towards(vertices[i], vertices[(i + 1) % count], radii[i]),
      ],
  ];
}

typedef _Scaled = ({int x, int y, bool onCurve});

/// Font units with y up; drops points that round onto their predecessor
/// (such as a contour's closing point landing on its start).
List<_Scaled> _toFont(List<FontPoint> contour) {
  final scaled = <_Scaled>[];
  for (final point in contour) {
    final next = (
      x: (point.x * unitsPerEm / _grid).round(),
      y: ((_grid - point.y) * unitsPerEm / _grid).round(),
      onCurve: point.onCurve,
    );
    if (scaled.isNotEmpty && scaled.last == next) continue;
    scaled.add(next);
  }
  while (scaled.length > 1 && scaled.last == scaled.first) {
    scaled.removeLast();
  }
  return scaled;
}

/// Serialises [glyphs] as a TrueType font. Ascent is the full em and descent
/// zero in the hhea, OS/2 typo and OS/2 win metrics alike — the layout of
/// Material Icons — so [Icon]'s 1.0-height line box maps the 24-unit canvas
/// exactly onto the icon's square on every platform's text stack.
Uint8List buildAtermiusIconFont([List<IconGlyph>? glyphs]) {
  final sorted = [...(glyphs ?? atermiusIconGlyphs)]
    ..sort((a, b) => a.codePoint - b.codePoint);
  for (var i = 1; i < sorted.length; i++) {
    if (sorted[i].codePoint == sorted[i - 1].codePoint) {
      throw ArgumentError('Duplicate code point ${sorted[i].codePoint}');
    }
  }

  // Glyph 0 is an empty .notdef; glyph i + 1 is sorted[i].
  final glyf = BytesBuilder();
  final loca = <int>[0, 0];
  final bounds = <({int xMin, int yMin, int xMax, int yMax})>[];
  var maxPoints = 0, maxContours = 0;
  for (final glyph in sorted) {
    final contours = [for (final c in glyph.contours) _toFont(c)];
    final points = [for (final c in contours) ...c];
    final box = (
      xMin: points.map((p) => p.x).reduce(math.min),
      yMin: points.map((p) => p.y).reduce(math.min),
      xMax: points.map((p) => p.x).reduce(math.max),
      yMax: points.map((p) => p.y).reduce(math.max),
    );
    bounds.add(box);
    maxPoints = math.max(maxPoints, points.length);
    maxContours = math.max(maxContours, contours.length);

    final data = _Writer()
      ..i16(contours.length)
      ..i16(box.xMin)
      ..i16(box.yMin)
      ..i16(box.xMax)
      ..i16(box.yMax);
    var end = -1;
    for (final contour in contours) {
      end += contour.length;
      data.u16(end);
    }
    data.u16(0); // no hinting instructions
    // Flags carry only the on-curve bit, so every coordinate is a full
    // 16-bit delta from the previous point.
    for (final point in points) {
      data.u8(point.onCurve ? 0x01 : 0x00);
    }
    for (var i = 0; i < points.length; i++) {
      data.i16(points[i].x - (i == 0 ? 0 : points[i - 1].x));
    }
    for (var i = 0; i < points.length; i++) {
      data.i16(points[i].y - (i == 0 ? 0 : points[i - 1].y));
    }
    glyf.add(data.bytes);
    while (glyf.length % 4 != 0) {
      glyf.addByte(0);
    }
    loca.add(glyf.length);
  }
  final numGlyphs = sorted.length + 1;
  final longLoca = glyf.length > 0x1fffe;
  final locaTable = _Writer();
  for (final offset in loca) {
    longLoca ? locaTable.u32(offset) : locaTable.u16(offset ~/ 2);
  }

  final xMin = bounds.map((b) => b.xMin).reduce(math.min);
  final yMin = bounds.map((b) => b.yMin).reduce(math.min);
  final xMax = bounds.map((b) => b.xMax).reduce(math.max);
  final yMax = bounds.map((b) => b.yMax).reduce(math.max);

  // A fixed date keeps the output byte-identical between runs.
  final created = DateTime.utc(2026).difference(DateTime.utc(1904)).inSeconds;

  final head = _Writer()
    ..u32(0x00010000)
    ..u32(0x00010000) // fontRevision 1.0
    ..u32(0) // checkSumAdjustment, set by _assemble
    ..u32(0x5f0f3cf5)
    ..u16(0x0003) // baseline at y=0, left side bearing at x=0
    ..u16(unitsPerEm)
    ..u32(0)
    ..u32(created)
    ..u32(0)
    ..u32(created)
    ..i16(xMin)
    ..i16(yMin)
    ..i16(xMax)
    ..i16(yMax)
    ..u16(0) // macStyle
    ..u16(8) // lowestRecPPEM
    ..i16(2) // fontDirectionHint
    ..i16(longLoca ? 1 : 0)
    ..i16(0);

  final hhea = _Writer()
    ..u32(0x00010000)
    ..i16(unitsPerEm) // ascender
    ..i16(0) // descender
    ..i16(0) // lineGap
    ..u16(unitsPerEm) // advanceWidthMax
    ..i16(xMin) // minLeftSideBearing
    ..i16(bounds.map((b) => unitsPerEm - b.xMax).reduce(math.min))
    ..i16(xMax) // xMaxExtent
    ..i16(1) // caretSlopeRise
    ..i16(0) // caretSlopeRun
    ..i16(0) // caretOffset
    ..i16(0)
    ..i16(0)
    ..i16(0)
    ..i16(0)
    ..i16(0) // metricDataFormat
    ..u16(numGlyphs);

  final hmtx = _Writer()
    ..u16(unitsPerEm)
    ..i16(0);
  for (final box in bounds) {
    hmtx
      ..u16(unitsPerEm)
      ..i16(box.xMin);
  }

  final maxp = _Writer()
    ..u32(0x00010000)
    ..u16(numGlyphs)
    ..u16(maxPoints)
    ..u16(maxContours)
    ..u16(0) // maxCompositePoints
    ..u16(0) // maxCompositeContours
    ..u16(2) // maxZones
    ..u16(0) // maxTwilightPoints
    ..u16(0) // maxStorage
    ..u16(0) // maxFunctionDefs
    ..u16(0) // maxInstructionDefs
    ..u16(0) // maxStackElements
    ..u16(0) // maxSizeOfInstructions
    ..u16(0) // maxComponentElements
    ..u16(0); // maxComponentDepth

  final os2 = _Writer()
    ..u16(4)
    ..i16(unitsPerEm) // xAvgCharWidth
    ..u16(400) // usWeightClass
    ..u16(5) // usWidthClass
    ..u16(0) // fsType: installable
    ..i16(unitsPerEm * 65 ~/ 100) // ySubscriptXSize
    ..i16(unitsPerEm * 60 ~/ 100) // ySubscriptYSize
    ..i16(0) // ySubscriptXOffset
    ..i16(unitsPerEm * 7 ~/ 100) // ySubscriptYOffset
    ..i16(unitsPerEm * 65 ~/ 100) // ySuperscriptXSize
    ..i16(unitsPerEm * 60 ~/ 100) // ySuperscriptYSize
    ..i16(0) // ySuperscriptXOffset
    ..i16(unitsPerEm * 48 ~/ 100) // ySuperscriptYOffset
    ..i16(unitsPerEm * 5 ~/ 100) // yStrikeoutSize
    ..i16(unitsPerEm * 26 ~/ 100) // yStrikeoutPosition
    ..i16(0) // sFamilyClass
    ..add(Uint8List(10)) // PANOSE: any
    ..u32(0)
    ..u32(1 << 28) // ulUnicodeRange2 bit 60: Private Use Area
    ..u32(0)
    ..u32(0)
    ..ascii('NONE') // achVendID: unregistered
    ..u16(0x00c0) // fsSelection: REGULAR | USE_TYPO_METRICS
    ..u16(sorted.first.codePoint)
    ..u16(sorted.last.codePoint)
    ..i16(unitsPerEm) // sTypoAscender
    ..i16(0) // sTypoDescender
    ..i16(0) // sTypoLineGap
    ..u16(unitsPerEm) // usWinAscent
    ..u16(0) // usWinDescent
    ..u32(1) // ulCodePageRange1: Latin 1
    ..u32(0)
    ..i16(0) // sxHeight
    ..i16(0) // sCapHeight
    ..u16(0) // usDefaultChar
    ..u16(0x20) // usBreakChar
    ..u16(0); // usMaxContext

  final post = _Writer()
    ..u32(0x00030000) // version 3: no glyph names
    ..u32(0) // italicAngle
    ..i16(-(unitsPerEm ~/ 10)) // underlinePosition
    ..i16(unitsPerEm ~/ 20) // underlineThickness
    ..u32(0) // isFixedPitch
    ..u32(0)
    ..u32(0)
    ..u32(0)
    ..u32(0);

  return _assemble({
    'OS/2': os2.bytes,
    'cmap': _cmap(sorted),
    'glyf': glyf.toBytes(),
    'head': head.bytes,
    'hhea': hhea.bytes,
    'hmtx': hmtx.bytes,
    'loca': locaTable.bytes,
    'maxp': maxp.bytes,
    'name': _name(const {
      1: 'Atermius Icons',
      2: 'Regular',
      3: 'Atermius Icons Regular 1.000',
      4: 'Atermius Icons Regular',
      5: 'Version 1.000',
      6: 'AtermiusIcons-Regular',
    }),
    'post': post.bytes,
  });
}

int _floorLog2(int value) => value.bitLength - 1;

Uint8List _cmap(List<IconGlyph> sorted) {
  // Format 4: one segment per run of consecutive code points, mapped by
  // idDelta, then the mandatory 0xFFFF terminator.
  final segments = <({int start, int end, int glyph})>[];
  for (var i = 0; i < sorted.length; i++) {
    final code = sorted[i].codePoint;
    if (code > 0xfffe) throw ArgumentError('Code point $code is outside BMP');
    if (segments.isNotEmpty && segments.last.end + 1 == code) {
      final run = segments.removeLast();
      segments.add((start: run.start, end: code, glyph: run.glyph));
    } else {
      segments.add((start: code, end: code, glyph: i + 1));
    }
  }
  segments.add((start: 0xffff, end: 0xffff, glyph: 0));
  final count = segments.length;
  final searchRange = 2 << _floorLog2(count);
  final subtable = _Writer()
    ..u16(4)
    ..u16(16 + 8 * count)
    ..u16(0) // language
    ..u16(2 * count)
    ..u16(searchRange)
    ..u16(_floorLog2(count))
    ..u16(2 * count - searchRange);
  for (final s in segments) {
    subtable.u16(s.end);
  }
  subtable.u16(0); // reservedPad
  for (final s in segments) {
    subtable.u16(s.start);
  }
  for (final s in segments) {
    subtable.u16((s.glyph - s.start) & 0xffff);
  }
  for (var i = 0; i < count; i++) {
    subtable.u16(0); // idRangeOffset
  }
  // Unicode BMP and Windows BMP records share the one subtable.
  return (_Writer()
        ..u16(0)
        ..u16(2)
        ..u16(0)
        ..u16(3)
        ..u32(20)
        ..u16(3)
        ..u16(1)
        ..u32(20)
        ..add(subtable.bytes))
      .bytes;
}

Uint8List _name(Map<int, String> names) {
  // Macintosh Roman and Windows Unicode records, as Material Icons ships
  // them; every string here is ASCII.
  final records = <({int platform, int encoding, int language, int id})>[];
  final strings = <List<int>>[];
  for (final MapEntry(:key, :value) in names.entries) {
    records.add((platform: 1, encoding: 0, language: 0, id: key));
    strings.add(value.codeUnits);
  }
  for (final MapEntry(:key, :value) in names.entries) {
    records.add((platform: 3, encoding: 1, language: 0x409, id: key));
    strings.add([
      for (final unit in value.codeUnits) ...[unit >> 8, unit & 0xff],
    ]);
  }
  final storage = BytesBuilder();
  final table = _Writer()
    ..u16(0)
    ..u16(records.length)
    ..u16(6 + 12 * records.length);
  for (var i = 0; i < records.length; i++) {
    final record = records[i];
    table
      ..u16(record.platform)
      ..u16(record.encoding)
      ..u16(record.language)
      ..u16(record.id)
      ..u16(strings[i].length)
      ..u16(storage.length);
    storage.add(strings[i]);
  }
  return (table..add(storage.toBytes())).bytes;
}

Uint8List _assemble(Map<String, Uint8List> tables) {
  // Table records sorted by tag; tables 4-byte aligned and zero padded.
  final tags = tables.keys.toList()..sort();
  final selector = _floorLog2(tags.length);
  final directory = _Writer()
    ..u32(0x00010000)
    ..u16(tags.length)
    ..u16(16 << selector)
    ..u16(selector)
    ..u16(16 * tags.length - (16 << selector));
  final body = BytesBuilder();
  var offset = 12 + 16 * tags.length;
  var headOffset = -1;
  for (final tag in tags) {
    final data = tables[tag]!;
    if (tag == 'head') headOffset = offset;
    directory
      ..ascii(tag)
      ..u32(_checksum(data))
      ..u32(offset)
      ..u32(data.length);
    final padded = (data.length + 3) & ~3;
    body
      ..add(data)
      ..add(Uint8List(padded - data.length));
    offset += padded;
  }
  final font =
      (BytesBuilder()
            ..add(directory.bytes)
            ..add(body.toBytes()))
          .toBytes();
  ByteData.sublistView(font)
      .setUint32(headOffset + 8, (0xb1b0afba - _checksum(font)) & 0xffffffff);
  return font;
}

int _checksum(Uint8List data) {
  final view = ByteData.sublistView(
    Uint8List((data.length + 3) & ~3)..setAll(0, data),
  );
  var sum = 0;
  for (var i = 0; i < view.lengthInBytes; i += 4) {
    sum = (sum + view.getUint32(i)) & 0xffffffff;
  }
  return sum;
}

class _Writer {
  final _builder = BytesBuilder();
  final _scratch = ByteData(4);

  Uint8List get bytes => _builder.toBytes();

  void add(List<int> bytes) => _builder.add(bytes);
  void u8(int value) => _builder.addByte(value);
  void ascii(String value) => _builder.add(value.codeUnits);
  void u16(int value) {
    _scratch.setUint16(0, value);
    _builder.add(_scratch.buffer.asUint8List(0, 2));
  }

  void i16(int value) {
    _scratch.setInt16(0, value);
    _builder.add(_scratch.buffer.asUint8List(0, 2));
  }

  void u32(int value) {
    _scratch.setUint32(0, value);
    _builder.add(_scratch.buffer.asUint8List(0, 4));
  }
}

void main() {
  final font = buildAtermiusIconFont();
  File(atermiusIconFontPath)
    ..createSync(recursive: true)
    ..writeAsBytesSync(font);
  stdout.writeln(
    'Wrote $atermiusIconFontPath: ${font.length} bytes, '
    '${atermiusIconGlyphs.length} glyph(s)',
  );
}
