import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:aterm_client/ui/fullscreen_tabs_peek.dart';
import 'package:aterm_client/platform/fullscreen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _tabs = [
  WorkspaceTab(id: 'home', title: 'Hosts', isHome: true),
  WorkspaceTab(id: 'a', title: 'Alpha', isConnected: true),
  WorkspaceTab(id: 'b', title: 'Beta'),
  WorkspaceTab(id: 'files', title: 'Files', isFile: true),
];
final _button = find.byKey(const ValueKey('workspace-tab-list-button'));
final _panel = find.byKey(const ValueKey('workspace-tab-list'));

void main() {
  testWidgets(
    '320px Android toolbar fits all controls and large text',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                children: [
                  WorkspaceTabBar(
                    tabs: _tabs,
                    selectedId: 'a',
                    leading: IconButton(
                      onPressed: () {},
                      icon: const Icon(Icons.arrow_back),
                    ),
                    onSelect: (_) {},
                    onClose: (_) {},
                    onSearch: () {},
                    onToggleTools: () {},
                    homeMenuActions: [
                      WorkspaceAction('add', 'Add host', Icons.add, () {}),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(_button, findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(_button);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('workspace-tab-a')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(_button);
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'fullscreen list stays open while browsing and releases the peek afterward',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var native = false;
      final fullscreen = FullscreenController(
        supported: true,
        read: () async => native,
        apply: (value) async => native = value,
        changes: const Stream.empty(),
      );
      final peek = FullscreenTabsPeek();
      FullscreenController.debugInstance = fullscreen;
      FullscreenTabsPeek.debugInstance = peek;
      addTearDown(() {
        FullscreenController.debugInstance = null;
        FullscreenTabsPeek.debugInstance = null;
        fullscreen.dispose();
        peek.dispose();
      });
      await fullscreen.toggle();
      await _mount(tester, TargetPlatform.android);
      peek.show();
      await tester.pumpAndSettle();
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(peek.held, isTrue);
      await tester.pump(const Duration(seconds: 5));
      expect(_panel, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('workspace-tab-b')));
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      expect(peek.visible, isTrue);
      expect(peek.held, isFalse);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(_button, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android narrow toolbar switches, closes and updates a vertical tab list',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var tabs = [..._tabs];
      var selected = 'b';
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: Column(
                  children: [
                    WorkspaceTabBar(
                      tabs: tabs,
                      selectedId: selected,
                      onSelect: (id) => setState(() => selected = id),
                      onClose: (id) => setState(() {
                        tabs.removeWhere((tab) => tab.id == id);
                        if (selected == id) selected = 'home';
                      }),
                      homeMenuActions: [
                        WorkspaceAction('add', 'Add host', Icons.add, () {}),
                      ],
                      onSearch: () {},
                      onToggleTools: () {},
                    ),
                    const Expanded(child: Text('terminal stays mounted')),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_button, findsOneWidget);
      expect(find.byKey(const ValueKey('workspace-tab-a')), findsNothing);
      final contentRect = tester.getRect(find.text('terminal stays mounted'));

      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget);
      final alpha = find.byKey(const ValueKey('workspace-tab-a'));
      final beta = find.byKey(const ValueKey('workspace-tab-b'));
      expect(tester.getTopLeft(alpha).dy, lessThan(tester.getTopLeft(beta).dy));
      expect(tester.getSize(alpha).width, greaterThan(300));
      expect(tester.getRect(find.text('terminal stays mounted')), contentRect);

      await tester.tap(find.byTooltip('Close Alpha'));
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget);
      expect(alpha, findsNothing);
      update(() => tabs.add(const WorkspaceTab(id: 'c', title: 'Gamma')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('workspace-tab-c')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('workspace-tab-files')));
      await tester.pumpAndSettle();
      expect(selected, 'files');
      expect(_panel, findsNothing);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_panel, findsNothing);
      expect(_button, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'width and toolbar space determine compact mode; rotating restores the strip',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _mount(tester, TargetPlatform.android);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(_panel, findsOneWidget);

      await tester.binding.setSurfaceSize(const Size(1000, 720));
      await tester.pumpAndSettle();
      expect(_button, findsNothing);
      expect(_panel, findsNothing);
      expect(find.byKey(const ValueKey('workspace-tab-a')), findsOneWidget);

      await tester.binding.setSurfaceSize(const Size(360, 720));
      await tester.pumpAndSettle();
      expect(_button, findsOneWidget);
      expect(_panel, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop keeps the horizontal strip on narrow windows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _mount(tester, TargetPlatform.linux);
    expect(_button, findsNothing);
    expect(find.byKey(const ValueKey('workspace-tab-a')), findsOneWidget);
  });

  testWidgets('group selection and close apply to the grouped members', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? selection;
    final closed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: Column(
            children: [
              WorkspaceTabBar(
                tabs: _tabs,
                selectedId: 'files',
                groups: const [
                  ['a', 'b'],
                ],
                groupSelections: const {'a': 'b'},
                onSelect: (id) => selection = id,
                onClose: closed.add,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(_button);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-tab-a')));
    await tester.pumpAndSettle();
    expect(selection, 'b');
    await tester.tap(_button);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close this split group'));
    expect(closed, ['a', 'b']);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _mount(WidgetTester tester, TargetPlatform platform) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(platform: platform),
      home: Scaffold(
        body: Column(
          children: [
            WorkspaceTabBar(
              tabs: _tabs,
              selectedId: 'a',
              onSelect: (_) {},
              onClose: (_) {},
            ),
            const Expanded(child: SizedBox.expand()),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
