import 'dart:io';
import 'dart:ui' as ui;

import 'package:aterm_client/domain/host_operating_system.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/host_system_icon.dart';
import 'package:aterm_client/ui/host_system_marks.g.dart';
import 'package:aterm_client/ui/svg_path.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/host_system_marks.dart' as generator;

/// Set to a directory to write a contact sheet of every mark (dark and light).
final _previewDir = Platform.environment['ATERMIUS_ICON_PREVIEW_DIR'];

HostOperatingSystem _linux(String id, {List<String> like = const []}) =>
    HostOperatingSystem(
      family: HostOperatingSystemFamily.linux,
      displayName: 'Example',
      distributionId: id,
      distributionLike: like,
      detectedAt: DateTime.utc(2026, 11, 18),
    );

void main() {
  test('generated table matches tool/host_system_marks.dart', () {
    expect(
      File(generator.hostSystemMarksPath).readAsStringSync(),
      generator.buildHostSystemMarks(Directory('tool/host_system_marks')),
      reason:
          'Regenerate with `dart run tool/host_system_marks.dart` in '
          'apps/client.',
    );
  });

  test('every outline parses and stays on the 24-unit canvas', () {
    expect(hostSystemMarks.length, greaterThanOrEqualTo(50));
    for (final entry in hostSystemMarks.entries) {
      // Sampled along the outline: getBounds() also counts control points.
      final path = parseSvgPath(entry.value.path);
      var bounds = Rect.zero;
      var first = true;
      for (final metric in path.computeMetrics()) {
        for (var at = 0.0; at <= metric.length; at += .05) {
          final point = metric.getTangentForOffset(at)!.position;
          bounds = first
              ? point & Size.zero
              : bounds.expandToInclude(point & Size.zero);
          first = false;
        }
      }
      expect(first, isFalse, reason: entry.key);
      expect(
        bounds.left >= -.05 &&
            bounds.top >= -.05 &&
            bounds.right <= 24.05 &&
            bounds.bottom <= 24.05,
        isTrue,
        reason: '${entry.key} $bounds',
      );
      expect(bounds.longestSide, greaterThan(18), reason: entry.key);
      expect(entry.value.color >> 24, 0xff, reason: entry.key);
    }
  });

  test('every alias and product leads to an outline', () {
    for (final entry in hostSystemMarkAliases.entries) {
      expect(hostSystemMarks, contains(entry.value), reason: entry.key);
      expect(_linux(entry.key).markId, entry.value);
    }
    for (final product in hostSystemProducts.keys) {
      expect(hostSystemMarkAliases, contains(product));
    }
    expect(
      hostSystemMarks.keys.toSet().difference({
        ...hostSystemMarkAliases.values,
        'freebsd',
        'openbsd',
        'netbsd',
      }),
      isEmpty,
      reason: 'outlines nothing resolves to',
    );
  });

  test('derivatives show the nearest system they are based on', () {
    expect(_linux('neon', like: ['ubuntu', 'debian']).markId, 'ubuntu');
    expect(_linux('devuan', like: ['debian']).markId, 'debian');
    expect(_linux('postmarketos', like: ['alpine']).markId, 'alpine');
    expect(
      _linux('anolis', like: ['rhel', 'fedora', 'centos']).markId,
      'redhat',
    );
    expect(_linux('cachyos', like: ['arch']).markId, 'arch');
    expect(_linux('pop', like: ['ubuntu', 'debian']).markId, 'pop');
    expect(_linux('somethingelse').markId, isNull);
    for (final family in HostOperatingSystemFamily.values) {
      final system = HostOperatingSystem(
        family: family,
        displayName: 'Example',
        detectedAt: DateTime.utc(2026, 11, 18),
      );
      expect(system.markId, switch (family) {
        HostOperatingSystemFamily.freebsd => 'freebsd',
        HostOperatingSystemFamily.openbsd => 'openbsd',
        HostOperatingSystemFamily.netbsd => 'netbsd',
        _ => null,
      });
    }
  });

  test('path data: relative commands, implicit repeats and compact arcs', () {
    final path = parseSvgPath('M2 2h4v4H2zm10 0 4 0 0 4-4 0z');
    expect(path.getBounds(), const Rect.fromLTRB(2, 2, 16, 6));
    expect(path.contains(const Offset(14, 4)), isTrue);
    expect(path.contains(const Offset(9, 4)), isFalse);
    // Flags without separators: "a5 5 0 105 5" is large-arc 1, sweep 0.
    final arc = parseSvgPath('M12 2a5 5 0 105 5L12 7z').getBounds();
    expect(arc.left, closeTo(7, .05));
    expect(arc.bottom, closeTo(12, .05));
    final smooth = parseSvgPath('M0 0C0 4 4 4 4 0S8-4 8 0').getBounds();
    // Control-point bounds: S mirrors the control (4, 4) to (4, -4).
    expect(smooth.top, closeTo(-4, .01));
    expect(smooth.bottom, closeTo(4, .01));
    for (final bad in [
      'L1 1x',
      '1 2',
      'M1',
      'M1 1A1 1 0 2 1 3 3',
      'M0 0z1 1',
    ]) {
      expect(() => parseSvgPath(bad), throwsFormatException, reason: bad);
    }
  });

  testWidgets('an identified system paints its own outline', (tester) async {
    const host = HostRecord(
      id: 'host',
      name: 'web',
      address: 'web.example',
      username: 'demo',
    );
    for (final (system, mark) in [
      (_linux('ubuntu'), 'ubuntu'),
      (_linux('debian'), 'debian'),
      (_linux('alpine'), 'alpine'),
      (_linux('proxmox', like: ['debian']), 'proxmox'),
      (_linux('linuxmint', like: ['ubuntu']), 'mint'),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HostSystemIcon(
              host: host.copyWithDetectedOperatingSystem(system),
            ),
          ),
        ),
      );
      expect(find.byKey(ValueKey('host-system-mark-$mark')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    // A Linux system nobody has a mark for keeps the penguin.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostSystemIcon(
            host: host.copyWithDetectedOperatingSystem(_linux('somethingelse')),
          ),
        ),
      ),
    );
    expect(
      find.byWidgetPredicate(
        (w) => w.key.toString().contains('host-system-mark-'),
      ),
      findsNothing,
    );
    expect(find.byTooltip('Example'), findsOneWidget);
  });

  testWidgets('contact sheet', skip: _previewDir == null, (tester) async {
    const host = HostRecord(id: 'h', name: 'h', address: 'h', username: 'u');
    final names = hostSystemMarks.keys.toList();
    final systems = <HostOperatingSystem?>[
      for (final name in names)
        _linux(
          hostSystemMarkAliases.entries
                  .where((e) => e.value == name)
                  .firstOrNull
                  ?.key ??
              'x',
          like: const [],
        ),
      _linux('unknown'),
    ];
    final key = GlobalKey();
    await tester.binding.setSurfaceSize(const Size(1040, 760));
    Widget sheet(Brightness brightness) => Theme(
      data: ThemeData(brightness: brightness),
      child: Builder(
        builder: (context) => ColoredBox(
          color: Theme.of(context).colorScheme.surface,
          child: Wrap(
            children: [
              for (final (i, system) in systems.indexed)
                SizedBox(
                  width: 74,
                  height: 62,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      i < names.length &&
                              const {
                                'freebsd',
                                'openbsd',
                                'netbsd',
                              }.contains(names[i])
                          ? HostSystemIcon(
                              size: 32,
                              host: host.copyWithDetectedOperatingSystem(
                                HostOperatingSystem(
                                  family: HostOperatingSystemFamily.values
                                      .byName(names[i]),
                                  displayName: 'x',
                                  detectedAt: DateTime.utc(2026),
                                ),
                              ),
                            )
                          : HostSystemIcon(
                              size: 32,
                              host: host.copyWithDetectedOperatingSystem(
                                system!,
                              ),
                            ),
                      Text(
                        i < names.length ? names[i] : 'linux',
                        style: const TextStyle(fontSize: 9),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: Column(
            children: [
              Expanded(child: sheet(Brightness.dark)),
              Expanded(child: sheet(Brightness.light)),
            ],
          ),
        ),
      ),
    );
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_previewDir/host-system-marks.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
