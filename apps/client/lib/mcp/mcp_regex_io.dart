import 'dart:async';
import 'dart:isolate';

import 'mcp_regex.dart';

Future<McpRegexEngine> startRegexEngine(
  String pattern,
  bool caseSensitive,
) async {
  final replies = ReceivePort();
  try {
    final isolate = await Isolate.spawn(
      _serve,
      [replies.sendPort, pattern, caseSensitive],
      onExit: replies.sendPort,
      debugName: 'mcp-regex',
    );
    final engine = _IsolateRegexEngine(isolate, replies);
    await engine._ready.future;
    return engine;
  } catch (_) {
    replies.close();
    rethrow;
  }
}

void _serve(List<Object?> init) {
  final replies = init[0]! as SendPort;
  final regex = RegExp(init[1]! as String, caseSensitive: init[2]! as bool);
  final requests = ReceivePort();
  replies.send(requests.sendPort);
  requests.listen((message) {
    final request = message as List;
    replies.send(
      mcpNewestRegexHits(
        regex,
        (request[0] as List).cast<String>(),
        request[1] as int,
      ),
    );
  });
}

class _IsolateRegexEngine implements McpRegexEngine {
  _IsolateRegexEngine(this._isolate, this._replies) {
    _replies.listen((message) {
      if (message is SendPort) {
        _requests = message;
        if (!_ready.isCompleted) _ready.complete();
        return;
      }
      final pending = _pending;
      _pending = null;
      if (message is List) {
        pending?.complete(message.cast<int>());
      } else {
        // The worker exited (null from onExit) or failed.
        if (!_ready.isCompleted) _ready.completeError(StateError('exited'));
        pending?.completeError(StateError('Regular expression worker exited.'));
        close();
      }
    });
  }

  final Isolate _isolate;
  final ReceivePort _replies;
  final _ready = Completer<void>();
  SendPort? _requests;
  Completer<List<int>>? _pending;
  bool _closed = false;

  @override
  Future<List<int>> newest(
    List<String> lines,
    int max,
    Duration timeout,
  ) async {
    final requests = _requests;
    if (_closed || requests == null || _pending != null) {
      throw StateError('Regular expression worker is not available.');
    }
    final pending = _pending = Completer<List<int>>();
    requests.send([lines, max]);
    try {
      return await pending.future.timeout(timeout);
    } on TimeoutException {
      close();
      rethrow;
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.future.ignore();
      pending.completeError(StateError('Regular expression worker closed.'));
    }
  }
}
