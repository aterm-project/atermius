import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'app_density.dart';
import 'app_motion.dart';
import 'app_theme.dart';

/// Development-only "allow insecure connection" switch shown wherever the
/// account server address is entered. It only reports the user's intent;
/// the caller confirms it with [confirmAllowInsecureServer] and binds it to
/// one server origin.
class AllowInsecureServerOption extends StatelessWidget {
  const AllowInsecureServerOption({
    required this.value,
    required this.onChanged,
    required this.web,
    super.key,
  });

  final bool value;

  /// Null disables the switch (for example while a request is running).
  final ValueChanged<bool>? onChanged;

  /// Browsers cannot skip certificate validation, so the wording there only
  /// promises what can work: a plain `http://` address.
  final bool web;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final warning = palette.orange;
    // A filled row; switched on it turns into a warning block, no outline.
    return Material(
      color: value ? palette.warningContainer : palette.fill,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppDensity.of(context).radiusMd),
      ),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        key: const ValueKey('allow_insecure_server'),
        value: value,
        onChanged: onChanged,
        contentPadding: const EdgeInsets.fromLTRB(12, 2, 6, 2),
        title: Text(
          context.l10n.allowInsecureServerTitle,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  Icons.warning_amber_rounded,
                  size: 15,
                  color: warning,
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  web
                      ? context.l10n.allowInsecureServerWarningWeb
                      : context.l10n.allowInsecureServerWarning,
                  style: TextStyle(fontSize: 12, height: 1.4, color: warning),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks the user to confirm the insecure option for exactly [origin]. Returns
/// true only for an explicit confirmation; dismissing the dialog is a "no".
Future<bool> confirmAllowInsecureServer(
  BuildContext context, {
  required String origin,
  required bool web,
}) async {
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: const ValueKey('allow_insecure_server_dialog'),
      icon: Icon(
        Icons.warning_amber_rounded,
        color: dialogContext.palette.orange,
      ),
      title: Text(dialogContext.l10n.allowInsecureServerConfirmTitle),
      content: SizedBox(
        width: appDialogWidth(dialogContext, 440),
        child: SingleChildScrollView(
          child: Text(
            web
                ? dialogContext.l10n.allowInsecureServerConfirmBodyWeb(origin)
                : dialogContext.l10n.allowInsecureServerConfirmBody(origin),
            style: const TextStyle(height: 1.45),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('allow_insecure_server_cancel'),
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(dialogContext.l10n.cancel2),
        ),
        FilledButton(
          key: const ValueKey('allow_insecure_server_confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: dialogContext.palette.red,
            foregroundColor: Colors.white,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(dialogContext.l10n.allowInsecureServerConfirmAction),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Persistent, non-dismissible warning shown for as long as the session uses
/// an account server with the insecure option on. Tapping it shows which
/// server the permission applies to and how to turn it off.
class InsecureServerIndicator extends StatelessWidget {
  const InsecureServerIndicator({
    required this.origin,
    this.strip = false,
    this.showOrigin = true,
    super.key,
  });

  /// Origin (scheme, host and port) the permission is bound to.
  final String origin;

  /// Edge-to-edge strip for the top of the workspace instead of a card.
  final bool strip;

  /// Whether the origin is spelled out next to the warning. The details
  /// dialog always names it.
  final bool showOrigin;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final warning = palette.orange;
    final radius = strip
        ? BorderRadius.zero
        : BorderRadius.circular(AppDensity.of(context).radiusMd);
    final label = context.l10n.insecureServerIndicator;
    return Semantics(
      container: true,
      button: true,
      label: '$label. ${context.l10n.insecureServerAppliesTo(origin)}',
      child: Material(
        color: palette.warningContainer,
        shape: RoundedRectangleBorder(borderRadius: radius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showInsecureServerDetails(context, origin: origin),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: strip ? 14 : 12,
              vertical: strip ? 6 : 9,
            ),
            child: ExcludeSemantics(
              child: Row(
                children: [
                  Icon(Icons.gpp_maybe_outlined, size: 18, color: warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            color: palette.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                          ),
                        ),
                        if (showOrigin)
                          Text(
                            origin,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: palette.text,
                              fontFamily: 'monospace',
                              fontSize: 11,
                              height: 1.3,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: context.l10n.insecureServerIndicatorDetails,
                    child: Icon(Icons.info_outline, size: 17, color: warning),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Explains the active insecure connection and names the server it applies
/// to. Closing the dialog does not hide the indicator.
Future<void> showInsecureServerDetails(
  BuildContext context, {
  required String origin,
}) => showAppDialog<void>(
  context: context,
  builder: (dialogContext) => AlertDialog(
    key: const ValueKey('insecure_server_details'),
    icon: Icon(Icons.gpp_maybe_outlined, color: dialogContext.palette.orange),
    title: Text(dialogContext.l10n.insecureServerDetailTitle),
    content: SizedBox(
      width: appDialogWidth(dialogContext, 440),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              origin,
              key: const ValueKey('insecure_server_details_origin'),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              dialogContext.l10n.insecureServerDetailBody(origin),
              style: const TextStyle(height: 1.45),
            ),
            const SizedBox(height: 12),
            Text(
              dialogContext.l10n.insecureServerDetailTurnOff,
              style: TextStyle(
                height: 1.45,
                color: dialogContext.palette.muted,
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('insecure_server_details_close'),
        onPressed: () => Navigator.pop(dialogContext),
        child: Text(dialogContext.l10n.close),
      ),
    ],
  ),
);
