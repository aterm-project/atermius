import 'dart:io';

import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/apple_hig.dart';
import 'package:aterm_client/ui/surfaces.dart';
import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('Apple HIG theme conformance (iOS & macOS)', () {
    for (final platform in const [TargetPlatform.iOS, TargetPlatform.macOS]) {
      for (final brightness in Brightness.values) {
        test(
          '$platform ($brightness) disables Material splash, applies squircles, and removes switch track outline',
          () {
            final theme = buildAppTheme(
              platform: platform,
              brightness: brightness,
            );

            expect(theme.platform, platform);
            expect(theme.splashFactory, same(NoSplash.splashFactory));
            expect(theme.splashColor, Colors.transparent);

            expect(theme.cardTheme.shape, isA<RoundedSuperellipseBorder>());
            expect(theme.dialogTheme.shape, isA<RoundedSuperellipseBorder>());
            expect(
              theme.popupMenuTheme.shape,
              isA<RoundedSuperellipseBorder>(),
            );
            // Chips are capsules on every platform (no outline).
            expect(theme.chipTheme.shape, isA<StadiumBorder>());
            expect(
              theme.filledButtonTheme.style?.shape?.resolve(const {}),
              isA<RoundedSuperellipseBorder>(),
            );
            expect(
              theme.outlinedButtonTheme.style?.shape?.resolve(const {}),
              isA<RoundedSuperellipseBorder>(),
            );
            expect(
              theme.textButtonTheme.style?.shape?.resolve(const {}),
              isA<RoundedSuperellipseBorder>(),
            );

            expect(
              theme.switchTheme.trackOutlineWidth?.resolve(const {}),
              equals(0),
            );
            expect(
              theme.switchTheme.trackOutlineColor?.resolve(const {}),
              Colors.transparent,
            );
            expect(theme.switchTheme.splashRadius, equals(0));
            expect(
              theme,
              equals(buildAppTheme(platform: platform, brightness: brightness)),
            );
          },
        );
      }
    }
  });

  group('Non-Apple platform preservation (Android & Windows)', () {
    for (final platform in const [
      TargetPlatform.android,
      TargetPlatform.windows,
    ]) {
      for (final brightness in Brightness.values) {
        test(
          '$platform ($brightness) preserves RoundedRectangleBorder and default Material ink splash',
          () {
            final theme = buildAppTheme(
              platform: platform,
              brightness: brightness,
            );

            expect(theme.platform, platform);
            expect(theme.splashFactory, isNot(same(NoSplash.splashFactory)));
            expect(theme.splashColor, isNot(equals(Colors.transparent)));

            expect(theme.cardTheme.shape, isA<RoundedRectangleBorder>());
            expect(
              theme.cardTheme.shape,
              isNot(isA<RoundedSuperellipseBorder>()),
            );
            expect(theme.dialogTheme.shape, isA<RoundedRectangleBorder>());
            expect(
              theme.dialogTheme.shape,
              isNot(isA<RoundedSuperellipseBorder>()),
            );
            expect(theme.popupMenuTheme.shape, isA<RoundedRectangleBorder>());
            expect(
              theme.popupMenuTheme.shape,
              isNot(isA<RoundedSuperellipseBorder>()),
            );
          },
        );
      }
    }
  });

  group('AppleScrollBehavior elastic bounce & overscroll indicator', () {
    for (final platform in const [TargetPlatform.iOS, TargetPlatform.macOS]) {
      testWidgets(
        '$platform returns BouncingScrollPhysics and un-wrapped child in buildOverscrollIndicator',
        (tester) async {
          const behavior = AppleScrollBehavior();
          late BuildContext capturedContext;

          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(platform: platform),
              scrollBehavior: behavior,
              home: Scaffold(
                body: Builder(
                  builder: (context) {
                    capturedContext = context;
                    return ListView(
                      children: const [
                        SizedBox(height: 120, child: Text('Item 1')),
                        SizedBox(height: 120, child: Text('Item 2')),
                      ],
                    );
                  },
                ),
              ),
            ),
          );

          final physics = behavior.getScrollPhysics(capturedContext);
          expect(physics, isA<BouncingScrollPhysics>());
          expect(physics.parent, isA<AlwaysScrollableScrollPhysics>());

          const sentinelChild = SizedBox(key: ValueKey('overscroll_sentinel'));
          final indicator = behavior.buildOverscrollIndicator(
            capturedContext,
            sentinelChild,
            const ScrollableDetails(direction: AxisDirection.down),
          );
          expect(indicator, same(sentinelChild));
          expect(indicator, isNot(isA<GlowingOverscrollIndicator>()));
          expect(find.byType(GlowingOverscrollIndicator), findsNothing);
        },
      );
    }

    testWidgets(
      'non-Apple platform delegates physics and overscroll to Material defaults',
      (tester) async {
        const behavior = AppleScrollBehavior();
        late BuildContext capturedContext;

        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(platform: TargetPlatform.android),
            scrollBehavior: behavior,
            home: Builder(
              builder: (context) {
                capturedContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        );

        final physics = behavior.getScrollPhysics(capturedContext);
        expect(physics, isNot(isA<BouncingScrollPhysics>()));
      },
    );
  });

  group('Apple HIG primitives & iOS ProMotion Info.plist', () {
    testWidgets('appleHairlineWidth scales with devicePixelRatio and haptics stay silent in tests', (
      tester,
    ) async {
      late double retinaHairline;
      late double standardHairline;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(platform: TargetPlatform.iOS),
          home: Column(
            children: [
              MediaQuery(
                data: const MediaQueryData(devicePixelRatio: 3.0),
                child: Builder(
                  builder: (context) {
                    retinaHairline = appleHairlineWidth(context);
                    AppleHaptics.selection(context);
                    AppleHaptics.light(context);
                    return const SizedBox.shrink();
                  },
                ),
              ),
              MediaQuery(
                data: const MediaQueryData(devicePixelRatio: 1.0),
                child: Builder(
                  builder: (context) {
                    standardHairline = appleHairlineWidth(context);
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ],
          ),
        ),
      );

      expect(retinaHairline, equals(0.5));
      expect(standardHairline, equals(1.0));
    });

    test(
      'iOS Runner Info.plist enables CADisableMinimumFrameDurationOnPhone for 120Hz ProMotion',
      () {
        final candidates = <File>[
          File('ios/Runner/Info.plist'),
          File('../../../ios/apps/client/ios/Runner/Info.plist'),
        ];
        File? infoPlist;
        for (final candidate in candidates) {
          if (candidate.existsSync()) {
            infoPlist = candidate;
            break;
          }
        }
        if (infoPlist == null) {
          // Allow standalone desktop checkouts without a sibling ios repo.
          return;
        }

        final content = infoPlist.readAsStringSync();
        expect(
          content,
          contains('<key>CADisableMinimumFrameDurationOnPhone</key>'),
        );
        expect(
          RegExp(
            r'<key>CADisableMinimumFrameDurationOnPhone</key>\s*<true/>',
          ).hasMatch(content),
          isTrue,
          reason:
              'CADisableMinimumFrameDurationOnPhone must be set to <true/> in Info.plist',
        );
      },
    );
  });

  group('Apple Liquid Glass & iOS soft-keyboard SSH Backspace', () {
    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets(
        'GlassSurface renders blurred glass on ${platform.name} without an outline and drops the blur in high contrast',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(platform: platform),
              home: const Scaffold(
                body: Column(
                  children: [
                    GlassSurface(
                      tint: Color(0xFF12191C),
                      child: SizedBox(height: 38, width: 200),
                    ),
                    GlassSurface(
                      borderRadius: BorderRadius.all(Radius.circular(16)),
                      elevated: true,
                      child: SizedBox(height: 80, width: 200),
                    ),
                  ],
                ),
              ),
            ),
          );
          expect(find.byType(BackdropFilter), findsNWidgets(2));
          for (final box in tester.widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(GlassSurface),
              matching: find.byType(DecoratedBox),
            ),
          )) {
            final decoration = box.decoration;
            if (decoration is BoxDecoration) {
              expect(decoration.border, isNull);
            }
          }

          // High-contrast accessibility disables blur for crisp legibility.
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(platform: platform),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(highContrast: true),
                child: child!,
              ),
              home: const Scaffold(
                body: GlassSurface(child: SizedBox(height: 80, width: 200)),
              ),
            ),
          );
          expect(find.byType(BackdropFilter), findsNothing);
        },
      );
    }

    testWidgets(
      'iOS TerminalView enables zero-width-space deleteDetection by default and emits DEL (0x7F) on repeated soft-keyboard Backspace',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          final emitted = <String>[];
          final terminal = Terminal(onOutput: emitted.add);
          final focusNode = FocusNode();
          addTearDown(focusNode.dispose);

          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(platform: TargetPlatform.iOS),
              home: Scaffold(
                body: SizedBox(
                  width: 400,
                  height: 300,
                  child: TerminalView(
                    terminal,
                    focusNode: focusNode,
                    autofocus: true,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();

          // Initial IME buffer on iOS must hold the 2-char zero-width sentinel.
          expect(tester.testTextInput.editingState?['text'], '\u200b\u200b');

          // Simulate three consecutive iOS soft-keyboard Backspace deletions:
          // each shrinks the 2-char sentinel to 1 char, triggers 0x7F, and
          // resets the sentinel back to '\u200b\u200b'.
          for (var i = 0; i < 3; i++) {
            tester.testTextInput.updateEditingValue(
              const TextEditingValue(
                text: '\u200b',
                selection: TextSelection.collapsed(offset: 1),
              ),
            );
            await tester.pump();
            expect(tester.testTextInput.editingState?['text'], '\u200b\u200b');
          }

          expect(emitted, ['\x7f', '\x7f', '\x7f']);
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}
