import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_update_backend.dart';
import 'app_update_channel.dart';
import 'release_marker.dart';
import 'release_tag.dart';

/// Remembers whether updates are installed without asking.
abstract interface class AppUpdateSettingStore {
  Future<bool?> readAutomatic();
  Future<void> writeAutomatic(bool value);
}

class MemoryAppUpdateSettingStore implements AppUpdateSettingStore {
  MemoryAppUpdateSettingStore([this.value]);
  bool? value;
  @override
  Future<bool?> readAutomatic() async => value;
  @override
  Future<void> writeAutomatic(bool value) async => this.value = value;
}

/// Why a newer release that was found is not being downloaded.
enum AppUpdateWaitReason {
  /// This copy cannot replace itself; the user installs the release.
  manualInstall,

  /// The user turned automatic updates off.
  automaticOff,

  /// The connection is metered; the download waits for the user or Wi-Fi.
  metered,
}

/// Looks for newer releases, has them installed in the background and tells
/// the UI when a restart will start the new version.
///
/// It never restarts by itself: [restart] is only called from the UI.
class AppUpdateController extends ChangeNotifier {
  AppUpdateController({
    required this.currentTag,
    required this.target,
    required AppUpdateChannel channel,
    required AppUpdateBackend backend,
    AppUpdateSettingStore? settings,
    this.startDelay = const Duration(seconds: 20),
    this.checkInterval = const Duration(hours: 4),
    this.stagedPollInterval = const Duration(minutes: 2),
    this.applyWatchdog = const Duration(seconds: 90),
  }) : _channel = channel,
       _backend = backend,
       _settings = settings ?? MemoryAppUpdateSettingStore();

  /// The updater of this process; null on the web, in development builds
  /// and on platforms that are updated another way.
  static AppUpdateController? instance;

  final String currentTag;
  final AppUpdateTarget target;
  final AppUpdateChannel _channel;
  final AppUpdateBackend _backend;
  final AppUpdateSettingStore _settings;
  final Duration startDelay;
  final Duration checkInterval;
  final Duration stagedPollInterval;
  final Duration applyWatchdog;

  Timer? _startTimer, _checkTimer, _pollTimer, _applyTimer;
  StreamSubscription<AppUpdateApplyProblem>? _problems;
  bool _started = false;
  bool _disposed = false;

  bool _automatic = true;
  bool _canInstall = true;
  bool _checking = false;
  bool _checkFailed = false;
  bool _checkedOnce = false;
  bool _downloading = false;
  bool _downloadFailed = false;
  bool _downloadRequested = false;
  bool _applying = false;
  double _progress = 0;
  AppUpdateStaged? _staged;
  AppUpdateRelease? _found;
  AppUpdateWaitReason? _waitReason;
  AppUpdateResult? _result;
  AppUpdateApplyProblem? _problem;

  /// Updates are downloaded and installed without asking.
  bool get automatic => _automatic;
  bool get checking => _checking;

  /// The last look at the channel failed (offline, rate limit).
  bool get checkFailed => _checkFailed;

  /// At least one look at the channel has finished since start.
  bool get checkedOnce => _checkedOnce;
  bool get downloading => _downloading;
  bool get downloadFailed => _downloadFailed;

  /// The running download was started by the user, not by the schedule.
  bool get downloadRequested => _downloadRequested;

  /// 0..1 while [downloading].
  double get progress => _progress;

  /// The switch to [ready] is under way; the process is about to end.
  bool get applying => _applying;

  /// Installed in the background and waiting for a restart.
  AppUpdateRelease? get ready => _staged?.release;

  /// A release newer than [ready] and the running build that is not (yet)
  /// downloaded; see [waitReason].
  AppUpdateRelease? get found => _found;
  AppUpdateWaitReason? get waitReason => _found == null ? null : _waitReason;

  /// Outcome of the switch that started this run, until dismissed.
  AppUpdateResult? get result => _result;

  /// Why the last [restart] did not happen, until the next attempt.
  AppUpdateApplyProblem? get problem => _problem;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      _automatic = await _settings.readAutomatic() ?? true;
    } catch (_) {
      // Default: on.
    }
    try {
      _canInstall = await _backend.canInstall();
      _result = await _backend.takeResult();
      await _backend.cleanup(currentTag);
    } catch (_) {
      // Housekeeping only.
    }
    if (_disposed) return;
    _problems = _backend.problems.listen(_onApplyProblem);
    await _adoptStaged();
    if (_disposed) return;
    notifyListeners();
    _startTimer = Timer(startDelay, () {
      unawaited(checkNow());
      _checkTimer = Timer.periodic(checkInterval, (_) => unawaited(checkNow()));
    });
    // Another window of the same user may finish a download.
    _pollTimer = Timer.periodic(
      stagedPollInterval,
      (_) => unawaited(_adoptStaged(notify: true)),
    );
  }

  Future<void> setAutomatic(bool value) async {
    if (_automatic == value) return;
    _automatic = value;
    notifyListeners();
    try {
      await _settings.writeAutomatic(value);
    } catch (_) {
      // Applies until the app closes.
    }
    if (value) unawaited(checkNow());
  }

  void dismissResult() {
    if (_result == null) return;
    _result = null;
    notifyListeners();
  }

  /// Looks at the channel once. With [download], a found release is fetched
  /// even when automatic updates are off or the connection is metered.
  Future<void> checkNow({bool download = false}) async {
    if (_disposed || _checking || _downloading || _applying) return;
    _checking = true;
    notifyListeners();
    AppUpdateRelease? latest;
    try {
      latest = await _channel.latest(currentTag: currentTag, target: target);
      _checkFailed = false;
      _checkedOnce = true;
    } catch (_) {
      // Nothing about the network or the server reaches the UI.
      _checkFailed = true;
    }
    if (_disposed) return;
    if (_checkFailed) {
      _checking = false;
      notifyListeners();
      return;
    }
    try {
      if (latest != null &&
          (await _backend.blockedTags()).contains(latest.tag)) {
        latest = null;
      }
      await _adoptStaged();
      final staged = _staged;
      if (latest != null &&
          staged != null &&
          !isNewerRelease(latest.tag, staged.release.tag)) {
        latest = null;
      }
      _found = latest;
      _waitReason = null;
      if (latest != null) {
        _canInstall = await _backend.canInstall();
        if (!_canInstall) {
          _waitReason = AppUpdateWaitReason.manualInstall;
        } else if (!download && !_automatic) {
          _waitReason = AppUpdateWaitReason.automaticOff;
        } else if (!download && await _backend.metered()) {
          _waitReason = AppUpdateWaitReason.metered;
        }
      }
    } catch (_) {
      // Treated as nothing found; the next check repeats it.
      _found = null;
    }
    if (_disposed) return;
    _checking = false;
    notifyListeners();
    if (_found != null && _waitReason == null) {
      await _download(_found!, requested: download);
    }
  }

  /// Fetches [found] now, whatever [waitReason] says (except when this copy
  /// cannot install at all).
  Future<void> downloadNow() async {
    final release = _found;
    if (release == null ||
        _waitReason == AppUpdateWaitReason.manualInstall ||
        _downloading ||
        _applying) {
      return;
    }
    _waitReason = null;
    await _download(release, requested: true);
  }

  Future<void> _download(
    AppUpdateRelease release, {
    bool requested = false,
  }) async {
    if (_disposed || _downloading) return;
    _downloading = true;
    _downloadRequested = requested;
    _downloadFailed = false;
    _progress = 0;
    notifyListeners();
    try {
      final staged = await _backend.stage(
        release,
        onProgress: (fraction) {
          final next = fraction.clamp(0.0, 1.0);
          // Whole percents are enough for a progress line.
          if ((next * 100).floor() == (_progress * 100).floor()) return;
          _progress = next;
          if (!_disposed) notifyListeners();
        },
      );
      if (staged != null) {
        _staged = staged;
        _found = null;
      }
      // Null: another window is downloading it; the poll picks it up.
    } on AppUpdateDeadEndRelease {
      // Skipped for good by the backend; nothing to offer or report.
      if (_found?.tag == release.tag) _found = null;
    } catch (_) {
      _downloadFailed = true;
    }
    _downloading = false;
    _downloadRequested = false;
    if (!_disposed) notifyListeners();
  }

  Future<void> _adoptStaged({bool notify = false}) async {
    if (_disposed || _downloading || _applying) return;
    AppUpdateStaged? staged;
    try {
      staged = await _backend.staged(currentTag);
    } catch (_) {
      return;
    }
    if (_disposed || staged?.release.tag == _staged?.release.tag) return;
    _staged = staged;
    if (staged != null &&
        _found != null &&
        !isNewerRelease(_found!.tag, staged.release.tag)) {
      _found = null;
    }
    if (notify) notifyListeners();
  }

  /// Switches to [ready]. On desktop the app ends here when it works; the
  /// returned problem says why it did not.
  Future<AppUpdateApplyProblem?> restart() async {
    final staged = _staged;
    if (_disposed || staged == null || _applying) return null;
    _applying = true;
    _problem = null;
    notifyListeners();
    AppUpdateApplyProblem? problem;
    try {
      problem = await _backend.apply(staged);
    } catch (_) {
      problem = AppUpdateApplyProblem.failed;
    }
    if (_disposed) return problem;
    if (problem == null) {
      // The system installer has it now (Android). If the process is still
      // here after a while, the banner offers the restart again.
      _applyTimer?.cancel();
      _applyTimer = Timer(applyWatchdog, () {
        if (_disposed || !_applying) return;
        _applying = false;
        notifyListeners();
      });
      return null;
    }
    _onApplyProblem(problem);
    return problem;
  }

  void _onApplyProblem(AppUpdateApplyProblem problem) {
    if (_disposed) return;
    _applyTimer?.cancel();
    _applying = false;
    _problem = problem;
    if (problem == AppUpdateApplyProblem.stagedMissing ||
        problem == AppUpdateApplyProblem.failed) {
      // The staged copy may be gone or blocked now; look again.
      _staged = null;
      unawaited(_adoptStaged(notify: true));
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _startTimer?.cancel();
    _checkTimer?.cancel();
    _pollTimer?.cancel();
    _applyTimer?.cancel();
    unawaited(_problems?.cancel());
    super.dispose();
  }
}
