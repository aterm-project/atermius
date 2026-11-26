import 'package:xterm/xterm.dart';

import '../console/local_console.dart';
import '../domain/models.dart';
import '../ssh/ssh_service.dart';
import 'mcp_access_policy.dart';

/// Live views, never copies of credentials or decrypted Vault records.
class McpSession {
  const McpSession({
    required this.id,
    required this.name,
    required this.kind,
    required this.state,
    required this.isAlive,
    required this.focus,
    required this.close,
    required this.input,
    this.hostId,
    this.terminal,
    this.connection,
    this.notice,
    this.isFocused,
  });
  final String id, name, kind, state;
  final String? hostId;
  final bool Function() isAlive;
  final void Function() focus;
  final Future<void> Function() close;
  final void Function(String) input;
  final Terminal? terminal;
  final SshConnection? connection;

  /// Shows a short notice in a session without a terminal (a remote
  /// desktop), so what an external AI client does to it is visible there.
  final void Function(String text)? notice;

  /// Whether this is the tab the user is looking at in Atermius.
  final bool Function()? isFocused;

  /// The policy identity this live session is authorized under. Console
  /// (local shell/serial) sessions use [mcpLocalDeviceHostId]; a remote
  /// session without a saved host, or one claiming the reserved local
  /// identity, cannot be attributed and is denied (null).
  String? get accessHostId => kind == 'console'
      ? mcpLocalDeviceHostId
      : hostId == mcpLocalDeviceHostId
      ? null
      : hostId;

  Map<String, Object?> toJson() {
    final terminal = this.terminal;
    return {
      'id': id,
      'name': name,
      'kind': kind,
      'state': state,
      if (kind != 'console' && hostId != null) 'host_id': hostId,
      'focused': isFocused?.call() ?? false,
      'terminal_available': terminal != null,
      if (terminal != null) ...{
        'columns': terminal.viewWidth,
        'rows': terminal.viewHeight,
        'alternate_screen': terminal.isUsingAltBuffer,
      },
      'ssh_exec_available': connection != null,
      'sftp_available': connection != null,
    };
  }
}

/// A host group as MCP shows it: names only, never credentials or defaults.
class McpGroup {
  const McpGroup({required this.id, required this.name, this.parentId});
  final String id, name;
  final String? parentId;
}

class McpWorkspace {
  const McpWorkspace({
    required this.scope,
    required this.describe,
    required this.hosts,
    required this.sessions,
    required this.connect,
    required this.openConsole,
    this.groups = _noGroups,
    this.localDeviceSupported = _localConsoleSupported,
  });

  /// Null while locked, retired, or not ready. Changes across Vault/profile switches.
  final String? Function() scope;
  final Map<String, Object?> Function() describe;
  final List<HostRecord> Function() hosts;
  final List<McpSession> Function() sessions;
  final Future<void> Function(HostRecord) connect;
  final Future<void> Function() openConsole;

  /// Host groups of the workspace. The tool runner shows only groups that
  /// lead to a host the caller may see.
  final List<McpGroup> Function() groups;

  /// Whether this workspace can open local shell/serial sessions, so the
  /// local-device policy choice is meaningful to show.
  final bool Function() localDeviceSupported;
}

List<McpGroup> _noGroups() => const [];

// Android has serial sessions (USB adapters) without a local shell; they
// are local-device sessions too, so the policy choice must be offered there.
bool _localConsoleSupported() =>
    localConsoleSupported || serialConsoleSupported;

/// What MCP shows of a saved host: never its credential, login or manifest.
/// [visible] tells whether another host may be named (a jump host the
/// caller cannot see is left out, not just its details).
Map<String, Object?> mcpHostMetadata(
  HostRecord host, {
  bool Function(String hostId)? visible,
}) {
  final jump = host.jumpHostId;
  final lastConnected = host.lastConnected;
  // Reported by the remote system itself: informational, untrusted text.
  final system = host.detectedOperatingSystem;
  return {
    'id': host.id,
    'name': host.name,
    'address': host.address,
    'port': host.port,
    'protocol': host.protocol.name,
    'username': host.username,
    if (host.groupId != null) 'group_id': host.groupId,
    'tags': List.of(host.tags),
    'favorite': host.isFavorite,
    if (jump != null && visible != null && visible(jump)) 'jump_host_id': jump,
    if (lastConnected != null)
      'last_connected': lastConnected.toUtc().toIso8601String(),
    if (system != null)
      'os': {
        'family': system.family.name,
        'name': system.displayName,
        if (system.distributionId != null)
          'distribution': system.distributionId,
        if (system.version != null) 'version': system.version,
      },
  };
}

/// These messages are suitable for MCP clients; arbitrary exceptions are not.
class McpToolException implements Exception {
  const McpToolException(this.code, this.message);
  final String code, message;
}

class McpCallContext {
  McpCallContext(this._validate);
  final void Function() _validate;
  final List<void Function()> _cancellations = [];
  final List<void Function()> _guards = [];
  bool _cancelled = false;
  McpToolException? _reason;
  bool get cancelled => _cancelled;
  void check() {
    if (_cancelled) {
      throw _reason ??
          const McpToolException('cancelled', 'Request cancelled.');
    }
    _validate();
    for (final guard in _guards) {
      guard();
    }
  }

  /// Adds a per-target authorization check (for example "this host is still
  /// read-write") that every later [check], including the final one before a
  /// result is released, must pass.
  void guard(void Function() guard) {
    _guards.add(guard);
    guard();
  }

  void onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _cancellations.add(callback);
    }
  }

  void cancel([McpToolException? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    for (final callback in _cancellations) {
      try {
        callback();
      } catch (_) {
        /* Continue cancelling remaining handles. */
      }
    }
    _cancellations.clear();
  }

  void finish() => _cancellations.clear();
}
