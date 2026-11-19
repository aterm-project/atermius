import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../app_controller.dart';
import 'page_address_stub.dart'
    if (dart.library.js_interop) 'page_address_web.dart'
    as platform;

/// The address-bar path of each workspace page, so a page can be bookmarked
/// or its link sent to someone else on the same server.
///
/// These share the server's top level with `/api`, `/s`, `/join` and the other
/// names in [reservedAddressNames]; none may be reused here.
const Map<WorkspacePage, String> _pageNames = {
  WorkspacePage.hosts: 'hosts',
  WorkspacePage.groups: 'groups',
  WorkspacePage.credentials: 'keychain',
  WorkspacePage.logs: 'logs',
  WorkspacePage.forwarding: 'forwarding',
  WorkspacePage.snippets: 'snippets',
  WorkspacePage.savedWorkspaces: 'workspaces',
  WorkspacePage.terminal: 'terminal',
  WorkspacePage.sftp: 'files',
  WorkspacePage.sync: 'sync',
  WorkspacePage.audit: 'audit',
  WorkspacePage.devices: 'devices',
  WorkspacePage.settings: 'settings',
  WorkspacePage.admin: 'admin',
};

/// First path segments the server or the sharing pages already own.
const Set<String> reservedAddressNames = {
  'api',
  'relay',
  'desktop',
  'collaboration',
  'gateway',
  'health',
  's',
  'join',
  'assets',
  'canvaskit',
  'icons',
  'gsap',
};

/// Path of [page]. The admin console is a site of its own below `/admin`,
/// so its sections have addresses too: `/admin/users`, `/admin/audit`, ….
String pagePath(WorkspacePage page, {String? section}) =>
    page == WorkspacePage.admin && section != null && section.isNotEmpty
    ? '/${_pageNames[page]!}/$section'
    : '/${_pageNames[page]!}';

/// What a path names: a page and, below `/admin`, a section of the console.
@immutable
class PageLocation {
  const PageLocation(this.page, [this.section]);

  final WorkspacePage page;
  final String? section;
}

/// The page and section a path names, or null when it names none (`/`,
/// `/join`, a second segment under a page that has no sections, …).
PageLocation? locationForPath(String path) {
  final match = RegExp(
    r'^/([a-z]+)(?:/([a-z0-9]+(?:-[a-z0-9]+)*))?/?$',
  ).firstMatch(path);
  if (match == null) return null;
  final section = match.group(2);
  for (final entry in _pageNames.entries) {
    if (entry.value != match.group(1)) continue;
    if (section != null && entry.key != WorkspacePage.admin) return null;
    return PageLocation(entry.key, section);
  }
  return null;
}

/// The page a path names, or null when it names none (`/`, `/join`, …).
WorkspacePage? pageForPath(String path) => locationForPath(path)?.page;

/// The browser's address bar and history, as far as page links need them.
abstract class PageAddressBar {
  /// Current path, starting with `/`.
  String get path;

  /// True until the link the page was opened with has been followed once.
  /// Signing out and in again later must not jump back to an old link.
  bool linkPending = true;

  /// Rewrites the current history entry.
  void replace(String path);

  /// Adds a history entry, so Back returns to the previous page.
  void push(String path);

  /// Called when the user moves through history (Back / Forward).
  VoidCallback? onNavigate;
}

/// The browser's address bar; null outside the browser.
PageAddressBar? browserPageAddressBar() => platform.browserPageAddressBar();

/// Stops the engine from handling the address itself. It would answer every
/// Back/Forward by pushing a route onto the Navigator.
void takeOverBrowserAddress() => platform.takeOverBrowserAddress();

/// Keeps the address bar on the open workspace page, and opens the page the
/// address names. Lives as long as the unlocked workspace is on screen.
///
/// Below `/admin` it also follows the console's sections: [adminSection] is
/// the section on screen (null while the console is not), [openAdminSection]
/// asks the console for one and answers whether it offers it, and [adminHome]
/// is the section `/admin` itself stands for.
class PageAddressBinding {
  PageAddressBinding(
    this.app,
    this.bar, {
    this.adminSection,
    this.openAdminSection,
    this.adminHome,
  });

  final AppController app;
  final PageAddressBar bar;
  final ValueListenable<String?>? adminSection;
  final bool Function(String section)? openAdminSection;
  final String? adminHome;
  bool _attached = false;

  /// The section an address asked for, until the console shows it. Until
  /// then the console still reports the one it is leaving, which must not be
  /// written back over the address that was just followed.
  String? _wantedSection;

  void _onSectionShown() {
    _wantedSection = null;
    _sync();
  }

  void attach() {
    if (_attached) return;
    _attached = true;
    app.addListener(_sync);
    adminSection?.addListener(_onSectionShown);
    bar.onNavigate = _followAddress;
    _sync();
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    app.removeListener(_sync);
    adminSection?.removeListener(_onSectionShown);
    bar.onNavigate = null;
  }

  bool get _workspaceOpen =>
      app.stage == ClientStage.workspace && !app.workspaceLocked;

  /// The address of what is on screen.
  String get _path {
    if (app.page != WorkspacePage.admin) {
      _wantedSection = null;
      return pagePath(app.page);
    }
    final section = _wantedSection ?? adminSection?.value;
    return pagePath(app.page, section: section == adminHome ? null : section);
  }

  /// Opens what [location] names. False when the account may not see it.
  bool _open(PageLocation location) {
    if (!app.canShowWorkspacePage(location.page)) return false;
    if (location.page == WorkspacePage.admin) {
      final section = location.section ?? adminHome;
      if (section != null && section != adminSection?.value) {
        _wantedSection = (openAdminSection?.call(section) ?? false)
            ? section
            : null;
      }
    }
    if (location.page != app.page) app.showWorkspacePage(location.page);
    return app.page == location.page;
  }

  void _sync() {
    if (!_workspaceOpen) return;
    if (bar.linkPending) {
      bar.linkPending = false;
      final linked = locationForPath(bar.path);
      if (linked != null) {
        final wasOpen = linked.page == app.page;
        if (!_open(linked)) {
          // Refused (the admin console, for an account that is not an
          // instance administrator): the address must not keep naming a page
          // that is not the one on screen, nor stay behind as a Back target.
          bar.replace(pagePath(app.page));
          return;
        }
        // Opened just now: that notified and re-entered here with the
        // address right.
        if (!wasOpen) return;
      }
    }
    final path = _path;
    if (bar.path == path) return;
    final from = locationForPath(bar.path);
    if (from == null ||
        (from.page == WorkspacePage.admin &&
            app.page == WorkspacePage.admin &&
            adminSection?.value == null)) {
      // `/`, or a join link that has been used: nothing worth going back to.
      // Likewise an address inside the console that the console has not
      // answered yet: it is corrected in place, not stacked.
      bar.replace(path);
    } else {
      bar.push(path);
    }
  }

  void _followAddress() {
    if (!_workspaceOpen) return;
    final location = locationForPath(bar.path);
    if (location == null) return;
    if (!_open(location)) bar.replace(pagePath(app.page));
  }
}
