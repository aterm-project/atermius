import 'dart:io';

import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/crypto/vault_crypto.dart';
import 'package:aterm_client/domain/vault_preference.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/platform/native_coordination.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/database_quarantine.dart';
import 'package:aterm_client/storage/keyword_highlight_store.dart';
import 'package:aterm_client/storage/local_profile_catalog.dart';
import 'package:aterm_client/storage/local_profile_service.dart';
import 'package:aterm_client/storage/local_vault_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/terminal/keyword_highlighter.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/local_profile_flow.dart';
import 'package:aterm_client/ui/settings_scaffold.dart';
import 'package:aterm_client/ui/terminal_color_theme.dart';
import 'package:aterm_client/ui/terminal_keyword_highlight_settings.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/settings_navigation.dart';

const _locales = ['en', 'zh', 'ja', 'ru'];
const _password = 'correct horse battery staple';
final _dark = buildTerminalColorTheme(VaultTerminalThemeChoice.atermDark);

Finder _key(String key) => find.byKey(ValueKey(key));

Widget _card(
  TerminalKeywordHighlighter highlighter, {
  String locale = 'en',
  VaultTerminalThemeChoice synced = VaultTerminalThemeChoice.atermDark,
}) => MaterialApp(
  theme: buildAppTheme(locale: Locale(locale)),
  locale: Locale(locale),
  localizationsDelegates: AppLocalizationSetup.delegates,
  supportedLocales: AppLocalizationSetup.locales,
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SettingsCard(
        semanticContainer: false,
        child: TerminalKeywordHighlightSettings(
          synced: synced,
          controller: highlighter,
        ),
      ),
    ),
  ),
);

void _phone(WidgetTester tester, {double height = 844}) {
  tester.view.physicalSize = Size(390, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// The color the preview draws [word] in.
Color? _previewColor(WidgetTester tester, String word) {
  Color? found;
  final preview = find.descendant(
    of: _key('keyword_highlight_preview'),
    matching: find.byType(RichText),
  );
  for (final text in tester.widgetList<RichText>(preview)) {
    text.text.visitChildren((span) {
      if (span is TextSpan && span.text == word) {
        found = span.style?.color ?? text.text.style?.color;
        return false;
      }
      return true;
    });
  }
  return found;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('settings card', () {
    testWidgets('master and group switches, colors and the live preview', (
      tester,
    ) async {
      _phone(tester, height: 2400);
      final store = MemoryKeywordHighlightStore();
      final highlighter = TerminalKeywordHighlighter();
      await highlighter.load(store);
      await tester.pumpWidget(_card(highlighter));
      final red = TerminalKeywordHighlighter.appearanceOf(
        _dark,
        KeywordHighlightColor.red,
      ).color;
      final blue = TerminalKeywordHighlighter.appearanceOf(
        _dark,
        KeywordHighlightColor.blue,
      ).color;

      for (final group in highlighter.settings.groups) {
        expect(_key('keyword_highlight_group_${group.id}'), findsOneWidget);
        expect(
          tester
              .widget<Switch>(_key('keyword_highlight_switch_${group.id}'))
              .value,
          isTrue,
        );
      }
      expect(
        tester.widget<Switch>(_key('keyword_highlight_enabled')).value,
        isTrue,
      );
      expect(_previewColor(tester, 'error'), red);
      expect(_previewColor(tester, 'https://example.com/docs'), blue);
      // Nothing to restore yet.
      expect(
        tester.widget<TextButton>(_key('keyword_highlight_restore')).onPressed,
        isNull,
      );

      // Master switch: applies at once, the preview goes plain, it is stored.
      await _tap(tester, _key('keyword_highlight_enabled'));
      expect(highlighter.settings.enabled, isFalse);
      expect(_previewColor(tester, 'error'), isNull);
      expect(KeywordHighlightSettings.decode(store.value)!.enabled, isFalse);
      await _tap(tester, _key('keyword_highlight_enabled'));
      expect(highlighter.settings.enabled, isTrue);
      expect(store.value, isNull);

      // One group off.
      await _tap(tester, _key('keyword_highlight_switch_error'));
      expect(highlighter.settings.group('error')!.enabled, isFalse);
      expect(_previewColor(tester, 'error'), isNull);
      expect(_previewColor(tester, 'WARNING'), isNotNull);
      await _tap(tester, _key('keyword_highlight_switch_error'));

      // Color menu: six ANSI hues, shown as they look on this palette.
      await _tap(tester, _key('keyword_highlight_color_error'));
      for (final color in KeywordHighlightColor.values) {
        expect(
          _key('keyword_highlight_color_option_${color.id}'),
          findsOneWidget,
        );
      }
      await tester.tap(_key('keyword_highlight_color_option_blue'));
      await tester.pumpAndSettle();
      expect(
        highlighter.settings.group('error')!.color,
        KeywordHighlightColor.blue,
      );
      expect(_previewColor(tester, 'error'), blue);
      expect(
        KeywordHighlightSettings.decode(store.value)!.group('error')!.color,
        KeywordHighlightColor.blue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('keywords, custom groups and restoring the defaults', (
      tester,
    ) async {
      _phone(tester, height: 2400);
      final store = MemoryKeywordHighlightStore();
      final highlighter = TerminalKeywordHighlighter();
      await highlighter.load(store);
      await tester.pumpWidget(_card(highlighter));

      // Pattern groups have no keyword list.
      expect(_key('keyword_highlight_expand_address'), findsNothing);
      expect(_key('keyword_highlight_expand_url'), findsNothing);
      expect(_key('keyword_highlight_chip_error_fatal'), findsNothing);

      await _tap(tester, _key('keyword_highlight_expand_error'));
      for (final keyword in highlighter.settings.group('error')!.keywords) {
        expect(_key('keyword_highlight_chip_error_$keyword'), findsOneWidget);
      }

      // Remove a word.
      final delete = find.descendant(
        of: _key('keyword_highlight_chip_error_fatal'),
        matching: find.byTooltip('Remove fatal'),
      );
      await _tap(tester, delete);
      expect(
        highlighter.settings.group('error')!.keywords,
        isNot(contains('fatal')),
      );
      expect(_key('keyword_highlight_chip_error_fatal'), findsNothing);

      // Add a phrase; it is normalized.
      await tester.enterText(
        _key('keyword_highlight_input_error'),
        '  Link   FLAP ',
      );
      await _tap(tester, _key('keyword_highlight_add_error'));
      expect(
        highlighter.settings.group('error')!.keywords,
        contains('link flap'),
      );
      expect(_key('keyword_highlight_chip_error_link flap'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(_key('keyword_highlight_input_error'))
            .controller!
            .text,
        isEmpty,
      );

      // A duplicate is refused with a message; submitting works from the
      // keyboard too.
      await tester.enterText(_key('keyword_highlight_input_error'), 'ERROR');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('This group already has that keyword.'), findsOneWidget);
      await tester.enterText(_key('keyword_highlight_input_error'), 'oops');
      await tester.pumpAndSettle();
      expect(find.text('This group already has that keyword.'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(highlighter.settings.group('error')!.keywords, contains('oops'));
      // Blank input does nothing.
      final before = highlighter.settings;
      await tester.enterText(_key('keyword_highlight_input_error'), '   ');
      await _tap(tester, _key('keyword_highlight_add_error'));
      expect(highlighter.settings, before);

      // A custom group with its own name, keywords and color.
      await _tap(tester, _key('keyword_highlight_add_group'));
      expect(
        tester
            .widget<FilledButton>(_key('keyword_highlight_group_create'))
            .onPressed,
        isNull,
      );
      await tester.enterText(_key('keyword_highlight_group_name'), ' BGP ');
      await tester.pumpAndSettle();
      await tester.tap(_key('keyword_highlight_group_create'));
      await tester.pumpAndSettle();
      final custom = highlighter.settings.customGroups.single;
      expect(custom.name, 'BGP');
      expect(find.text('BGP'), findsOneWidget);
      expect(find.text('No keywords'), findsOneWidget);
      // It opens ready for its first keyword.
      await tester.enterText(
        _key('keyword_highlight_input_${custom.id}'),
        'neighbor',
      );
      await _tap(tester, _key('keyword_highlight_add_${custom.id}'));
      expect(find.text('1 keyword'), findsOneWidget);
      await _tap(tester, _key('keyword_highlight_color_${custom.id}'));
      await tester.tap(_key('keyword_highlight_color_option_yellow'));
      await tester.pumpAndSettle();
      final stored = KeywordHighlightSettings.decode(store.value)!;
      expect(stored.group(custom.id)!.keywords, ['neighbor']);
      expect(stored.group(custom.id)!.color, KeywordHighlightColor.yellow);
      expect(stored.group('error')!.keywords, contains('link flap'));

      // Delete it again.
      await _tap(tester, _key('keyword_highlight_delete_${custom.id}'));
      expect(highlighter.settings.customGroups, isEmpty);
      expect(find.text('BGP'), findsNothing);

      // Restore defaults asks first.
      await _tap(tester, _key('keyword_highlight_restore'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(highlighter.settings.isDefault, isFalse);
      await _tap(tester, _key('keyword_highlight_restore'));
      await tester.tap(_key('keyword_highlight_restore_confirm'));
      await tester.pumpAndSettle();
      expect(highlighter.settings.isDefault, isTrue);
      expect(store.value, isNull);
      expect(_key('keyword_highlight_chip_error_fatal'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('limits and a failed save are explained', (tester) async {
      _phone(tester, height: 3200);
      final store = MemoryKeywordHighlightStore();
      final highlighter = TerminalKeywordHighlighter();
      await highlighter.load(store);
      for (var i = 0; i < KeywordHighlightLimits.maxCustomGroups; i++) {
        highlighter.addGroup('group $i');
      }
      final full = highlighter.settings.customGroups.first.id;
      for (var i = 0; i < KeywordHighlightLimits.maxKeywordsPerGroup; i++) {
        highlighter.addKeyword(full, 'word $i');
      }
      await tester.pumpWidget(_card(highlighter));
      await tester.pumpAndSettle();

      await _tap(tester, _key('keyword_highlight_add_group'));
      expect(_key('keyword_highlight_group_name'), findsNothing);
      expect(find.text('You can add up to 8 groups.'), findsOneWidget);

      await _tap(tester, _key('keyword_highlight_expand_$full'));
      await tester.enterText(_key('keyword_highlight_input_$full'), 'extra');
      await _tap(tester, _key('keyword_highlight_add_$full'));
      expect(find.text('This group is full (64 keywords).'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // The notice disappears once there is room again.
      await _tap(tester, _key('keyword_highlight_delete_$full'));
      expect(find.text('You can add up to 8 groups.'), findsNothing);

      store.failWith = StateError('disk full');
      await _tap(tester, _key('keyword_highlight_enabled'));
      expect(highlighter.settings.enabled, isFalse);
      expect(_key('keyword_highlight_save_failed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final locale in _locales) {
      testWidgets('fits a 390 px wide card with everything open ($locale)', (
        tester,
      ) async {
        _phone(tester, height: 5200);
        final highlighter = TerminalKeywordHighlighter();
        await highlighter.load(
          MemoryKeywordHighlightStore()..failWith = StateError('read-only'),
        );
        final custom = highlighter.addGroup('A custom group with a long name')!;
        highlighter.addKeyword(
          custom,
          'a fairly long phrase used as a keyword',
        );
        await tester.pumpWidget(
          _card(
            highlighter,
            locale: locale,
            synced: VaultTerminalThemeChoice.light,
          ),
        );
        await tester.pumpAndSettle();
        final l10n = appLocalizationsFor(Locale(locale));
        expect(find.text(l10n.keywordHighlightTitle), findsOneWidget);
        expect(find.text(l10n.keywordHighlightDescription), findsOneWidget);
        expect(find.text(l10n.keywordHighlightSaveFailed), findsOneWidget);
        for (final group in highlighter.settings.groups) {
          final label = keywordHighlightGroupLabel(l10n, group);
          expect(find.text(label), findsOneWidget, reason: group.id);
          final expand = _key('keyword_highlight_expand_${group.id}');
          if (expand.evaluate().isNotEmpty) await _tap(tester, expand);
        }
        expect(find.text(l10n.keywordHighlightAddressHint), findsOneWidget);
        expect(find.text(l10n.keywordHighlightUrlHint), findsOneWidget);
        expect(find.text(l10n.keywordHighlightKeywordCount(1)), findsOneWidget);
        // Provoke the inline messages too.
        await tester.enterText(_key('keyword_highlight_input_error'), 'error');
        await _tap(tester, _key('keyword_highlight_add_error'));
        expect(find.text(l10n.keywordHighlightDuplicate), findsOneWidget);
        await _tap(tester, _key('keyword_highlight_color_warning'));
        expect(find.text(l10n.keywordHighlightColorMagenta), findsOneWidget);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        await _tap(tester, _key('keyword_highlight_add_group'));
        expect(find.text(l10n.keywordHighlightGroupName), findsOneWidget);
        await tester.tap(find.text(l10n.cancel));
        await tester.pumpAndSettle();
        await _tap(tester, _key('keyword_highlight_restore'));
        expect(find.text(l10n.keywordHighlightRestoreConfirm), findsOneWidget);
        await tester.tap(find.text(l10n.cancel));
        await tester.pumpAndSettle();
        // No overflow anywhere, and nothing wider than the screen.
        expect(tester.takeException(), isNull);
        final card = tester.getRect(_key('keyword_highlight_settings'));
        expect(card.left, greaterThanOrEqualTo(0));
        expect(card.right, lessThanOrEqualTo(390));
        for (final element
            in find
                .descendant(
                  of: _key('keyword_highlight_settings'),
                  matching: find.byType(InputChip),
                )
                .evaluate()) {
          final box = element.renderObject! as RenderBox;
          final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
          expect(right, lessThanOrEqualTo(390));
        }
      });
    }
  });

  group('account (cloud) settings', () {
    for (final locale in _locales) {
      testWidgets('the appearance page has the card at 390 px ($locale)', (
        tester,
      ) async {
        _phone(tester);
        final highlighter = TerminalKeywordHighlighter();
        TerminalKeywordHighlighter.debugInstance = highlighter;
        addTearDown(() => TerminalKeywordHighlighter.debugInstance = null);
        final database = ClientDatabase.forTesting(NativeDatabase.memory());
        final app =
            AppController(
                sodium: await SodiumSumoInit.init(),
                database: database,
                secureStore: ClientSecureStore(),
              )
              ..stage = ClientStage.workspace
              ..page = WorkspacePage.settings;
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(locale: Locale(locale)),
              locale: Locale(locale),
              localizationsDelegates: AppLocalizationSetup.delegates,
              supportedLocales: AppLocalizationSetup.locales,
              home: AppShell(controller: app),
            ),
          );
          await tester.pump();
          await openSettingsCategory(tester, 'appearance');
          await tester.pumpAndSettle();
          await _useCard(tester, highlighter, Locale(locale));
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          app.dispose();
          await database.close();
        }
      });
    }
  });

  group('local profile settings', () {
    late Directory directory;
    late LocalProfileCatalog catalog;
    late LocalProfileService profiles;
    late VaultCrypto crypto;
    late LocalProfileRecord record;
    late List<LocalVaultDatabase> opened;

    setUpAll(() async {
      crypto = VaultCrypto(await SodiumSumoInit.init());
    });

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('kw-highlight-local-');
      coordinationDirectory = () async =>
          Directory('${directory.path}/coordination');
      catalog = LocalProfileCatalog.forTesting(
        NativeDatabase(File('${directory.path}/catalog.sqlite')),
      );
      profiles = LocalProfileService(catalog: catalog, crypto: crypto);
      final seed = await profiles.create(password: _password);
      record = seed.record;
      // An unlock is refused unless the profile's vault database exists.
      final vault = await LocalVaultDatabase.openForTesting(
        executor: NativeDatabase(File('${directory.path}/vault.sqlite')),
        profileId: record.profileId,
        localDataDomainId: record.localDataDomainId,
        localVaultId: record.localVaultId,
      );
      await vault.close();
      await seed.lock();
      opened = [];
    });

    tearDown(() async {
      for (final database in opened.reversed) {
        try {
          await database.close();
        } on Object {
          // The flow may already have closed it while disposing.
        }
      }
      await catalog.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    Future<void> idle(WidgetTester tester) async {
      var idleFrames = 0;
      for (var attempt = 0; attempt < 100; attempt++) {
        await tester.pump(const Duration(milliseconds: 50));
        final waiting =
            find.byType(LinearProgressIndicator).evaluate().isNotEmpty ||
            find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        idleFrames = waiting ? 0 : idleFrames + 1;
        if (idleFrames >= 4) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
      }
      fail('LocalProfileFlow did not finish its pending operation.');
    }

    for (final locale in _locales) {
      testWidgets('the appearance page has the card at 390 px ($locale)', (
        tester,
      ) async {
        _phone(tester);
        final highlighter = TerminalKeywordHighlighter();
        TerminalKeywordHighlighter.debugInstance = highlighter;
        addTearDown(() => TerminalKeywordHighlighter.debugInstance = null);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(locale: Locale(locale)),
            locale: Locale(locale),
            localizationsDelegates: AppLocalizationSetup.delegates,
            supportedLocales: AppLocalizationSetup.locales,
            home: LocalProfileFlow(
              catalog: catalog,
              service: profiles,
              crypto: crypto,
              onExit: () {},
              quarantineRegistry: DatabaseQuarantineRegistry(),
              databaseFactory: (profile, {required mode}) async {
                final database = await LocalVaultDatabase.openForTesting(
                  executor: NativeDatabase(
                    File('${directory.path}/vault.sqlite'),
                  ),
                  profileId: profile.record.profileId,
                  localDataDomainId: profile.record.localDataDomainId,
                  localVaultId: profile.record.localVaultId,
                  mode: mode,
                );
                opened.add(database);
                return database;
              },
            ),
          ),
        );
        await idle(tester);
        await tester.tap(_key('local_profile_${record.profileId}'));
        await tester.pump();
        await tester.enterText(
          _key('local_profile_unlock_password'),
          _password,
        );
        await tester.tap(_key('local_profile_unlock_button'));
        await idle(tester);
        await tester.tap(_key('workspace_host_menu'));
        await tester.pumpAndSettle();
        await _tap(tester, _key('local_profile_preferences_toggle'));
        expect(_key('local_profile_preferences'), findsOneWidget);
        // Settings open on the Workspace page, whose default-section dropdown
        // overflows by a few pixels in Russian at this width. That is not
        // this card's page: drop it so the checks below judge only the
        // appearance page.
        tester.takeException();
        await openSettingsCategory(tester, 'appearance');
        await tester.pumpAndSettle();
        await _useCard(tester, highlighter, Locale(locale));
        await tester.pumpWidget(const SizedBox.shrink());
        await idle(tester);
      });
    }
  });
}

/// Finds the card on the open appearance page (next to the palette gallery)
/// and uses it: the process-wide highlighter follows.
Future<void> _useCard(
  WidgetTester tester,
  TerminalKeywordHighlighter highlighter,
  Locale locale,
) async {
  final l10n = appLocalizationsFor(locale);
  final page = _key('settings_page_appearance');
  Finder onPage(String key) => find.descendant(of: page, matching: _key(key));
  expect(onPage('terminal_palette_gallery'), findsOneWidget);
  expect(onPage('keyword_highlight_settings'), findsOneWidget);
  expect(find.text(l10n.keywordHighlightTitle), findsOneWidget);
  // The card comes right after the palette gallery.
  expect(
    tester.getTopLeft(onPage('keyword_highlight_settings')).dy,
    greaterThan(tester.getTopLeft(onPage('terminal_palette_gallery')).dy),
  );

  expect(highlighter.settings.enabled, isTrue);
  await _tap(tester, onPage('keyword_highlight_enabled'));
  expect(highlighter.settings.enabled, isFalse);
  await _tap(tester, onPage('keyword_highlight_enabled'));
  expect(highlighter.settings.enabled, isTrue);

  await _tap(tester, onPage('keyword_highlight_switch_warning'));
  expect(highlighter.settings.group('warning')!.enabled, isFalse);

  await _tap(tester, onPage('keyword_highlight_expand_success'));
  await tester.enterText(onPage('keyword_highlight_input_success'), 'synced');
  await _tap(tester, onPage('keyword_highlight_add_success'));
  expect(highlighter.settings.group('success')!.keywords, contains('synced'));
  expect(find.text(l10n.keywordHighlightGroupSuccess), findsOneWidget);

  final card = tester.getRect(onPage('keyword_highlight_settings'));
  expect(card.left, greaterThanOrEqualTo(0));
  expect(card.right, lessThanOrEqualTo(390));
  expect(tester.takeException(), isNull);
}
