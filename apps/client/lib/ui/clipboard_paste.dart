import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../platform/local_clipboard.dart';

/// Largest text pasted into a terminal at once, in UTF-8 bytes.
const terminalPasteMaxBytes = 16 * 1024 * 1024;

/// Reads the clipboard for a paste the user asked for.
///
/// Returns the text, or null after a snackbar says why there is none: the
/// clipboard is empty, holds no text (an image or a file), the system
/// refused (with a button to the app's settings where a phone keeps its
/// clipboard permission), Android saw no focus, or the text exceeds
/// [maxBytes]. A paste never fails silently.
Future<String?> readClipboardForPaste(
  BuildContext context, {
  required int maxBytes,
  LocalClipboard? clipboard,
}) async {
  final source = clipboard ?? LocalClipboard.instance;
  // Looked up before the read: the caller may be gone when it returns.
  final messenger = ScaffoldMessenger.maybeOf(context);
  final l10n = context.l10n;
  final LocalClipboardRead read;
  try {
    read = await source.readText(maxBytes: maxBytes);
  } on Object {
    messenger?.showSnackBar(SnackBar(content: Text(l10n.clipboardHasNoText)));
    return null;
  }
  if (read.status == LocalClipboardStatus.text && read.text != null) {
    return read.text;
  }
  final denied = read.status == LocalClipboardStatus.denied;
  final message = switch (read.status) {
    LocalClipboardStatus.text ||
    LocalClipboardStatus.empty => l10n.clipboardIsEmpty,
    LocalClipboardStatus.noText => l10n.clipboardHasNoText,
    LocalClipboardStatus.denied => l10n.clipboardReadDenied,
    LocalClipboardStatus.unfocused => l10n.clipboardReadUnfocused,
    LocalClipboardStatus.tooLarge => l10n.clipboardTextTooLarge(
      formatClipboardLimit(maxBytes),
    ),
  };
  messenger?.showSnackBar(
    SnackBar(
      content: Text(message),
      action: denied && source.hasSettings
          ? SnackBarAction(
              label: l10n.settings,
              onPressed: () => unawaited(source.openSettings()),
            )
          : null,
    ),
  );
  return null;
}

/// "64 KiB", "16 MiB": a byte limit for clipboard messages.
String formatClipboardLimit(int bytes) {
  const mib = 1024 * 1024;
  if (bytes >= mib && bytes % mib == 0) return '${bytes ~/ mib} MiB';
  if (bytes >= 1024 && bytes % 1024 == 0) return '${bytes ~/ 1024} KiB';
  return '$bytes B';
}
