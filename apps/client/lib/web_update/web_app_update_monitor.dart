import 'dart:async';

import 'package:flutter/foundation.dart';

/// Finds a newer self-hosted Web bundle, has it downloaded into the browser's
/// bundle cache in the background, and waits for a user initiated reload.
///
/// The update is offered ([hasUpdate]) only once the new bundle is completely
/// stored; until then the page keeps running the build it started with and
/// [downloadingUpdate] is true. The monitor never applies an update itself.
/// The caller owns readiness checks such as active SSH sessions and
/// unsynchronized Vault operations.
class WebAppUpdateMonitor extends ChangeNotifier {
  WebAppUpdateMonitor({
    required this.currentBuildId,
    required Future<String> Function() probeBuildId,
    required Future<void> Function() reload,
    Future<void> Function(String buildId)? prepareBuild,
    Future<void> Function(String buildId)? activateBuild,
    this.checkInterval = const Duration(minutes: 5),
  }) : _probeBuildId = probeBuildId,
       _reload = reload,
       _prepareBuild = prepareBuild,
       _activateBuild = activateBuild;

  /// Stores the complete bundle of a build in the browser cache; completes
  /// when it is ready to start from (also when the browser has no such
  /// cache), throws when the download did not finish. Null: no cache, a
  /// found update is offered at once.
  final Future<void> Function(String buildId)? _prepareBuild;

  /// Makes the next page load start from a prepared build.
  final Future<void> Function(String buildId)? _activateBuild;
  String? _preparedBuildId;
  String? _preparingBuildId;

  final String currentBuildId;
  final Future<String> Function() _probeBuildId;
  final Future<void> Function() _reload;
  final Duration checkInterval;

  Timer? _timer;
  bool _disposed = false;
  bool _checking = false;
  bool _lastCheckSucceeded = false;
  String? _availableBuildId;

  bool get checking => _checking;
  bool get lastCheckSucceeded => _lastCheckSucceeded;

  /// A newer build exists and is ready to reload into.
  bool get hasUpdate =>
      _availableBuildId != null &&
      (_prepareBuild == null || _preparedBuildId == _availableBuildId);

  /// A newer build was found and is still being downloaded in the
  /// background; the page keeps running the current build meanwhile.
  bool get downloadingUpdate =>
      _availableBuildId != null &&
      _prepareBuild != null &&
      _preparedBuildId != _availableBuildId;
  String? get availableBuildId => _availableBuildId;

  /// Begins a best-effort probe and checks periodically while the page is open.
  Future<void> start() async {
    if (_disposed || _timer != null) return;
    _timer = Timer.periodic(checkInterval, (_) => unawaited(checkNow()));
    await checkNow();
  }

  Future<void> checkNow() async {
    if (_disposed || _checking) return;
    _setChecking(true);
    try {
      final candidate = (await _probeBuildId()).trim();
      _lastCheckSucceeded = true;
      _availableBuildId = candidate.isNotEmpty && candidate != currentBuildId
          ? candidate
          : null;
    } catch (_) {
      // Keep the update UI free of network, origin, and server error details.
      _lastCheckSucceeded = false;
      _availableBuildId = null;
    } finally {
      _setChecking(false);
    }
    final candidate = _availableBuildId;
    if (candidate != null) unawaited(_prepare(candidate));
  }

  /// Downloads [buildId] once; a failed download is tried again at the next
  /// check, and the update is not offered before it succeeded.
  Future<void> _prepare(String buildId) async {
    final prepare = _prepareBuild;
    if (prepare == null ||
        _disposed ||
        _preparedBuildId == buildId ||
        _preparingBuildId == buildId) {
      return;
    }
    _preparingBuildId = buildId;
    try {
      await prepare(buildId);
      if (_disposed) return;
      _preparedBuildId = buildId;
      notifyListeners();
    } catch (_) {
      // Stay on the current build; nothing is offered.
    } finally {
      if (_preparingBuildId == buildId) _preparingBuildId = null;
    }
  }

  /// Reloads only after the UI has confirmed a currently available update.
  Future<void> applyUpdate() async {
    if (_disposed || !hasUpdate) return;
    final buildId = _availableBuildId;
    final activate = _activateBuild;
    if (activate != null && buildId != null) {
      try {
        await activate(buildId);
      } catch (_) {
        // The reload below still fetches from the server.
      }
    }
    if (_disposed) return;
    await _reload();
  }

  void _setChecking(bool value) {
    if (_disposed) return;
    // Also announces a changed availability when a check finishes.
    _checking = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
