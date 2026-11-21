import 'app_menu.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import '../ssh/port_forward_rule_change.dart';
import '../ssh/port_forward_runtime.dart';

export '../ssh/port_forward_rule_change.dart';
import 'app_density.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'ios_native/ios_native.dart';
import 'page_kit.dart';
import 'ssh_port_forwarding_dialog.dart';
import 'workspace_controls.dart' show WorkspaceAction;

/// Connection phase of one SSH session (terminal tab) as seen by the
/// forwarding page.
enum SshForwardingSessionPhase { connecting, connected, disconnected, failed }

/// One SSH session of a Host that can carry forwards. Built by the mode
/// adapter from its own tab/session objects; never persisted.
@immutable
class SshForwardingSessionInfo {
  const SshForwardingSessionInfo({
    required this.id,
    required this.hostId,
    required this.label,
    required this.phase,
    this.manager,
  });

  /// Stable id of the tab/session (cloud tab id, local session id).
  final String id;
  final String hostId;
  final String label;
  final SshForwardingSessionPhase phase;

  /// The forwarding runtime of this session's authenticated connection.
  final SshPortForwardManager? manager;

  /// The runtime only while the session is authenticated and its manager is
  /// still open; forwards are never started on anything else.
  SshPortForwardManager? get liveManager {
    final value = manager;
    return phase == SshForwardingSessionPhase.connected &&
            value != null &&
            value.isOpen
        ? value
        : null;
  }
}

/// Mode adapter between the shared page and one workspace (cloud Vault or
/// standalone local profile). Every getter reads the current state when it
/// is called, so a pending start re-validates against live data.
abstract class SshForwardingSource implements Listenable {
  /// Opaque identity of the active scope's lifetime (cloud: the open Vault
  /// repository object; local: repository + unlocked profile objects). It
  /// must change on every switch, lock or sign-out, so an A -> B -> A
  /// sequence never compares equal to the first A. Compared with `==`.
  /// A pending connect-and-start only starts while it is unchanged.
  Object? get scopeKey;

  /// Hosts in the active scope. The page shows SSH hosts only.
  List<HostRecord> get hosts;

  /// Every SSH session/tab of this workspace, across all hosts.
  List<SshForwardingSessionInfo> get sessions;

  bool get canEdit;
  String? get readOnlyReason;
  String get storageDescription;

  /// Persists ONE rule change through the existing encrypted Host store,
  /// applied with [applySshPortForwardRuleChange] to the Host as it is where
  /// the write is serialized (cloud: inside the mutation queue; local: inside
  /// the repository operation with its revision CAS), and only while [scope]
  /// (the [scopeKey] captured before the user edited/confirmed) is current.
  /// Throws [SshPortForwardRuleConflict] when the saved rule is not
  /// [expected] (or an inserted id exists), and other errors on failure.
  Future<void> saveRule(
    String hostId, {
    SshPortForwardProfile? expected,
    SshPortForwardProfile? replacement,
    required Object? scope,
  });

  String describeSaveError(Object error);

  /// Opens a new SSH session for [host] through the workspace's normal
  /// connect flow (credential resolution, known-host and certificate gates,
  /// interactive prompts). Completes with the id of the session it opened
  /// once that session is authenticated, or `null` when it did not
  /// authenticate (cancelled, rejected, failed). Must never bypass trust.
  Future<String?> connect(HostRecord host);

  /// Shows the session (focuses its terminal tab). Optional.
  void showSession(String sessionId);
}

/// [SshForwardingSource] assembled from closures; used by the standalone
/// local profile (whose sessions are private to its state) and by tests.
class CallbackSshForwardingSource implements SshForwardingSource {
  CallbackSshForwardingSource({
    required Object? Function() scopeKey,
    required List<HostRecord> Function() hosts,
    required List<SshForwardingSessionInfo> Function() sessions,
    required Future<void> Function(
      String hostId,
      SshPortForwardProfile? expected,
      SshPortForwardProfile? replacement,
      Object? scope,
    )
    saveRule,
    required Future<String?> Function(HostRecord host) connect,
    required String storageDescription,
    // Resolve localized descriptions when read; retained adapters outlive locale changes.
    String Function()? storageDescriptionGetter,
    Listenable? changes,
    bool Function()? canEdit,
    String? readOnlyReason,
    String Function(Object error)? describeSaveError,
    void Function(String sessionId)? showSession,
  }) : _scopeKeyFn = scopeKey,
       _hostsFn = hosts,
       _sessionsFn = sessions,
       _saveRuleFn = saveRule,
       _connectFn = connect,
       _storageDescriptionValue = storageDescription,
       _storageDescriptionGetter = storageDescriptionGetter,
       _changesValue = changes,
       _canEditFn = canEdit,
       _readOnlyReasonValue = readOnlyReason,
       _describeSaveErrorFn = describeSaveError,
       _showSessionFn = showSession;

  final Object? Function() _scopeKeyFn;
  final List<HostRecord> Function() _hostsFn;
  final List<SshForwardingSessionInfo> Function() _sessionsFn;
  final Future<void> Function(
    String,
    SshPortForwardProfile?,
    SshPortForwardProfile?,
    Object?,
  )
  _saveRuleFn;
  final Future<String?> Function(HostRecord host) _connectFn;
  final String _storageDescriptionValue;
  final String Function()? _storageDescriptionGetter;
  final Listenable? _changesValue;
  final bool Function()? _canEditFn;
  final String? _readOnlyReasonValue;
  final String Function(Object error)? _describeSaveErrorFn;
  final void Function(String sessionId)? _showSessionFn;

  @override
  Object? get scopeKey => _scopeKeyFn();
  @override
  List<HostRecord> get hosts => _hostsFn();
  @override
  List<SshForwardingSessionInfo> get sessions => _sessionsFn();
  @override
  bool get canEdit => _canEditFn?.call() ?? true;
  @override
  String? get readOnlyReason => _readOnlyReasonValue;
  @override
  String get storageDescription =>
      _storageDescriptionGetter?.call() ?? _storageDescriptionValue;
  @override
  Future<void> saveRule(
    String hostId, {
    SshPortForwardProfile? expected,
    SshPortForwardProfile? replacement,
    required Object? scope,
  }) => _saveRuleFn(hostId, expected, replacement, scope);
  @override
  String describeSaveError(Object error) =>
      _describeSaveErrorFn?.call(error) ??
      currentL10n.couldNotSaveForwardingSettingsNothing;
  @override
  Future<String?> connect(HostRecord host) => _connectFn(host);
  @override
  void showSession(String sessionId) => _showSessionFn?.call(sessionId);
  @override
  void addListener(VoidCallback listener) =>
      _changesValue?.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      _changesValue?.removeListener(listener);
}

class _PendingStart {
  bool cancelled = false;
}

/// Volatile forwarding UI state that should outlive one visit of the page:
/// the session chosen per Host and "connect and start" requests that are
/// waiting for authentication. Own one per workspace shell and pass it to
/// every [SshForwardingPage]; it holds no secrets and is never persisted.
class SshForwardingController extends ChangeNotifier {
  /// Pass the shell's [source] so every scope transition (Vault switch, lock,
  /// sign-out, profile change) drops pending starts even while the page is
  /// not shown. Pending starts also re-check the scope when they complete.
  SshForwardingController({
    bool? runtimeSupported,
    String? unsupportedReason,
    SshForwardingSource? source,
  }) : _supported = runtimeSupported,
       _reason = unsupportedReason,
       _source = source {
    if (source != null) {
      bindScope(source.scopeKey);
      source.addListener(_onSourceChanged);
    }
  }

  final SshForwardingSource? _source;

  void _onSourceChanged() {
    final source = _source;
    if (source != null && !_disposed) bindScope(source.scopeKey);
  }

  bool? _supported;
  String? _reason;
  Object? _scopeKey;
  bool _scopeBound = false;
  final Map<String, String> _selectedSession = {};
  final Map<String, _PendingStart> _pending = {};
  final Map<String, String> _notes = {};
  final Set<String> _busy = {};
  bool _disposed = false;

  static String _key(String hostId, String profileId) => '$hostId\n$profileId';

  /// Whether this platform can open forwarding listeners at all. Checked
  /// before connecting, so an unsupported build never opens a session just
  /// to fail.
  bool get runtimeSupported => _supported ??= _probePlatform();
  String? get unsupportedReason {
    runtimeSupported;
    return _reason;
  }

  bool _probePlatform() {
    final platform = createSshPortForwardPlatform();
    _reason ??= platform.unsupportedReason;
    return platform.isSupported;
  }

  /// Forgets selections, notes and pending starts when the workspace scope
  /// (Vault, local profile) changed. Pending starts re-check the scope too.
  void bindScope(Object? scopeKey) {
    if (_scopeBound && scopeKey == _scopeKey) return;
    final hadState =
        _selectedSession.isNotEmpty || _pending.isNotEmpty || _notes.isNotEmpty;
    _scopeBound = true;
    _scopeKey = scopeKey;
    for (final pending in _pending.values) {
      pending.cancelled = true;
    }
    _pending.clear();
    _selectedSession.clear();
    _notes.clear();
    if (hadState) _notify();
  }

  List<SshForwardingSessionInfo> sessionsOf(
    SshForwardingSource source,
    String hostId,
  ) => source.sessions
      .where((session) => session.hostId == hostId)
      .toList(growable: false);

  List<SshForwardingSessionInfo> liveSessionsOf(
    SshForwardingSource source,
    String hostId,
  ) => sessionsOf(
    source,
    hostId,
  ).where((session) => session.liveManager != null).toList(growable: false);

  String? selectedSessionId(String hostId) => _selectedSession[hostId];

  void selectSession(String hostId, String sessionId) {
    if (_selectedSession[hostId] == sessionId) return;
    _selectedSession[hostId] = sessionId;
    _notify();
  }

  /// The session new starts go to: the user's choice, or the only
  /// authenticated session. `null` when there is none or the choice is
  /// ambiguous.
  SshForwardingSessionInfo? targetSession(
    SshForwardingSource source,
    String hostId,
  ) {
    final live = liveSessionsOf(source, hostId);
    final selected = _selectedSession[hostId];
    for (final session in live) {
      if (session.id == selected) return session;
    }
    return live.length == 1 ? live.single : null;
  }

  bool isConnecting(String hostId, String profileId) =>
      _pending.containsKey(_key(hostId, profileId));

  bool isBusy(String hostId, String profileId) =>
      _busy.contains(_key(hostId, profileId));

  String? noteOf(String hostId, String profileId) =>
      _notes[_key(hostId, profileId)];

  void clearNote(String hostId, String profileId) {
    if (_notes.remove(_key(hostId, profileId)) != null) _notify();
  }

  /// Starts a saved rule. Uses the target session when there is one;
  /// otherwise opens a new session through [SshForwardingSource.connect] and
  /// starts only on exactly that session, only after it authenticated, and
  /// only if scope, Host and rule are unchanged. Exposure confirmation is the
  /// caller's job and must happen before this call.
  ///
  /// [expected] / [expectedScope] bind the start to the exact rule the user
  /// saw or approved (for example in the exposure confirmation) and the
  /// scope it was shown in; any difference cancels the start.
  Future<void> start(
    SshForwardingSource source,
    String hostId,
    String profileId, {
    SshPortForwardProfile? expected,
    Object? expectedScope,
  }) async {
    final key = _key(hostId, profileId);
    if (_pending.containsKey(key) || _busy.contains(key)) return;
    _notes.remove(key);
    final scope = source.scopeKey;
    if (expected != null && scope != expectedScope) {
      _note(key, currentL10n.r7ForwardScopeChanged);
      return;
    }
    bindScope(scope);
    final host = _hostOf(source, hostId);
    final profile = _profileOf(host, profileId);
    if (host == null ||
        profile == null ||
        (expected != null && profile != expected)) {
      _note(key, currentL10n.r7ForwardRuleChanged);
      return;
    }
    if (!runtimeSupported) {
      _note(key, unsupportedReason ?? currentL10n.forwardRuntimeUnsupported);
      return;
    }
    final target = targetSession(source, hostId);
    if (target != null) {
      await _startOn(key, target.liveManager!, profile);
      return;
    }
    if (liveSessionsOf(source, hostId).length > 1) {
      _note(key, currentL10n.r7ForwardChooseSession);
      return;
    }
    if (sessionsOf(
      source,
      hostId,
    ).any((session) => session.phase == SshForwardingSessionPhase.connecting)) {
      _note(key, currentL10n.r7ForwardWaitForSession);
      return;
    }

    final pending = _PendingStart();
    _pending[key] = pending;
    _notify();
    String? sessionId;
    try {
      sessionId = await source.connect(host);
    } catch (_) {
      // The workspace's connect flow reports its own (sanitized) error.
      sessionId = null;
    }
    if (_disposed || pending.cancelled || !identical(_pending[key], pending)) {
      return;
    }
    _pending.remove(key);
    if (sessionId == null) {
      _note(key, currentL10n.r7ForwardNotConnected);
      return;
    }
    if (source.scopeKey != scope) {
      _note(key, currentL10n.r7ForwardScopeChanged);
      return;
    }
    final latestHost = _hostOf(source, hostId);
    final latest = _profileOf(latestHost, profileId);
    if (latest == null || latest != profile) {
      _note(key, currentL10n.r7ForwardRuleChanged);
      return;
    }
    SshForwardingSessionInfo? session;
    for (final candidate in source.sessions) {
      if (candidate.id == sessionId) session = candidate;
    }
    final manager = session?.liveManager;
    if (session == null || session.hostId != hostId || manager == null) {
      _note(key, currentL10n.r7ForwardNotConnected);
      return;
    }
    _selectedSession[hostId] = session.id;
    await _startOn(key, manager, latest);
  }

  /// Drops a pending "connect and start"; the connection itself (if it
  /// completes) stays open as a normal session.
  void cancelPending(String hostId, String profileId) {
    final key = _key(hostId, profileId);
    final pending = _pending.remove(key);
    if (pending == null) return;
    pending.cancelled = true;
    _notes[key] = currentL10n.r7ForwardStartCancelled;
    _notify();
  }

  Future<void> stop(
    SshPortForwardManager manager,
    String hostId,
    String profileId,
  ) async {
    final key = _key(hostId, profileId);
    _notes.remove(key);
    _busy.add(key);
    _notify();
    try {
      await manager.stop(profileId);
    } catch (error) {
      _notes[key] = describeSshPortForwardError(error);
    } finally {
      _busy.remove(key);
      _notify();
    }
  }

  /// Stops the rule on every session of the Host and drops a pending start.
  Future<void> stopEverywhere(
    SshForwardingSource source,
    String hostId,
    String profileId,
  ) async {
    final pending = _pending.remove(_key(hostId, profileId));
    if (pending != null) {
      pending.cancelled = true;
      _notify();
    }
    await Future.wait([
      for (final session in sessionsOf(source, hostId))
        if (session.manager != null &&
            ruleIsActive(session.manager!, profileId))
          stop(session.manager!, hostId, profileId),
    ]);
  }

  Future<void> _startOn(
    String key,
    SshPortForwardManager manager,
    SshPortForwardProfile profile,
  ) async {
    _busy.add(key);
    _notify();
    try {
      await manager.start(profile);
    } catch (error) {
      // Failures recorded by the manager show on the status line; others
      // (listener conflicts, closed connection) are noted on the row.
      if (manager.statusOf(profile.id).state != SshPortForwardState.failed) {
        _notes[key] = describeSshPortForwardError(error);
      }
    } finally {
      _busy.remove(key);
      _notify();
    }
  }

  void _note(String key, String message) {
    _notes[key] = message;
    _notify();
  }

  static HostRecord? _hostOf(SshForwardingSource source, String hostId) {
    for (final host in source.hosts) {
      if (host.id == hostId && host.protocol == HostProtocol.ssh) return host;
    }
    return null;
  }

  static SshPortForwardProfile? _profileOf(HostRecord? host, String id) {
    if (host == null) return null;
    for (final profile in host.portForwardProfiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _source?.removeListener(_onSourceChanged);
    for (final pending in _pending.values) {
      pending.cancelled = true;
    }
    _pending.clear();
    super.dispose();
  }
}

/// True while [profileId] runs, starts or stops on [manager].
bool ruleIsActive(SshPortForwardManager manager, String profileId) =>
    manager.isOpen &&
    (manager.activeProfileIds.contains(profileId) ||
        manager.isStarting(profileId) ||
        manager.isStopping(profileId));

/// Home page listing every SSH Host's forwarding rules (local `-L`, remote
/// `-R`, dynamic SOCKS `-D`) with create/edit/duplicate/delete and per
/// session start/stop/status. Shared by cloud and standalone local mode.
///
/// Visiting the page never connects or starts anything.
class SshForwardingPage extends StatefulWidget {
  const SshForwardingPage({
    required this.source,
    this.controller,
    this.initialHostId,
    super.key,
  });

  final SshForwardingSource source;

  /// Shell-owned state that survives leaving the page (pending
  /// connect-and-start, chosen sessions). Created per page when omitted.
  final SshForwardingController? controller;

  /// Shows this Host first (for example when opened from a Host menu).
  final String? initialHostId;

  @override
  State<SshForwardingPage> createState() => _SshForwardingPageState();
}

class _SshForwardingPageState extends State<SshForwardingPage> {
  SshForwardingController? _ownController;
  final Set<SshPortForwardManager> _managers = {};
  final _search = TextEditingController();
  String _query = '';
  bool _showAllHosts = false;
  bool _working = false;
  String? _error;

  SshForwardingController get _controller =>
      widget.controller ?? (_ownController ??= SshForwardingController());

  SshForwardingSource get _source => widget.source;

  @override
  void initState() {
    super.initState();
    _source.addListener(_onSourceChanged);
    _controller.addListener(_onChanged);
    _controller.bindScope(_source.scopeKey);
    _bindManagers();
  }

  @override
  void didUpdateWidget(SshForwardingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      oldWidget.source.removeListener(_onSourceChanged);
      widget.source.addListener(_onSourceChanged);
    }
    final oldController = oldWidget.controller ?? _ownController;
    if (!identical(oldController, _controller)) {
      oldController?.removeListener(_onChanged);
      _controller.addListener(_onChanged);
    }
    _controller.bindScope(_source.scopeKey);
    _bindManagers();
  }

  @override
  void dispose() {
    _source.removeListener(_onSourceChanged);
    _controller.removeListener(_onChanged);
    for (final manager in _managers) {
      manager.removeListener(_onChanged);
    }
    _ownController?.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Listens to every session runtime so connection counts and failures
  /// update live; managers of ended sessions are dropped.
  void _bindManagers() {
    final next = <SshPortForwardManager>{
      for (final session in _source.sessions)
        if (session.manager != null) session.manager!,
    };
    for (final manager in _managers.difference(next)) {
      manager.removeListener(_onChanged);
    }
    for (final manager in next.difference(_managers)) {
      manager.addListener(_onChanged);
    }
    _managers
      ..clear()
      ..addAll(next);
  }

  void _onSourceChanged() {
    if (!mounted) return;
    setState(() {
      _controller.bindScope(_source.scopeKey);
      _bindManagers();
    });
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  List<HostRecord> get _sshHosts => _source.hosts
      .where((host) => host.protocol == HostProtocol.ssh)
      .toList(growable: false);

  HostRecord? _currentHost(String hostId) {
    for (final host in _sshHosts) {
      if (host.id == hostId) return host;
    }
    return null;
  }

  bool _activeAnywhere(String hostId, String profileId) {
    if (_controller.isConnecting(hostId, profileId) ||
        _controller.isBusy(hostId, profileId)) {
      return true;
    }
    for (final session in _controller.sessionsOf(_source, hostId)) {
      final manager = session.manager;
      if (manager != null && ruleIsActive(manager, profileId)) return true;
    }
    return false;
  }

  // ---- editing --------------------------------------------------------

  Future<void> _newRule() async {
    final hosts = _sshHosts;
    if (hosts.isEmpty) return;
    final host = hosts.length == 1
        ? hosts.single
        : isIosPhone(context)
        ? await showIosFormSheet<HostRecord>(
            context,
            builder: (_) => _HostPicker(hosts: hosts),
          )
        : await showAppDialog<HostRecord>(
            context: context,
            builder: (_) => _HostPicker(hosts: hosts),
          );
    if (host == null || !mounted) return;
    await _edit(host);
  }

  /// Opens the shared encrypted-profile editor for a new ([existing] and
  /// [template] null), edited, or duplicated ([template]) rule and saves the
  /// result into the Host's latest rule list.
  Future<void> _edit(
    HostRecord host, {
    SshPortForwardProfile? existing,
    SshPortForwardProfile? template,
  }) async {
    if (_working || !_source.canEdit) return;
    final l10n = context.l10n;
    if (existing != null && _activeAnywhere(host.id, existing.id)) {
      setState(() => _error = l10n.stopThisForwardBeforeEditingIts);
      return;
    }
    final current = _currentHost(host.id)?.portForwardProfiles;
    if (current == null) {
      setState(() => _error = l10n.thisHostIsNoLongerAvailable);
      return;
    }
    if (existing == null && current.length >= maxHostPortForwardProfiles) {
      setState(
        () => _error = l10n.aHostCanHaveAtMost(maxHostPortForwardProfiles),
      );
      return;
    }
    // The rule as the user sees it now; the save is a compare-and-set
    // against exactly this rule in exactly this scope.
    final scope = _source.scopeKey;
    final profile = await showAppDialog<SshPortForwardProfile>(
      context: context,
      builder: (_) => SshPortForwardProfileEditor(
        existing: existing,
        template: template,
        siblings: current.where((item) => item.id != existing?.id).toList(),
      ),
    );
    if (profile == null || !mounted) return;
    if (_source.scopeKey != scope || _currentHost(host.id) == null) {
      setState(() => _error = l10n.thisHostIsNoLongerAvailable);
      return;
    }
    if (existing != null && _activeAnywhere(host.id, existing.id)) {
      setState(() => _error = l10n.stopThisForwardBeforeEditingIts);
      return;
    }
    for (final session in _controller.sessionsOf(_source, host.id)) {
      session.manager?.clearError(profile.id);
    }
    _controller.clearNote(host.id, profile.id);
    await _save(
      host.id,
      expected: existing,
      replacement: profile,
      scope: scope,
    );
  }

  Future<void> _duplicate(HostRecord host, SshPortForwardProfile profile) {
    final name = context.l10n.r7ForwardCopyName(profile.name);
    return _edit(
      host,
      template: profile.copyWith(
        name: name.length > 64 ? name.substring(0, 64) : name,
      ),
    );
  }

  Future<void> _delete(HostRecord host, SshPortForwardProfile profile) async {
    if (_working || !_source.canEdit) return;
    // Bind the confirmation to this scope and this exact rule.
    final scope = _source.scopeKey;
    final bool? confirmed;
    if (isIosPhone(context)) {
      confirmed = await showIosDestructiveConfirm(
        context,
        title: context.l10n.r7ForwardDeleteTitle,
        message: context.l10n.r7ForwardDeleteBody(profile.name),
        action: context.l10n.delete,
        cancel: context.l10n.cancel2,
        actionKey: const ValueKey('r7fwd-delete-accept'),
      );
    } else {
      confirmed = await showAppDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          key: const ValueKey('r7fwd-delete-confirm'),
          title: Text(context.l10n.r7ForwardDeleteTitle),
          content: Text(context.l10n.r7ForwardDeleteBody(profile.name)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.l10n.cancel2),
            ),
            FilledButton(
              key: const ValueKey('r7fwd-delete-accept'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.l10n.delete),
            ),
          ],
        ),
      );
    }
    if (confirmed != true || !mounted) return;
    if (!_stillSaved(scope, host.id, profile)) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      // Never leave a listener running for a rule that no longer exists.
      await _controller.stopEverywhere(_source, host.id, profile.id);
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (!mounted || !_stillSaved(scope, host.id, profile)) return;
    await _save(host.id, expected: profile, scope: scope);
  }

  /// True while [scope] is current and the Host still saves exactly
  /// [profile]; otherwise shows why the action was dropped.
  bool _stillSaved(
    Object? scope,
    String hostId,
    SshPortForwardProfile profile,
  ) {
    final l10n = context.l10n;
    if (_source.scopeKey != scope) {
      setState(() => _error = l10n.r7ForwardScopeChanged);
      return false;
    }
    final saved = _currentHost(hostId)?.portForwardProfiles
        .where((rule) => rule.id == profile.id)
        .firstOrNull;
    if (saved != profile) {
      setState(() => _error = l10n.r7ForwardRuleConflict);
      return false;
    }
    return true;
  }

  Future<void> _save(
    String hostId, {
    SshPortForwardProfile? expected,
    SshPortForwardProfile? replacement,
    required Object? scope,
  }) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await _source.saveRule(
        hostId,
        expected: expected,
        replacement: replacement,
        scope: scope,
      );
    } on SshPortForwardRuleConflict {
      if (mounted) setState(() => _error = context.l10n.r7ForwardRuleConflict);
    } catch (error) {
      if (mounted) setState(() => _error = _source.describeSaveError(error));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  // ---- runtime --------------------------------------------------------

  Future<void> _start(HostRecord host, SshPortForwardProfile profile) async {
    setState(() => _error = null);
    // The start is bound to the rule the user saw (and approved) in this
    // scope; a rule changed meanwhile is never started blindly.
    final scope = _source.scopeKey;
    if (profile.exposesBeyondLoopback) {
      // Asked before every start, including before a new connection.
      final confirmed = await confirmSshPortForwardExposure(context, profile);
      if (!confirmed || !mounted) return;
    }
    await _controller.start(
      _source,
      host.id,
      profile.id,
      expected: profile,
      expectedScope: scope,
    );
  }

  // ---- build ----------------------------------------------------------

  bool _matches(HostRecord host) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    bool has(String value) => value.toLowerCase().contains(query);
    return has(host.name) ||
        has(host.address) ||
        has(host.username) ||
        host.portForwardProfiles.any(
          (profile) =>
              has(profile.name) ||
              has(sshPortForwardProfileDescription(profile)),
        );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hosts = _sshHosts;
    final hostIds = hosts.map((host) => host.id).toSet();
    final sessions = _source.sessions;
    var ruleCount = 0;
    var running = 0;
    for (final host in hosts) {
      ruleCount += host.portForwardProfiles.length;
    }
    for (final session in sessions) {
      final manager = session.liveManager;
      if (manager != null) running += manager.runningCount;
    }
    final searching = _query.trim().isNotEmpty;
    final visible =
        hosts
            .where(
              (host) =>
                  _matches(host) &&
                  (searching ||
                      _showAllHosts ||
                      host.portForwardProfiles.isNotEmpty ||
                      host.id == widget.initialHostId ||
                      _controller
                          .liveSessionsOf(_source, host.id)
                          .any((s) => s.liveManager!.runningCount > 0)),
            )
            .toList()
          ..sort((a, b) {
            if (a.id == widget.initialHostId) return -1;
            if (b.id == widget.initialHostId) return 1;
            final rules = (b.portForwardProfiles.isNotEmpty ? 1 : 0).compareTo(
              a.portForwardProfiles.isNotEmpty ? 1 : 0,
            );
            if (rules != 0) return rules;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
    final removedHostSessions = sessions
        .where(
          (session) =>
              !hostIds.contains(session.hostId) &&
              (session.liveManager?.activeProfiles.isNotEmpty ?? false),
        )
        .toList(growable: false);
    final supported = _controller.runtimeSupported;
    final anyDynamic = hosts.any(
      (host) => host.portForwardProfiles.any(
        (profile) => profile.type == SshPortForwardType.dynamic,
      ),
    );

    if (isIosPhone(context)) {
      return _buildIosPhone(
        context,
        hosts: hosts,
        visible: visible,
        removedHostSessions: removedHostSessions,
        supported: supported,
        anyDynamic: anyDynamic,
        searching: searching,
        ruleCount: ruleCount,
        running: running,
      );
    }

    final palette = context.palette;
    final canAddRule = !_working && _source.canEdit && hosts.isNotEmpty;
    final notices = <Widget>[
      if (!supported)
        PageNotice(
          key: const ValueKey('r7fwd-unsupported'),
          icon: Icons.block_rounded,
          tone: palette.orange,
          message:
              _controller.unsupportedReason ?? l10n.forwardRuntimeUnsupported,
        ),
      if (!_source.canEdit && _source.readOnlyReason != null)
        PageNotice(
          icon: Icons.lock_outline_rounded,
          tone: palette.muted,
          message: _source.readOnlyReason!,
        ),
      if (anyDynamic)
        PageNotice(
          icon: Icons.shield_outlined,
          tone: palette.orange,
          message: l10n.dynamicForwardingIsASocks44a,
        ),
      if (_error != null)
        PageNotice(
          key: const ValueKey('r7fwd-error'),
          icon: Icons.error_outline_rounded,
          tone: palette.red,
          message: _error!,
        ),
    ];

    return Material(
      key: const ValueKey('ssh-forwarding-page'),
      color: Colors.transparent,
      child: ListView(
        key: const ValueKey('r7fwd-list'),
        padding: AppDensity.of(context).pagePadding,
        children: [
          PageHeader(
            title: l10n.r7ForwardTitle,
            subtitle:
                '${_source.storageDescription} ${l10n.r7ForwardNoAutoStart}',
            actions: [
              FilledButton.icon(
                key: const ValueKey('r7fwd-new-rule'),
                onPressed: canAddRule ? _newRule : null,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.r7ForwardNewRule),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (hosts.isNotEmpty) ...[
            _toolbar(
              summary: l10n.r7ForwardSummary(
                ruleCount,
                hosts
                    .where((host) => host.portForwardProfiles.isNotEmpty)
                    .length,
                running,
              ),
              running: running > 0,
            ),
            const SizedBox(height: 14),
          ],
          for (final notice in notices) ...[notice, const SizedBox(height: 10)],
          if (notices.isNotEmpty) const SizedBox(height: 4),
          if (hosts.isEmpty)
            _ForwardingEmpty(
              icon: Icons.dns_outlined,
              text: l10n.r7ForwardNoHosts,
            )
          else if (visible.isEmpty && removedHostSessions.isEmpty)
            searching
                ? _ForwardingNoMatches(text: l10n.r7ForwardNoMatches)
                : _ForwardingEmpty(
                    icon: Icons.alt_route_rounded,
                    text: l10n.r7ForwardNoRules,
                    action: canAddRule
                        ? FilledButton.tonalIcon(
                            onPressed: _newRule,
                            icon: const Icon(Icons.add, size: 18),
                            label: Text(l10n.r7ForwardNewRule),
                          )
                        : null,
                  ),
          for (final host in visible) _hostCard(host, supported: supported),
          for (final session in removedHostSessions) _removedHostCard(session),
        ],
      ),
    );
  }

  /// Search, the "hosts without rules" filter and the page's counts.
  Widget _toolbar({required String summary, required bool running}) {
    final l10n = context.l10n;
    final palette = context.palette;
    final search = TextField(
      key: const ValueKey('r7fwd-search'),
      controller: _search,
      onChanged: (value) => setState(() => _query = value),
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 18),
        hintText: l10n.r7ForwardSearchHint,
      ),
    );
    final showAll = _TogglePill(
      key: const ValueKey('r7fwd-show-all'),
      label: l10n.r7ForwardShowAllHosts,
      selected: _showAllHosts,
      onChanged: (value) => setState(() => _showAllHosts = value),
    );
    final tone = running ? palette.teal : palette.muted;
    final counts = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: running
            ? palette.teal.withValues(alpha: .1)
            : palette.surfaceRaised.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: running
              ? palette.teal.withValues(alpha: .3)
              : palette.line.withValues(alpha: .7),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.swap_horiz_rounded, size: 15, color: tone),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              summary,
              key: const ValueKey('r7fwd-summary'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: running ? palette.teal : palette.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < 760) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              search,
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [showAll, counts],
              ),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: math.min(380, box.maxWidth * .4), child: search),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * .3),
              child: showAll,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: counts,
              ),
            ),
          ],
        );
      },
    );
  }

  /// A bordered card; [highlight] tints the border (a connected host).
  Widget _card({
    required Key key,
    required List<Widget> children,
    Color? highlight,
  }) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        key: key,
        color: palette.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            AppDensity.of(context).radiusLg + 2,
          ),
          side: BorderSide(
            color: highlight?.withValues(alpha: .38) ?? palette.line,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0)
                Divider(height: 1, color: palette.line.withValues(alpha: .6)),
              children[i],
            ],
          ],
        ),
      ),
    );
  }

  Widget _hostCard(HostRecord host, {required bool supported}) {
    final l10n = context.l10n;
    final palette = context.palette;
    final sessions = _controller.sessionsOf(_source, host.id);
    final live = sessions
        .where((session) => session.liveManager != null)
        .toList(growable: false);
    final connecting = sessions.any(
      (session) => session.phase == SshForwardingSessionPhase.connecting,
    );
    final target = _controller.targetSession(_source, host.id);
    final pendingAny = host.portForwardProfiles.any(
      (profile) => _controller.isConnecting(host.id, profile.id),
    );
    final (String state, Color color) = live.isEmpty
        ? (connecting || pendingAny)
              ? (l10n.r7ForwardHostConnecting, palette.orange)
              : (l10n.r7ForwardHostNotConnected, palette.muted)
        : live.length == 1
        ? (l10n.r7ForwardHostConnected, palette.teal)
        : (l10n.r7ForwardHostSessions(live.length), palette.teal);
    final savedIds = host.portForwardProfiles.map((p) => p.id).toSet();
    final orphans = [
      for (final session in live)
        for (final profile in session.liveManager!.activeProfiles)
          if (!savedIds.contains(profile.id)) (session, profile),
    ];
    final endpoint = host.username.isEmpty
        ? '${host.address}:${host.port}'
        : '${host.username}@${host.address}:${host.port}';
    final avatarTone = live.isNotEmpty
        ? palette.teal
        : (connecting || pendingAny)
        ? palette.orange
        : palette.hostBlue;

    final avatar = Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: avatarTone.withValues(alpha: .13),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(Icons.dns_outlined, size: 18, color: avatarTone),
    );
    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          host.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: palette.text,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          endpoint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            fontFamily: 'monospace',
            color: palette.muted,
          ),
        ),
      ],
    );
    final controls = <Widget>[
      _Pill(
        label: state,
        tone: color,
        textKey: ValueKey('r7fwd-host-state-${host.id}'),
      ),
      if (live.length > 1)
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: palette.surfaceRaised,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.line),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: ValueKey('r7fwd-session-select-${host.id}'),
                value: target?.id,
                isDense: true,
                isExpanded: true,
                borderRadius: BorderRadius.circular(10),
                icon: const Icon(Icons.expand_more_rounded, size: 18),
                hint: Text(
                  l10n.r7ForwardChooseSession,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: palette.orange),
                ),
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontSize: 12.5, color: palette.text),
                items: [
                  for (final session in live)
                    DropdownMenuItem(
                      value: session.id,
                      child: Text(
                        session.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (id) {
                  if (id != null) _controller.selectSession(host.id, id);
                },
              ),
            ),
          ),
        )
      else if (target != null)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal_rounded, size: 14, color: palette.hint),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                target.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ),
          ],
        ),
      if (target != null)
        TextButton.icon(
          key: ValueKey('r7fwd-open-session-${host.id}'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: () => _source.showSession(target.id),
          icon: const Icon(Icons.open_in_new_rounded, size: 16),
          label: Text(l10n.r7ForwardOpenSession),
        ),
      TextButton.icon(
        key: ValueKey('r7fwd-add-${host.id}'),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: _working || !_source.canEdit ? null : () => _edit(host),
        icon: const Icon(Icons.add, size: 16),
        label: Text(l10n.addProfile),
      ),
    ];
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: LayoutBuilder(
        builder: (context, box) {
          final wrap = Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: controls,
          );
          if (box.maxWidth >= 760) {
            return Row(
              children: [
                avatar,
                const SizedBox(width: 12),
                Expanded(child: identity),
                const SizedBox(width: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: box.maxWidth * .6),
                  child: wrap,
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  avatar,
                  const SizedBox(width: 12),
                  Expanded(child: identity),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: controls,
              ),
            ],
          );
        },
      ),
    );
    return _card(
      key: ValueKey('r7fwd-host-${host.id}'),
      highlight: live.isNotEmpty ? palette.teal : null,
      children: [
        header,
        if (host.portForwardProfiles.isEmpty && orphans.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: palette.hint),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.noForwardingProfilesSavedForThis,
                    style: TextStyle(fontSize: 12.5, color: palette.muted),
                  ),
                ),
              ],
            ),
          ),
        for (final profile in host.portForwardProfiles)
          _ruleRow(
            host,
            profile,
            live: live,
            target: target,
            connectingSession: connecting,
            supported: supported,
          ),
        for (final (session, profile) in orphans)
          _orphanRow(host.id, session, profile),
      ],
    );
  }

  Widget _ruleRow(
    HostRecord host,
    SshPortForwardProfile profile, {
    required List<SshForwardingSessionInfo> live,
    required SshForwardingSessionInfo? target,
    required bool connectingSession,
    required bool supported,
  }) {
    final l10n = context.l10n;
    final palette = context.palette;
    final id = '${host.id}-${profile.id}';
    final pending = _controller.isConnecting(host.id, profile.id);
    final busy = _controller.isBusy(host.id, profile.id);
    final manager = target?.liveManager;
    final status =
        manager?.statusOf(profile.id) ?? SshPortForwardStatus.stopped;
    final active =
        status.state == SshPortForwardState.running ||
        status.state == SshPortForwardState.starting;
    final stopping = status.state == SshPortForwardState.stopping;
    final note = _controller.noteOf(host.id, profile.id);
    final others = [
      for (final session in live)
        if (!identical(session, target) &&
            session.id != target?.id &&
            ruleIsActive(session.liveManager!, profile.id))
          session,
    ];
    final editable =
        !_working && _source.canEdit && !_activeAnywhere(host.id, profile.id);

    // What the primary button does right now.
    VoidCallback? onToggle;
    String tooltip;
    IconData icon;
    Color tone;
    if (active) {
      tooltip = l10n.stopForwarding;
      icon = Icons.stop_rounded;
      tone = palette.red;
      onToggle = busy || manager == null
          ? null
          : () => _controller.stop(manager, host.id, profile.id);
    } else if (target != null) {
      tooltip = l10n.startForwarding;
      icon = Icons.play_arrow_rounded;
      tone = palette.teal;
      onToggle = busy || stopping || pending || !supported
          ? null
          : () => _start(host, profile);
    } else {
      tooltip = live.length > 1
          ? l10n.r7ForwardChooseSession
          : connectingSession
          ? l10n.r7ForwardWaitForSession
          : l10n.r7ForwardConnectAndStart;
      icon = Icons.power_settings_new_rounded;
      tone = palette.accentText;
      onToggle =
          busy || pending || !supported || live.length > 1 || connectingSession
          ? null
          : () => _start(host, profile);
    }

    final statusLine = pending
        ? Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Pill(
                label: l10n.r7ForwardConnectingStart,
                tone: palette.orange,
                textKey: ValueKey('r7fwd-status-$id'),
              ),
              TextButton(
                key: ValueKey('r7fwd-cancel-$id'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _controller.cancelPending(host.id, profile.id),
                child: Text(l10n.cancel2),
              ),
            ],
          )
        : _statusPill(id, status);
    final extra = <Widget>[
      if (status.isRunning && status.lastConnectionError != null)
        Text(
          l10n.lastConnectionLastconnectionerror(status.lastConnectionError!),
          key: ValueKey('r7fwd-connection-error-$id'),
          style: TextStyle(color: palette.orange, fontSize: 12, height: 1.4),
        ),
      if (note != null)
        Text(
          note,
          key: ValueKey('r7fwd-note-$id'),
          style: TextStyle(color: palette.orange, fontSize: 12, height: 1.4),
        ),
      for (final session in others)
        _otherSessionLine(host.id, profile.id, session),
    ];
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (supported)
          IconButton(
            key: ValueKey('r7fwd-toggle-$id'),
            tooltip: tooltip,
            onPressed: onToggle,
            style: IconButton.styleFrom(
              foregroundColor: tone,
              backgroundColor: tone.withValues(alpha: .12),
              disabledForegroundColor: palette.hint,
              disabledBackgroundColor: palette.surfaceRaised,
            ),
            icon: Icon(icon, size: 20),
          ),
        PopupMenuButton<String>(
          key: ValueKey('r7fwd-menu-$id'),
          tooltip: l10n.r7ForwardMoreActions,
          enabled: !_working && _source.canEdit,
          icon: const Icon(Icons.more_vert_rounded, size: 20),
          onSelected: (action) {
            switch (action) {
              case 'edit':
                _edit(host, existing: profile);
              case 'duplicate':
                _duplicate(host, profile);
              case 'delete':
                _delete(host, profile);
            }
          },
          itemBuilder: (context) => [
            appMenuItem(
              context,
              key: const ValueKey('r7fwd-edit'),
              value: 'edit',
              enabled: editable,
              child: Text(l10n.editForwardingProfile),
            ),
            appMenuItem(
              context,
              key: const ValueKey('r7fwd-duplicate'),
              value: 'duplicate',
              enabled: !_working && _source.canEdit,
              child: Text(l10n.r7ForwardDuplicate),
            ),
            appMenuItem(
              context,
              key: const ValueKey('r7fwd-delete'),
              value: 'delete',
              enabled: !_working && _source.canEdit,
              child: Text(l10n.deleteForwardingProfile),
            ),
          ],
        ),
      ],
    );

    return Padding(
      key: ValueKey('r7fwd-rule-$id'),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: LayoutBuilder(
        builder: (context, box) {
          final route = _RouteText(
            profile: profile,
            activePort: status.listeningPort,
          );
          final lines = [
            for (final line in extra) ...[const SizedBox(height: 4), line],
          ];
          if (box.maxWidth >= 680) {
            return Row(
              children: [
                _TypeBadge(profile.type),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [_ruleName(profile), ..._ruleTags(profile)],
                      ),
                      const SizedBox(height: 3),
                      route,
                      ...lines,
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: box.maxWidth * .3,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: statusLine,
                  ),
                ),
                const SizedBox(width: 6),
                actions,
              ],
            );
          }
          // Narrow: the name shares its line with the buttons only, so the
          // route and the status get the full width below it.
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _TypeBadge(profile.type),
                  const SizedBox(width: 12),
                  Expanded(child: _ruleName(profile)),
                  const SizedBox(width: 6),
                  actions,
                ],
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 44, end: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: _ruleTags(profile),
                    ),
                    const SizedBox(height: 5),
                    route,
                    const SizedBox(height: 7),
                    statusLine,
                    ...lines,
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _ruleName(SshPortForwardProfile profile) => Text(
    profile.name,
    style: TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w600,
      color: context.palette.text,
    ),
  );

  /// The rule's type and, when it listens beyond loopback, an exposure tag.
  List<Widget> _ruleTags(SshPortForwardProfile profile) {
    final palette = context.palette;
    return [
      _TypeTag(profile.type),
      if (profile.exposesBeyondLoopback)
        Tooltip(
          message: context.l10n.reachableBeyondLoopback,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: palette.orange.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Icon(Icons.public, size: 13, color: palette.orange),
          ),
        ),
    ];
  }

  Widget _statusPill(String id, SshPortForwardStatus status) {
    final l10n = context.l10n;
    final palette = context.palette;
    final (String text, Color color) = switch (status.state) {
      SshPortForwardState.running => (
        l10n.forwardStatusRunning(
          status.activeConnections,
          status.totalConnections,
        ),
        palette.teal,
      ),
      SshPortForwardState.starting => (l10n.starting, palette.orange),
      SshPortForwardState.stopping => (
        l10n.forwardStatusStopping,
        palette.muted,
      ),
      SshPortForwardState.failed => (
        l10n.forwardStatusFailed(
          status.error ?? l10n.forwardStatusUnknownError,
        ),
        palette.red,
      ),
      SshPortForwardState.stopped => (l10n.forwardStatusStopped, palette.muted),
    };
    return _Pill(
      label: text,
      tone: color,
      textKey: ValueKey('r7fwd-status-$id'),
    );
  }

  Widget _otherSessionLine(
    String hostId,
    String profileId,
    SshForwardingSessionInfo session,
  ) {
    final palette = context.palette;
    final manager = session.liveManager!;
    final status = manager.statusOf(profileId);
    final stopping = status.state == SshPortForwardState.stopping;
    return Row(
      key: ValueKey('r7fwd-other-$hostId-$profileId-${session.id}'),
      children: [
        Icon(
          Icons.subdirectory_arrow_right_rounded,
          size: 14,
          color: palette.hint,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            context.l10n.r7ForwardOnSession(session.label, switch (status
                .state) {
              SshPortForwardState.running => context.l10n.forwardStatusRunning(
                status.activeConnections,
                status.totalConnections,
              ),
              SshPortForwardState.starting => context.l10n.starting,
              SshPortForwardState.stopping =>
                context.l10n.forwardStatusStopping,
              _ => context.l10n.forwardStatusStopped,
            }),
            style: TextStyle(fontSize: 12, color: palette.muted),
          ),
        ),
        IconButton(
          key: ValueKey('r7fwd-other-stop-$hostId-$profileId-${session.id}'),
          tooltip: context.l10n.stopForwarding,
          visualDensity: VisualDensity.compact,
          color: palette.red,
          onPressed: stopping || _controller.isBusy(hostId, profileId)
              ? null
              : () => _controller.stop(manager, hostId, profileId),
          icon: const Icon(Icons.stop_circle_outlined, size: 18),
        ),
      ],
    );
  }

  Widget _orphanRow(
    String hostId,
    SshForwardingSessionInfo session,
    SshPortForwardProfile profile,
  ) {
    final palette = context.palette;
    final manager = session.liveManager!;
    final status = manager.statusOf(profile.id);
    return Padding(
      key: ValueKey('r7fwd-orphan-${session.id}-${profile.id}'),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TypeBadge(profile.type),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.name,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  context.l10n
                      .sshportforwardprofiledescriptionNoLongerSavedForThis(
                        sshPortForwardProfileDescription(
                          profile,
                          activePort: status.listeningPort,
                        ),
                      ),
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: palette.orange,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(Icons.terminal_rounded, size: 13, color: palette.hint),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        session.label,
                        style: TextStyle(fontSize: 12, color: palette.muted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            key: ValueKey('r7fwd-orphan-stop-${session.id}-${profile.id}'),
            tooltip: context.l10n.stopForwarding,
            style: IconButton.styleFrom(
              foregroundColor: palette.red,
              backgroundColor: palette.red.withValues(alpha: .12),
              disabledForegroundColor: palette.hint,
              disabledBackgroundColor: palette.surfaceRaised,
            ),
            onPressed: status.state == SshPortForwardState.stopping
                ? null
                : () => _controller.stop(manager, hostId, profile.id),
            icon: const Icon(Icons.stop_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _removedHostCard(SshForwardingSessionInfo session) {
    final palette = context.palette;
    final manager = session.liveManager!;
    return _card(
      key: ValueKey('r7fwd-removed-${session.id}'),
      highlight: palette.orange,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: palette.orange.withValues(alpha: .13),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: palette.orange,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '${session.label} · ${context.l10n.r7ForwardRemovedHost}',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: palette.orange,
                  ),
                ),
              ),
            ],
          ),
        ),
        for (final profile in manager.activeProfiles)
          _orphanRow(session.hostId, session, profile),
      ],
    );
  }

  // ---- iOS Phone native layout ----------------------------------------

  Widget _buildIosPhone(
    BuildContext context, {
    required List<HostRecord> hosts,
    required List<HostRecord> visible,
    required List<SshForwardingSessionInfo> removedHostSessions,
    required bool supported,
    required bool anyDynamic,
    required bool searching,
    required int ruleCount,
    required int running,
  }) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final isSubpage = ModalRoute.of(context)?.canPop ?? false;
    final hostWithRulesCount = hosts
        .where((host) => host.portForwardProfiles.isNotEmpty)
        .length;
    final summaryLine = l10n.r7ForwardSummary(
      ruleCount,
      hostWithRulesCount,
      running,
    );

    final searchField = buildIosSearchTextField(
      context,
      key: const ValueKey('r7fwd-search'),
      controller: _search,
      placeholder: l10n.r7ForwardSearchHint,
      onChanged: (value) => setState(() => _query = value),
      onSuffixTap: () => setState(() => _query = ''),
    );

    final canAddRule = !_working && _source.canEdit && hosts.isNotEmpty;
    final trailing = IosBarButtonGroup(
      items: [
        IosBarButtonItem(
          key: const ValueKey('r7fwd-new-rule'),
          icon: IosIcons.add,
          semanticLabel: l10n.r7ForwardNewRule,
          onPressed: canAddRule ? (_) => _newRule() : null,
        ),
        IosBarButtonItem(
          key: const ValueKey('r7fwd-show-all'),
          icon: IosIcons.more,
          semanticLabel: l10n.more,
          badge: _working
              ? const Positioned.fill(
                  child: IgnorePointer(
                    child: Center(child: CupertinoActivityIndicator(radius: 8)),
                  ),
                )
              : null,
          onPressed: (anchor) => showIosPullDownMenu(
            context,
            anchor: anchor,
            sections: [
              [
                WorkspaceAction(
                  'ios_fwd_show_all_hosts',
                  l10n.r7ForwardShowAllHosts,
                  _showAllHosts ? IosIcons.check : kIosMenuNoIcon,
                  () => setState(() => _showAllHosts = !_showAllHosts),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    final slivers = <Widget>[];

    if (isSubpage) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              IosMetrics.sectionMargin,
              0,
              IosMetrics.sectionMargin,
              12,
            ),
            child: searchField,
          ),
        ),
      );
    }

    // 平台限制 / 只读提示 / 错误横幅
    final noticeChildren = <Widget>[
      if (!supported)
        IosListRow(
          leading: IosIconTile(icon: IosIcons.warning, color: c.warning),
          title: Text(
            _controller.unsupportedReason ?? l10n.forwardRuntimeUnsupported,
            key: const ValueKey('r7fwd-unsupported'),
            maxLines: 3,
          ),
        ),
      if (!_source.canEdit && _source.readOnlyReason != null)
        IosListRow(
          leading: IosIconTile(icon: IosIcons.lock, color: c.gray),
          title: Text(_source.readOnlyReason!, maxLines: 3),
        ),
      if (_error != null)
        IosListRow(
          leading: IosIconTile(icon: IosIcons.warning, color: c.destructive),
          title: Text(_error!, key: const ValueKey('r7fwd-error'), maxLines: 3),
          destructive: true,
        ),
    ];
    if (noticeChildren.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: IosListSection(
            separatorIndent: IosListSection.indentForIcon(),
            children: noticeChildren,
          ),
        ),
      );
    }

    if (hosts.isEmpty) {
      slivers.add(
        SliverIosEmptyState(
          child: IosEmptyState(
            key: const ValueKey('r7fwd-empty'),
            icon: IosIcons.hosts,
            title: l10n.r7ForwardNoHosts,
          ),
        ),
      );
    } else if (visible.isEmpty && removedHostSessions.isEmpty) {
      slivers.add(
        SliverIosEmptyState(
          child: IosEmptyState(
            key: const ValueKey('r7fwd-empty'),
            icon: IosIcons.forwarding,
            title: searching ? l10n.r7ForwardNoMatches : l10n.r7ForwardNoRules,
            message:
                '${_source.storageDescription} ${l10n.r7ForwardNoAutoStart}',
            actionLabel: !searching && canAddRule
                ? l10n.r7ForwardNewRule
                : null,
            onAction: !searching && canAddRule ? _newRule : null,
          ),
        ),
      );
    } else {
      final sections = <Widget>[
        for (var i = 0; i < visible.length; i++)
          _buildIosHostSection(
            context,
            visible[i],
            supported: supported,
            footer: i == visible.length - 1 && removedHostSessions.isEmpty
                ? '$summaryLine\n${_source.storageDescription} ${l10n.r7ForwardNoAutoStart}${anyDynamic ? '\n${l10n.dynamicForwardingIsASocks44a}' : ''}'
                : null,
          ),
        for (final session in removedHostSessions)
          _buildIosRemovedHostSection(context, session),
      ];
      slivers.add(
        SliverToBoxAdapter(
          key: const ValueKey('r7fwd-list'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 保留隐藏的统计 key 便于测试定位
              Offstage(
                child: Text(summaryLine, key: const ValueKey('r7fwd-summary')),
              ),
              ...sections,
            ],
          ),
        ),
      );
    }

    return KeyedSubtree(
      key: const ValueKey('ssh-forwarding-page'),
      child: IosLargeTitlePage(
        title: l10n.r7ForwardTitle,
        largeTitle: !isSubpage,
        showBackButton: isSubpage,
        trailing: trailing,
        searchField: isSubpage ? null : searchField,
        slivers: slivers,
      ),
    );
  }

  Widget _buildIosHostSection(
    BuildContext context,
    HostRecord host, {
    required bool supported,
    String? footer,
  }) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final sessions = _controller.sessionsOf(_source, host.id);
    final live = sessions
        .where((session) => session.liveManager != null)
        .toList(growable: false);
    final connecting = sessions.any(
      (session) => session.phase == SshForwardingSessionPhase.connecting,
    );
    final target = _controller.targetSession(_source, host.id);
    final pendingAny = host.portForwardProfiles.any(
      (profile) => _controller.isConnecting(host.id, profile.id),
    );
    final (String stateText, Color stateColor) = live.isEmpty
        ? (connecting || pendingAny)
              ? (l10n.r7ForwardHostConnecting, c.warning)
              : (l10n.r7ForwardHostNotConnected, c.secondaryLabel)
        : live.length == 1
        ? (l10n.r7ForwardHostConnected, c.online)
        : (l10n.r7ForwardHostSessions(live.length), c.online);

    final savedIds = host.portForwardProfiles.map((p) => p.id).toSet();
    final orphans = [
      for (final session in live)
        for (final profile in session.liveManager!.activeProfiles)
          if (!savedIds.contains(profile.id)) (session, profile),
    ];

    final headerTrailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (live.length > 1)
          IosPullDownButton(
            key: ValueKey('r7fwd-session-select-${host.id}'),
            sections: () => [
              [
                for (final session in live)
                  WorkspaceAction(
                    'ios_fwd_session_${session.id}',
                    session.label,
                    target?.id == session.id ? IosIcons.check : kIosMenuNoIcon,
                    () => _controller.selectSession(host.id, session.id),
                  ),
              ],
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 110),
                  child: Text(
                    target?.label ?? l10n.r7ForwardChooseSession,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: IosType.footnote.copyWith(color: c.tint),
                  ),
                ),
                const SizedBox(width: 3),
                IosChevron(
                  direction: IosChevronDirection.down,
                  size: 9,
                  color: c.tint,
                ),
              ],
            ),
          )
        else
          Text(
            stateText,
            key: ValueKey('r7fwd-host-state-${host.id}'),
            style: IosType.footnote.copyWith(color: stateColor),
          ),
        if (target != null) ...[
          const SizedBox(width: 10),
          GestureDetector(
            key: ValueKey('r7fwd-open-session-${host.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => _source.showSession(target.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: Icon(IosIcons.terminal, size: 16, color: c.tint),
            ),
          ),
        ],
      ],
    );

    final children = <Widget>[
      for (final profile in host.portForwardProfiles)
        _buildIosRuleRow(
          context,
          host,
          profile,
          live: live,
          target: target,
          connectingSession: connecting,
          supported: supported,
        ),
      for (final (session, profile) in orphans)
        _buildIosOrphanRow(context, host.id, session, profile),
      if (_source.canEdit)
        IosListActionRow(
          key: ValueKey('r7fwd-add-${host.id}'),
          label: l10n.addProfile,
          onTap: _working ? null : () => _edit(host),
        )
      else if (host.portForwardProfiles.isEmpty && orphans.isEmpty)
        IosListRow(
          title: Text(
            l10n.noForwardingProfilesSavedForThis,
            style: IosType.subheadline.copyWith(color: c.secondaryLabel),
          ),
        ),
    ];

    return IosListSection(
      key: ValueKey('r7fwd-host-${host.id}'),
      headerWidget: IosSectionHeader(host.name, trailing: headerTrailing),
      footer: footer,
      separatorIndent: IosListSection.indentForIcon(),
      children: children,
    );
  }

  Widget _buildIosRuleRow(
    BuildContext context,
    HostRecord host,
    SshPortForwardProfile profile, {
    required List<SshForwardingSessionInfo> live,
    required SshForwardingSessionInfo? target,
    required bool connectingSession,
    required bool supported,
  }) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final id = '${host.id}-${profile.id}';
    final pending = _controller.isConnecting(host.id, profile.id);
    final busy = _controller.isBusy(host.id, profile.id);
    final manager = target?.liveManager;
    final status =
        manager?.statusOf(profile.id) ?? SshPortForwardStatus.stopped;
    final active =
        status.state == SshPortForwardState.running ||
        status.state == SshPortForwardState.starting;
    final stopping = status.state == SshPortForwardState.stopping;
    final note = _controller.noteOf(host.id, profile.id);
    final others = [
      for (final session in live)
        if (!identical(session, target) &&
            session.id != target?.id &&
            ruleIsActive(session.liveManager!, profile.id))
          session,
    ];
    final editable =
        !_working && _source.canEdit && !_activeAnywhere(host.id, profile.id);

    // 规则开关回调：开启 = 启动或连接并启动；关闭 = 停止或取消待连接
    final switchValue = active || pending;
    ValueChanged<bool>? onSwitchChanged;
    if (supported && !busy && !stopping) {
      if (pending) {
        onSwitchChanged = (next) {
          if (!next) _controller.cancelPending(host.id, profile.id);
        };
      } else if (active) {
        if (manager != null) {
          onSwitchChanged = (next) {
            if (!next) _controller.stop(manager, host.id, profile.id);
          };
        }
      } else if (target != null) {
        onSwitchChanged = (next) {
          if (next) _start(host, profile);
        };
      } else if (live.length <= 1 && !connectingSession) {
        onSwitchChanged = (next) {
          if (next) _start(host, profile);
        };
      }
    }

    final (String statusLabel, Color statusColor) = pending
        ? (l10n.r7ForwardConnectingStart, c.warning)
        : switch (status.state) {
            SshPortForwardState.running => (
              l10n.forwardStatusRunning(
                status.activeConnections,
                status.totalConnections,
              ),
              c.online,
            ),
            SshPortForwardState.starting => (l10n.starting, c.warning),
            SshPortForwardState.stopping => (
              l10n.forwardStatusStopping,
              c.secondaryLabel,
            ),
            SshPortForwardState.failed => (
              l10n.forwardStatusFailed(
                status.error ?? l10n.forwardStatusUnknownError,
              ),
              c.destructive,
            ),
            SshPortForwardState.stopped => (
              l10n.forwardStatusStopped,
              c.tertiaryLabel,
            ),
          };

    void handleRowTap() {
      if (_working || !_source.canEdit) return;
      if (editable) {
        _edit(host, existing: profile);
      } else {
        IosToast.show(
          context,
          l10n.stopThisForwardBeforeEditingIts,
          kind: IosToastKind.warning,
        );
      }
    }

    Widget buildBody({required bool inPreview}) => IosPressable(
      key: inPreview ? null : ValueKey('r7fwd-rule-$id'),
      enabled: !inPreview && !_working && _source.canEdit,
      onTap: inPreview ? null : handleRowTap,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(
          IosMetrics.rowPaddingH,
          11,
          IosMetrics.rowPaddingH,
          11,
        ),
        child: Row(
          children: [
            _IosForwardTypeTile(type: profile.type),
            const SizedBox(width: IosMetrics.iconTextGap),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: IosType.body.copyWith(color: c.label),
                        ),
                      ),
                      if (profile.exposesBeyondLoopback) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.public_rounded, size: 15, color: c.warning),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sshPortForwardProfileDescription(
                      profile,
                      activePort: status.listeningPort,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: IosType.mono.copyWith(color: c.secondaryLabel),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          statusLabel,
                          key: inPreview ? null : ValueKey('r7fwd-status-$id'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: IosType.caption1.copyWith(color: statusColor),
                        ),
                      ),
                      if (pending && !inPreview) ...[
                        const SizedBox(width: 8),
                        GestureDetector(
                          key: ValueKey('r7fwd-cancel-$id'),
                          onTap: () =>
                              _controller.cancelPending(host.id, profile.id),
                          child: Text(
                            l10n.cancel2,
                            style: IosType.caption1.copyWith(
                              color: c.tint,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (status.isRunning && status.lastConnectionError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        l10n.lastConnectionLastconnectionerror(
                          status.lastConnectionError!,
                        ),
                        key: inPreview
                            ? null
                            : ValueKey('r7fwd-connection-error-$id'),
                        style: IosType.caption1.copyWith(color: c.warning),
                      ),
                    ),
                  if (note != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        note,
                        key: inPreview ? null : ValueKey('r7fwd-note-$id'),
                        style: IosType.caption1.copyWith(color: c.warning),
                      ),
                    ),
                  if (!inPreview)
                    for (final session in others)
                      _buildIosOtherSessionLine(
                        context,
                        host.id,
                        profile.id,
                        session,
                      ),
                ],
              ),
            ),
            if (supported && !inPreview) ...[
              const SizedBox(width: 10),
              if (busy || stopping)
                const Padding(
                  padding: EdgeInsets.only(right: 6),
                  child: CupertinoActivityIndicator(radius: 9),
                ),
              CupertinoSwitch(
                key: ValueKey('r7fwd-toggle-$id'),
                value: switchValue,
                activeTrackColor: c.online,
                onChanged: onSwitchChanged,
              ),
            ],
          ],
        ),
      ),
    );

    final contextActions = <Widget>[
      if (!_working && _source.canEdit) ...[
        if (editable)
          Builder(
            builder: (menuCtx) => CupertinoContextMenuAction(
              trailingIcon: IosIcons.edit,
              onPressed: () {
                Navigator.of(menuCtx).pop();
                _edit(host, existing: profile);
              },
              child: Text(l10n.editForwardingProfile),
            ),
          ),
        Builder(
          builder: (menuCtx) => CupertinoContextMenuAction(
            trailingIcon: IosIcons.copy,
            onPressed: () {
              Navigator.of(menuCtx).pop();
              _duplicate(host, profile);
            },
            child: Text(l10n.r7ForwardDuplicate),
          ),
        ),
        Builder(
          builder: (menuCtx) => CupertinoContextMenuAction(
            isDestructiveAction: true,
            trailingIcon: IosIcons.delete,
            onPressed: () {
              Navigator.of(menuCtx).pop();
              _delete(host, profile);
            },
            child: Text(l10n.deleteForwardingProfile),
          ),
        ),
      ],
    ];

    final Widget withContextMenu = contextActions.isEmpty
        ? buildBody(inPreview: false)
        : CupertinoContextMenu.builder(
            actions: contextActions,
            builder: (ctx, animation) {
              if (animation.value < CupertinoContextMenu.animationOpensAt) {
                return buildBody(inPreview: false);
              }
              final maxW = (MediaQuery.sizeOf(ctx).width - 40).clamp(
                240.0,
                360.0,
              );
              return Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: ClipRSuperellipse(
                    borderRadius: BorderRadius.circular(IosMetrics.groupRadius),
                    child: Material(
                      color: c.cell,
                      child: SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: buildBody(inPreview: true),
                      ),
                    ),
                  ),
                ),
              );
            },
          );

    return IosSwipeActionCell(
      enabled: !_working && _source.canEdit,
      trailing: [
        IosSwipeAction(
          key: ValueKey('ios_fwd_swipe_delete_$id'),
          label: l10n.delete,
          icon: IosIcons.delete,
          color: c.destructive,
          destructive: true,
          onTap: () => _delete(host, profile),
        ),
        IosSwipeAction(
          key: ValueKey('ios_fwd_swipe_duplicate_$id'),
          label: l10n.r7ForwardDuplicate,
          icon: IosIcons.copy,
          color: c.indigo,
          onTap: () => _duplicate(host, profile),
        ),
        if (editable)
          IosSwipeAction(
            key: ValueKey('ios_fwd_swipe_edit_$id'),
            label: l10n.edit,
            icon: IosIcons.edit,
            color: c.gray,
            onTap: () => _edit(host, existing: profile),
          ),
      ],
      child: withContextMenu,
    );
  }

  Widget _buildIosOtherSessionLine(
    BuildContext context,
    String hostId,
    String profileId,
    SshForwardingSessionInfo session,
  ) {
    final c = IosColors.of(context);
    final manager = session.liveManager!;
    final status = manager.statusOf(profileId);
    final stopping = status.state == SshPortForwardState.stopping;
    return Padding(
      key: ValueKey('r7fwd-other-$hostId-$profileId-${session.id}'),
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Flexible(
            child: Text(
              context.l10n.r7ForwardOnSession(
                session.label,
                switch (status.state) {
                  SshPortForwardState.running =>
                    context.l10n.forwardStatusRunning(
                      status.activeConnections,
                      status.totalConnections,
                    ),
                  SshPortForwardState.starting => context.l10n.starting,
                  SshPortForwardState.stopping =>
                    context.l10n.forwardStatusStopping,
                  _ => context.l10n.forwardStatusStopped,
                },
              ),
              style: IosType.caption1.copyWith(color: c.secondaryLabel),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            key: ValueKey('r7fwd-other-stop-$hostId-$profileId-${session.id}'),
            onTap: stopping || _controller.isBusy(hostId, profileId)
                ? null
                : () => _controller.stop(manager, hostId, profileId),
            child: Icon(
              Icons.stop_circle_rounded,
              size: 18,
              color: c.destructive,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIosOrphanRow(
    BuildContext context,
    String hostId,
    SshForwardingSessionInfo session,
    SshPortForwardProfile profile,
  ) {
    final c = IosColors.of(context);
    final manager = session.liveManager!;
    final status = manager.statusOf(profile.id);
    final stopping = status.state == SshPortForwardState.stopping;
    return IosListRow(
      key: ValueKey('r7fwd-orphan-${session.id}-${profile.id}'),
      minHeight: IosMetrics.hostRowHeight,
      leading: _IosForwardTypeTile(type: profile.type),
      title: Text(profile.name),
      subtitle: Text(
        '${context.l10n.sshportforwardprofiledescriptionNoLongerSavedForThis(sshPortForwardProfileDescription(profile, activePort: status.listeningPort))} · ${session.label}',
      ),
      trailing: CupertinoSwitch(
        key: ValueKey('r7fwd-orphan-stop-${session.id}-${profile.id}'),
        value: true,
        activeTrackColor: c.online,
        onChanged: stopping
            ? null
            : (_) => _controller.stop(manager, hostId, profile.id),
      ),
    );
  }

  Widget _buildIosRemovedHostSection(
    BuildContext context,
    SshForwardingSessionInfo session,
  ) {
    final manager = session.liveManager!;
    return IosListSection(
      key: ValueKey('r7fwd-removed-${session.id}'),
      header: '${session.label} · ${context.l10n.r7ForwardRemovedHost}',
      separatorIndent: IosListSection.indentForIcon(),
      children: [
        for (final profile in manager.activeProfiles)
          _buildIosOrphanRow(context, session.hostId, session, profile),
      ],
    );
  }
}

/// iOS 转发类型彩色连续曲率图标块（Local 蓝 `L` / Remote 橙 `R` / Dynamic 紫 `D`）。
class _IosForwardTypeTile extends StatelessWidget {
  const _IosForwardTypeTile({required this.type});

  final SshPortForwardType type;

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final (String letter, Color color) = switch (type) {
      SshPortForwardType.local => ('L', c.blue),
      SshPortForwardType.remote => ('R', c.orange),
      SshPortForwardType.dynamic => ('D', c.purple),
    };
    return IosIconTile(
      color: color,
      child: Text(
        letter,
        style: IosType.subheadline.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Identity colour of a forward type: local blue, remote orange, dynamic
/// purple (as on iOS).
Color _typeTone(BuildContext context, SshPortForwardType type) {
  final palette = context.palette;
  return switch (type) {
    SshPortForwardType.local => palette.hostBlue,
    SshPortForwardType.remote => palette.orange,
    SshPortForwardType.dynamic =>
      palette.brightness == Brightness.dark
          ? const Color(0xFFB79CF4)
          : const Color(0xFF6A45BE),
  };
}

String _typeLabel(BuildContext context, SshPortForwardType type) =>
    switch (type) {
      SshPortForwardType.local => context.l10n.localL,
      SshPortForwardType.remote => context.l10n.remoteR,
      SshPortForwardType.dynamic => context.l10n.dynamicSocksD,
    };

class _TypeBadge extends StatelessWidget {
  const _TypeBadge(this.type);

  final SshPortForwardType type;

  @override
  Widget build(BuildContext context) {
    final tone = _typeTone(context, type);
    final letter = switch (type) {
      SshPortForwardType.local => 'L',
      SshPortForwardType.remote => 'R',
      SshPortForwardType.dynamic => 'D',
    };
    return Tooltip(
      message: _typeLabel(context, type),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tone.withValues(alpha: .13),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: tone.withValues(alpha: .3)),
        ),
        child: Text(
          letter,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
            color: tone,
          ),
        ),
      ),
    );
  }
}

/// The type's name beside a rule's name ("Local (-L)").
class _TypeTag extends StatelessWidget {
  const _TypeTag(this.type);

  final SshPortForwardType type;

  @override
  Widget build(BuildContext context) {
    final tone = _typeTone(context, type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        _typeLabel(context, type),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: tone,
        ),
      ),
    );
  }
}

/// Where a rule listens and where it leads, in monospace
/// (`127.0.0.1:15432 → db.internal:5432`); the full sentence is the
/// tooltip.
class _RouteText extends StatelessWidget {
  const _RouteText({required this.profile, this.activePort});

  final SshPortForwardProfile profile;
  final int? activePort;

  @override
  Widget build(BuildContext context) {
    String endpoint(String address, String port) =>
        address.contains(':') ? '[$address]:$port' : '$address:$port';
    final port = profile.bindPort == 0
        ? activePort?.toString() ?? context.l10n.forwardingPortAuto
        : '${profile.bindPort}';
    final bind = endpoint(profile.bindAddress, port);
    final destination = profile.destinationAddress;
    final route =
        profile.type == SshPortForwardType.dynamic || destination == null
        ? bind
        : '$bind → ${endpoint(destination, '${profile.destinationPort}')}';
    return Tooltip(
      message: sshPortForwardProfileDescription(
        profile,
        activePort: activePort,
      ),
      child: Text(
        route,
        style: TextStyle(
          fontSize: 12,
          height: 1.4,
          fontFamily: 'monospace',
          color: context.palette.muted,
        ),
      ),
    );
  }
}

/// A status label in the style of the kit's status chip; a long label
/// (a failure reason) wraps instead of running out of a narrow row.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.tone, this.textKey});

  final String label;
  final Color tone;
  final Key? textKey;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: .12),
      // Round as a pill on one line; a wrapped label keeps soft corners.
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            key: textKey,
            style: TextStyle(
              fontSize: 11,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: tone,
            ),
          ),
        ),
      ],
    ),
  );
}

/// An on/off filter in the shape of the page's filter chips; unlike a chip
/// its label wraps at large text sizes instead of fading out.
class _TogglePill extends StatelessWidget {
  const _TogglePill({
    required this.label,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final foreground = selected ? palette.onAccentContainer : palette.text;
    final shape = StadiumBorder(
      side: BorderSide(
        color: selected
            ? palette.accentText.withValues(alpha: .45)
            : palette.line,
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? palette.accentContainer : palette.surfaceRaised,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onChanged(!selected),
          customBorder: shape,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 16,
                  color: selected ? foreground : palette.muted,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.3,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: foreground,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the host list when there is nothing to list.
class _ForwardingEmpty extends StatelessWidget {
  const _ForwardingEmpty({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 12),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: palette.teal.withValues(alpha: .12),
              shape: BoxShape.circle,
              border: Border.all(color: palette.teal.withValues(alpha: .25)),
            ),
            child: Icon(icon, size: 24, color: palette.teal),
          ),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Text(
              text,
              key: const ValueKey('r7fwd-empty'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                fontWeight: FontWeight.w500,
                color: palette.muted,
              ),
            ),
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}

/// One-line "nothing matches the search" row.
class _ForwardingNoMatches extends StatelessWidget {
  const _ForwardingNoMatches({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(
          AppDensity.of(context).radiusLg + 2,
        ),
        border: Border.all(color: palette.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.search_off_rounded, size: 18, color: palette.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                key: const ValueKey('r7fwd-empty'),
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HostPicker extends StatefulWidget {
  const _HostPicker({required this.hosts});

  final List<HostRecord> hosts;

  @override
  State<_HostPicker> createState() => _HostPickerState();
}

class _HostPickerState extends State<_HostPicker> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final hosts = widget.hosts
        .where(
          (host) =>
              query.isEmpty ||
              host.name.toLowerCase().contains(query) ||
              host.address.toLowerCase().contains(query),
        )
        .toList(growable: false);
    if (isIosPhone(context)) {
      final c = IosColors.of(context);
      return IosSheetScaffold(
        key: const ValueKey('r7fwd-host-picker'),
        title: context.l10n.r7ForwardChooseHost,
        cancelLabel: context.l10n.cancel2,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              IosMetrics.sectionMargin,
              0,
              IosMetrics.sectionMargin,
              16,
            ),
            child: buildIosSearchTextField(
              context,
              key: const ValueKey('r7fwd-host-picker-search'),
              controller: _search,
              autofocus: true,
              placeholder: context.l10n.r7ForwardSearchHint,
              onChanged: (value) => setState(() => _query = value),
              onSuffixTap: () => setState(() => _query = ''),
            ),
          ),
          if (hosts.isEmpty)
            IosEmptyState(
              icon: IosIcons.search,
              title: context.l10n.r7ForwardNoMatches,
            )
          else
            IosListSection(
              separatorIndent: IosListSection.indentForIcon(),
              children: [
                for (final host in hosts)
                  IosListRow(
                    key: ValueKey('r7fwd-pick-${host.id}'),
                    leading: IosIconTile(icon: IosIcons.hosts, color: c.tint),
                    title: Text(host.name),
                    subtitle: Text('${host.address}:${host.port}'),
                    monoSubtitle: true,
                    accessory: IosRowAccessory.chevron,
                    onTap: () {
                      HapticFeedback.selectionClick().catchError((Object _) {});
                      Navigator.of(context).pop(host);
                    },
                  ),
              ],
            ),
        ],
      );
    }
    return AlertDialog(
      key: const ValueKey('r7fwd-host-picker'),
      title: Text(context.l10n.r7ForwardChooseHost),
      content: SizedBox(
        width: 420,
        height: 360,
        child: Column(
          children: [
            TextField(
              key: const ValueKey('r7fwd-host-picker-search'),
              autofocus: true,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: context.l10n.r7ForwardSearchHint,
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final host in hosts)
                    ListTile(
                      key: ValueKey('r7fwd-pick-${host.id}'),
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(host.name),
                      subtitle: Text('${host.address}:${host.port}'),
                      onTap: () => Navigator.pop(context, host),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.cancel2),
        ),
      ],
    );
  }
}
