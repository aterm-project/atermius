import 'dart:async';

import 'package:flutter/services.dart';

import '../credential_visibility/sensitive_clipboard.dart';
import '../domain/host_login_export.dart';
import '../domain/models.dart';
import '../l10n/l10n.dart';

/// Puts the sign-in details of [host] on the clipboard as JSON (see
/// [exportHostLogin] for the shape and the lookups) and returns the line to
/// show the user, with whether it reports a failure.
///
/// The copied text is registered as a secret first, so automatic clipboard
/// sync with remote desktops never sends it on its own.
Future<({String message, bool failed})> copyHostLoginJson({
  required AppLocalizations l10n,
  required HostRecord host,
  required FutureOr<CredentialRecord?> Function(HostRecord host) credentialFor,
  required FutureOr<HostRecord?> Function(String id) hostById,
  String? temporaryJumpHostId,
}) async {
  try {
    final export = await exportHostLogin(
      host: host,
      credentialFor: credentialFor,
      hostById: hostById,
      temporaryJumpHostId: temporaryJumpHostId,
    );
    SensitiveClipboard.markSecret(export.json);
    await Clipboard.setData(
      ClipboardData(text: export.json),
    ).timeout(const Duration(seconds: 5));
    return (
      message: export.hasSecret
          ? l10n.loginInfoCopied
          : l10n.loginInfoCopiedWithoutSecret,
      failed: false,
    );
  } on Object {
    return (message: l10n.loginInfoCopyFailed, failed: true);
  }
}
