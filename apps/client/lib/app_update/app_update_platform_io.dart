import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../platform/application_windows.dart';
import '../platform/window_chrome.dart';
import 'app_update_android.dart';
import 'app_update_backend.dart';
import 'app_update_channel.dart';
import 'app_update_controller.dart';
import 'app_update_desktop.dart';
import 'app_update_download.dart';
import 'app_update_setting_store_io.dart';
import 'release_tag.dart';

export 'app_update_desktop.dart' show appUpdateStartup, appUpdateHoldInstance;

/// A test feed in place of GitHub: the origin of a server that answers like
/// the GitHub API. Only for builds made to test the updater itself.
const _testFeed = String.fromEnvironment('ATERMIUS_UPDATE_FEED');

/// The package this build can replace itself with, if any. iOS and macOS
/// are updated through their own stores and are not handled here.
AppUpdateTarget? _target() => switch (Abi.current()) {
  Abi.windowsX64 => AppUpdateTarget.windowsX64,
  Abi.linuxX64 => AppUpdateTarget.linuxX64,
  Abi.androidArm64 || Abi.androidX64 => AppUpdateTarget.android,
  _ => null,
};

/// Ends the app the way quitting it does, and makes sure the process is
/// really gone soon after: the installer waits for that.
Future<void> _quit({Duration limit = const Duration(seconds: 6)}) async {
  final chrome = WindowChromeController.instance;
  if (chrome.supported && chrome.state.enabled) {
    // Windows: the normal quit path ends sessions and child windows first.
    // Quit, not close: with MCP running a close only hides the window.
    unawaited(chrome.hideTray().catchError((Object _) {}));
    unawaited(ApplicationWindows.instance.requestParentClose(quit: true));
    await Future<void>.delayed(limit);
  } else {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  exit(0);
}

/// Desktop windows: a ready release is installed when the app closes, and a
/// window closes when another one restarts into a new version.
void _installCloseHooks(AppUpdateController controller) {
  final windows = ApplicationWindows.instance;
  windows.beforeExit = controller.installOnExit;
  controller.closeRequests.listen(
    (_) => unawaited(_quit(limit: const Duration(seconds: 20))),
  );
}

AppUpdateController? createAppUpdateController({
  required AppUpdateDoneNotice Function() doneNotice,
}) {
  final target = _target();
  // Development builds carry no release tag and are never replaced.
  if (target == null || ReleaseStamp.tryParse(atermiusReleaseTag) == null) {
    return null;
  }
  final client = createAppUpdateHttpClient();
  final AppUpdateBackend backend;
  if (target == AppUpdateTarget.android) {
    backend = AndroidAppUpdateBackend(
      client: client,
      cacheDirectory: getApplicationCacheDirectory,
      doneNotice: doneNotice,
    );
  } else {
    final layout = AppUpdateDesktopLayout.current();
    if (layout == null) return null;
    backend = DesktopAppUpdateBackend(
      layout: layout,
      client: client,
      quit: _quit,
    );
  }
  final controller = AppUpdateController(
    currentTag: atermiusReleaseTag,
    target: target,
    channel: GitHubReleaseChannel(
      client: client,
      api: _testFeed.isEmpty ? null : Uri.parse(_testFeed),
    ),
    backend: backend,
    settings: FileAppUpdateSettingStore(),
  );
  if (target != AppUpdateTarget.android) _installCloseHooks(controller);
  return controller;
}
