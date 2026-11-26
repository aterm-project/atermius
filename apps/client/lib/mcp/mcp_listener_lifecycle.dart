import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';

import '../platform/mcp_foreground.dart';
import 'mcp_service.dart';

/// The part of the MCP service the platform lifecycle needs. Kept minimal so
/// the lifecycle never sees tokens, policy or workspace data.
abstract interface class McpLifecycleTarget implements Listenable {
  bool get running;
  bool get starting;
  Uri? get endpoint;

  /// Stops listening; the saved token stops being accepted with it.
  Future<void> stop();

  /// Stops listening and turns MCP off on this device: the user stopped it
  /// (notification Stop), so it must not start again by itself.
  Future<void> disable();

  /// Listens again where the user last enabled MCP, after [stop] paused it
  /// because the app was hidden. Does nothing when that no longer applies.
  Future<void> resume();
}

class McpServiceLifecycleTarget implements McpLifecycleTarget {
  McpServiceLifecycleTarget(this.service);
  final McpService service;

  @override
  bool get running => service.running;
  @override
  bool get starting => service.starting;
  @override
  Uri? get endpoint => service.endpoint;
  @override
  Future<void> stop() => service.stop();
  @override
  Future<void> disable() => service.disable();
  @override
  Future<void> resume() => service.resume();
  @override
  void addListener(VoidCallback listener) => service.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      service.removeListener(listener);
}

enum McpBackgroundMode {
  /// MCP is not listening.
  inactive,

  /// Listening; waiting for the foreground service to confirm.
  starting,

  /// Listening and kept reachable in the background by an Android foreground
  /// service. Its ongoing notification carries a Stop action; when Android
  /// cannot show it (permission denied, notifications blocked) the service
  /// still runs and stays listed, and stoppable, in Android's active apps.
  protected,

  /// Listening only while the app is visible: hiding the app pauses the
  /// listener and showing it again resumes it with the same token. Used on
  /// iOS and when Android could not start the foreground service, because a
  /// frozen process would hold the port without answering.
  foregroundOnly,
}

/// Binds the MCP listener lifetime to the mobile app lifecycle.
///
/// * Listener starts (explicit user action, app visible) -> foreground
///   service lease with an ongoing notification and Stop action. Leaving the
///   app (Home, Back, another app) keeps MCP listening.
/// * Listener stops for any reason -> lease released, notification removed.
/// * Notification Stop / task removal / service death -> stopped.
/// * Notifications hidden or blocked -> still listening; only
///   [notificationsVisible] changes (Android lists the service in its active
///   apps, where it can be stopped).
/// * No foreground service (denied, failed, timed out), and always on iOS ->
///   foreground-only: hiding the app pauses the listener (a frozen process
///   would hold the port without answering) and showing it again resumes it
///   on the same port with the same token.
/// * Flutter engine detaching -> stopped.
class McpListenerLifecycle extends ChangeNotifier with WidgetsBindingObserver {
  McpListenerLifecycle({
    required this.target,
    McpForegroundChannel? channel,
    McpForegroundText Function()? text,
    WidgetsBinding? binding,
    String Function()? newLeaseId,
    this.foregroundOnly = false,
  }) : channel = channel ?? McpForegroundChannel(),
       _text = text ?? (() => const McpForegroundText()),
       _binding = binding ?? WidgetsBinding.instance,
       _newLeaseId = newLeaseId ?? (() => const Uuid().v4()) {
    _appState = _binding.lifecycleState;
    _binding.addObserver(this);
    _events = this.channel.events.listen(_onEvent);
    target.addListener(_targetChanged);
    _targetChanged();
  }

  static McpListenerLifecycle? _installed;

  /// Lifecycle bound to [McpService.instance], or null when the platform
  /// needs none (desktop/Web) or it has not been installed.
  static McpListenerLifecycle? get installed => _installed;

  /// Installs the mobile lifecycle guard once for the application.
  static McpListenerLifecycle? install(
    McpService service, {
    McpForegroundText Function()? text,
  }) {
    if (!needsMcpForegroundService) return null;
    return _installed ??= McpListenerLifecycle(
      target: McpServiceLifecycleTarget(service),
      text: text,
      foregroundOnly: mcpForegroundOnly,
    );
  }

  final McpLifecycleTarget target;
  final McpForegroundChannel channel;
  final bool foregroundOnly;
  final McpForegroundText Function() _text;
  final WidgetsBinding _binding;
  final String Function() _newLeaseId;
  late final StreamSubscription<McpForegroundEvent> _events;
  AppLifecycleState? _appState;
  String? _lease;
  int? _leasePort;
  bool _disposed = false;

  McpBackgroundMode _mode = McpBackgroundMode.inactive;
  bool _notificationsVisible = false;
  bool _serviceActive = false;
  String? _lastRevocation;
  bool _resumeWhenVisible = false;

  McpBackgroundMode get mode => _mode;

  /// Whether Android reported the ongoing notification as displayable.
  bool get notificationsVisible => _notificationsVisible;

  /// Whether the native foreground service holds the current lease. It may be
  /// active in [McpBackgroundMode.foregroundOnly] while notifications are
  /// hidden, so that granting them can restore protection without a restart.
  bool get serviceActive => _serviceActive;

  /// Why the platform last stopped MCP (`user_stop`, `task_removed`,
  /// `timeout`, `service_destroyed`, `replaced`, `background_unprotected`,
  /// `detached`, `unknown`), or null. Cleared on the next start.
  String? get lastRevocation => _lastRevocation;

  /// MCP was paused because the app was hidden and resumes when it is shown.
  bool get resumeWhenVisible => _resumeWhenVisible;

  bool get _inBackground =>
      _appState == AppLifecycleState.hidden ||
      _appState == AppLifecycleState.paused ||
      _appState == AppLifecycleState.detached;

  void _set(McpBackgroundMode mode, {bool? notifications, bool? service}) {
    _mode = mode;
    if (service != null) _serviceActive = service;
    if (notifications != null) _notificationsVisible = notifications;
    if (!_disposed) notifyListeners();
  }

  void _targetChanged() {
    if (_disposed) return;
    if (target.running || target.starting) _resumeWhenVisible = false;
    if (foregroundOnly &&
        _inBackground &&
        (target.starting || target.running)) {
      unawaited(_revoke('background_unprotected'));
      return;
    }
    final port = target.running ? target.endpoint?.port : null;
    if (port != null) {
      if (_lease != null && _leasePort == port) return;
      if (_lease != null) _release();
      _acquire(port);
    } else if (_lease != null) {
      _release();
    }
  }

  void _acquire(int port) {
    final id = _newLeaseId();
    _lease = id;
    _leasePort = port;
    _lastRevocation = null;
    _set(McpBackgroundMode.starting, notifications: false, service: false);
    unawaited(_requestGrant(id, port));
  }

  Future<void> _requestGrant(String id, int port) async {
    var grant = McpForegroundGrant.unavailable;
    try {
      grant = await channel.start(leaseId: id, port: port, text: _text());
    } on Object {
      grant = McpForegroundGrant.unavailable;
    }
    if (_disposed || _lease != id) {
      // Stopped (or restarted) while the native side was starting: make sure
      // a late-started service for this stale lease is torn down.
      if (grant.active) unawaited(_stopNative(id));
      return;
    }
    if (foregroundOnly && !grant.active) {
      await _revoke('background_unprotected');
      return;
    }
    if (!grant.active) {
      // A timed-out request may still start natively later; release it.
      unawaited(_stopNative(id));
      _set(
        McpBackgroundMode.foregroundOnly,
        notifications: false,
        service: false,
      );
      if (_inBackground) await _revoke('background_unprotected');
      return;
    }
    if (foregroundOnly) {
      _set(
        McpBackgroundMode.foregroundOnly,
        notifications: false,
        service: true,
      );
      if (_inBackground) await _revoke('background_unprotected');
      return;
    }
    // The service keeps the process running whether or not Android can show
    // its notification; without one it is still listed in the active apps.
    _set(
      McpBackgroundMode.protected,
      notifications: grant.notifications,
      service: true,
    );
  }

  void _release() {
    final id = _lease;
    _lease = null;
    _leasePort = null;
    _set(McpBackgroundMode.inactive, notifications: false, service: false);
    if (id != null) unawaited(_stopNative(id));
  }

  Future<void> _stopNative(String id) async {
    try {
      await channel.stop(id);
    } on Object {
      // Engine teardown releases any remaining native lease.
    }
  }

  Future<void> _revoke(String reason, {bool native = true}) async {
    final id = _lease;
    _lease = null;
    _leasePort = null;
    _lastRevocation = reason;
    // Paused only because nobody can see the app: back when it is shown.
    _resumeWhenVisible =
        reason == 'background_unprotected' &&
        (target.running || target.starting);
    _set(McpBackgroundMode.inactive, notifications: false, service: false);
    if (native && id != null) unawaited(_stopNative(id));
    // Stop even without a lease: a running listener must never outlive the
    // reason for revocation.
    if (target.running || target.starting) {
      await (reason == 'user_stop' ? target.disable() : target.stop());
    }
  }

  void _onEvent(McpForegroundEvent event) {
    if (_disposed || event.leaseId != _lease) return;
    switch (event) {
      case McpForegroundRevoked(:final reason):
        unawaited(_revoke(reason, native: false));
      case McpForegroundNotifications(:final visible):
        _notificationsChanged(visible);
    }
  }

  void _notificationsChanged(bool visible) {
    // While starting, the grant reply carries the authoritative value; the
    // native side only reports changes for an acknowledged lease.
    if (foregroundOnly ||
        !_serviceActive ||
        _mode == McpBackgroundMode.starting) {
      return;
    }
    // Shown or not, the service keeps running; settings say which.
    _set(_mode, notifications: visible);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appState = state;
    if (_disposed) return;
    if (state == AppLifecycleState.resumed && _resumeWhenVisible) {
      _resumeWhenVisible = false;
      unawaited(target.resume().catchError((Object _) {}));
      return;
    }
    if (state == AppLifecycleState.detached) _resumeWhenVisible = false;
    if (!target.running && !(foregroundOnly && target.starting)) {
      return;
    }
    if (state == AppLifecycleState.detached) {
      unawaited(_revoke('detached'));
    } else if (_inBackground &&
        (foregroundOnly || _mode == McpBackgroundMode.foregroundOnly)) {
      unawaited(_revoke('background_unprotected'));
    }
    // `starting` is resolved in _requestGrant once the native answer arrives.
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _binding.removeObserver(this);
    target.removeListener(_targetChanged);
    unawaited(_events.cancel());
    final id = _lease;
    _lease = null;
    if (id != null) unawaited(_stopNative(id));
    if (identical(_installed, this)) _installed = null;
    super.dispose();
  }
}
