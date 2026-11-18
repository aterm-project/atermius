import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal_view.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/gesture/gesture_detector.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';

class TerminalGestureHandler extends StatefulWidget {
  const TerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onSingleTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.readOnly = false,
  });

  final TerminalViewState terminalView;

  final TerminalController terminalController;

  final Widget? child;

  final GestureTapUpCallback? onTapUp;

  final GestureTapUpCallback? onSingleTapUp;

  final GestureTapDownCallback? onTapDown;

  final GestureTapDownCallback? onSecondaryTapDown;

  final GestureTapUpCallback? onSecondaryTapUp;

  final GestureTapDownCallback? onTertiaryTapDown;

  final GestureTapUpCallback? onTertiaryTapUp;

  final bool readOnly;

  @override
  State<TerminalGestureHandler> createState() => _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<TerminalGestureHandler> {
  TerminalViewState get terminalView => widget.terminalView;

  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  CellAnchor? _dragAnchor;
  Buffer? _dragBuffer;
  late Offset _mousePosition;
  Timer? _edgeScroll;

  LongPressStartDetails? _lastLongPressStartDetails;

  @override
  Widget build(BuildContext context) {
    return TerminalGestureDetector(
      child: widget.child,
      onTapUp: widget.onTapUp,
      onSingleTapUp: onSingleTapUp,
      onTapDown: onTapDown,
      onSecondaryTapDown: onSecondaryTapDown,
      onSecondaryTapUp: onSecondaryTapUp,
      onTertiaryTapDown: onSecondaryTapDown,
      onTertiaryTapUp: onSecondaryTapUp,
      onLongPressStart: onLongPressStart,
      onLongPressMoveUpdate: onLongPressMoveUpdate,
      onLongPressEnd: onLongPressEnd,
      onLongPressCancel: onLongPressCancel,
      onDragStart: onDragStart,
      onDragUpdate: onDragUpdate,
      onDragEnd: (_) => _endMouseDrag(),
      onDragCancel: _endMouseDrag,
      onDoubleTapDown: onDoubleTapDown,
    );
  }

  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      widget.terminalController.shouldSendPointerInput(PointerInput.tap);

  void _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap down event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // Check if the terminal should and can handle the tap up event.
    var handled = false;
    if (_shouldSendTapEvent) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
    // If the event was not handled by the terminal, use the supplied callback.
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  void onTapDown(TapDownDetails details) {
    // onTapDown is special, as it will always call the supplied callback.
    // The TerminalView depends on it to bring the terminal into focus.
    _tapDown(
      widget.onTapDown,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );
  }

  void onSingleTapUp(TapUpDetails details) {
    _tapUp(widget.onSingleTapUp, details, TerminalMouseButton.left);
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(widget.onSecondaryTapUp, details, TerminalMouseButton.right);
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.right);
  }

  void onDoubleTapDown(TapDownDetails details) {
    renderTerminal.selectWord(details.localPosition);
    final kind = details.kind;
    if (kind != null &&
        kind != PointerDeviceKind.mouse &&
        kind != PointerDeviceKind.trackpad) {
      terminalView.touchSelection?.showToolbarForSelection();
    }
  }

  void onLongPressStart(LongPressStartDetails details) {
    _lastLongPressStartDetails = details;
    // A new long press always starts a new selection, even on blank cells
    // where no word can be selected (that long press offers Paste instead).
    if (widget.terminalController.selection != null) {
      widget.terminalController.clearSelection();
    }
    renderTerminal.selectWord(details.localPosition);
    terminalView.touchSelection?.beginDrag(details.globalPosition);
  }

  void onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    final start = _lastLongPressStartDetails;
    if (start == null) return;
    renderTerminal.selectWord(start.localPosition, details.localPosition);
    terminalView.touchSelection?.updateDrag(details.globalPosition);
  }

  void onLongPressEnd(LongPressEndDetails details) {
    _lastLongPressStartDetails = null;
    terminalView.touchSelection?.endDrag(details.globalPosition);
  }

  void onLongPressCancel() {
    _lastLongPressStartDetails = null;
    terminalView.touchSelection?.cancelDrag();
  }

  void onDragStart(DragStartDetails details) {
    _endMouseDrag();
    final buffer = terminalView.widget.terminal.buffer;
    final local = renderTerminal.globalToLocal(details.globalPosition);
    _dragBuffer = buffer;
    _dragAnchor =
        buffer.createAnchorFromOffset(renderTerminal.getCellOffset(local));
    renderTerminal.selectCharacters(local);
  }

  void onDragUpdate(DragUpdateDetails details) {
    _mousePosition = details.globalPosition;
    _updateMouseSelection();
  }

  void _updateMouseSelection({bool scroll = false}) {
    final anchor = _dragAnchor;
    final position = terminalView.scrollPosition;
    if (anchor == null ||
        !anchor.attached ||
        position == null ||
        terminalView.widget.terminal.buffer != _dragBuffer ||
        widget.terminalController.selection == null) {
      _endMouseDrag();
      return;
    }
    final render = renderTerminal;
    final viewport = render.contentRect;
    if (viewport.isEmpty) {
      _endMouseDrag();
      return;
    }
    final pointer = render.globalToLocal(_mousePosition);
    final fromTop = pointer.dy - viewport.top;
    final fromBottom = viewport.bottom - pointer.dy;
    final band = math.min(render.lineHeight, viewport.height / 2);
    // Within one line of either edge, scroll faster as the pointer gets closer.
    final speed = (1 - math.min(fromTop, fromBottom) / band).clamp(0.0, 1.0);
    final step = (fromTop < fromBottom ? -1 : 1) * speed * render.lineHeight;
    final next = (position.pixels + step)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (next == position.pixels) {
      _edgeScroll?.cancel();
      _edgeScroll = null;
    } else if (scroll) {
      position.jumpTo(next);
    } else {
      _edgeScroll ??= Timer.periodic(const Duration(milliseconds: 40),
          (_) => _updateMouseSelection(scroll: true));
    }
    final lastPixel = math.max(viewport.top, viewport.bottom - 1);
    final y = pointer.dy.clamp(viewport.top, lastPixel);
    render.selectCharactersFromCell(anchor.offset, Offset(pointer.dx, y));
  }

  void _endMouseDrag() {
    _edgeScroll?.cancel();
    _edgeScroll = null;
    _dragAnchor?.dispose();
    _dragAnchor = null;
    _dragBuffer = null;
  }

  @override
  void didUpdateWidget(TerminalGestureHandler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminalController != widget.terminalController) {
      _endMouseDrag();
    }
  }

  @override
  void deactivate() {
    _endMouseDrag();
    super.deactivate();
  }
}
