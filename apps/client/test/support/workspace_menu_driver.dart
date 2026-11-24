import 'package:aterm_client/ui/workspace_controls.dart';
import 'package:aterm_client/ui/workspace_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const workspaceMenuTrigger = ValueKey('workspace_host_menu');

/// Opens the workspace (☰) menu when it is closed, then the submenus that
/// lead to the entry [id], so that entry is on screen. Works for both the
/// cascading (wide) and the drill-down (narrow) menu.
Future<void> revealWorkspaceMenuItem(WidgetTester tester, String id) async {
  final item = find.byKey(ValueKey(id));
  if (item.hitTestable().evaluate().isNotEmpty) return;
  final menu = tester.widget<WorkspaceMenu>(
    find.ancestor(
      of: find.byKey(workspaceMenuTrigger),
      matching: find.byType(WorkspaceMenu),
    ),
  );
  final path = workspaceMenuPathTo(menu.actions, id);
  if (path == null) {
    throw TestFailure('the workspace menu has no entry "$id"');
  }
  const back = ValueKey('workspace_menu_back');
  final topLevel = normalizeWorkspaceMenu(menu.actions)
      .where((entry) => !entry.isDivider)
      .map((entry) => ValueKey(entry.id));
  bool open() =>
      find.byKey(back).evaluate().isNotEmpty ||
      topLevel.any((key) => find.byKey(key).evaluate().isNotEmpty);
  if (!open()) {
    await tester.tap(find.byKey(workspaceMenuTrigger));
    await tester.pumpAndSettle();
  }
  // A drill-down menu may still show a submenu from an earlier step.
  while (find.byKey(back).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(back));
    await tester.pumpAndSettle();
  }
  for (final submenu in path) {
    await tester.tap(find.byKey(ValueKey(submenu)));
    await tester.pumpAndSettle();
  }
}

/// Reveals the entry [id] (see [revealWorkspaceMenuItem]) and activates it.
Future<void> tapWorkspaceMenuItem(
  WidgetTester tester,
  String id, {
  bool settle = true,
}) async {
  await revealWorkspaceMenuItem(tester, id);
  await tester.ensureVisible(find.byKey(ValueKey(id)));
  await tester.tap(find.byKey(ValueKey(id)));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// Ids of the submenus, outermost first, that hold the entry [id] as the
/// menu shows it; empty when it is on the top level, null when absent.
List<String>? workspaceMenuPathTo(List<WorkspaceAction> actions, String id) {
  for (final action in normalizeWorkspaceMenu(actions)) {
    if (action.isDivider) continue;
    if (action.id == id) return const [];
    if (action.isSubmenu) {
      final inner = workspaceMenuPathTo(action.children, id);
      if (inner != null) return [action.id, ...inner];
    }
  }
  return null;
}
