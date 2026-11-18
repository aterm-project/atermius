import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;

import 'page_address.dart';

final _BrowserAddressBar _bar = _BrowserAddressBar();

PageAddressBar? browserPageAddressBar() => _bar;

void takeOverBrowserAddress() => ui_web.urlStrategy = null;

class _BrowserAddressBar extends PageAddressBar {
  _BrowserAddressBar() {
    web.window.addEventListener(
      'popstate',
      ((web.Event _) => onNavigate?.call()).toJS,
    );
  }

  /// Path of the app's own folder, without the trailing slash ('' at the
  /// site root), for a server that publishes the app below a prefix.
  String get _prefix {
    final base = Uri.tryParse(web.document.baseURI)?.path ?? '/';
    final folder = base.substring(0, base.lastIndexOf('/') + 1);
    return folder.substring(0, folder.length - 1);
  }

  @override
  String get path {
    final full = web.window.location.pathname;
    final prefix = _prefix;
    if (prefix.isNotEmpty && full.startsWith('$prefix/')) {
      return full.substring(prefix.length);
    }
    return full.isEmpty ? '/' : full;
  }

  String _url(String path) => '$_prefix$path${web.window.location.search}';

  @override
  void replace(String path) =>
      web.window.history.replaceState(null, '', _url(path));

  @override
  void push(String path) => web.window.history.pushState(null, '', _url(path));
}
