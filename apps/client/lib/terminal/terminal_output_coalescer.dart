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
      _windowFlushedChars += data.length;
      _flushedBatches++;
      onFlush(data);
      return;
    }

    _coalescedChunks++;
    _buffer.write(data);
    if (_buffer.length >= maxBatchChars) {
      _drain(preserveTrailingHighSurrogate: true, respectBatchCap: true);
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
    _drain(preserveTrailingHighSurrogate: true, respectBatchCap: true);
  }

  void _scheduleFrameTimer() {
    if (_closed || _timer != null) return;
    _timer = Timer(burstWindow, () {
      _timer = null;
      if (_closed || _buffer.isEmpty) return;
      _drain(preserveTrailingHighSurrogate: true, respectBatchCap: true);
    });
  }

  /// 立即冲刷当前缓冲区内全部待渲染文本。
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_closed || _buffer.isEmpty) return;
    _drain(preserveTrailingHighSurrogate: false, respectBatchCap: false);
  }

  void _drain({
    required bool preserveTrailingHighSurrogate,
    required bool respectBatchCap,
  }) {
    if (_buffer.isEmpty) return;
    final raw = _buffer.toString();
    _buffer.clear();

    var splitAt = raw.length;
    if (respectBatchCap && splitAt > maxBatchChars) {
      splitAt = maxBatchChars;
    }

    // 边界切分时若末尾恰好落在一个高代理码元上，留给下一批与低代理拼合。
    if (preserveTrailingHighSurrogate && splitAt > 1) {
      final lastUnit = raw.codeUnitAt(splitAt - 1);
      if (lastUnit >= 0xD800 && lastUnit <= 0xDBFF) {
        splitAt--;
      }
    }

    final batch = splitAt == raw.length ? raw : raw.substring(0, splitAt);
    if (splitAt < raw.length) {
      _buffer.write(raw.substring(splitAt));
    }

    if (batch.isNotEmpty) {
      final now = _now();
      _refreshWindow(now);
      _windowFlushedChars += batch.length;
      _flushedBatches++;
      onFlush(batch);
    }

    if (_buffer.isNotEmpty && !_closed) {
      _scheduleFrameTimer();
    }
  }

  /// 关闭合批器并释放定时器；默认先将剩余输出全部冲刷以免丢失断线前最后几行日志。
  void close({bool flushPending = true}) {
    if (_closed) return;
    _timer?.cancel();
    _timer = null;
    if (flushPending && _buffer.isNotEmpty) {
      _drain(preserveTrailingHighSurrogate: false, respectBatchCap: false);
    } else {
      _buffer.clear();
    }
    _closed = true;
  }
}
