import 'app_update_channel.dart';

/// A release that is downloaded, verified and ready to start from: an
/// unpacked copy of the app on desktop, the package file on Android.
class AppUpdateStaged {
  const AppUpdateStaged({required this.release, required this.path});

  final AppUpdateRelease release;
  final String path;

  Map<String, Object?> toJson() => {'release': release.toJson(), 'path': path};

  static AppUpdateStaged? fromJson(Object? json) {
    if (json is! Map) return null;
    final release = AppUpdateRelease.fromJson(json['release']);
    final path = json['path'];
    if (release == null || path is! String || path.isEmpty) return null;
    return AppUpdateStaged(release: release, path: path);
  }
}

/// How the last attempt to switch to a staged release ended.
class AppUpdateResult {
  const AppUpdateResult({required this.tag, required this.succeeded});

  final String tag;
  final bool succeeded;

  Map<String, Object?> toJson() => {'tag': tag, 'ok': succeeded};

  static AppUpdateResult? fromJson(Object? json) {
    if (json is! Map) return null;
    final tag = json['tag'], ok = json['ok'];
    if (tag is! String || ok is! bool) return null;
    return AppUpdateResult(tag: tag, succeeded: ok);
  }
}

/// Why the app could not switch to the staged release right now.
enum AppUpdateApplyProblem {
  /// Other Atermius windows of this user run from the same files and did
  /// not close when asked to (or were not asked to).
  otherWindowsOpen,

  /// The staged copy is gone or incomplete; it will be downloaded again.
  stagedMissing,

  /// The user dismissed the system's installation prompt.
  cancelled,

  /// The system refused, or the new version could not take over.
  failed,
}

/// The platform half of the updater: where packages are kept and how the
/// installed app is replaced. The controller owns when; this owns how.
abstract interface class AppUpdateBackend {
  /// Whether this installed copy can replace itself. False for a copy in a
  /// directory the user cannot write to: updates are then only announced.
  Future<bool> canInstall();

  /// The release that is ready to start from, if it is newer than
  /// [currentTag]. Another window may have staged it.
  Future<AppUpdateStaged?> staged(String currentTag);

  /// Releases that failed to install; not offered again.
  Future<Set<String>> blockedTags();

  /// The outcome of the last switch, reported once.
  Future<AppUpdateResult?> takeResult();

  /// Whether automatic downloads should wait for the user (mobile data).
  Future<bool> metered();

  /// Downloads, verifies and unpacks [release]. Null when another window is
  /// already doing so. [onProgress] gets the downloaded fraction.
  Future<AppUpdateStaged?> stage(
    AppUpdateRelease release, {
    required void Function(double fraction) onProgress,
  });

  /// Switches to [staged]. On desktop this ends the process and the new
  /// version starts; on Android the system installer takes over and ends
  /// the process when it is done. Returns only when that did not happen.
  ///
  /// With [closeOthers] (desktop) other main windows of this user are asked
  /// to close first, which ends their sessions; the user agreed to that.
  Future<AppUpdateApplyProblem?> apply(
    AppUpdateStaged staged, {
    bool closeOthers = false,
  });

  /// Whether other main windows of this user run from the same installed
  /// copy (also one hidden in the notification area). Always false where
  /// the app has a single window (Android).
  Future<bool> othersRunning();

  /// Another window asked every window to close because it is about to
  /// switch to a new version. Never fires for this window's own request.
  Stream<void> get closeRequests;

  /// The app is closing (the last window, not a window hidden to keep
  /// running): switches to a staged release without asking and without
  /// starting the app again. True when the new version took over; the
  /// process only has to end then. False when nothing was done, e.g. other
  /// windows still run or the switch would need administrator rights.
  Future<bool> applyOnExit();

  /// Problems reported after [apply] returned without one, e.g. the user
  /// cancelling the system's installation prompt.
  Stream<AppUpdateApplyProblem> get problems;

  /// Removes packages and old program files that are no longer needed.
  Future<void> cleanup(String currentTag);
}
