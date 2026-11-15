import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';

/// Stable key of the show/hide button of the [PasswordField] whose text field
/// is keyed `ValueKey(fieldKey)`.
ValueKey<String> passwordRevealKey(String fieldKey) =>
    ValueKey<String>('${fieldKey}_reveal');

/// A secret text field that is obscured by default and has a show/hide (eye)
/// button, so a typed or saved password can be read again.
///
/// The widget only changes how the controller's text is drawn. It never
/// copies, stores or logs the value, and it re-obscures itself whenever the
/// field is rebuilt from scratch (for example when its dialog is reopened).
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    this.fieldKey,
    this.revealKey,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.enabled,
    this.readOnly = false,
    this.autofocus = false,
    this.canReveal = true,
    this.revealedMaxLines = 1,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.autofillHints,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
    this.showTooltip,
    this.hideTooltip,
  }) : assert(revealedMaxLines >= 1);

  /// Key of the inner [TextField], so callers and tests address the field
  /// exactly as they did before it gained the button.
  final Key? fieldKey;

  /// Key of the show/hide button. Defaults to [passwordRevealKey] of a
  /// `ValueKey<String>` [fieldKey].
  final Key? revealKey;

  final TextEditingController? controller;
  final FocusNode? focusNode;

  /// Decoration of the field; its `suffixIcon` is replaced by the button.
  final InputDecoration decoration;
  final bool? enabled;
  final bool readOnly;
  final bool autofocus;

  /// Whether the value may be shown. When false the field stays obscured and
  /// has no button (for example a read-only view of someone else's Vault).
  final bool canReveal;

  /// Lines shown while revealed; more than one suits PEM private keys.
  ///
  /// A hidden field is a single line, and editing a single line drops line
  /// breaks. So while such a field hides a value that has line breaks it is
  /// read-only: the key is shown first and then edited as several lines, and
  /// a stray keystroke can never flatten a saved key.
  final int revealedMaxLines;

  /// Keyboard used while obscured. A revealed field always asks for the
  /// visible-password (or multi-line) keyboard so nothing is learned by it.
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final Iterable<String>? autofillHints;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Button tooltips; default to "Show password" / "Hide password".
  final String? showTooltip;
  final String? hideTooltip;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _revealed = false;

  // Tab keeps moving from field to field as it did before the button existed;
  // the button stays reachable by pointer, touch and assistive technology.
  final _buttonFocus = FocusNode(
    skipTraversal: true,
    debugLabel: 'password reveal button',
  );

  /// Whether the value has line breaks a hidden single-line edit would drop.
  bool _hasLineBreaks = false;

  bool _readLineBreaks() =>
      widget.revealedMaxLines > 1 &&
      (widget.controller?.text.contains('\n') ?? false);

  void _onValueChanged() {
    final hasLineBreaks = _readLineBreaks();
    if (hasLineBreaks != _hasLineBreaks) {
      setState(() => _hasLineBreaks = hasLineBreaks);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.controller?.addListener(_onValueChanged);
    _hasLineBreaks = _readLineBreaks();
  }

  @override
  void didUpdateWidget(PasswordField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.canReveal) _revealed = false;
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onValueChanged);
      widget.controller?.addListener(_onValueChanged);
    }
    _hasLineBreaks = _readLineBreaks();
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onValueChanged);
    _buttonFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final revealed = _revealed && widget.canReveal;
    final multiline = revealed && widget.revealedMaxLines > 1;
    final fieldKey = widget.fieldKey;
    final revealKey =
        widget.revealKey ??
        (fieldKey is ValueKey<String>
            ? passwordRevealKey(fieldKey.value)
            : null);
    final l10n = context.l10n;
    return TextField(
      key: fieldKey,
      controller: widget.controller,
      focusNode: widget.focusNode,
      enabled: widget.enabled,
      readOnly: widget.readOnly || (!revealed && _hasLineBreaks),
      autofocus: widget.autofocus,
      obscureText: !revealed,
      maxLines: multiline ? widget.revealedMaxLines : 1,
      keyboardType: multiline
          ? TextInputType.multiline
          : revealed
          ? TextInputType.visiblePassword
          : widget.keyboardType,
      textInputAction: multiline
          ? TextInputAction.newline
          : widget.textInputAction,
      inputFormatters: widget.inputFormatters,
      autofillHints: widget.autofillHints,
      maxLength: widget.maxLength,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: widget.decoration.copyWith(
        suffixIcon: widget.canReveal
            ? IconButton(
                key: revealKey,
                focusNode: _buttonFocus,
                tooltip: revealed
                    ? widget.hideTooltip ?? l10n.passwordRevealHide
                    : widget.showTooltip ?? l10n.passwordRevealShow,
                onPressed: () => setState(() => _revealed = !_revealed),
                icon: Icon(
                  revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              )
            : null,
      ),
    );
  }
}
