import 'dart:async';
import 'dart:collection';

import 'package:xterm/xterm.dart';

import 'terminal_scrollback_tiers.dart';

/// 零堆分配精确计算 Dart UTF-16 字符串经 `utf8.encode` 编码后的字节数。
///
/// 严格对齐 RFC 3629 与 Dart `Utf8Encoder` 行为：
/// - `0x00..0x7F` -> 1 字节
/// - `0x80..0x7FF` -> 2 字节
/// - 合法 UTF-16 代理对 (`0xD800..0xDBFF` + `0xDC00..0xDFFF`) -> 4 字节
/// - 其余 BMP 码元及孤立代理（编码为 U+FFFD `EF BF BD`）-> 3 字节
int utf8EncodedLength(String text) {
  var bytes = 0;
  final length = text.length;
  for (var i = 0; i < length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit <= 0x7F) {
      bytes += 1;
    } else if (unit <= 0x7FF) {
      bytes += 2;
    } else if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < length) {
      final next = text.codeUnitAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        bytes += 4;
        i++;
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

class MirroredTerminalChunk {
  const MirroredTerminalChunk(this.sequence, this.data);
  final int sequence;
  final String data;
}

/// Retains bounded raw VT output without taking ownership of the SSH channel.
class MirroredTerminal extends Terminal {
  MirroredTerminal({
    super.maxLines,
    super.scrollback,
    super.onBell,
    super.onTitleChange,
    super.onIconChange,
    super.onOutput,
    super.onResize,
    super.platform,
    super.inputHandler,
    super.mouseHandler,
    super.onPrivateOSC,
    super.reflowEnabled,
    super.wordSeparators,
    this.maxHistoryBytes = 512 * 1024,
  }) : assert(maxHistoryBytes >= 1024);
  final int maxHistoryBytes;
  final Queue<({String data, int bytes})> _history = Queue();
  final _output = StreamController<MirroredTerminalChunk>.broadcast(sync: true);
  int _historyBytes = 0;
  int _sequence = 0;
  bool _truncated = false;
  bool _mirrorClosed = false;
  Stream<MirroredTerminalChunk> get mirroredOutput => _output.stream;
  int get sequence => _sequence;
  int get retainedBytes => _historyBytes;
  bool get historyTruncated => _truncated;
  List<String> get history =>
      _history.map((entry) => entry.data).toList(growable: false);

  @override
  void write(String data) {
    if (_mirrorClosed || data.isEmpty) return;
    // Bound each live packet as well as the replay buffer. Avoid splitting a
    // UTF-16 surrogate pair at a packet boundary.
    final hasMirrorListener = !_output.isClosed && _output.hasListener;
    for (var start = 0; start < data.length;) {
      var end = (start + 4096).clamp(0, data.length);
      if (end < data.length &&
          end > start &&
          data.codeUnitAt(end - 1) >= 0xd800 &&
          data.codeUnitAt(end - 1) <= 0xdbff) {
        end--;
      }
      final part = start == 0 && end == data.length
          ? data
          : data.substring(start, end);
      final bytes = utf8EncodedLength(part);
      _history.addLast((data: part, bytes: bytes));
      _historyBytes += bytes;
      while (_historyBytes > maxHistoryBytes && _history.isNotEmpty) {
        _historyBytes -= _history.removeFirst().bytes;
        _truncated = true;
      }
      final seq = ++_sequence;
      if (hasMirrorListener && !_output.isClosed) {
        _output.add(MirroredTerminalChunk(seq, part));
      }
      start = end;
    }
    // 整批调用一次 super.write，避免大输出块按 4KB 切片反复触发多次 notifyListeners 重绘风暴。
    super.write(data);
  }

  Future<void> closeMirror() {
    if (!_mirrorClosed) {
      _mirrorClosed = true;
      _history.clear();
      _historyBytes = 0;
      mainBuffer.clear();
      altBuffer.clear();
      // The terminal is gone for good: delete its temporary scrollback file.
      disposeTerminalScrollback(this);
      onOutput = null;
      onResize = null;
      onPrivateOSC = null;
    }
    return _output.close();
  }
}
