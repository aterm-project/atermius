import 'dart:async';

/// 两级自适应终端输出合批器（零延迟微任务聚批 + 高吞吐帧级节流）。
///
/// 在商业服务器运维场景下，远端常出现 `kubectl logs -f`、`dmesg`、`find /` 或
/// `cat` 大日志等瞬时洪流（单帧数百个小 SSH 包）。若每包同步触发 `Terminal.write`，
/// 会引起数百次 `ChangeNotifier` 与终端重绘风暴。
///
/// 两级策略：
/// 1. **Stage 1（交互直通与微任务聚批，0ms 延迟）**：
///    - 空闲窗口首包（`<= immediatePassThroughMaxChars`）立即同步送达，确保按键回显零延迟；
///    - 同一帧窗口内累计输出尚未超过 [microtaskBudgetChars] 时，同事件轮内的连续小包
///      通过 `scheduleMicrotask` 归并成单次刷屏（例如 60 行短输出 + 全屏切换序列合并为 1 批，
///      不引入定时器延迟）；
/// 2. **Stage 2（洪流帧级节流）**：
///    - 一旦单帧窗口内持续吞吐超过 [microtaskBudgetChars]，自动切换为 [burstWindow]
///      （默认 8ms，对齐 120Hz ProMotion）帧级合批，单批严格封顶 [maxBatchChars] 并
///      保护 UTF-16 代理对不被批次边界腰斩，避免 UI 主线程在数十 MB/s 日志洪流下卡死。
class TerminalOutputCoalescer {
  TerminalOutputCoalescer({
    required this.onFlush,
    this.burstWindow = const Duration(milliseconds: 8),
    this.maxBatchChars = 64 * 1024,
    this.microtaskBudgetChars = 16 * 1024,
    this.immediatePassThroughMaxChars = 2048,
    DateTime Function()? now,
  }) : assert(maxBatchChars >= 1024),
       assert(microtaskBudgetChars >= 0),
       assert(immediatePassThroughMaxChars >= 0),
       _now = now ?? DateTime.now;

  final void Function(String batch) onFlush;

  /// 洪流态帧级合批窗口（默认 8ms，契合 120Hz ProMotion 单帧节奏）。
  final Duration burstWindow;

  /// 单次冲刷允许输出的最大字符数，防止极端洪流下缓冲区与单次解析无限膨胀。
  final int maxBatchChars;

  /// 单个 [burstWindow] 内允许零延迟微任务冲刷的字符预算；超出后切入帧级定时器节流。
  final int microtaskBudgetChars;

  /// 空闲窗口首包可立即同步直通的字符上限。
  final int immediatePassThroughMaxChars;

  final DateTime Function() _now;
  final StringBuffer _buffer = StringBuffer();
  Timer? _timer;
  bool _microtaskScheduled = false;
  DateTime? _windowStart;
  int _windowFlushedChars = 0;
  bool _closed = false;

  int _inputChunks = 0;
  int _flushedBatches = 0;
  int _coalescedChunks = 0;
  int _totalChars = 0;

  int get inputChunks => _inputChunks;
  int get flushedBatches => _flushedBatches;
  int get coalescedChunks => _coalescedChunks;
  int get totalChars => _totalChars;
  int get pendingChars => _buffer.length;
  bool get isClosed => _closed;

  void _refreshWindow(DateTime now) {
    final start = _windowStart;
    if (start == null) {
      _windowStart = now;
      _windowFlushedChars = 0;
      return;
    }
    final elapsed = now.difference(start);
    if (elapsed.isNegative || elapsed >= burstWindow) {
      _windowStart = now;
      _windowFlushedChars = 0;
    }
  }

  static bool _isHighSurrogate(int codeUnit) =>
      codeUnit >= 0xD800 && codeUnit <= 0xDBFF;

  void _emitBatch(String batch) {
    if (batch.isEmpty) return;
    final now = _now();
    _refreshWindow(now);
    _windowFlushedChars += batch.length;
    _flushedBatches++;
    onFlush(batch);
  }

  /// 推入一段来自 SSH / Telnet / 本机终端的新输出。
  void add(String data) {
    if (_closed || data.isEmpty) return;
    _inputChunks++;
    _totalChars += data.length;

    final now = _now();
    _refreshWindow(now);

    final isIdle =
        _buffer.isEmpty &&
        _timer == null &&
        !_microtaskScheduled &&
        _windowFlushedChars == 0;

    if (isIdle && data.length <= immediatePassThroughMaxChars) {
      if (_isHighSurrogate(data.codeUnitAt(data.length - 1))) {
        // 避免闲时直通把末尾孤立高代理提前切出，留待下一包低代理拼合。
        if (data.length > 1) {
          _emitBatch(data.substring(0, data.length - 1));
          if (_closed) return;
          _buffer.writeCharCode(data.codeUnitAt(data.length - 1));
        } else {
          _coalescedChunks++;
          _buffer.write(data);
        }
        _scheduleFrameTimer();
        return;
      }
      _emitBatch(data);
      return;
    }

    _coalescedChunks++;
    _buffer.write(data);
    if (_buffer.length >= maxBatchChars) {
      _drainFullBatches();
    } else if (_windowFlushedChars < microtaskBudgetChars &&
        _timer == null) {
      // Stage 1: 同事件轮连续短输出经微任务零延迟聚批。
      if (!_microtaskScheduled) {
        _microtaskScheduled = true;
        scheduleMicrotask(_onMicrotaskFlush);
      }
    } else {
      // Stage 2: 持续高吞吐洪流切换为帧级定时器节流。
      _scheduleFrameTimer();
    }
  }

  void _onMicrotaskFlush() {
    _microtaskScheduled = false;
    if (_closed || _buffer.isEmpty) return;
    _drain(
      preserveTrailingHighSurrogate: true,
      respectBatchCap: true,
      allowEmitLoneSurrogate: false,
    );
  }

  void _scheduleFrameTimer() {
    if (_closed || _timer != null) return;
    _timer = Timer(burstWindow, () {
      _timer = null;
      if (_closed || _buffer.isEmpty) return;
      // 完整帧窗口到期后，若缓冲里仍只有孤立高代理则放行，避免坏序列永久滞留。
      _drain(
        preserveTrailingHighSurrogate: true,
        respectBatchCap: true,
        allowEmitLoneSurrogate: true,
      );
    });
  }

  /// 立即冲刷当前缓冲区内全部待渲染文本。
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_closed || _buffer.isEmpty) return;
    _drain(
      preserveTrailingHighSurrogate: false,
      respectBatchCap: false,
      allowEmitLoneSurrogate: true,
    );
  }

  /// 当单次或累积推入超出 [maxBatchChars] 时，用线性游标顺序切出全部满批，
  /// 避免大块洪流下每包只消费 1 批导致缓冲区净增长与 O(N²) 复制。
  void _drainFullBatches() {
    if (_closed || _buffer.isEmpty) return;
    final raw = _buffer.toString();
    _buffer.clear();

    var offset = 0;
    while (!_closed && raw.length - offset >= maxBatchChars) {
      var end = offset + maxBatchChars;
      if (_isHighSurrogate(raw.codeUnitAt(end - 1)) && end - offset > 1) {
        end--;
      }
      final batch = raw.substring(offset, end);
      offset = end;
      _emitBatch(batch);
    }

    if (!_closed && offset < raw.length) {
      _buffer.write(raw.substring(offset));
      _scheduleFrameTimer();
    }
  }

  void _drain({
    required bool preserveTrailingHighSurrogate,
    required bool respectBatchCap,
    required bool allowEmitLoneSurrogate,
  }) {
    if (_buffer.isEmpty) return;
    final raw = _buffer.toString();
    _buffer.clear();

    var splitAt = raw.length;
    if (respectBatchCap && splitAt > maxBatchChars) {
      splitAt = maxBatchChars;
    }

    // 边界切分时若末尾恰好落在一个高代理码元上，留给下一批与低代理拼合。
    if (preserveTrailingHighSurrogate &&
        splitAt >= 1 &&
        _isHighSurrogate(raw.codeUnitAt(splitAt - 1))) {
      if (splitAt > 1 || !allowEmitLoneSurrogate) {
        splitAt--;
      }
    }

    final batch = splitAt == 0
        ? ''
        : splitAt == raw.length
        ? raw
        : raw.substring(0, splitAt);
    if (splitAt < raw.length) {
      _buffer.write(raw.substring(splitAt));
    }

    if (batch.isNotEmpty) {
      _emitBatch(batch);
    }

    if (_buffer.isNotEmpty && !_closed) {
      _scheduleFrameTimer();
    }
  }

  /// 关闭合批器并释放定时器；默认先将剩余输出全部冲刷以免丢失断线前最后几行日志。
  void close({bool flushPending = true}) {
    if (_closed) return;
    // 先置关闭态再冲刷，防止 onFlush 回调重入 add()/close() 泄漏新定时器。
    _closed = true;
    _timer?.cancel();
    _timer = null;
    if (flushPending && _buffer.isNotEmpty) {
      final remaining = _buffer.toString();
      _buffer.clear();
      _emitBatch(remaining);
    } else {
      _buffer.clear();
    }
  }
}
