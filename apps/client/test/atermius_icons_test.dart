// The app's icon font: the committed file matches its generator, is a
// well-formed sfnt registered in the asset bundle, and the RDP mark renders
// and follows IconTheme. With ATERMIUS_ICON_PREVIEW_DIR set it also writes
// PNG previews (16/24/48 px in light and dark, a comparison with the VNC and
// SSH icons, and the mark in a tab bar and host search results) for review:
//
//   ATERMIUS_ICON_PREVIEW_DIR=/tmp/rdp-icon flutter test \
//     test/atermius_icons_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/telnet/telnet_ui.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/atermius_icons.dart';
import 'package:aterm_client/ui/host_search_field.dart';
import 'package:aterm_client/ui/host_search_palette.dart';
import 'package:aterm_client/ui/new_session_menu.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/atermius_icon_font.dart' as generator;

final _previewDir = Platform.environment['ATERMIUS_ICON_PREVIEW_DIR'];

/// flutter_test renders only fonts loaded by the test; load the icon font
/// through the asset bundle so a broken pubspec entry fails here too.
Future<void> _loadFonts({bool preview = false}) async {
  final icons = FontLoader('AtermiusIcons')
    ..addFont(rootBundle.load(generator.atermiusIconFontPath));
  await icons.load();
  if (!preview) return;
  // Material Icons and Roboto for the comparison and context previews.
  final sdk = Platform.environment['FLUTTER_ROOT'];
  if (sdk == null) return;
  final fonts = '$sdk/bin/cache/artifacts/material_fonts';
  for (final (family, files) in [
    ('MaterialIcons', ['MaterialIcons-Regular.otf']),
    ('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']),
  ]) {
    final loader = FontLoader(family);
    for (final file in files) {
      final source = File('$fonts/$file');
      if (!source.existsSync()) continue;
      loader.addFont(
        Future.value(ByteData.sublistView(source.readAsBytesSync())),
      );
    }
    await loader.load();
  }
}

Future<ui.Image> _capture(WidgetTester tester, Finder finder) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(finder);
  final view = tester.view;
  return (await tester.runAsync(
    () => boundary.toImage(pixelRatio: view.devicePixelRatio),
  ))!;
}

/// Straight-alpha RGBA of [image], row-major.
Future<Uint8List> _rgba(WidgetTester tester, ui.Image image) async {
  final data = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawStraightRgba),
  );
  return data!.buffer.asUint8List();
}

Future<void> _writePng(WidgetTester tester, ui.Image image, String name) async {
  final png = await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  File('$_previewDir/$name')
    ..createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}

/// [image] scaled up [factor] times without smoothing, to inspect pixels.
Future<ui.Image> _magnify(
  WidgetTester tester,
  ui.Image image,
  int factor,
) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..scale(factor.toDouble())
    ..drawImage(
      image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.none,
    );
  return (await tester.runAsync(
    () => recorder.endRecording().toImage(
      image.width * factor,
      image.height * factor,
    ),
  ))!;
}

/// The colour (straight alpha) of the most opaque pixel: wherever a 2-unit
/// stroke fully covers a pixel, this is exactly the colour the icon painted.
({int r, int g, int b, int a, int inked}) _ink(Uint8List rgba) {
  var best = 0, inked = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i + 3] > rgba[best + 3]) best = i;
    if (rgba[i + 3] > 0) inked++;
  }
  return (
    r: rgba[best],
    g: rgba[best + 1],
    b: rgba[best + 2],
    a: rgba[best + 3],
    inked: inked,
  );
}

int _channel(double value) => (value * 255).round();

/// Asserts the painted [ink] is [color] (straight alpha); one step of slack
/// per channel for the premultiply round trip of translucent colours.
void _expectInk(
  ({int r, int g, int b, int a, int inked}) ink,
  Color color, {
  String? reason,
}) {
  expect(ink.a, closeTo(_channel(color.a), 1), reason: '$reason: alpha');
  expect(ink.r, closeTo(_channel(color.r), 2), reason: '$reason: red');
  expect(ink.g, closeTo(_channel(color.g), 2), reason: '$reason: green');
  expect(ink.b, closeTo(_channel(color.b), 2), reason: '$reason: blue');
}

const _boundaryKey = ValueKey('icon_boundary');

/// The app theme with Roboto named for menu and chip labels, which the theme
/// leaves to the platform default font (flutter_test's box font here).
ThemeData _previewTheme(Brightness brightness) {
  final theme = buildAppTheme(brightness: brightness);
  final label = theme.popupMenuTheme.labelTextStyle;
  return theme.copyWith(
    popupMenuTheme: theme.popupMenuTheme.copyWith(
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => label?.resolve(states)?.copyWith(fontFamily: 'Roboto'),
      ),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: theme.chipTheme.labelStyle?.copyWith(fontFamily: 'Roboto'),
    ),
  );
}

/// [child] alone in a transparent boundary, so captures hold only its ink.
Widget _bare(Widget child, {ThemeData? theme}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: theme,
  home: Material(
    type: MaterialType.transparency,
    child: Align(
      alignment: Alignment.topLeft,
      child: RepaintBoundary(key: _boundaryKey, child: child),
    ),
  ),
);

void main() {
  setUpAll(() => _loadFonts(preview: _previewDir != null));

  group('font file', () {
    late Uint8List committed;
    setUpAll(() {
      committed = File(generator.atermiusIconFontPath).readAsBytesSync();
    });

    test('matches tool/atermius_icon_font.dart', () {
      expect(
        committed,
        generator.buildAtermiusIconFont(),
        reason:
            'Regenerate with `dart run tool/atermius_icon_font.dart` in '
            'apps/client after changing an outline.',
      );
    });

    test('is a well-formed sfnt that maps every AtermiusIcons glyph', () {
      final view = ByteData.sublistView(committed);
      int checksum(int offset, int length) {
        var sum = 0;
        for (var i = 0; i < length; i += 4) {
          var word = 0;
          for (var j = 0; j < 4; j++) {
            final at = offset + i + j;
            word = (word << 8) | (at < committed.length ? committed[at] : 0);
          }
          sum = (sum + word) & 0xffffffff;
        }
        return sum;
      }

      expect(view.getUint32(0), 0x00010000, reason: 'TrueType outlines');
      final count = view.getUint16(4);
      final tables = <String, (int, int)>{};
      for (var i = 0; i < count; i++) {
        final record = 12 + 16 * i;
        final tag = ascii.decode(committed.sublist(record, record + 4));
        final offset = view.getUint32(record + 8);
        final length = view.getUint32(record + 12);
        expect(offset % 4, 0, reason: '$tag alignment');
        expect(offset + length, lessThanOrEqualTo(committed.length));
        if (tag != 'head') {
          expect(
            checksum(offset, length),
            view.getUint32(record + 4),
            reason: tag,
          );
        }
        tables[tag] = (offset, length);
      }
      expect(
        tables.keys,
        containsAll(<String>[
          'OS/2',
          'cmap',
          'glyf',
          'head',
          'hhea',
          'hmtx',
          'loca',
          'maxp',
          'name',
          'post',
        ]),
      );
      expect(
        checksum(0, committed.length),
        0xb1b0afba,
        reason: 'head.checkSumAdjustment',
      );
      final (head, _) = tables['head']!;
      expect(view.getUint32(head + 12), 0x5f0f3cf5, reason: 'head magic');

      // The Windows BMP cmap (format 4) maps each code point to a real glyph.
      final (cmap, _) = tables['cmap']!;
      int? subtable;
      for (var i = 0; i < view.getUint16(cmap + 2); i++) {
        final record = cmap + 4 + 8 * i;
        if (view.getUint16(record) == 3 && view.getUint16(record + 2) == 1) {
          subtable = cmap + view.getUint32(record + 4);
        }
      }
      expect(subtable, isNotNull);
      expect(view.getUint16(subtable!), 4);
      final segments = view.getUint16(subtable + 6) ~/ 2;
      int glyphFor(int code) {
        for (var s = 0; s < segments; s++) {
          final end = view.getUint16(subtable! + 14 + 2 * s);
          final start = view.getUint16(subtable + 16 + 2 * segments + 2 * s);
          final delta = view.getUint16(subtable + 16 + 4 * segments + 2 * s);
          if (code >= start && code <= end) return (code + delta) & 0xffff;
        }
        return 0;
      }

      const icons = [AtermiusIcons.remoteDesktop];
      expect(
        {for (final icon in icons) icon.codePoint},
        {for (final glyph in generator.atermiusIconGlyphs) glyph.codePoint},
        reason: 'AtermiusIcons and the generator list the same glyphs',
      );
      for (final icon in icons) {
        expect(icon.fontFamily, 'AtermiusIcons');
        expect(icon.fontPackage, isNull);
        expect(glyphFor(icon.codePoint), greaterThan(0));
      }
    });

    test('is registered as the AtermiusIcons family', () async {
      final manifest = jsonDecode(
        await rootBundle.loadString('FontManifest.json'),
      ) as List<Object?>;
      expect(
        manifest,
        contains(
          equals({
            'family': 'AtermiusIcons',
            'fonts': [
              {'asset': generator.atermiusIconFontPath},
            ],
          }),
        ),
      );
    });
  });

  group('RDP mark', () {
    testWidgets('draws the frame, stand and pointer, not the screen', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _bare(
          const Icon(
            AtermiusIcons.remoteDesktop,
            size: 48,
            color: Colors.black,
          ),
        ),
      );
      final image = await _capture(tester, find.byKey(_boundaryKey));
      final rgba = await _rgba(tester, image);
      expect((image.width, image.height), (48, 48));
      // Sample points on the 24-unit design canvas (2 px per unit here).
      int alphaAt(double x, double y) =>
          rgba[((y * 2).floor() * 48 + (x * 2).floor()) * 4 + 3];
      expect(alphaAt(12, 3), 255, reason: 'frame, top');
      expect(alphaAt(2, 10), 255, reason: 'frame, left');
      expect(alphaAt(22, 10), 255, reason: 'frame, right');
      expect(alphaAt(12, 16), 255, reason: 'frame, bottom');
      expect(alphaAt(12, 18.5), 255, reason: 'neck');
      expect(alphaAt(8.5, 21), 255, reason: 'base');
      expect(alphaAt(10.5, 8.5), 255, reason: 'pointer');
      expect(alphaAt(4.5, 13), 0, reason: 'screen beside the pointer');
      expect(alphaAt(19, 13), 0, reason: 'screen beside the pointer');
      expect(alphaAt(18, 5), 0, reason: 'screen beside the pointer');
      expect(alphaAt(9.5, 18.5), 0, reason: 'beside the neck');
      expect(alphaAt(12, 1), 0, reason: 'above the frame');
      expect(alphaAt(12, 23), 0, reason: 'below the base');
      image.dispose();
    });

    testWidgets('follows IconTheme size, colour and opacity', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const color = Color(0xff2a6fdb);
      for (final size in [14.0, 16.0, 24.0, 48.0]) {
        await tester.pumpWidget(
          _bare(
            IconTheme(
              data: IconThemeData(size: size, color: color, opacity: .5),
              child: const Icon(AtermiusIcons.remoteDesktop),
            ),
          ),
        );
        expect(tester.getSize(find.byType(Icon)), Size.square(size));
        final image = await _capture(tester, find.byKey(_boundaryKey));
        final ink = _ink(await _rgba(tester, image));
        image.dispose();
        expect(ink.inked, greaterThan(size * 2), reason: 'renders at $size');
        _expectInk(ink, color.withValues(alpha: .5), reason: 'at $size');
      }
    });

    for (final brightness in Brightness.values) {
      testWidgets('takes the ${brightness.name} theme colour, also disabled', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final colors = <Color>[];
        for (final enabled in [true, false]) {
          await tester.pumpWidget(
            _bare(
              theme: buildAppTheme(brightness: brightness),
              SizedBox(
                width: 200,
                child: ListTile(
                  enabled: enabled,
                  leading: const Icon(AtermiusIcons.remoteDesktop),
                ),
              ),
            ),
          );
          final theme = IconTheme.of(tester.element(find.byType(Icon)));
          final color = theme.color!.withValues(
            alpha: theme.color!.a * (theme.opacity ?? 1),
          );
          colors.add(color);
          final image = await _capture(tester, find.byKey(_boundaryKey));
          final ink = _ink(await _rgba(tester, image));
          image.dispose();
          _expectInk(ink, color, reason: enabled ? 'enabled' : 'disabled');
        }
        expect(colors.first, isNot(colors.last), reason: 'disabled differs');
      });
    }
  });

  test('RDP has its own protocol icon, distinct from VNC and SSH', () {
    expect(hostProtocolIcon(HostProtocol.rdp), AtermiusIcons.remoteDesktop);
    expect(hostProtocolIcon(HostProtocol.vnc), Icons.desktop_windows_outlined);
    expect(hostProtocolIcon(HostProtocol.ssh), Icons.terminal);
    expect(hostProtocolIcon(HostProtocol.telnet), Icons.settings_ethernet);
    expect(hostSessionIcon(HostProtocol.rdp), AtermiusIcons.remoteDesktop);
    expect(hostSessionIcon(HostProtocol.vnc), Icons.desktop_windows_outlined);
    expect(hostSessionIcon(HostProtocol.ssh), Icons.terminal);
    expect(hostSessionIcon(HostProtocol.telnet), Icons.terminal);
  });

  group('previews', skip: _previewDir == null, () {
    for (final brightness in Brightness.values) {
      final name = brightness.name;
      testWidgets('icon sizes, $name', (tester) async {
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final theme = buildAppTheme(brightness: brightness);
        Widget tile(IconData icon, double size) => Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: size),
        );
        Widget sheet(Widget child) =>
            ColoredBox(color: theme.scaffoldBackgroundColor, child: child);
        for (final size in [16.0, 24.0, 48.0]) {
          await tester.pumpWidget(
            _bare(theme: theme, sheet(tile(AtermiusIcons.remoteDesktop, size))),
          );
          final image = await _capture(tester, find.byKey(_boundaryKey));
          await _writePng(tester, image, 'rdp_${size.round()}_$name.png');
          final magnified = await _magnify(tester, image, 8);
          await _writePng(
            tester,
            magnified,
            'rdp_${size.round()}_${name}_x8.png',
          );
          image.dispose();
          magnified.dispose();
        }

        // RDP against VNC (lists; the new-session menu) and SSH, at the
        // sizes the app uses: menus and tabs 16-18, lists 20-24.
        const sizes = [14.0, 16.0, 18.0, 20.0, 24.0, 32.0, 48.0];
        await tester.pumpWidget(
          _bare(
            theme: theme,
            sheet(
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final icon in [
                    hostProtocolIcon(HostProtocol.rdp),
                    hostProtocolIcon(HostProtocol.vnc),
                    Icons.desktop_mac_outlined,
                    hostProtocolIcon(HostProtocol.ssh),
                  ])
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [for (final size in sizes) tile(icon, size)],
                    ),
                ],
              ),
            ),
          ),
        );
        final image = await _capture(tester, find.byKey(_boundaryKey));
        await _writePng(tester, image, 'compare_$name.png');
        final magnified = await _magnify(tester, image, 5);
        await _writePng(tester, magnified, 'compare_${name}_x5.png');
        image.dispose();
        magnified.dispose();
      });

      testWidgets('tab bar, host search and new-session menu, $name', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 2;
        tester.view.physicalSize = const Size(1440, 1240);
        addTearDown(tester.view.reset);
        const hosts = [
          HostRecord(
            id: 'ssh',
            name: 'Build server',
            address: 'build.example.test',
            username: 'ci',
          ),
          HostRecord(
            id: 'rdp',
            name: 'Windows desktop',
            address: 'win.example.test',
            username: 'ops',
            protocol: HostProtocol.rdp,
          ),
          HostRecord(
            id: 'vnc',
            name: 'Lab display',
            address: 'lab.example.test',
            protocol: HostProtocol.vnc,
          ),
        ];
        await tester.pumpWidget(
          RepaintBoundary(
            key: _boundaryKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _previewTheme(brightness),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Column(
                  children: [
                    WorkspaceTabBar(
                      tabs: [
                        const WorkspaceTab(
                          id: 'hosts',
                          title: 'Home',
                          isHome: true,
                        ),
                        for (final host in hosts)
                          WorkspaceTab(
                            id: host.id,
                            title: host.name,
                            isConnected: host.protocol != HostProtocol.vnc,
                            icon: hostSessionIcon(host.protocol),
                          ),
                      ],
                      selectedId: 'rdp',
                      onSelect: (_) {},
                      onClose: (_) {},
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: NewSessionMenu(onHost: (_) {}),
                    ),
                    const Expanded(child: SizedBox.expand()),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        showHostSearchPalette(
          tester.element(find.byType(WorkspaceTabBar)),
          hosts: () => hosts,
          groups: const {},
          fieldKey: const ValueKey('preview_search'),
          isCurrent: () => true,
        );
        await tester.pumpAndSettle();
        final search = await _capture(tester, find.byKey(_boundaryKey));
        await _writePng(tester, search, 'ui_search_$name.png');
        search.dispose();

        Navigator.of(tester.element(find.byType(HostSearchField))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byType(NewSessionMenu));
        await tester.pumpAndSettle();
        final menu = await _capture(tester, find.byKey(_boundaryKey));
        await _writePng(tester, menu, 'ui_menu_$name.png');
        menu.dispose();
      });
    }
  });
}
