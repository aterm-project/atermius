import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../l10n/l10n.dart';
import 'responsive_layout.dart';
import 'session_workspace.dart';

/// Runtime-only text magnification, shared by a terminal and its keybar.
/// Weak terminal keys keep the scale across tab switches without retaining
/// closed sessions or changing the saved font size.
class TerminalFontZoom extends StatefulWidget {
  const TerminalFontZoom({
    super.key,
    required this.terminal,
    required this.builder,
  });

  final Terminal terminal;
  final Widget Function(BuildContext context, double scale) builder;

  static final _scales = Expando<ValueNotifier<double>>();
  static const minScale = 0.5;
  static const maxScale = 3.0;

  static bool get enabled => !kIsWeb && isTouchPlatform(defaultTargetPlatform);

  static ValueNotifier<double> scaleFor(Terminal terminal) =>
      _scales[terminal] ??= ValueNotifier(1.0);

  @override
  State<TerminalFontZoom> createState() => _TerminalFontZoomState();
}

class _TerminalFontZoomState extends State<TerminalFontZoom> {
  SessionPaneActionSlot? _paneSlot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final slot = TerminalFontZoom.enabled
        ? SessionPaneActionSlot.maybeOf(context)
        : null;
    if (identical(slot, _paneSlot)) return;
    _paneSlot?.detach(this);
    _paneSlot = slot;
    slot?.attach(this, _resetButton);
  }

  @override
  void didUpdateWidget(TerminalFontZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminal != widget.terminal) {
      _paneSlot?.attach(this, _resetButton);
    }
  }

  @override
  void dispose() {
    _paneSlot?.detach(this);
    super.dispose();
  }

  Widget _resetButton(BuildContext context) {
    final scale = TerminalFontZoom.scaleFor(widget.terminal);
    return ValueListenableBuilder<double>(
      valueListenable: scale,
      builder: (context, value, _) => ExcludeFocus(
        child: IconButton(
          key: const ValueKey('terminal-font-zoom-reset'),
          tooltip: context.l10n.resetTerminalTextScale,
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.text_fields),
          onPressed: value == 1.0
              ? null
              : () {
                  scale.value = 1.0;
                  _paneSlot?.release();
                },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!TerminalFontZoom.enabled) return widget.builder(context, 1.0);
    final scale = TerminalFontZoom.scaleFor(widget.terminal);
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        _TerminalPinchRecognizer:
            GestureRecognizerFactoryWithHandlers<_TerminalPinchRecognizer>(
              () => _TerminalPinchRecognizer(debugOwner: this),
              (recognizer) => recognizer
                ..onStart = () {
                  recognizer.startScale = scale.value;
                }
                ..onUpdate = (ratio) {
                  scale.value = (recognizer.startScale * ratio).clamp(
                    TerminalFontZoom.minScale,
                    TerminalFontZoom.maxScale,
                  );
                },
            ),
      },
      child: ValueListenableBuilder<double>(
        valueListenable: scale,
        builder: (context, value, _) => widget.builder(context, value),
      ),
    );
  }
}

/// Claims the gesture as soon as two fingers land. Single-finger gestures
/// remain available to xterm's scroll, tap and long-press recognizers. Once
/// pinching, the remaining finger stays claimed until it lifts as well.
class _TerminalPinchRecognizer extends OneSequenceGestureRecognizer {
  _TerminalPinchRecognizer({super.debugOwner})
    : super(supportedDevices: {PointerDeviceKind.touch});

  final _positions = <int, Offset>{};
  VoidCallback? onStart;
  ValueChanged<double>? onUpdate;
  double startScale = 1.0;
  double? _startDistance;
  bool _pinching = false;
  bool _scaling = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _positions[event.pointer] = event.localPosition;
    if (_positions.length == 2 && !_pinching) {
      _pinching = true;
      _scaling = true;
      _startDistance = _distance;
      resolve(GestureDisposition.accepted);
      onStart?.call();
    } else if (_pinching) {
      _scaling = false;
      resolve(GestureDisposition.accepted);
    }
  }

  double get _distance {
    final points = _positions.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _positions[event.pointer] = event.localPosition;
      if (_scaling && _positions.length == 2) {
        final initial = _startDistance;
        if (initial == null || initial < 1) {
          _startDistance = _distance;
        } else {
          onUpdate?.call(_distance / initial);
        }
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _scaling = false;
      _positions.remove(event.pointer);
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void rejectGesture(int pointer) {
    _positions.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    resolve(GestureDisposition.rejected);
    _positions.clear();
    _pinching = false;
    _scaling = false;
    _startDistance = null;
  }

  @override
  String get debugDescription => 'terminal pinch zoom';
}
