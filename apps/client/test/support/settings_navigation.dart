import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openSettingsCategory(
  WidgetTester tester,
  String id, {
  bool ifAvailable = false,
}) async {
  final item = find.byKey(ValueKey('settings_category_$id'));
  final navigation = find.byKey(const ValueKey('settings_category_navigation'));
  final iosList = find.byKey(
    const ValueKey('ios_settings_category_list'),
    skipOffstage: false,
  );
  if (navigation.evaluate().isNotEmpty) {
    final navScrollable = find.descendant(
      of: navigation,
      matching: find.byType(Scrollable),
    );
    if (item.evaluate().isEmpty) {
      await tester.drag(navigation, const Offset(0, 2000));
      await tester.pump();
      if (ifAvailable && item.evaluate().isEmpty) {
        final sections = tester
            .widget<SettingsScaffold>(find.byType(SettingsScaffold))
            .sections;
        if (!sections.any((section) => section.id == id)) return;
      }
      await tester.scrollUntilVisible(item, 150, scrollable: navScrollable);
    }
    await tester.ensureVisible(item);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(item);
  } else if (iosList.evaluate().isNotEmpty) {
    // iOS Phone 模式：二级页位于嵌套 Navigator 栈顶时先返回一级分类列表，再点击行 push。
    final targetPage = find.byKey(ValueKey('settings_page_$id'));
    if (targetPage.evaluate().isNotEmpty) return;
    final backButton = find.byKey(const ValueKey('ios_settings_back_button'));
    if (backButton.evaluate().isNotEmpty) {
      await tester.tap(backButton);
      await tester.pumpAndSettle();
    }
    final activeIosList = find.byKey(
      const ValueKey('ios_settings_category_list'),
    );
    if (ifAvailable) {
      final scaffoldFinder = find.byType(SettingsScaffold);
      if (scaffoldFinder.evaluate().isEmpty) return;
      final sections = tester.widget<SettingsScaffold>(scaffoldFinder).sections;
      if (!sections.any((section) => section.id == id)) return;
    }
    final navScrollable = find.descendant(
      of: activeIosList,
      matching: find.byType(Scrollable),
    );
    if (item.evaluate().isEmpty && navScrollable.evaluate().isNotEmpty) {
      await tester.drag(activeIosList, const Offset(0, 2000));
      await tester.pump();
      await tester.scrollUntilVisible(
        item,
        150,
        scrollable: navScrollable.first,
      );
    }
    await tester.ensureVisible(item);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(item);
  } else {
    final picker = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField<String> &&
          widget.key.toString().contains('settings_category_picker_'),
    );
    if (ifAvailable && picker.evaluate().isEmpty) return;
    final field = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: picker,
        matching: find.byType(DropdownButton<String>),
      ),
    );
    if (ifAvailable && !field.items!.any((item) => item.value == id)) return;
    final option = field.items!.singleWhere((item) => item.value == id);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text((option.child as Text).data!).last);
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}
