import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/src/socket/ssh_socket.dart';

Future<SSHSocket> connectNativeSocket(
  String host,
  int port, {
  Duration? timeout,
}) async {
  final socket = await Socket.connect(host, port, timeout: timeout);
  try {
    // 禁用 Nagle 算法，消除交互式 SSH 终端（vim/tmux/htop）按键回显的 40~200ms 合并延迟。
    socket.setOption(SocketOption.tcpNoDelay, true);
  } catch (_) {
    // 部分受限平台或自定义 socket 实现可能不支持该选项，忽略而不影响建连。
  }
  return _SSHNativeSocket._(socket);
}

class _SSHNativeSocket implements SSHSocket {
  final Socket _socket;

  _SSHNativeSocket._(this._socket);

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> close() async {
    await _socket.close();
  }

  @override
  Future<void> get done => _socket.done;

  @override
  void destroy() {
    _socket.destroy();
  }

  @override
  Future<void> flush() async {
    await _socket.flush();
  }

  @override
  String toString() {
    final address = '${_socket.remoteAddress.host}:${_socket.remotePort}';
    return '_SSHNativeSocket($address)';
  }
}
