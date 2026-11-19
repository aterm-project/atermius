import 'dart:async';

import 'package:flutter/services.dart';

import 'mcp_access_policy.dart';
import 'mcp_protocol.dart';
import 'mcp_service.dart';
import 'mcp_tools.dart';
import 'mcp_workspace.dart';

/// 供未来内置 AI、Apple Intelligence / App Intents 与桌面宿主使用的进程内原生 MCP MethodChannel 通道名。
const String mcpNativeChannelName = 'atermius/mcp_native';

/// 无 HTTP 端口的进程内原生 MCP 网关。
///
/// 复用与外部 Streamable HTTP 服务完全一致的 [McpProtocol]、[McpAccessPolicy] 权限策略、
/// 工作区隔离（锁屏/切换自动撤销）与终端 `[MCP]` 透明审计记录。
class McpNativeGateway {
  McpNativeGateway(
    this._prepare,
    this._onClose, {
    required this.callerId,
    required String? boundScope,
    required bool Function() isReady,
    required McpWorkspace? workspace,
    required McpAccessResolver access,
    required void Function(String name, bool success) onCall,
  }) : _boundScope = boundScope,
       _isReady = isReady,
       _access = access,
       _protocol = workspace == null || boundScope == null
           ? null
           : McpProtocol(
               workspace: workspace,
               validateAccess: () {
                 if (!isReady()) {
                   throw const McpToolException(
                     'workspace_changed',
                     'Workspace authorization expired.',
                   );
                 }
               },
               access: access,
               onCall: onCall,
             );

  final String callerId;
  final String? _boundScope;
  final bool Function() _isReady;
  final Future<void> Function() _prepare;
  final McpAccessResolver _access;
  final VoidCallback? _onClose;
  final McpProtocol? _protocol;
  int _nextRpcId = 1;
  bool _closed = false;

  /// 当前网关绑定的授权工作区范围标识（未解锁时为 null）。
  String? get boundScope => _boundScope;

  /// 网关是否已关闭或被撤销。
  bool get closed => _closed;

  /// 网关是否处于可响应状态（未关闭、工作区未切换且权限策略就绪）。
  bool get ready => !_closed && _boundScope != null && _isReady();

  /// 重新校验所有在途工具调用的机器权限；权限定紧时立即中断受影响调用。
  void revalidate() {
    _protocol?.revalidate();
  }

  /// 永久关闭本网关、取消所有在途调用并解除在 [McpService] 中的注册。
  void close() {
    if (_closed) return;
    _closed = true;
    _protocol?.close();
    _onClose?.call();
  }

  /// 分发一条原生 JSON-RPC 2.0 请求（遵循 `2026-07-28` / `2025-11-25` MCP 协议规范）。
  Future<McpReply> handleJsonRpc(Map<String, dynamic> request) async {
    final rpcId = request['id'];
    if (_closed || _boundScope == null || _protocol == null) {
      return McpReply(403, {
        'jsonrpc': '2.0',
        'id': rpcId,
        'error': {
          'code': -32603,
          'message': 'Workspace authorization expired or locked.',
        },
      });
    }
    try {
      await _prepare();
    } on McpToolException catch (e) {
      return McpReply(403, {
        'jsonrpc': '2.0',
        'id': rpcId,
        'error': {'code': -32603, 'message': e.message},
      });
    } on McpPermissionsUnavailable {
      return McpReply(403, {
        'jsonrpc': '2.0',
        'id': rpcId,
        'error': {'code': -32603, 'message': 'MCP permissions are unavailable.'},
      });
    }
    if (_closed || !_isReady()) {
      return McpReply(403, {
        'jsonrpc': '2.0',
        'id': rpcId,
        'error': {
          'code': -32603,
          'message': 'Workspace authorization expired or locked.',
        },
      });
    }
    return _protocol.handle(request);
  }

  /// 获取原生 MCP 服务元信息（`server/discover`）。
  Future<Map<String, Object?>> discover() async {
    final reply = await handleJsonRpc({
      'jsonrpc': '2.0',
      'id': _nextRpcId++,
      'method': 'server/discover',
    });
    return _unwrapRpcResult(reply);
  }

  /// 列出所有对 AI 开放的只读与读写工具定义（`tools/list`）。
  Future<List<Map<String, Object?>>> listTools() async {
    final reply = await handleJsonRpc({
      'jsonrpc': '2.0',
      'id': _nextRpcId++,
      'method': 'tools/list',
    });
    final data = _unwrapRpcResult(reply);
    final rawTools = data['tools'] as List? ?? const [];
    return [for (final item in rawTools) Map<String, Object?>.from(item as Map)];
  }

  /// 调用指定工具，返回完整 MCP `tools/call` 结果负载（包含 `content` 与 `structuredContent`）。
  ///
  /// 当工作区被锁定、已撤销或 JSON-RPC 协议层拒收时抛出 [McpToolException]；
  /// 当单机权限为只读/禁止导致工具执行受拒时，按 MCP 规范返回 `isError: true` 结果。
  Future<Map<String, Object?>> callTool(
    String name, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    final reply = await handleJsonRpc({
      'jsonrpc': '2.0',
      'id': _nextRpcId++,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    });
    return _unwrapRpcResult(reply);
  }

  /// 查询某台主机在本网关下的当前生效权限模式（供原生 UI 预检查）。
  McpAccessMode effectiveAccessForHost(String? hostId) =>
      ready ? _access(hostId) : McpAccessMode.denied;

  Map<String, Object?> _unwrapRpcResult(McpReply reply) {
    final body = reply.body;
    final err = body?['error'];
    if (reply.status >= 400 || err is Map) {
      final errMap = err is Map ? err : const <Object?, Object?>{};
      final message =
          errMap['message'] as String? ?? 'Native MCP request rejected.';
      final code = reply.status == 403 ? 'workspace_locked' : 'rpc_error';
      throw McpToolException(code, message);
    }
    final result = body?['result'];
    if (result is! Map) {
      throw const McpToolException(
        'invalid_response',
        'Unexpected native MCP reply payload.',
      );
    }
    return Map<String, Object?>.from(result);
  }
}

/// 绑定 `atermius/mcp_native` [MethodChannel] 的平台原生桥接宿主。
///
/// 保持无端口监听架构（iOS / iPadOS 不开任何 HTTP 端口，严格兼容审核与沙盒规则），
/// 供 Apple Intelligence / App Intents 及桌面端原生 AI 模块安全复用受控工具能力。
class McpNativeBridge {
  McpNativeBridge({
    required this.service,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(mcpNativeChannelName);

  static McpNativeBridge? _installed;

  /// 已安装在全局 [McpService.instance] 上的桥接实例（如有）。
  static McpNativeBridge? get installed => _installed;

  /// 幂等注册原生 MCP MethodChannel 处理器。
  static McpNativeBridge install(
    McpService service, {
    MethodChannel? channel,
  }) {
    if (_installed != null && identical(_installed!.service, service)) {
      return _installed!;
    }
    _installed?.dispose();
    final bridge = McpNativeBridge(service: service, channel: channel)..bind();
    _installed = bridge;
    return bridge;
  }

  final McpService service;
  final MethodChannel _channel;
  McpNativeGateway? _gateway;
  bool _bound = false;
  bool _disposed = false;

  void bind() {
    if (_bound || _disposed) return;
    _bound = true;
    _channel.setMethodCallHandler(_handlePlatformCall);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_bound) {
      _channel.setMethodCallHandler(null);
      _bound = false;
    }
    _gateway?.close();
    _gateway = null;
    if (identical(_installed, this)) {
      _installed = null;
    }
  }

  McpNativeGateway _ensureGateway() {
    if (!service.workspaceReady) {
      throw const McpToolException(
        'locked',
        'Unlock a workspace before calling native MCP.',
      );
    }
    final existing = _gateway;
    if (existing != null && !existing.closed && existing.ready) {
      return existing;
    }
    existing?.close();
    final created = service.createNativeGateway(callerId: 'platform_channel');
    _gateway = created;
    return created;
  }

  Future<Object?> _handlePlatformCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'status':
          return <String, Object?>{
            'supported': service.nativeBridgeSupported,
            'http_supported': service.supported,
            'http_running': service.running,
            'workspace_ready': service.workspaceReady,
            'permissions_ready': service.permissionsReady,
            'default_access': service.defaultAccess.storageName,
          };
        case 'discover':
          final gw = _ensureGateway();
          return await gw.discover();
        case 'listTools':
          final gw = _ensureGateway();
          return <String, Object?>{'tools': await gw.listTools()};
        case 'callTool':
          final args = _asMap(call.arguments);
          final name = args['name'];
          if (name is! String || name.isEmpty) {
            throw PlatformException(
              code: 'invalid_arguments',
              message: 'Missing tool name.',
            );
          }
          final toolArgs = args['arguments'] == null
              ? const <String, dynamic>{}
              : _asMap(args['arguments']);
          final gw = _ensureGateway();
          return await gw.callTool(name, toolArgs);
        case 'jsonRpc':
          final request = _asMap(call.arguments);
          final gw = _ensureGateway();
          final reply = await gw.handleJsonRpc(request);
          return <String, Object?>{
            'status': reply.status,
            if (reply.body != null) 'body': reply.body,
          };
        default:
          throw MissingPluginException(
            'Unsupported native MCP method: ${call.method}',
          );
      }
    } on McpToolException catch (e) {
      throw PlatformException(code: e.code, message: e.message);
    } on McpPermissionsUnavailable catch (e) {
      throw PlatformException(
        code: 'permissions_unavailable',
        message: e.toString(),
      );
    }
  }

  Map<String, dynamic> _asMap(Object? raw) {
    if (raw == null) return const <String, dynamic>{};
    if (raw is Map) {
      return {
        for (final entry in raw.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
    }
    throw PlatformException(
      code: 'invalid_arguments',
      message: 'Expected map arguments.',
    );
  }
}
