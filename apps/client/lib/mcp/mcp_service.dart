import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import 'mcp_access_policy.dart';
import 'mcp_access_policy_store.dart';
import 'mcp_listen_settings_store.dart';
import 'mcp_listener.dart';
import 'mcp_native_bridge.dart';
import 'mcp_protocol.dart';
import 'mcp_token_store.dart';
import 'mcp_workspace.dart';

export 'mcp_access_policy.dart' show McpAccessMode, mcpLocalDeviceHostId;
export 'mcp_native_bridge.dart'
    show McpNativeBridge, McpNativeGateway, mcpNativeChannelName;

/// One tool call shown to the user (settings and the AI activity panel).
/// Created when the call starts; [finish] records how it ended.
class McpAuditEntry {
  McpAuditEntry({
    required this.id,
    required this.tool,
    this.source = mcpExternalCaller,
    this.sessionId,
    this.target,
    this.summary = '',
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final int id;
  final String tool;

  /// [mcpExternalCaller] for HTTP clients, otherwise the caller ID of an
  /// in-process gateway.
  final String source;

  /// The session the call acts on, when it names one.
  final String? sessionId;

  /// Display name of the session or host the call acts on.
  final String? target;

  /// The arguments on one printable line (never file contents).
  final String summary;
  final DateTime at;
  DateTime? _finishedAt;
  bool? _success;
  String? _error, _result;

  bool get running => _success == null;
  bool get success => _success ?? false;
  DateTime? get finishedAt => _finishedAt;

  /// Tool error code of a failed call.
  String? get error => _error;

  /// Short printable outcome of a successful call (for example `exit 0`).
  String? get result => _result;
  Duration? get duration => _finishedAt?.difference(at);

  void finish(bool success, {String? error, String? result}) {
    if (!running) return;
    _success = success;
    _error = error;
    _result = result;
    _finishedAt = DateTime.now();
  }
}

/// [McpAuditEntry.source] of calls from the HTTP listener.
const mcpExternalCaller = 'external';

/// Thrown by permission setters (and by [McpService.start]) when the policy
/// for the current workspace is not loaded or could not be read.
class McpPermissionsUnavailable implements Exception {
  const McpPermissionsUnavailable();
  @override
  String toString() => 'McpPermissionsUnavailable';
}

class McpService extends ChangeNotifier {
  McpService({
    McpAccessPolicyStore? policyStore,
    McpTokenStore? tokenStore,
    McpListenSettingsStore? listenStore,
  }) : _store = policyStore ?? createMcpAccessPolicyStore(),
       _tokens = tokenStore ?? createMcpTokenStore(),
       _listen = listenStore ?? createMcpListenSettingsStore();

  static final instance = McpService();

  static const _tokenStoreTimeout = Duration(seconds: 5);

  /// Policy identity for hostless local shell/serial sessions.
  static const localDeviceHostId = mcpLocalDeviceHostId;

  final McpAccessPolicyStore _store;
  final McpTokenStore _tokens;
  final McpListenSettingsStore _listen;
  McpWorkspace? _workspace;

  /// Start MCP by itself when a workspace is unlocked and the user left it
  /// enabled on this device ([enable] without a later [disable]). Only the
  /// main window turns this on: file and detached windows are separate
  /// processes that must not compete for the port.
  bool autoStart = false;
  bool _autoStartFailed = false;

  /// MCP is enabled on this device but could not start by itself (for
  /// example the port is taken by another window). Cleared by any start.
  bool get autoStartFailed => _autoStartFailed;
  McpListener? _listener;
  McpProtocol? _protocol;

  /// [_scope]: the workspace the listener serves; [_token]: the bearer token
  /// it accepts.
  String? _scope, _token;

  /// Where the last listener started by the user listened, so the platform
  /// lifecycle can bring it back after pausing it in the background.
  ({int port, McpBind bind, String scope})? _resumable;
  int _generation = 0;
  int _nativeEpoch = 0;
  bool _starting = false;
  bool _disposed = false;
  final _audit = <McpAuditEntry>[];
  final _nativeGateways = <McpNativeGateway>{};

  // Access policy. Everything below belongs to [_policyScope]; a different
  // live workspace scope means "not loaded" and therefore denied.
  String? _policyScope;
  int _policyEpoch = 0;
  bool _policyLoading = false;
  bool _policyError = false;
  McpAccessPolicy? _committed; // last value read from / written to the store
  McpAccessPolicy? _requested; // latest user intent (what settings show)
  final _pending = <McpAccessPolicy>[]; // intents not yet persisted
  McpAccessPolicy? _floor; // restrictions whose save failed
  McpAccessPolicy? _enforced; // meet(committed, pending..., floor)
  // The bearer token of [_policyScope], loaded with its policy.
  String? _savedToken;
  bool _tokenSaved = false;
  Future<void> _storeChain = Future.value();

  bool get supported => mcpListenerSupported;

  /// 无 HTTP 端口的进程内原生 MCP 桥接能力在所有平台（含 iOS / iPadOS）均可用。
  bool get nativeBridgeSupported => true;

  bool get running => _listener != null;
  bool get starting => _starting;
  bool get workspaceReady => _workspace?.scope() != null;
  Uri? get endpoint => _listener?.endpoint;

  /// Every URL a client may use while running (several when listening on all
  /// interfaces), preferred first; empty when stopped.
  List<Uri> get endpoints => switch (_listener) {
    null => const [],
    final McpAddressedListener listener => listener.endpoints,
    final listener => [listener.endpoint],
  };

  /// Where the running (or starting) listener accepts connections.
  McpBind get bind => _bind;
  McpBind _bind = const McpBind.loopback();
  List<McpAuditEntry> get audit => List.unmodifiable(_audit.reversed);

  // ---------------------------------------------------------------------
  // Per-machine access policy.

  String? get _liveScope => _workspace?.scope();

  /// Starts (re)loading the policy when the live scope differs from the
  /// loaded one. Never notifies synchronously, so it is safe from getters
  /// used during build.
  void _syncScope() {
    if (_disposed) return;
    final scope = _liveScope;
    if (scope == _policyScope) return;
    _policyEpoch++;
    _nativeEpoch++;
    _policyScope = scope;
    _policyError = false;
    _committed = _requested = _floor = _enforced = null;
    _savedToken = null;
    _tokenSaved = false;
    _pending.clear();
    _policyLoading = scope != null;
    _protocol?.revalidate();
    _closeNativeGateways();
    if (scope != null) unawaited(_load(scope, _policyEpoch));
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final next = _storeChain.then((_) => operation());
    _storeChain = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<void> _load(String scope, int epoch) => _enqueue(() async {
    McpAccessPolicy? policy;
    try {
      policy = await _store.read(scope) ?? McpAccessPolicy();
    } catch (_) {
      policy = null;
    }
    final (token, saved) = await _loadToken(scope);
    if (_disposed || epoch != _policyEpoch) return;
    _policyLoading = false;
    _policyError = policy == null;
    _committed = _requested = policy;
    _savedToken = token;
    _tokenSaved = saved;
    _recompute();
    notifyListeners();
    if (policy != null) unawaited(_autoStartFor(scope, epoch));
  });

  /// After [scope]'s policy loaded: listen again if the user left MCP
  /// enabled. Runs outside the store chain that [start] waits for.
  Future<void> _autoStartFor(String scope, int epoch) async {
    if (!autoStart || !supported) return;
    final settings = await savedListenSettings();
    if (!settings.enabled ||
        _disposed ||
        epoch != _policyEpoch ||
        running ||
        _starting ||
        _workspace?.scope() != scope) {
      return;
    }
    try {
      await start(port: settings.port, bind: settings.bind);
    } catch (_) {
      if (_disposed || epoch != _policyEpoch) return;
      _autoStartFailed = true;
      notifyListeners();
    }
  }

  /// Port, bind address and whether MCP is enabled, as saved on this device.
  Future<McpListenSettings> savedListenSettings() async {
    try {
      return McpListenSettings.parse(
        await _listen.read().timeout(const Duration(seconds: 2)),
      );
    } catch (_) {
      return const McpListenSettings();
    }
  }

  Future<void> _saveListenSettings(McpListenSettings settings) async {
    try {
      await _listen.write(settings.encode());
    } catch (_) {
      // A device preference: MCP itself is unaffected.
    }
  }

  /// Starts MCP and keeps it enabled on this device: from now on it starts
  /// by itself whenever this or another workspace is unlocked and whenever
  /// Atermius starts, until [disable].
  Future<void> enable({
    int port = mcpDefaultPort,
    McpBind bind = const McpBind.loopback(),
  }) async {
    await start(port: port, bind: bind);
    await _saveListenSettings(
      McpListenSettings(port: port, bind: bind, enabled: true),
    );
  }

  /// Stops MCP and turns it off on this device until the next [enable].
  Future<void> disable() async {
    await stop();
    final saved = await savedListenSettings();
    if (saved.enabled) {
      await _saveListenSettings(saved.copyWith(enabled: false));
    }
  }

  /// The saved token of [scope], creating and saving one the first time.
  /// When the store cannot be read, this run uses a token of its own and
  /// leaves whatever is stored untouched.
  Future<(String?, bool)> _loadToken(String scope) async {
    if (!supported) return (null, false);
    String? stored;
    try {
      // A keyring waiting for its password must not hold up the policy.
      stored = await _tokens.read(scope).timeout(_tokenStoreTimeout);
    } catch (_) {
      return (newMcpToken(), false);
    }
    if (mcpTokenValid(stored)) return (stored, true);
    final created = newMcpToken();
    try {
      await _tokens.write(scope, created).timeout(_tokenStoreTimeout);
      return (created, true);
    } catch (_) {
      return (created, false);
    }
  }

  /// The bearer token AI clients use for the current workspace, shown in
  /// settings. It stays the same across stops, restarts and app launches and
  /// changes only through [resetToken]. Null while locked or loading.
  String? get token {
    _syncScope();
    return _policyScope != null && _policyScope == _liveScope
        ? _savedToken
        : null;
  }

  /// False when [token] could not be saved on this device (no usable secure
  /// storage): it then lasts only until the app closes.
  bool get tokenSaved => token != null && _tokenSaved;

  /// Replaces the current workspace's token. The old token stops working at
  /// once, also on a running listener, which keeps its port. Throws (and
  /// keeps the old token) when the new one cannot be saved.
  Future<void> resetToken() async {
    if (_disposed) throw StateError('MCP service disposed.');
    if (_starting) throw StateError('MCP is starting.');
    _syncScope();
    final scope = _policyScope;
    final epoch = _policyEpoch;
    if (scope == null || scope != _liveScope || _savedToken == null) {
      throw const McpPermissionsUnavailable();
    }
    final next = newMcpToken();
    var saved = true;
    try {
      await _enqueue(
        () => _tokens.write(scope, next).timeout(_tokenStoreTimeout),
      );
    } catch (_) {
      // The saved token would come back at the next launch.
      if (_tokenSaved) rethrow;
      saved = false;
    }
    if (_disposed || epoch != _policyEpoch) return;
    _savedToken = next;
    _tokenSaved = saved;
    final listener = _listener;
    if (listener != null && _scope == scope) {
      if (listener is McpRekeyableListener) {
        listener.replaceToken(next);
        _token = next;
      } else {
        final port = listener.endpoint.port;
        final bind = _bind;
        await stop();
        await start(port: port, bind: bind);
        return;
      }
    }
    notifyListeners();
  }

  void _recompute() {
    final committed = _committed;
    if (committed == null) {
      _enforced = null;
      return;
    }
    var policy = committed;
    for (final pending in _pending) {
      policy = McpAccessPolicy.meet(policy, pending);
    }
    if (_floor case final floor?) policy = McpAccessPolicy.meet(policy, floor);
    _enforced = policy;
  }

  /// The enforced policy if it belongs to the live scope, otherwise null.
  McpAccessPolicy? get _current {
    _syncScope();
    return _policyScope != null && _policyScope == _liveScope
        ? _enforced
        : null;
  }

  McpAccessPolicy? get _shown {
    _syncScope();
    return _policyScope != null && _policyScope == _liveScope
        ? _requested
        : null;
  }

  bool get permissionsLoading {
    _syncScope();
    return _policyLoading;
  }

  bool get permissionsReady => _current != null;

  /// The current scope's stored policy could not be read (or the platform
  /// has no store). Every machine is denied until [reloadPermissions]
  /// succeeds.
  bool get permissionsError {
    _syncScope();
    return _policyError;
  }

  /// True while a change is being persisted. Restrictions are already
  /// enforced; grants take effect once saved.
  bool get permissionsSaving => _pending.isNotEmpty;

  /// Default for machines without an explicit choice (as last chosen in
  /// settings). [McpAccessMode.denied] whenever the policy is unavailable.
  McpAccessMode get defaultAccess =>
      _shown?.defaultAccess ?? McpAccessMode.denied;

  /// Explicit choice for [hostId], or null when it inherits [defaultAccess].
  McpAccessMode? accessOverrideForHost(String hostId) =>
      _shown?.overrides[hostId];

  /// Access actually enforced for [hostId] right now.
  McpAccessMode effectiveAccessForHost(String hostId) =>
      _current?.effective(hostId) ?? McpAccessMode.denied;

  /// Saved machines of the live workspace that can be configured. Empty
  /// while locked or before the policy is loaded.
  List<HostRecord> get permissionHosts {
    if (_current == null) return const [];
    return _workspace!
        .hosts()
        .where((h) => h.id != mcpLocalDeviceHostId)
        .toList(growable: false);
  }

  /// Whether to offer the local-device (local shell/serial) choice.
  bool get localDeviceAccessApplicable =>
      _workspace?.localDeviceSupported() ?? false;

  Future<void> setDefaultAccess(McpAccessMode mode) =>
      _update((policy) => policy.withDefault(mode));

  /// A null [mode] removes the override so [hostId] inherits the default.
  Future<void> setHostAccess(String hostId, McpAccessMode? mode) {
    if (!mcpAccessPolicyValidHostId(hostId)) {
      return Future.error(ArgumentError.value(hostId, 'hostId'));
    }
    return _update((policy) => policy.withHost(hostId, mode));
  }

  /// Retries reading the current scope's policy after an error.
  Future<void> reloadPermissions() {
    if (_disposed) return Future.value();
    _policyScope = null;
    _syncScope();
    return _storeChain;
  }

  Future<void> _update(McpAccessPolicy Function(McpAccessPolicy) change) async {
    if (_disposed) throw StateError('MCP service disposed.');
    _syncScope();
    final scope = _policyScope;
    final epoch = _policyEpoch;
    final base = _requested;
    if (scope == null || base == null || _policyError) {
      throw const McpPermissionsUnavailable();
    }
    final next = change(base);
    if (next == base) return;
    final before = _enforced!;
    _requested = next;
    _pending.add(next);
    _recompute();
    if (before.reducedBy(_enforced!)) {
      _protocol?.revalidate();
      _revalidateNativeGateways();
    }
    notifyListeners();
    try {
      // Keyed by the captured scope, so a lock or switch while queued still
      // records the user's choice for that scope only, never another one.
      await _enqueue(() => _store.write(scope, next));
    } catch (_) {
      if (!_disposed && epoch == _policyEpoch) {
        _pending.removeWhere((p) => identical(p, next));
        final floor = _floor;
        _floor = floor == null ? next : McpAccessPolicy.meet(floor, next);
        _recompute();
        notifyListeners();
      }
      rethrow;
    }
    if (_disposed || epoch != _policyEpoch) return;
    _pending.removeWhere((p) => identical(p, next));
    _committed = next;
    // Every later intent was derived from this one, so earlier failed
    // restrictions are either included or deliberately undone by the user.
    _floor = null;
    _recompute();
    notifyListeners();
  }

  /// Compatibility alias for the former global switch: true when the
  /// default for unconfigured machines is read-write. Per-machine overrides
  /// (including denied) always take precedence.
  bool get allowOperations => defaultAccess == McpAccessMode.readWrite;

  /// Compatibility alias: sets [defaultAccess] to read-write or read-only.
  /// Never widens a machine with an explicit override.
  void setAllowOperations(bool value) => unawaited(
    setDefaultAccess(value ? McpAccessMode.readWrite : McpAccessMode.readOnly)
        .catchError((Object _) {}),
  );

  McpAccessMode _resolve(
    String? hostKey,
    int generation,
    McpWorkspace workspace,
    String scope,
  ) {
    if (_disposed ||
        generation != _generation ||
        !identical(_workspace, workspace) ||
        workspace.scope() != scope ||
        _policyScope != scope) {
      return McpAccessMode.denied;
    }
    return _enforced?.effective(hostKey) ?? McpAccessMode.denied;
  }

  int _nextAuditId = 1;

  /// Calls that have started and not finished yet, oldest first.
  List<McpAuditEntry> get activeCalls =>
      List.unmodifiable(_audit.where((entry) => entry.running));

  McpCallEnd _beginCall(
    String source,
    String tool,
    Map<String, dynamic> arguments,
  ) {
    final entry = McpAuditEntry(
      id: _nextAuditId++,
      tool: tool,
      source: source,
      sessionId: arguments['session_id'] as String?,
    );
    _audit.add(entry);
    if (_audit.length > 50) _audit.removeAt(0);
    if (!_disposed) notifyListeners();
    return (success, {error, output}) {
      entry.finish(success, error: error);
      if (!_disposed) notifyListeners();
    };
  }

  void _revalidateNativeGateways() {
    for (final gw in _nativeGateways.toList(growable: false)) {
      gw.revalidate();
    }
  }

  void _closeNativeGateways() {
    for (final gw in _nativeGateways.toList(growable: false)) {
      gw.close();
    }
    _nativeGateways.clear();
  }

  McpAccessMode _resolveNative(
    String? hostKey,
    int nativeEpoch,
    McpWorkspace workspace,
    String scope,
  ) {
    if (_disposed ||
        nativeEpoch != _nativeEpoch ||
        !identical(_workspace, workspace) ||
        workspace.scope() != scope ||
        _policyScope != scope) {
      return McpAccessMode.denied;
    }
    return _enforced?.effective(hostKey) ?? McpAccessMode.denied;
  }

  /// 创建无 HTTP 端口的进程内原生 MCP 网关，供内置 AI、Apple Intelligence 或原生插件调用。
  ///
  /// 与外部 Streamable HTTP 服务共享相同的 [McpAccessPolicy]、锁屏/切区自动撤销以及审计流水。
  McpNativeGateway createNativeGateway({String callerId = 'native'}) {
    _syncScope();
    final workspace = _workspace;
    final scope = workspace?.scope();
    final capturedEpoch = _nativeEpoch;

    bool isGatewayReady() =>
        !_disposed &&
        capturedEpoch == _nativeEpoch &&
        workspace != null &&
        scope != null &&
        identical(_workspace, workspace) &&
        workspace.scope() == scope &&
        _policyScope == scope &&
        _enforced != null;

    Future<void> prepare() async {
      if (_disposed || capturedEpoch != _nativeEpoch || scope == null) {
        throw const McpToolException(
          'workspace_changed',
          'Workspace authorization expired.',
        );
      }
      _syncScope();
      await _storeChain;
      if (_disposed ||
          capturedEpoch != _nativeEpoch ||
          !identical(_workspace, workspace) ||
          workspace?.scope() != scope) {
        throw const McpToolException(
          'workspace_changed',
          'Workspace authorization expired.',
        );
      }
      if (_policyScope != scope || _enforced == null) {
        throw const McpPermissionsUnavailable();
      }
    }

    late final McpNativeGateway gateway;
    gateway = McpNativeGateway(
      prepare,
      () => _nativeGateways.remove(gateway),
      callerId: callerId,
      boundScope: scope,
      workspace: workspace,
      isReady: isGatewayReady,
      access: (hostKey) => workspace == null || scope == null
          ? McpAccessMode.denied
          : _resolveNative(hostKey, capturedEpoch, workspace, scope),
      onCallBegin: (tool, arguments) {
        if (_disposed || capturedEpoch != _nativeEpoch) {
          return (success, {error, output}) {};
        }
        return _beginCall(callerId, tool, arguments);
      },
    );
    if (workspace != null && scope != null && !_disposed) {
      _nativeGateways.add(gateway);
    }
    return gateway;
  }

  // ---------------------------------------------------------------------
  // Lifecycle.

  void attach(McpWorkspace workspace) {
    if (identical(_workspace, workspace)) return;
    _nativeEpoch++;
    _closeNativeGateways();
    unawaited(stop());
    _workspace = workspace;
    _syncScope();
  }

  void detach(McpWorkspace workspace) {
    if (!identical(_workspace, workspace)) return;
    _nativeEpoch++;
    _closeNativeGateways();
    _workspace = null;
    unawaited(stop());
    _syncScope();
  }

  void workspaceChanged() {
    _nativeEpoch++;
    _closeNativeGateways();
    if (_scope != null && _scope != _workspace?.scope()) unawaited(stop());
    final previous = _policyScope;
    _syncScope();
    if (previous != _policyScope && !_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _policyEpoch++;
    _nativeEpoch++;
    _closeNativeGateways();
    unawaited(stop());
    super.dispose();
  }

  Future<void> start({
    int port = mcpDefaultPort,
    McpBind bind = const McpBind.loopback(),
  }) async {
    if (_disposed) throw StateError('MCP service disposed.');
    if (_starting || running) return;
    final workspace = _workspace;
    final scope = workspace?.scope();
    if (workspace == null || scope == null) {
      throw const McpToolException(
        'locked',
        'Unlock a workspace before enabling MCP.',
      );
    }
    if (!supported) {
      throw UnsupportedError('MCP listening is unavailable on this platform.');
    }
    final generation = ++_generation;
    _starting = true;
    _scope = scope;
    _bind = bind;
    if (!_disposed) notifyListeners();
    McpProtocol? protocol;
    try {
      _syncScope();
      await _storeChain;
      if (generation != _generation) return;
      if (workspace.scope() != scope) {
        throw const McpToolException(
          'workspace_changed',
          'Workspace authorization expired.',
        );
      }
      if (_policyScope != scope || _enforced == null || _savedToken == null) {
        throw const McpPermissionsUnavailable();
      }
      _token = _savedToken;
      protocol = McpProtocol(
        workspace: workspace,
        validateAccess: () {
          if (generation != _generation ||
              !identical(_workspace, workspace) ||
              workspace.scope() != scope) {
            throw const McpToolException(
              'workspace_changed',
              'Workspace authorization expired.',
            );
          }
        },
        access: (hostKey) => _resolve(hostKey, generation, workspace, scope),
        onCallBegin: (tool, arguments) {
          if (generation != _generation) {
            return (success, {error, output}) {};
          }
          return _beginCall(mcpExternalCaller, tool, arguments);
        },
      );
      _protocol = protocol;
      final listener = await startMcpListener(
        port: port,
        token: _token!,
        handler: protocol.handle,
        bind: bind,
      );
      if (generation != _generation || workspace.scope() != scope) {
        protocol.close();
        await listener.close();
        return;
      }
      _listener = listener;
      _autoStartFailed = false;
      _resumable = (
        port: port == 0 ? listener.endpoint.port : port,
        bind: bind,
        scope: scope,
      );
      if (listener is McpObservableListener) {
        unawaited(
          listener.done.then((_) {
            if (generation == _generation) unawaited(stop());
          }),
        );
      }
    } catch (_) {
      protocol?.close();
      if (generation == _generation) {
        _scope = null;
        _token = null;
        _protocol = null;
      }
      rethrow;
    } finally {
      if (generation == _generation) {
        _starting = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  /// The client configuration for [endpoint] (one of [endpoints]; the
  /// preferred one when omitted).
  String connectionConfiguration({Uri? endpoint}) {
    if (!running || _token == null) throw StateError('MCP is stopped.');
    return const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'atermius': {
          'url': (endpoint ?? this.endpoint).toString(),
          'headers': {'Authorization': 'Bearer $_token'},
        },
      },
    });
  }

  /// Starts listening again where the user last enabled MCP, after the
  /// platform lifecycle paused it in the background. Does nothing while MCP
  /// runs or when the workspace has changed since.
  Future<void> resume() async {
    final last = _resumable;
    if (_disposed || last == null || running || _starting) return;
    if (_workspace?.scope() != last.scope) return;
    await start(port: last.port, bind: last.bind);
  }

  /// Stops listening. The workspace's token stays saved and is used again by
  /// the next [start].
  Future<void> stop() async {
    ++_generation;
    _starting = false;
    _protocol?.close();
    _protocol = null;
    _scope = null;
    _token = null;
    _audit.clear();
    final listener = _listener;
    _listener = null;
    if (listener != null) await listener.close();
    if (!_disposed) notifyListeners();
  }
}
