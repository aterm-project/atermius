import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:aterm_client/ui/workspace_menu.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/workspace_menu_driver.dart';

void main() {
  final ran = <String>[];
  setUp(ran.clear);

  WorkspaceAction leaf(
    String id, {
    bool enabled = true,
    bool checked = false,
  }) => WorkspaceAction(
    id,
    'Label $id',
    Icons.circle_outlined,
    () => ran.add(id),
    enabled: enabled,
    checked: checked,
  );

  List<WorkspaceAction> tree() => [
    const WorkspaceAction.divider(),
    WorkspaceAction.submenu('menu_new', 'New', Icons.add, [
      leaf('new_ssh'),
      leaf('new_rdp'),
      const WorkspaceAction.divider(),
      leaf('new_group', enabled: false),
    ]),
    const WorkspaceAction.submenu('menu_empty', 'Empty', Icons.block, [
      WorkspaceAction.divider(),
    ]),
    WorkspaceAction.submenu('menu_single', 'Single', Icons.looks_one, [
      leaf('only_child'),
    ]),
    const WorkspaceAction.divider(),
    const WorkspaceAction.divider(),
    WorkspaceAction.submenu('menu_vaults', 'Vaults', Icons.lock, [
      leaf('vault_a', checked: true),
      leaf('vault_b'),
    ]),
    leaf('settings'),
    const WorkspaceAction.divider(),
  ];

  Future<void> pumpBar(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(platform: TargetPlatform.windows),
        home: Scaffold(
          body: Column(
            children: [
              WorkspaceTabBar(
                tabs: const [
                  WorkspaceTab(id: 'hosts', title: 'Home', isHome: true),
                ],
                selectedId: 'hosts',
                onSelect: (_) {},
                onClose: (_) {},
                homeMenuActions: tree(),
              ),
              const Expanded(child: TextField(key: ValueKey('editor'))),
            ],
          ),
        ),
      ),
    );
  }

  test('the menu drops empty submenus and stray dividers', () {
    final shown = normalizeWorkspaceMenu(tree());
    expect(shown.map((entry) => entry.isDivider ? '-' : entry.id), [
      'menu_new',
      'only_child',
      '-',
      'menu_vaults',
      'settings',
    ]);
    expect(workspaceMenuPathTo(tree(), 'new_ssh'), ['menu_new']);
    expect(workspaceMenuPathTo(tree(), 'only_child'), isEmpty);
    expect(workspaceMenuPathTo(tree(), 'missing'), isNull);
    expect(flattenWorkspaceActions(tree()).map((entry) => entry.id), [
      'new_ssh',
      'new_rdp',
      'new_group',
      'only_child',
      'vault_a',
      'vault_b',
      'settings',
    ]);
  });

  testWidgets('wide windows cascade submenus beside the menu', (tester) async {
    await pumpBar(tester, 1200);
    await tester.tap(find.byKey(workspaceMenuTrigger));
    await tester.pumpAndSettle();
    expect(find.text('New'), findsOneWidget);
    expect(find.text('Label only_child'), findsOneWidget);
    expect(find.text('Empty'), findsNothing);
    expect(find.text('Label new_ssh'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('menu_new')));
    await tester.pumpAndSettle();
    final parent = tester.getRect(find.byKey(const ValueKey('menu_new')));
    final child = tester.getRect(find.byKey(const ValueKey('new_ssh')));
    // Beside the parent row, not in place of it.
    expect(child.left, greaterThanOrEqualTo(parent.right - 8));
    expect(find.text('Settings'), findsNothing);
    expect(find.text('Label settings'), findsOneWidget);

    // A disabled entry stays visible and does nothing.
    await tester.tap(find.byKey(const ValueKey('new_group')));
    await tester.pumpAndSettle();
    expect(ran, isEmpty);

    await tester.tap(find.byKey(const ValueKey('new_ssh')));
    await tester.pumpAndSettle();
    expect(ran, ['new_ssh']);
    expect(find.text('New'), findsNothing, reason: 'the menu closed');
  });

  testWidgets('phone widths open a submenu in place with a back row', (
    tester,
  ) async {
    await pumpBar(tester, 390);
    await tester.tap(find.byKey(workspaceMenuTrigger));
    await tester.pumpAndSettle();
    final menuWidth = tester
        .getSize(find.byKey(const ValueKey('menu_new')))
        .width;

    await tester.tap(find.byKey(const ValueKey('menu_vaults')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace_menu_back')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu_new')), findsNothing);
    expect(find.byKey(const ValueKey('vault_a')), findsOneWidget);
    // The open Vault is ticked.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('vault_a')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('vault_b')),
        matching: find.byIcon(Icons.check_rounded),
      ),
      findsNothing,
    );
    // Same panel width at every level.
    expect(
      tester.getSize(find.byKey(const ValueKey('vault_a'))).width,
      menuWidth,
    );

    await tester.tap(find.byKey(const ValueKey('workspace_menu_back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu_new')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace_menu_back')), findsNothing);

    await tapWorkspaceMenuItem(tester, 'new_rdp');
    expect(ran, ['new_rdp']);
    expect(find.byKey(const ValueKey('menu_new')), findsNothing);

    // Reopening starts at the top again.
    await tester.tap(find.byKey(workspaceMenuTrigger));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu_new')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace_menu_back')), findsNothing);
  });

  testWidgets('system Back closes the menu, a level at a time on phones', (
    tester,
  ) async {
    await pumpBar(tester, 390);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    await tester.tap(find.byKey(workspaceMenuTrigger));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu_new')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace_menu_back')), findsOneWidget);

    // First Back leaves the submenu, the second closes the menu; neither
    // pops the page or leaves the app.
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('workspace_menu_back')), findsNothing);
    expect(find.byKey(const ValueKey('menu_new')), findsOneWidget);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('menu_new')), findsNothing);
    expect(find.byKey(workspaceMenuTrigger), findsOneWidget);
    expect(navigator.canPop(), isFalse);
  });

  testWidgets('closing the menu gives focus back to what had it', (
    tester,
  ) async {
    await pumpBar(tester, 1200);
    await tester.tap(find.byKey(const ValueKey('editor')));
    await tester.pump();
    final editor = tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode;
    expect(editor.hasFocus, isTrue);

    await tester.tap(find.byKey(workspaceMenuTrigger));
    await tester.pumpAndSettle();
    // Escape and the arrow keys reach the menu, not the editor.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      Focus.of(tester.element(find.text('New'))).hasFocus,
      isTrue,
      reason: 'Down steps into the first entry',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      Focus.of(tester.element(find.text('Label only_child'))).hasFocus,
      isTrue,
    );
    expect(editor.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('New'), findsNothing);
    expect(editor.hasFocus, isTrue);

    // Enter on the focused trigger opens the menu on its first entry.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    Focus.of(tester.element(find.byIcon(Icons.menu_rounded))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('New'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('New'), findsNothing);
  });

  testWidgets('a mouse click takes the editor focus; Escape gives it back', (
    tester,
  ) async {
    await pumpBar(tester, 1200);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    Future<void> click(Finder target) async {
      final at = tester.getCenter(target);
      await mouse.moveTo(at);
      await mouse.down(at);
      await mouse.up();
      await tester.pumpAndSettle();
    }

    await click(find.byKey(const ValueKey('editor')));
    final editor = tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode;
    expect(editor.hasFocus, isTrue);

    // The click on the trigger unfocuses the text field (tap outside)
    // before the menu opens; hovering a submenu moves focus into the menu.
    await click(find.byKey(workspaceMenuTrigger));
    await mouse.moveTo(tester.getCenter(find.text('New')));
    await tester.pumpAndSettle();
    expect(find.text('Label new_ssh'), findsOneWidget);
    expect(editor.hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('New'), findsNothing);
    expect(editor.hasFocus, isTrue);

    // Same after choosing an entry with the mouse.
    await click(find.byKey(workspaceMenuTrigger));
    await click(find.text('Label settings'));
    expect(ran, ['settings']);
    expect(editor.hasFocus, isTrue);
  });

  testWidgets('the trigger keeps its tooltip and button semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpBar(tester, 1200);
    expect(
      tester.getSemantics(find.byKey(workspaceMenuTrigger)),
      matchesSemantics(
        isButton: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
        hasExpandedState: true,
        tooltip: 'Host menu · click to open',
      ),
    );
    // Entries are announced as menu items of a menu, at every level.
    await tester.tap(find.byKey(workspaceMenuTrigger));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.text('Label settings')).getSemanticsData().role,
      SemanticsRole.menuItem,
    );
    expect(
      tester.getSemantics(find.text('New')).getSemanticsData().role,
      SemanticsRole.menuItem,
    );
    await tester.tap(find.byKey(const ValueKey('menu_new')));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.text('Label new_ssh')).getSemanticsData().role,
      SemanticsRole.menuItem,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
