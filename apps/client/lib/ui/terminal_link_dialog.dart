import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/l10n.dart';
import 'app_motion.dart';

void showTerminalLink(BuildContext context, Uri uri) {
  final l10n = context.l10n;
  final messenger = ScaffoldMessenger.maybeOf(context);

  Future<void> openLink() async {
    try {
      final opened = await launchUrl(
        uri,
        mode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      );
      if (opened) return;
    } on Exception {
      // A platform with no registered handler may throw instead of returning false.
    }
    if (messenger != null && messenger.mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.terminalLinkOpenFailed)),
      );
    }
  }

  unawaited(
    showAppDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.terminalLinkTitle),
        scrollable: true,
        content: SelectableText(
          uri.toString(),
          textDirection: TextDirection.ltr,
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              // Keep the Web launch inside the browser's click event.
              unawaited(openLink());
              Navigator.of(dialogContext).pop();
            },
            child: Text(l10n.terminalLinkOpenInBrowser),
          ),
        ],
      ),
    ),
  );
}
