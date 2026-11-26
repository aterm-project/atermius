import 'dart:async';

import 'package:flutter/foundation.dart';

import '../mcp/mcp_service.dart';
import 'application_windows.dart';
import 'window_chrome.dart';

/// Texts of the notification-area icon, resolved when the window hides.
class McpBackgroundTexts {
  const McpBackgroundTexts({
    required this.tooltip,
    required this.open,
    required this.quit,
    required this.noticeTitle,
    required this.notice,
  });

  final String tooltip;
  final String open;
  final String quit;
  final String noticeTitle;
  final String notice;
}

/// Keeps MCP running as a background service on Windows.
///
/// While MCP listens, closing the main window (caption button, Alt+F4, the
/// taskbar) hides it instead of quitting: sessions, tabs and the listener
/// stay as they are, and an Atermius icon in the notification area opens the
/// window again or quits. The first time in a run a notification says so.
/// Without a notification-area icon the window is never hidden, so the
/// process can always be reached. When MCP stops while the window is hidden
/// there is nothing left to serve in the background and the window returns.
class McpBackgroundHost {
  McpBackgroundHost({
    required this.service,
    required this.chrome,
    required this.windows,
    required this.texts,
  }) {
    windows.keepRunningOnClose = _keepRunning;
    _tray = chrome.trayEvents.listen(_onTray);
    service.addListener(_serviceChanged);
  }

  /// Installs the host for the main window on Windows; null elsewhere.
  static McpBackgroundHost? install(
    McpService service, {
    required McpBackgroundTexts Function() texts,
  }) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return null;
    return McpBackgroundHost(
      service: service,
      chrome: WindowChromeController.instance,
      windows: ApplicationWindows.instance,
      texts: texts,
    );
  }

  final McpService service;
  final WindowChromeController chrome;
  final ApplicationWindows windows;
  final McpBackgroundTexts Function() texts;
  late final StreamSubscription<WindowTrayEvent> _tray;
  bool _hidden = false;
  bool _noticeShown = false;
  bool _disposed = false;

  /// The window is hidden and MCP runs in the background.
  bool get hidden => _hidden;

  Future<bool> _keepRunning() async {
    if (_disposed || !service.running) return false;
    final t = texts();
    final shown = await chrome.showTray(
      tooltip: t.tooltip,
      open: t.open,
      quit: t.quit,
      noticeTitle: _noticeShown ? '' : t.noticeTitle,
      notice: _noticeShown ? '' : t.notice,
    );
    if (!shown || _disposed) return false;
    _noticeShown = true;
    _hidden = true;
    await chrome.hide();
    return true;
  }

  void _onTray(WindowTrayEvent event) {
    switch (event) {
      case WindowTrayEvent.open:
        unawaited(_open());
      case WindowTrayEvent.quit:
        unawaited(_quit());
    }
  }

  Future<void> _open() async {
    _hidden = false;
    await chrome.hideTray();
    await windows.showParent();
  }

  Future<void> _quit() async {
    await chrome.hideTray();
    if (_hidden) {
      // Sessions close as on any quit; keep the window out of sight.
      _hidden = false;
    }
    await windows.requestParentClose(quit: true);
  }

  void _serviceChanged() {
    // MCP also stops while the app quits (e.g. another window restarts into
    // a new version): the window stays out of sight then.
    if (_hidden &&
        !windows.quitting &&
        !service.running &&
        !service.starting) {
      unawaited(_open());
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (windows.keepRunningOnClose == _keepRunning) {
      windows.keepRunningOnClose = null;
    }
    unawaited(_tray.cancel());
    service.removeListener(_serviceChanged);
  }
}
