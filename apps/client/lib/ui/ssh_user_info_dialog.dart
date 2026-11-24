import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';
import 'app_theme.dart';
import 'password_field.dart';

Future<List<String>?> showSshUserInfo(
  BuildContext context,
  HostRecord host,
  SSHUserInfoRequest request,
  Future<void> cancelled,
) async {
  if (!context.mounted) return null;
  const maxPrompts = 8;
  const maxPromptRunes = 512;
  String safeText(String value, int maxRunes) {
    final visible = value.replaceAll(
      RegExp(
        r'[\u0000-\u001f\u007f-\u009f\u061c\u200e\u200f\u2028-\u202e\u2066-\u2069]',
      ),
      ' ',
    );
    return String.fromCharCodes(visible.runes.take(maxRunes));
  }

  final promptLimitExceeded = request.prompts.length > maxPrompts;
  final safePrompts = promptLimitExceeded
      ? const <_SafeSshUserInfoPrompt>[]
      : request.prompts
            .map(
              (prompt) => _SafeSshUserInfoPrompt(
                text: safeText(prompt.promptText, maxPromptRunes),
                echo: prompt.echo,
              ),
            )
            .toList(growable: false);
  final safeRequestName = safeText(request.name, 512);
  final safeInstruction = safeText(request.instruction, 2048);
  // OpenSSH/PAM can send a final empty INFO_REQUEST after the last actual
  // answer. There is nothing for the user to review or enter in that packet.
  if (safePrompts.isEmpty &&
      !promptLimitExceeded &&
      safeRequestName.isEmpty &&
      safeInstruction.isEmpty) {
    return const <String>[];
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<List<String>?>(
    context: context,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierDismissible: false,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    builder: (_) => _SshUserInfoDialog(
      hostLabel: safeText('${host.name} · ${host.endpoint}', 512),
      requestName: safeRequestName,
      instruction: safeInstruction,
      prompts: safePrompts,
      promptLimitExceeded: promptLimitExceeded,
    ),
  );
  final dialogResult = navigator.push(route);
  final outcome = await Future.any<(bool, List<String>?)>([
    dialogResult.then((responses) => (false, responses)),
    cancelled.then((_) => (true, null)),
  ]);
  if (outcome.$1) {
    if (navigator.mounted && route.isActive) navigator.removeRoute(route);
    return null;
  }
  return outcome.$2;
}

class _SafeSshUserInfoPrompt {
  const _SafeSshUserInfoPrompt({required this.text, required this.echo});

  final String text;
  final bool echo;
}

class _SshUserInfoDialog extends StatefulWidget {
  const _SshUserInfoDialog({
    required this.hostLabel,
    required this.requestName,
    required this.instruction,
    required this.prompts,
    required this.promptLimitExceeded,
  });

  final String hostLabel;
  final String requestName;
  final String instruction;
  final List<_SafeSshUserInfoPrompt> prompts;
  final bool promptLimitExceeded;

  @override
  State<_SshUserInfoDialog> createState() => _SshUserInfoDialogState();
}

class _SshUserInfoDialogState extends State<_SshUserInfoDialog> {
  late final _responses = List<TextEditingController>.generate(
    widget.prompts.length,
    (_) => TextEditingController(),
    growable: false,
  );

  void _clearResponses() {
    for (final response in _responses) {
      response.clear();
    }
  }

  void _cancel() {
    _clearResponses();
    Navigator.of(context).pop();
  }

  void _submit() {
    if (widget.promptLimitExceeded) return;
    final responses = _responses.map((controller) => controller.text).toList();
    _clearResponses();
    Navigator.of(context).pop(responses);
  }

  @override
  void dispose() {
    _clearResponses();
    for (final response in _responses) {
      response.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('ssh-user-info-dialog'),
    title: Text(context.l10n.sshAuthenticationChallenge),
    content: SizedBox(
      width: appDialogWidth(context, 520),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.hostLabel,
              key: const ValueKey('ssh-user-info-host'),
              style: TextStyle(color: context.palette.muted),
            ),
            if (widget.requestName.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                widget.requestName,
                key: const ValueKey('ssh-user-info-name'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
            if (widget.instruction.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                widget.instruction,
                key: const ValueKey('ssh-user-info-instruction'),
              ),
            ],
            if (widget.promptLimitExceeded) ...[
              const SizedBox(height: 14),
              Text(
                context.l10n.theSshServerRequestedTooMany,
                key: const ValueKey('ssh-user-info-prompt-limit'),
                style: TextStyle(color: context.palette.red),
              ),
            ] else if (widget.prompts.isEmpty) ...[
              const SizedBox(height: 14),
              Text(context.l10n.theServerDidNotRequestA),
            ] else ...[
              const SizedBox(height: 14),
              for (var index = 0; index < widget.prompts.length; index++) ...[
                if (index > 0) const SizedBox(height: 10),
                if (widget.prompts[index].echo)
                  TextField(
                    key: ValueKey('ssh-user-info-response-$index'),
                    controller: _responses[index],
                    autofocus: index == 0,
                    autocorrect: false,
                    enableIMEPersonalizedLearning: false,
                    keyboardType: TextInputType.text,
                    maxLength: 4096,
                    decoration: InputDecoration(
                      labelText: widget.prompts[index].text.isEmpty
                          ? context.l10n.responseValuevalue(index + 1)
                          : widget.prompts[index].text,
                      counterText: '',
                    ),
                    onSubmitted: index == widget.prompts.length - 1
                        ? (_) => _submit()
                        : null,
                  )
                else
                  // A no-echo answer (password, one-time code) can be checked
                  // with the eye button before it is sent.
                  PasswordField(
                    fieldKey: ValueKey('ssh-user-info-response-$index'),
                    controller: _responses[index],
                    autofocus: index == 0,
                    keyboardType: TextInputType.visiblePassword,
                    maxLength: 4096,
                    decoration: InputDecoration(
                      labelText: widget.prompts[index].text.isEmpty
                          ? context.l10n.responseValuevalue(index + 1)
                          : widget.prompts[index].text,
                      counterText: '',
                    ),
                    onSubmitted: index == widget.prompts.length - 1
                        ? (_) => _submit()
                        : null,
                  ),
              ],
            ],
            const SizedBox(height: 10),
            Text(
              context.l10n.responsesAreSentOnlyForThis,
              key: const ValueKey('ssh-user-info-not-saved'),
              style: TextStyle(color: context.palette.muted),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('ssh-user-info-cancel'),
        onPressed: _cancel,
        child: Text(
          widget.promptLimitExceeded
              ? context.l10n.stopAuthentication
              : context.l10n.cancel2,
        ),
      ),
      if (!widget.promptLimitExceeded)
        FilledButton(
          key: const ValueKey('ssh-user-info-submit'),
          onPressed: _submit,
          child: Text(context.l10n.sendResponses),
        ),
    ],
  );
}
