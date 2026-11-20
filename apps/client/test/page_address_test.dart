import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/web/page_address.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
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

  test('the admin console has addresses of its own below /admin', () {
    expect(pagePath(WorkspacePage.admin), '/admin');
    expect(pagePath(WorkspacePage.admin, section: 'users'), '/admin/users');
    // Only the console has sections.
    expect(pagePath(WorkspacePage.settings, section: 'users'), '/settings');

    PageLocation at(String path) => locationForPath(path)!;
    expect(at('/admin').page, WorkspacePage.admin);
    expect(at('/admin').section, isNull);
    expect(at('/admin/').section, isNull);
    expect(at('/admin/users').page, WorkspacePage.admin);
    expect(at('/admin/users').section, 'users');
    expect(at('/admin/workspace-agents/').section, 'workspace-agents');
    expect(pageForPath('/admin/audit'), WorkspacePage.admin);
    for (final path in [
      '/admin/users/extra',
      '/admin/Users',
      '/admin/-users',
      '/admin//users',
      '/admin/../hosts',
      '/hosts/users',
    ]) {
      expect(locationForPath(path), isNull, reason: path);
    }
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

  test('/terminal with no session open lands on the hosts', () async {
    final app = await workspace();
    final bar = _FakeBar('/terminal');
    PageAddressBinding(app, bar).attach();
    expect(app.page, WorkspacePage.hosts);
    // Rewritten in place: Back must not return to the empty terminal page.
    expect(bar.entries, ['/hosts']);

    // The app's own navigation still opens the page (a connect, the menu).
    app.showWorkspacePage(WorkspacePage.terminal);
    expect(app.page, WorkspacePage.terminal);
    expect(bar.entries, ['/hosts', '/terminal']);

    // Back to it with still nothing open: the hosts again.
    app.showWorkspacePage(WorkspacePage.snippets);
    bar.back();
    expect(app.page, WorkspacePage.hosts);
    expect(bar.entries, ['/hosts', '/hosts', '/snippets']);
  });

  test('/terminal stays when something is open there', () async {
    final app = await workspace();
    final bar = _FakeBar('/terminal');
    PageAddressBinding(app, bar, hasFileTabs: () => true).attach();
    expect(app.page, WorkspacePage.terminal);
    expect(bar.entries, ['/terminal']);
  });

  test('the bare address is rewritten, not stacked', () async {
    final app = await workspace();
    final bar = _FakeBar('/');
    PageAddressBinding(app, bar).attach();
    expect(bar.entries, ['/hosts']);
  });

  test('a link to a page this account may not open is dropped', () async {
    // The Admin page is for instance administrators only.
    final app = await workspace();
    expect(app.canShowWorkspacePage(WorkspacePage.admin), isFalse);
    final bar = _FakeBar('/admin');
    PageAddressBinding(app, bar).attach();
    expect(app.page, WorkspacePage.hosts);
    // Rewritten in place: Back must not lead to an address that shows
    // another page.
    expect(bar.entries, ['/hosts']);

    app.showWorkspacePage(WorkspacePage.snippets);
    bar
      ..replace('/admin')
      ..onNavigate!();
    expect(app.page, WorkspacePage.snippets);
    expect(bar.path, '/snippets');
  });

  group('admin console sections', () {
    const sections = {'instance', 'users', 'audit'};

    /// An administrator's workspace, the console's section notifier, the
    /// sections the address asked the console for, and the binding.
    Future<
      (AppController, ValueNotifier<String?>, List<String>, PageAddressBinding)
    >
    console(_FakeBar bar) async {
      final app = await workspace()
        ..account = AccountProfile(
          accountId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          deviceId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
          accountKeyEnvelopeVersion: 1,
          accountKeyEnvelope: const {},
          policy: const {'instance_admin': true},
        );
      final shown = ValueNotifier<String?>(null);
      addTearDown(shown.dispose);
      final asked = <String>[];
      final binding = PageAddressBinding(
        app,
        bar,
        adminSection: shown,
        adminHome: 'instance',
        openAdminSection: (id) {
          if (!sections.contains(id)) return false;
          asked.add(id);
          return true;
        },
      )..attach();
      addTearDown(binding.detach);
      return (app, shown, asked, binding);
    }

    test('a link to a section opens the console on it', () async {
      final bar = _FakeBar('/admin/users');
      final (app, shown, asked, _) = await console(bar);
      expect(app.page, WorkspacePage.admin);
      expect(asked, ['users']);
      // Before the console has built, and after it reports the section, the
      // address is the one that was opened: nothing is stacked on it.
      expect(bar.entries, ['/admin/users']);
      shown.value = 'users';
      expect(bar.entries, ['/admin/users']);
    });

    test('sections add history; Back returns to the one before', () async {
      final bar = _FakeBar('/admin/users');
      final (app, shown, asked, _) = await console(bar);
      shown.value = 'users';
      shown.value = 'audit';
      expect(bar.entries, ['/admin/users', '/admin/audit']);

      bar.back();
      expect(asked, ['users', 'users']);
      // The console still shows the section it is leaving. Whatever else
      // notifies meanwhile must not write that one back over the address.
      app.notifyListeners();
      expect(bar.entries, ['/admin/users', '/admin/audit']);
      expect(bar.path, '/admin/users');
      shown.value = 'users';
      expect(bar.entries, ['/admin/users', '/admin/audit']);
      expect(bar.path, '/admin/users');
    });

    test('/admin itself is the first section', () async {
      final bar = _FakeBar('/admin');
      final (app, shown, asked, _) = await console(bar);
      expect(app.page, WorkspacePage.admin);
      expect(asked, ['instance']);
      shown.value = 'instance';
      expect(bar.entries, ['/admin']);
      shown.value = 'users';
      shown.value = 'instance';
      expect(bar.entries, ['/admin', '/admin/users', '/admin']);
    });

    test('entering and leaving from the workspace', () async {
      final bar = _FakeBar('/hosts');
      final (app, shown, asked, _) = await console(bar);
      app.showWorkspacePage(WorkspacePage.admin);
      expect(bar.entries, ['/hosts', '/admin']);
      expect(asked, isEmpty);
      shown.value = 'instance';
      expect(bar.entries, ['/hosts', '/admin']);

      app.showWorkspacePage(WorkspacePage.hosts);
      shown.value = null;
      expect(bar.entries, ['/hosts', '/admin', '/hosts']);

      // Back into the console, then Back out of it again.
      bar.back();
      expect(app.page, WorkspacePage.admin);
      expect(asked, ['instance']);
      shown.value = 'instance';
      bar.back();
      expect(app.page, WorkspacePage.hosts);
      expect(bar.entries, ['/hosts', '/admin', '/hosts']);
    });

    test('a section the console does not offer falls back to /admin', () async {
      final bar = _FakeBar('/admin/sandbox');
      final (app, shown, asked, _) = await console(bar);
      expect(app.page, WorkspacePage.admin);
      expect(asked, isEmpty);
      expect(bar.entries, ['/admin']);
      shown.value = 'instance';
      expect(bar.entries, ['/admin']);
    });
  });

  test('a link into the console is dropped for other accounts', () async {
    final app = await workspace();
    final bar = _FakeBar('/admin/users');
    final asked = <String>[];
    PageAddressBinding(
      app,
      bar,
      adminHome: 'instance',
      openAdminSection: (id) {
        asked.add(id);
        return true;
      },
    ).attach();
    expect(app.page, WorkspacePage.hosts);
    expect(bar.entries, ['/hosts']);
    // Nothing is left asking a later console for that section.
    expect(asked, isEmpty);
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
