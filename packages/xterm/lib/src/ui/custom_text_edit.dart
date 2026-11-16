import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CustomTextEdit extends StatefulWidget {
  CustomTextEdit({
    super.key,
    required this.child,
    required this.onInsert,
    required this.onDelete,
    required this.onComposing,
    required this.onAction,
    required this.onKeyEvent,
    required this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    // this.initEditingState = TextEditingValue.empty,
    this.inputType = TextInputType.text,
    this.inputAction = TextInputAction.newline,
    this.keyboardAppearance = Brightness.light,
    this.deleteDetection = false,
  });

  final Widget child;

  final void Function(String) onInsert;

  final void Function() onDelete;

  final void Function(String?) onComposing;

  final void Function(TextInputAction) onAction;

  final KeyEventResult Function(FocusNode, KeyEvent) onKeyEvent;

  final FocusNode focusNode;

  final bool autofocus;

  final bool readOnly;

  final TextInputType inputType;

  final TextInputAction inputAction;

  final Brightness keyboardAppearance;

  final bool deleteDetection;

  @override
  CustomTextEditState createState() => CustomTextEditState();
}

class CustomTextEditState extends State<CustomTextEdit> with TextInputClient {
  TextInputConnection? _connection;

  @override
  void initState() {
    widget.focusNode.addListener(_onFocusChange);
    super.initState();
  }

  @override
  void didUpdateWidget(CustomTextEdit oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
    }

    if (oldWidget.deleteDetection != widget.deleteDetection) {
      _currentEditingState = _initEditingState;
      if (hasInputConnection) {
        _connection!.setEditingState(_initEditingState);
      }
    }

    if (!_shouldCreateInputConnection) {
      _closeInputConnectionIfNeeded();
    } else {
      if (oldWidget.readOnly && widget.focusNode.hasFocus) {
        _openInputConnection();
      }
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    _closeInputConnectionIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: _onKeyEvent,
      child: widget.child,
    );
  }

  bool get hasInputConnection => _connection != null && _connection!.attached;

  void requestKeyboard() {
    if (widget.focusNode.hasFocus) {
      _openInputConnection();
    } else {
      widget.focusNode.requestFocus();
    }
  }

  /// Focuses this input without showing the software keyboard. The input
  /// connection still attaches, so hardware keys and IME commits keep working
  /// and a later [requestKeyboard] only has to show the keyboard. A keyboard
  /// that is already on screen (focus moving between terminals) stays open.
  void requestFocusWithoutKeyboard() {
    if (widget.focusNode.hasFocus || !widget.focusNode.canRequestFocus) {
      return;
    }
    _focusWithoutKeyboard = View.of(context).viewInsets.bottom <= 0;
    widget.focusNode.requestFocus();
    // A request that never lands must not hide the keyboard of a later one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusWithoutKeyboard = false;
    });
  }

  bool _focusWithoutKeyboard = false;

  void closeKeyboard() {
    if (hasInputConnection) {
      _connection?.close();
    }
  }

  void setEditingState(TextEditingValue value) {
    _currentEditingState = value;
    _connection?.setEditingState(value);
  }

  /// Tells the platform where text is being entered, so that the input
  /// method places its composition and candidate windows at the cursor.
  ///
  /// [rect] is the terminal and [caretRect] the cursor cell, both in the
  /// coordinates of the view (global logical pixels).
  ///
  /// The platform is told the same way a text field tells it: the size of
  /// the editable area with the transform to its position, and the cursor as
  /// the caret and as the composing ("marked text") rectangle inside that
  /// area. Which of them a platform reads differs: Windows and Linux place
  /// the candidate window by the composing rectangle and ignore the caret
  /// rectangle, macOS and iOS use the caret rectangle. A platform that was
  /// never told the composing rectangle shows the candidates in the top left
  /// corner of the window.
  ///
  /// On the Web the browser places the candidates at the hidden input
  /// element, whose position is the transform alone. There the editable
  /// area is the rest of the cursor row, so the element sits at the cursor.
  ///
  /// The values are kept and sent again when an input connection opens. The
  /// connection itself skips values that did not change.
  void setEditableRect(Rect rect, Rect caretRect) {
    _editableRect = rect;
    _caretRect = caretRect;
    _sendEditableRect();
  }

  Rect? _editableRect;
  Rect? _caretRect;

  void _sendEditableRect() {
    final rect = _editableRect;
    final caretRect = _caretRect;
    if (rect == null || caretRect == null || !hasInputConnection) {
      return;
    }
    final area = kIsWeb
        ? Rect.fromLTRB(
            caretRect.left,
            caretRect.top,
            max(rect.right, caretRect.right),
            caretRect.bottom,
          )
        : rect;
    final connection = _connection!;
    connection.setEditableSizeAndTransform(
      area.size,
      Matrix4.translationValues(area.left, area.top, 0),
    );
    final localCaret = caretRect.shift(-area.topLeft);
    connection.setCaretRect(localCaret);
    connection.setComposingRect(localCaret);
  }

  void _onFocusChange() {
    _openOrCloseInputConnectionIfNeeded();
  }

  int _lastHardwareBackspaceMicros = 0;

  KeyEventResult _onKeyEvent(FocusNode focusNode, KeyEvent event) {
    if (_currentEditingState.composing.isCollapsed) {
      final result = widget.onKeyEvent(focusNode, event);
      if (result == KeyEventResult.handled &&
          event is! KeyUpEvent &&
          event.logicalKey == LogicalKeyboardKey.backspace) {
        _lastHardwareBackspaceMicros = DateTime.now().microsecondsSinceEpoch;
      }
      return result;
    }

    return KeyEventResult.skipRemainingHandlers;
  }

  void _openOrCloseInputConnectionIfNeeded() {
    if (widget.focusNode.hasFocus && widget.focusNode.consumeKeyboardToken()) {
      final showKeyboard = !_focusWithoutKeyboard;
      _focusWithoutKeyboard = false;
      _openInputConnection(showKeyboard: showKeyboard);
    } else if (!widget.focusNode.hasFocus) {
      _focusWithoutKeyboard = false;
      _closeInputConnectionIfNeeded();
    }
  }

  bool get _shouldCreateInputConnection => kIsWeb || !widget.readOnly;

  void _openInputConnection({bool showKeyboard = true}) {
    if (!_shouldCreateInputConnection) {
      return;
    }

    if (hasInputConnection) {
      if (showKeyboard) _connection!.show();
    } else {
      final config = TextInputConfiguration(
        // Native multi-view clients must belong to the actual hosting view.
        viewId: View.of(context).viewId,
        inputType: widget.inputType,
        inputAction: widget.inputAction,
        keyboardAppearance: widget.keyboardAppearance,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      );

      _connection = TextInput.attach(this, config);

      if (showKeyboard) _connection!.show();

      // A new connection knows nothing about the cursor position yet.
      _sendEditableRect();

      _connection!.setEditingState(_initEditingState);
    }
  }

  void _closeInputConnectionIfNeeded() {
    if (_connection != null && _connection!.attached) {
      _connection!.close();
      _connection = null;
    }
  }

  static const _sentinel = '\u200b\u200b';

  TextEditingValue get _initEditingState => widget.deleteDetection
      ? const TextEditingValue(
          text: _sentinel,
          selection: TextSelection.collapsed(offset: _sentinel.length),
        )
      : const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );

  late var _currentEditingState = _initEditingState.copyWith();

  @override
  TextEditingValue? get currentTextEditingValue {
    return _currentEditingState;
  }

  @override
  AutofillScope? get currentAutofillScope {
    return null;
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    _currentEditingState = value;

    // Get input after composing is done
    if (!_currentEditingState.composing.isCollapsed) {
      final text = _currentEditingState.text;
      final composingText = _currentEditingState.composing.textInside(text);
      widget.onComposing(composingText);
      return;
    }

    widget.onComposing(null);

    final initLen = _initEditingState.text.length;
    final currText = _currentEditingState.text;
    final stripped = widget.deleteDetection
        ? currText.replaceAll('\u200b', '')
        : currText;

    if (widget.deleteDetection && stripped.isEmpty && currText.length < initLen) {
      final nowMicros = DateTime.now().microsecondsSinceEpoch;
      final duplicateHardwareBackspace =
          nowMicros - _lastHardwareBackspaceMicros < 24000;
      if (!duplicateHardwareBackspace) {
        final deletedCount = initLen - currText.length;
        for (var i = 0; i < deletedCount; i++) {
          widget.onDelete();
        }
      }
    } else if (stripped.isNotEmpty) {
      widget.onInsert(stripped);
    }

    // Reset editing state if composing is done so subsequent Backspace taps
    // always have sentinel characters available to delete.
    if (_currentEditingState.composing.isCollapsed &&
        (_currentEditingState.text != _initEditingState.text ||
            _currentEditingState.selection != _initEditingState.selection)) {
      _currentEditingState = _initEditingState;
      _connection?.setEditingState(_initEditingState);
    }
  }

  @override
  void performAction(TextInputAction action) {
    // print('performAction $action');
    widget.onAction(action);
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {
    // print('updateFloatingCursor $point');
  }

  @override
  void showAutocorrectionPromptRect(int start, int end) {
    // print('showAutocorrectionPromptRect');
  }

  @override
  void connectionClosed() {
    final connection = _connection;
    _connection = null;
    if (connection?.attached == true) {
      connection!.connectionClosedReceived();
    }
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {
    // print('performPrivateCommand $action');
  }

  @override
  void insertTextPlaceholder(Size size) {
    // print('insertTextPlaceholder');
  }

  @override
  void removeTextPlaceholder() {
    // print('removeTextPlaceholder');
  }

  @override
  void showToolbar() {
    // print('showToolbar');
  }
}
