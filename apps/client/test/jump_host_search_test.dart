import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ui/host_editor_panel.dart';
import 'package:aterm_client/ui/ios_native/ios_native.dart';
import 'package:aterm_client/ui/temporary_jump_host_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const target = HostRecord(
  id: 'target',
  name: 'Target',
  address: 'target.test',
  jumpHostId: 'east',
);
const west = HostRecord(
  id: 'west',
  name: 'Gateway',
  address: '10.42.1.10',
  port: 2202,
  username: 'Deploy',
  tags: ['蓝区'],
  groupId: 'edge',
);
const east = HostRecord(
  id: 'east',
  name: 'Gateway',
  address: '10.99.1.10',
  username: 'ops',
);
const groups = [
  GroupRecord(id: 'prod', name: 'Production'),
  GroupRecord(id: 'edge', name: 'London', parentId: 'prod'),
];

void main() {
  for (final ios in [false, true]) {
    testWidgets(
      'saved jump search filters eligible hosts and preserves selection on cancel (iOS: $ios)',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(600, 850));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: IosNativeScope(
              enabled: ios,
              child: const HostEditorPanel(
                existing: target,
                groups: groups,
                hosts: [east, west, target],
              ),
            ),
          ),
        );
        final field = find.byKey(const ValueKey('host_editor_jump_host'));
        final search = find.byKey(
          const ValueKey('host_editor_jump_host_search'),
        );
        Finder option(String id) =>
            find.byKey(ValueKey('host_editor_jump_host_option_$id'));
        Future<void> open() async {
          await tester.ensureVisible(field);
          await tester.tap(field);
          await tester.pumpAndSettle();
        }

        await open();
        await tester.enterText(search, 'gate');
        await tester.pump();
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pump();
        expect(option('west'), findsOneWidget);
        expect(option('east'), findsOneWidget);
        await tester.enterText(search, 'TARGET');
        await tester.pump();
        expect(option('target'), findsNothing);
        expect(
          find.byKey(const ValueKey('host_editor_jump_host_empty')),
          findsOneWidget,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await open();
        expect(option('east'), findsOneWidget);
        if (ios) {
          expect(
            tester.widget<IosListRow>(option('east')).accessory,
            IosRowAccessory.checkmark,
          );
        } else {
          expect(
            find.descendant(
              of: option('east'),
              matching: find.byIcon(Icons.check),
            ),
            findsOneWidget,
          );
        }
        await tester.enterText(
          search,
          '  蓝区  2202 PROD deploy@10.42 LON gate ',
        );
        await tester.pump();
        expect(option('west'), findsOneWidget);
        expect(option('east'), findsNothing);
        await tester.tap(option('west'));
        await tester.pumpAndSettle();
        expect(search, findsNothing);
        await open();
        if (!ios) {
          expect(
            find.descendant(
              of: option('west'),
              matching: find.byIcon(Icons.check),
            ),
            findsOneWidget,
          );
        }
        await tester.tap(
          find.byKey(const ValueKey('host_editor_jump_host_saved_route')),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: field, matching: find.text('Direct connection')),
          findsOneWidget,
        );
      },
    );
  }

  testWidgets(
    'temporary jump picker searches a single candidate and submits the match',
    (tester) async {
      TemporaryJumpChoice? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  picked = await showTemporaryJumpHostPicker(
                    context,
                    target: target,
                    groups: groups,
                    candidates: const [west],
                  );
                },
                child: const Text('Choose'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('temporary_jump_search'));
      await tester.enterText(search, 'wrong');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('temporary_jump_empty')),
        findsOneWidget,
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(search, findsOneWidget);
      await tester.enterText(search, '2202 BLUE');
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('temporary_jump_option_west')),
        findsOneWidget,
      );
      await tester.enterText(search, 'lon 蓝区 dePloy 2202');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(picked, (jumpHostId: 'west'));
    },
  );
}
