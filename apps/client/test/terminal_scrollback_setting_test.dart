import 'dart:async';
import 'dart:io';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/platform/window_chrome.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/storage/terminal_scrollback_store.dart';
import 'package:aterm_client/storage/terminal_scrollback_store_native.dart';
import 'package:aterm_client/terminal/terminal_scrollback.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/terminal_scrollback_setting.dart';
import 'package:aterm_client/ui/window_caption.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/settings_navigation.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  theme: buildAppTheme(),
  locale: locale,
  localizationsDelegates: AppLocalizationSetup.delegates,
  supportedLocales: AppLocalizationSetup.locales,
  builder: (context, page) => WindowsWindowChrome(
    controller: WindowChromeController(supported: false),
    child: page!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

/// The label the setting shows for [lines] in [locale].
String _label(String locale, int lines) {
  final l10n = appLocalizationsFor(Locale(locale));
  final count = NumberFormat.decimalPattern(locale).format(lines);
  return lines == terminalScrollbackDefault
      ? l10n.terminalScrollbackLinesDefault(count)
      : l10n.terminalScrollbackLines(count);
}

/// A store whose read never completes in time (or throws).
class _BrokenReadStore implements TerminalScrollbackStore {
  _BrokenReadStore({this.error});
  final Object? error;
  final List<String> written = [];

  @override
  Future<String?> read() {
    if (error case final error?) return Future<String?>.error(error);
    return Completer<String?>().future;
  }

  @override
  Future<void> write(String value) async => written.add(value);
}

/// A store whose writes complete only when the test releases them.
class _GatedWriteStore implements TerminalScrollbackStore {
  final List<String> started = [];
  final List<Completer<void>> gates = [];

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String value) {
    started.add(value);
    final gate = Completer<void>();
    gates.add(gate);
    return gate.future;
  }
}

class _SettingsController extends AppController {
  _SettingsController({
    required super.sodium,
    required super.database,
    required super.secureStore,
  });
  @override
  bool get isInstanceAdmin => true;
}

void main() {
  group('scrollback choices', () {
    test('offer six sizes with a 100,000 line default', () {
      expect(terminalScrollbackChoices, [
        10000,
        50000,
        100000,
        500000,
        1000000,
        5000000,
      ]);
      expect(terminalScrollbackDefault, 100000);
      expect(terminalScrollbackChoices, contains(terminalScrollbackDefault));
    });

    test('parse accepts exactly the offered sizes', () {
      for (final choice in terminalScrollbackChoices) {
        expect(parseTerminalScrollback('$choice'), choice);
        expect(parseTerminalScrollback('  $choice\n'), choice);
      }
    });

    test('parse falls back to the default for anything else', () {
      const rejected = <String?>[
        null,
        '',
        '   ',
        '\n',
        'garbage',
        'unlimited',
        'null',
        '-1',
        '-10000',
        '0',
        '1',
        '5000',
        '9999',
        '10001',
        '20000',
        '100001',
        '2000000',
        '4999999',
        '5000001',
        '10000000',
        '50000000',
        '9223372036854775807',
        '99999999999999999999999999999999',
        '+10000',
        '010000',
        '10000.0',
        '1e4',
        '0x2710',
        '10,000',
        '10 000',
        '10000 lines',
        '10000\n50000',
        '１００００',
        '{"lines":10000}',
      ];
      for (final value in rejected) {
        expect(
          parseTerminalScrollback(value),
          terminalScrollbackDefault,
          reason: 'stored value: $value',
        );
      }
    });

    test('parse rejects overly long values, even padded valid ones', () {
      expect(parseTerminalScrollback('1' * 5000), terminalScrollbackDefault);
      expect(parseTerminalScrollback('9' * 65), terminalScrollbackDefault);
      expect(
        parseTerminalScrollback('${' ' * 100}500000'),
        terminalScrollbackDefault,
      );
      expect(parseTerminalScrollback('${' ' * 20}500000'), 500000);
    });
  });

  group('scrollback stores', () {
    test('memory store round-trips and can fail writes', () async {
      final store = MemoryTerminalScrollbackStore();
      expect(await store.read(), isNull);
      await store.write('50000');
      expect(await store.read(), '50000');
      expect(store.writes, 1);
      store.failWith = const FileSystemException('read-only');
      await expectLater(
        store.write('10000'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await store.read(), '50000');
      expect(MemoryTerminalScrollbackStore('1000000').value, '1000000');
    });

    test('file store round-trips atomically', () async {
      final directory = await Directory.systemTemp.createTemp('scrollback-');
      addTearDown(() => directory.delete(recursive: true));
      final store = FileTerminalScrollbackStore(
        directory: () async => directory,
      );
      expect(await store.read(), isNull, reason: 'missing file');
      await store.write('500000');
      expect(await store.read(), '500000');
      await store.write('10000');
      expect(await store.read(), '10000');
      expect(directory.listSync().map((entry) => entry.uri.pathSegments.last), [
        'terminal-scrollback-v1',
      ], reason: 'no temporary files are left behind');

      final controller = TerminalScrollbackController();
      await controller.load(store);
      expect(controller.lines, 10000);
      await controller.select(1000000);
      final relaunched = TerminalScrollbackController();
      await relaunched.load(
        FileTerminalScrollbackStore(directory: () async => directory),
      );
      expect(relaunched.lines, 1000000, reason: 'persists across launches');
    });

    test('file store creates a missing directory on write', () async {
      final parent = await Directory.systemTemp.createTemp('scrollback-');
      addTearDown(() => parent.delete(recursive: true));
      final directory = Directory('${parent.path}/not/yet/created');
      final store = FileTerminalScrollbackStore(
        directory: () async => directory,
      );
      expect(await store.read(), isNull);
      await store.write('50000');
      expect(await store.read(), '50000');
    });

    test('corrupt, empty and oversized files load as the default', () async {
      final directory = await Directory.systemTemp.createTemp('scrollback-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/terminal-scrollback-v1');
      final store = FileTerminalScrollbackStore(
        directory: () async => directory,
      );
      Future<int> loaded() async {
        final controller = TerminalScrollbackController();
        await controller.load(store);
        return controller.lines;
      }

      await file.writeAsString('');
      expect(await store.read(), isNull);
      expect(await loaded(), terminalScrollbackDefault);

      await file.writeAsString('   \n');
      expect(await store.read(), isNull);
      expect(await loaded(), terminalScrollbackDefault);

      await file.writeAsString('not a number');
      expect(await loaded(), terminalScrollbackDefault);
      expect(
        await file.readAsString(),
        'not a number',
        reason: 'not rewritten',
      );

      await file.writeAsString('-500000');
      expect(await loaded(), terminalScrollbackDefault);

      await file.writeAsString('5' * 500);
      expect(await store.read(), isNull, reason: 'oversized content');
      expect(await loaded(), terminalScrollbackDefault);

      await file.writeAsBytes([0xff, 0xfe, 0x00, 0x80, 0xc3]);
      expect(await loaded(), terminalScrollbackDefault, reason: 'not UTF-8');

      await file.writeAsString(' 50000\n');
      expect(await loaded(), 50000, reason: 'surrounding whitespace is fine');
    });

    test('an unreadable location loads as the default', () async {
      final store = FileTerminalScrollbackStore(
        directory: () async => throw const FileSystemException('no directory'),
      );
      final controller = TerminalScrollbackController();
      await controller.load(store);
      expect(controller.lines, terminalScrollbackDefault);
      await controller.select(50000);
      expect(controller.lines, 50000);
      expect(controller.writeFailed, isTrue);
    });
  });

  group('scrollback controller', () {
    test('defaults to 100,000 lines before and after an empty load', () async {
      final controller = TerminalScrollbackController();
      expect(controller.lines, 100000);
      expect(controller.writeFailed, isFalse);
      final store = MemoryTerminalScrollbackStore();
      await controller.load(store);
      expect(controller.lines, 100000);
      expect(store.writes, 0, reason: 'loading never writes');
    });

    test('loads every stored choice', () async {
      for (final choice in terminalScrollbackChoices) {
        final controller = TerminalScrollbackController();
        var notified = 0;
        controller.addListener(() => notified++);
        await controller.load(MemoryTerminalScrollbackStore('$choice'));
        expect(controller.lines, choice);
        expect(notified, choice == terminalScrollbackDefault ? 0 : 1);
      }
    });

    test('unknown stored values fall back without being rewritten', () async {
      for (final stored in ['2000000', 'from-a-newer-version', '-1', '']) {
        final store = MemoryTerminalScrollbackStore(stored);
        final controller = TerminalScrollbackController();
        await controller.load(store);
        expect(controller.lines, terminalScrollbackDefault, reason: stored);
        expect(store.writes, 0, reason: 'unknown values are not overwritten');
        expect(store.value, stored);
      }
    });

    test('select applies at once, notifies and persists', () async {
      final store = MemoryTerminalScrollbackStore();
      final controller = TerminalScrollbackController();
      await controller.load(store);
      var notified = 0;
      controller.addListener(() => notified++);

      final saved = controller.select(500000);
      expect(controller.lines, 500000, reason: 'applies before the write');
      expect(notified, 1);
      await saved;
      expect(store.value, '500000');
      expect(controller.writeFailed, isFalse);

      final relaunched = TerminalScrollbackController();
      await relaunched.load(store);
      expect(relaunched.lines, 500000, reason: 'persists across launches');

      for (final choice in terminalScrollbackChoices) {
        await controller.select(choice);
        expect(controller.lines, choice);
        expect(store.value, '$choice');
      }
    });

    test('select rejects sizes that are not offered', () async {
      final store = MemoryTerminalScrollbackStore('50000');
      final controller = TerminalScrollbackController();
      await controller.load(store);
      for (final lines in [0, -1, 1, 9999, 20000, 100001, 5000001, 1 << 40]) {
        expect(() => controller.select(lines), throwsArgumentError);
      }
      expect(controller.lines, 50000);
      expect(store.writes, 0);
    });

    test('a failed write still applies and is reported', () async {
      final store = MemoryTerminalScrollbackStore()
        ..failWith = const FileSystemException('read-only');
      final controller = TerminalScrollbackController();
      await controller.load(store);
      var notified = 0;
      controller.addListener(() => notified++);

      await controller.select(1000000);
      expect(controller.lines, 1000000);
      expect(controller.writeFailed, isTrue);
      expect(store.value, isNull);
      expect(notified, 2, reason: 'the choice, then the failure');

      store.failWith = null;
      await controller.select(1000000);
      expect(controller.writeFailed, isFalse, reason: 'a retry clears it');
      expect(store.value, '1000000');
    });

    test('select before load applies without a store', () async {
      final controller = TerminalScrollbackController();
      await controller.select(10000);
      expect(controller.lines, 10000);
      expect(controller.writeFailed, isFalse);
    });

    test('load never throws and gives up on a stuck or failing read', () async {
      final failing = TerminalScrollbackController();
      await failing.load(_BrokenReadStore(error: StateError('broken')));
      expect(failing.lines, terminalScrollbackDefault);

      final stuckStore = _BrokenReadStore();
      final stuck = TerminalScrollbackController();
      final started = DateTime.now();
      await stuck.load(stuckStore);
      expect(DateTime.now().difference(started).inSeconds, lessThan(10));
      expect(stuck.lines, terminalScrollbackDefault);
      await stuck.select(50000);
      expect(stuckStore.written, ['50000'], reason: 'later choices persist');
    });

    test('a choice made while loading wins over the stored value', () async {
      final store = MemoryTerminalScrollbackStore('10000');
      final controller = TerminalScrollbackController();
      final loading = controller.load(store);
      final saving = controller.select(1000000);
      await Future.wait([loading, saving]);
      expect(controller.lines, 1000000);
      expect(store.value, '1000000');
    });

    test('writes are serialized and coalesced; the last choice wins', () async {
      final store = _GatedWriteStore();
      final controller = TerminalScrollbackController();
      await controller.load(store);

      final first = controller.select(10000);
      await pumpEventQueue();
      expect(store.started, ['10000']);
      final second = controller.select(50000);
      final third = controller.select(500000);
      await pumpEventQueue();
      expect(store.started, ['10000'], reason: 'one write at a time');

      store.gates[0].completeError(const FileSystemException('late failure'));
      await pumpEventQueue();
      expect(store.started, ['10000', '500000'], reason: '50000 is skipped');
      expect(
        controller.writeFailed,
        isFalse,
        reason: 'a superseded write cannot report its failure',
      );
      store.gates[1].complete();
      await Future.wait([first, second, third]);
      expect(controller.lines, 500000);
      expect(controller.writeFailed, isFalse);
    });

    test('the process-wide instance can be replaced for tests', () async {
      addTearDown(() => TerminalScrollbackController.debugInstance = null);
      final controller = TerminalScrollbackController();
      TerminalScrollbackController.debugInstance = controller;
      expect(TerminalScrollbackController.instance, same(controller));
      await controller.select(50000);
      expect(terminalScrollbackLines, 50000);
      TerminalScrollbackController.debugInstance = null;
      expect(TerminalScrollbackController.instance, isNot(same(controller)));
      expect(terminalScrollbackLines, terminalScrollbackDefault);
    });
  });

  group('terminals created after a change', () {
    tearDown(() => TerminalScrollbackController.debugInstance = null);

    test('cloud terminal tabs take the current scrollback', () async {
      final controller = TerminalScrollbackController();
      TerminalScrollbackController.debugInstance = controller;
      await controller.load(MemoryTerminalScrollbackStore());

      final byDefault = TerminalTabSession(id: 'default', host: null);
      expect(byDefault.terminal.maxLines, 100000);

      await controller.select(1000000);
      final longer = TerminalTabSession(id: 'longer', host: null);
      expect(longer.terminal.maxLines, 1000000);

      await controller.select(10000);
      final shorter = TerminalTabSession(id: 'shorter', host: null);
      expect(shorter.terminal.maxLines, 10000);

      expect(
        [byDefault.terminal.maxLines, longer.terminal.maxLines],
        [100000, 1000000],
        reason: 'terminals that already exist keep their limit',
      );
    });

    test(
      'a stored choice is used by the first terminal after startup',
      () async {
        final controller = TerminalScrollbackController();
        TerminalScrollbackController.debugInstance = controller;
        await controller.load(MemoryTerminalScrollbackStore('500000'));
        expect(
          TerminalTabSession(id: 'first', host: null).terminal.maxLines,
          500000,
        );
      },
    );
  });

  group('scrollback setting widget', () {
    for (final (locale, diskTier) in const [
      ('en', true),
      ('zh', true),
      ('ja', true),
      ('ru', true),
      ('en', false),
      ('zh', false),
      ('ja', false),
      ('ru', false),
    ]) {
      final variant = diskTier ? 'with a disk tier' : 'memory only';
      testWidgets('fits 390 px and selects every choice in $locale, $variant', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = MemoryTerminalScrollbackStore();
        final controller = TerminalScrollbackController();
        await controller.load(store);
        final l10n = appLocalizationsFor(Locale(locale));

        await tester.pumpWidget(
          _app(
            TerminalScrollbackSetting(
              controller: controller,
              diskTier: diskTier,
            ),
            locale: Locale(locale),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(l10n.terminalScrollbackTitle), findsOneWidget);
        expect(
          tester
              .widget<Text>(
                find.byKey(const ValueKey('terminal_scrollback_description')),
              )
              .data,
          diskTier
              ? l10n.terminalScrollbackDescription
              : l10n.terminalScrollbackDescriptionMemoryOnly,
        );
        expect(
          find.text(l10n.terminalScrollbackDescription),
          diskTier ? findsOneWidget : findsNothing,
        );
        expect(find.text(l10n.terminalScrollbackAppliesToNew), findsOneWidget);
        expect(
          find.byKey(const ValueKey('terminal_scrollback_applies_note')),
          findsOneWidget,
        );
        expect(
          find.text(_label(locale, terminalScrollbackDefault)),
          findsOneWidget,
          reason: 'the default is shown as the current choice',
        );
        expect(
          find.byKey(const ValueKey('terminal_scrollback_save_failed')),
          findsNothing,
        );

        final dropdown = find.byKey(
          const ValueKey('terminal_scrollback_dropdown'),
        );
        for (final lines in [
          ...terminalScrollbackChoices.reversed,
          terminalScrollbackDefault,
        ]) {
          await tester.tap(dropdown);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'open menu');
          for (final choice in terminalScrollbackChoices) {
            expect(
              find.text(_label(locale, choice)),
              findsWidgets,
              reason: 'menu offers $choice',
            );
          }
          await tester.tap(find.text(_label(locale, lines)).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'selected $lines');
          expect(controller.lines, lines);
          expect(store.value, '$lines');
          expect(find.text(_label(locale, lines)), findsOneWidget);
        }

        // Every visible text stays inside the 390 px wide window.
        for (final element in find.byType(Text).evaluate()) {
          final box = element.renderObject! as RenderBox;
          // Painted bounds (the field label is drawn scaled down).
          final bounds = MatrixUtils.transformRect(
            box.getTransformTo(null),
            Offset.zero & box.size,
          );
          final text = (element.widget as Text).data;
          expect(bounds.left, greaterThanOrEqualTo(0), reason: text);
          expect(bounds.right, lessThanOrEqualTo(390), reason: text);
        }
      });
    }

    testWidgets('formats line counts for the language', (tester) async {
      expect(_label('en', 10000), '10,000 lines');
      expect(_label('en', 100000), '100,000 lines (default)');
      expect(_label('en', 1000000), '1,000,000 lines');
      expect(_label('en', 5000000), '5,000,000 lines');
      expect(_label('zh', 5000000), '5,000,000 行');
      expect(_label('ja', 5000000), '5,000,000 行');
      expect(_label('ru', 5000000), '5\u00a0000\u00a0000 строк');
      expect(_label('zh', 500000), '500,000 行');
      expect(_label('zh', 100000), '100,000 行（默认）');
      expect(_label('ja', 50000), '50,000 行');
      expect(_label('ja', 100000), '100,000 行（既定）');
      // Russian groups digits with a no-break space.
      expect(_label('ru', 1000000), '1\u00a0000\u00a0000 строк');
      expect(_label('ru', 100000), '100\u00a0000 строк (по умолчанию)');
    });

    testWidgets('explains where history is kept and when it applies', (
      tester,
    ) async {
      // Native builds: compressed in memory, then an encrypted temporary file.
      await tester.pumpWidget(
        _app(
          TerminalScrollbackSetting(
            controller: TerminalScrollbackController(),
            diskTier: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Scrollback'), findsOneWidget);
      const memory = 'Older lines are kept compressed in memory';
      const disk =
          'older history is kept encrypted in a temporary file on this device '
          'and is removed when the tab closes';
      const applies = 'Applies to terminals opened afterwards';
      expect(find.textContaining(memory), findsOneWidget);
      expect(find.textContaining(disk), findsOneWidget);
      expect(find.textContaining('Nothing is synced'), findsOneWidget);
      expect(find.textContaining(applies), findsOneWidget);

      // Browser build: no temporary file, so that sentence is left out.
      await tester.pumpWidget(
        _app(
          TerminalScrollbackSetting(
            controller: TerminalScrollbackController(),
            diskTier: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining(memory), findsOneWidget);
      expect(find.textContaining('temporary file'), findsNothing);
      expect(find.textContaining('Nothing is synced'), findsOneWidget);
      expect(find.textContaining(applies), findsOneWidget);
    });

    test('every language states the same facts in both variants', () {
      for (final locale in const ['en', 'zh', 'ja', 'ru']) {
        final l10n = appLocalizationsFor(Locale(locale));
        final disk = l10n.terminalScrollbackDescription;
        final memoryOnly = l10n.terminalScrollbackDescriptionMemoryOnly;
        expect(disk.length, greaterThan(memoryOnly.length), reason: locale);
        // The memory-only text is the disk text minus the temporary-file
        // sentence: same opening (memory) and same ending (nothing synced).
        var prefix = 0;
        while (prefix < memoryOnly.length &&
            memoryOnly[prefix] == disk[prefix]) {
          prefix++;
        }
        expect(
          disk.endsWith(memoryOnly.substring(prefix)),
          isTrue,
          reason: locale,
        );
        expect(l10n.terminalScrollbackAppliesToNew, isNotEmpty);
        if (locale != 'en') {
          final english = appLocalizationsFor(const Locale('en'));
          expect(disk, isNot(english.terminalScrollbackDescription));
          expect(
            l10n.terminalScrollbackAppliesToNew,
            isNot(english.terminalScrollbackAppliesToNew),
          );
        }
      }
    });

    testWidgets('follows the controller and reports a failed save', (
      tester,
    ) async {
      final store = MemoryTerminalScrollbackStore('50000');
      final controller = TerminalScrollbackController();
      await tester.pumpWidget(
        _app(TerminalScrollbackSetting(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('100,000 lines (default)'), findsOneWidget);

      // The stored choice arriving after the first frame is shown.
      await controller.load(store);
      await tester.pumpAndSettle();
      expect(find.text('50,000 lines'), findsOneWidget);
      expect(find.text('100,000 lines (default)'), findsNothing);

      store.failWith = const FileSystemException('read-only');
      await tester.tap(
        find.byKey(const ValueKey('terminal_scrollback_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('1,000,000 lines').last);
      await tester.pumpAndSettle();
      expect(controller.lines, 1000000, reason: 'still applies');
      expect(find.text('1,000,000 lines'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('terminal_scrollback_save_failed')),
        findsOneWidget,
      );
      expect(
        find.text(
          appLocalizationsFor(const Locale('en'))
              .syncSettingsPreferenceSaveFailed,
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      store.failWith = null;
      await tester.tap(
        find.byKey(const ValueKey('terminal_scrollback_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('10,000 lines').last);
      await tester.pumpAndSettle();
      expect(store.value, '10000');
      expect(
        find.byKey(const ValueKey('terminal_scrollback_save_failed')),
        findsNothing,
      );
    });

    testWidgets('uses the process-wide controller by default', (tester) async {
      addTearDown(() => TerminalScrollbackController.debugInstance = null);
      final store = MemoryTerminalScrollbackStore();
      final controller = TerminalScrollbackController();
      TerminalScrollbackController.debugInstance = controller;
      await controller.load(store);
      await tester.pumpWidget(_app(const TerminalScrollbackSetting()));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('terminal_scrollback_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('500,000 lines').last);
      await tester.pumpAndSettle();
      expect(terminalScrollbackLines, 500000);
      expect(store.value, '500000');
      expect(
        TerminalTabSession(id: 'next', host: null).terminal.maxLines,
        500000,
      );
    });
  });

  group('cloud settings page', () {
    tearDown(() => TerminalScrollbackController.debugInstance = null);

    testWidgets('shows Scrollback next to the terminal color schemes', (
      tester,
    ) async {
      final store = MemoryTerminalScrollbackStore();
      final scrollback = TerminalScrollbackController();
      TerminalScrollbackController.debugInstance = scrollback;
      await scrollback.load(store);
      final sodium = await SodiumSumoInit.init();
      final database = ClientDatabase.forTesting(NativeDatabase.memory());
      final app =
          _SettingsController(
              sodium: sodium,
              database: database,
              secureStore: ClientSecureStore(),
            )
            ..stage = ClientStage.workspace
            ..page = WorkspacePage.settings
            ..activeVault = const VaultDescriptor(
              id: '11111111-1111-4111-8111-111111111111',
              role: 'owner',
              activeKeyEpoch: '1',
              membershipVersion: '1',
              canWrite: true,
            );
      try {
        await tester.binding.setSurfaceSize(const Size(1280, 900));
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            home: AppShell(controller: app),
          ),
        );
        await tester.pumpAndSettle();
        final setting = find.byKey(
          const ValueKey('terminal_scrollback_setting'),
        );
        final dropdown = find.byKey(
          const ValueKey('terminal_scrollback_dropdown'),
        );
        for (final width in [1280.0, 390.0]) {
          await tester.binding.setSurfaceSize(Size(width, 900));
          await tester.pumpAndSettle();
          await openSettingsCategory(tester, 'appearance');
          await tester.pumpAndSettle();
          expect(setting, findsOneWidget, reason: 'width $width');
          expect(
            find.byKey(const ValueKey('terminal_palette_gallery')),
            findsOneWidget,
            reason: 'same category as the terminal color schemes',
          );
          await tester.ensureVisible(dropdown);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'width $width');
          expect(
            find.descendant(
              of: setting,
              matching: find.textContaining('terminals opened afterwards'),
            ),
            findsOneWidget,
          );
        }

        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text('500,000 lines').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(scrollback.lines, 500000);
        expect(store.value, '500000');
        expect(
          TerminalTabSession(id: 'next', host: null).terminal.maxLines,
          500000,
          reason: 'the next cloud terminal uses the new scrollback',
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        app.dispose();
        await database.close();
        await tester.binding.setSurfaceSize(null);
      }
    });
  });
}
