import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/web/page_address.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

class _FakeBar extends PageAddressBar {
  _FakeBar(String start) : entries = [start];
  final List<String> entries;
  int index = 0;

  @override
  String get path => entries[index];

  @override
  void replace(String path) => entries[index] = path;

  @override
  void push(String path) {
    entries.removeRange(index + 1, entries.length);
    entries.add(path);
    index++;
  }

  void back() {
    index--;
    onNavigate?.call();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every page has its own path, clear of the server\'s names', () {
    final paths = WorkspacePage.values.map(pagePath).toSet();
    expect(paths, hasLength(WorkspacePage.values.length));
    for (final page in WorkspacePage.values) {
      final path = pagePath(page);
      expect(pageForPath(path), page);
      expect(pageForPath('$path/'), page);
      expect(reservedAddressNames, isNot(contains(path.substring(1))));
    }
    expect(pageForPath('/'), isNull);
    expect(pageForPath('/join'), isNull);
    expect(pageForPath('/s/demo-room'), isNull);
    expect(pageForPath('/settings/extra'), isNull);
  });

  Future<AppController> workspace() async {
    final sodium = await SodiumSumoInit.init();
    final app = AppController(
      sodium: sodium,
      database: ClientDatabase.forTesting(NativeDatabase.memory()),
      secureStore: ClientSecureStore(),
    )..stage = ClientStage.workspace;
    addTearDown(app.dispose);
    return app;
  }

  test('a link opens its page once; later pages add history', () async {
    final app = await workspace();
    final bar = _FakeBar('/settings');
    final binding = PageAddressBinding(app, bar)..attach();
    expect(app.page, WorkspacePage.settings);
    expect(bar.entries, ['/settings']);

    app.showWorkspacePage(WorkspacePage.snippets);
    expect(bar.entries, ['/settings', '/snippets']);

    bar.back();
    expect(app.page, WorkspacePage.settings);
    expect(bar.entries, ['/settings', '/snippets']);

    // Signing in again later starts on its own page, not the old link.
    binding.detach();
    app.page = WorkspacePage.hosts;
    PageAddressBinding(app, bar).attach();
    expect(app.page, WorkspacePage.hosts);
    expect(bar.path, '/hosts');
  });

  test('the bare address is rewritten, not stacked', () async {
    final app = await workspace();
    final bar = _FakeBar('/');
    PageAddressBinding(app, bar).attach();
    expect(bar.entries, ['/hosts']);
  });

  test('nothing moves before the workspace is open', () async {
    final app = await workspace()..stage = ClientStage.login;
    final bar = _FakeBar('/audit');
    PageAddressBinding(app, bar).attach();
    expect(bar.entries, ['/audit']);
    expect(bar.linkPending, isTrue);
    expect(app.page, WorkspacePage.hosts);
  });
}
