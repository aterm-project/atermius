import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/quick_connect.dart';
import '../domain/models.dart';
import 'app_motion.dart';
import '../l10n/l10n.dart';

Future<HostRecord?> chooseQuickConnectHost(
  BuildContext context,
  List<HostRecord> matches,
) async {
  if (matches.length == 1) return matches.single;
  return showAppDialog<HostRecord>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(context.l10n.chooseAHostToConnectTo),
      children: [
        for (final host in matches)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, host),
            child: Text(
              '${host.name}\n${host.username}@${host.address}:${host.port}',
            ),
          ),
      ],
    ),
  );
}

class HostSearchField extends StatefulWidget {
  const HostSearchField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.onChanged,
    required this.onConnect,
    this.enabled = true,
    this.autofocus = false,
    this.onSearchSubmitted,
    this.captureTyping = false,
    this.active = true,
  });
  final Key fieldKey;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<QuickConnectRequest> onConnect;
  final bool enabled;
  final bool autofocus;
  final VoidCallback? onSearchSubmitted;

  /// Home page behaviour. The field takes the focus when its page is shown
  /// (on platforms that normally have a hardware keyboard; on phones and
  /// tablets that would raise the on-screen keyboard on every visit), and
  /// text typed while nothing else is being edited goes into the field, so
  /// typing anywhere on the page starts a search.
  ///
  /// With this set, Enter in an empty field does nothing instead of calling
  /// [onSearchSubmitted]: the field is focused by default, and a stray Enter
  /// must not connect to the first host.
  final bool captureTyping;

  /// Whether the page that holds the field is the one the user is looking
  /// at. Only used with [captureTyping]: while false nothing is captured, and
  /// the field takes the focus again when it turns true.
  final bool active;

  @override
  State<HostSearchField> createState() => _HostSearchFieldState();
}

class _HostSearchFieldState extends State<HostSearchField> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'host_search_field');
  ModalRoute<Object?>? _route;
  bool _capturingKeys = false;

  /// Whether focusing the field without being asked is welcome: not where it
  /// would open an on-screen keyboard.
  static bool get _focusByDefault => switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.fuchsia => false,
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
  };

  @override
  void initState() {
    super.initState();
    _syncKeyCapture();
    if (widget.captureTyping && widget.active) _focusSoon();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(HostSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncKeyCapture();
    final wasShown = oldWidget.captureTyping && oldWidget.active;
    if (widget.captureTyping && widget.active && !wasShown) _focusSoon();
  }

  @override
  void dispose() {
    if (_capturingKeys) HardwareKeyboard.instance.removeHandler(_onKey);
    _focusNode.dispose();
    super.dispose();
  }

  void _syncKeyCapture() {
    if (widget.captureTyping == _capturingKeys) return;
    _capturingKeys = widget.captureTyping;
    if (_capturingKeys) {
      HardwareKeyboard.instance.addHandler(_onKey);
    } else {
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
  }

  /// The page is in front: shown, not covered by a dialog or another route,
  /// and not a hidden child of a stack of pages.
  bool get _inFront =>
      mounted &&
      widget.captureTyping &&
      widget.active &&
      (_route?.isCurrent ?? true) &&
      _focusNode.canRequestFocus;

  /// Whether the user is typing into some other text field right now.
  bool _editingElsewhere() {
    final focus = FocusManager.instance.primaryFocus;
    final focused = focus?.context;
    if (focus == null || focus == _focusNode || focused == null) return false;
    return focused.widget is EditableText ||
        focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _focusSoon() {
    if (!_focusByDefault) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_inFront || _focusNode.hasFocus || _editingElsewhere()) return;
      _focusNode.requestFocus();
    });
  }

  /// Runs before the focus tree sees the key. Takes printable characters
  /// typed while the page is in front and no text field has the focus, puts
  /// them into the field and focuses it; everything after that is ordinary
  /// text input.
  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    final character = event.character;
    if (character == null || character.trim().isEmpty) return false;
    if (character.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      return false;
    }
    if (!_inFront || _focusNode.hasFocus || _editingElsewhere()) return false;
    final keyboard = HardwareKeyboard.instance;
    // Shortcuts are not text. Control and Alt together are AltGr, which is.
    if (keyboard.isMetaPressed ||
        keyboard.isControlPressed != keyboard.isAltPressed) {
      return false;
    }
    final controller = widget.controller;
    final text = controller.text + character;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    widget.onChanged(text);
    _focusAtEnd(text);
    return true;
  }

  /// Focuses the field and keeps the caret behind [text]. On desktop and the
  /// Web a single-line field selects everything when it gains the focus, and
  /// the next typed character would replace what was just captured.
  void _focusAtEnd(String text) {
    void placeCaret() {
      if (!_focusNode.hasFocus) return;
      _focusNode.removeListener(placeCaret);
      final controller = widget.controller;
      if (controller.text == text) {
        controller.selection = TextSelection.collapsed(offset: text.length);
      }
    }

    // Added now, so it runs after the listener of the text field itself.
    _focusNode.addListener(placeCaret);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final enabled = widget.enabled;
    final onConnect = widget.onConnect;
    final onChanged = widget.onChanged;
    final onSearchSubmitted = widget.onSearchSubmitted;
    QuickConnectRequest? request;
    String? syntax;
    try {
      request = QuickConnectRequest.parse(controller.text);
    } on FormatException catch (e) {
      syntax = e.message;
    }
    final command = request;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: widget.fieldKey,
          controller: controller,
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          onChanged: onChanged,
          textInputAction: TextInputAction.go,
          onSubmitted: !enabled || syntax != null
              ? null
              : (_) {
                  if (command != null) {
                    onConnect(command);
                  } else if (!widget.captureTyping ||
                      controller.text.trim().isNotEmpty) {
                    onSearchSubmitted?.call();
                  }
                },
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: context.l10n.searchHostsOrTypeAnSsh,
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: context.l10n.clearSearch,
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
          ),
        ),
        if (command != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextButton.icon(
              key: const ValueKey('quick_connect_action'),
              onPressed: enabled ? () => onConnect(command) : null,
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: Text(context.l10n.labelPressEnterToConnect(command.label)),
            ),
          ),
        if (syntax != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(syntax, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}
