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

String pagePath(WorkspacePage page) => '/${_pageNames[page]!}';

/// The page a path names, or null when it names none (`/`, `/join`, …).
WorkspacePage? pageForPath(String path) {
  final match = RegExp(r'^/([a-z]+)/?$').firstMatch(path);
  if (match == null) return null;
  for (final entry in _pageNames.entries) {
    if (entry.value == match.group(1)) return entry.key;
  }
  return null;
}

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
class PageAddressBinding {
  PageAddressBinding(this.app, this.bar);

  final AppController app;
  final PageAddressBar bar;
  bool _attached = false;

  void attach() {
    if (_attached) return;
    _attached = true;
    app.addListener(_sync);
    bar.onNavigate = _followAddress;
    _sync();
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    app.removeListener(_sync);
    bar.onNavigate = null;
  }

  bool get _workspaceOpen =>
      app.stage == ClientStage.workspace && !app.workspaceLocked;

  void _sync() {
    if (!_workspaceOpen) return;
    if (bar.linkPending) {
      bar.linkPending = false;
      final linked = pageForPath(bar.path);
      if (linked != null && linked != app.page) {
        // Notifies, which re-enters here with the address already right.
        app.showWorkspacePage(linked);
        return;
      }
    }
    final path = pagePath(app.page);
    if (bar.path == path) return;
    if (pageForPath(bar.path) == null) {
      // `/`, or a join link that has been used: nothing worth going back to.
      bar.replace(path);
    } else {
      bar.push(path);
    }
  }

  void _followAddress() {
    if (!_workspaceOpen) return;
    final page = pageForPath(bar.path);
    if (page == null || page == app.page) return;
    app.showWorkspacePage(page);
  }
}
