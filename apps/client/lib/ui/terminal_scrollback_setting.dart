import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../terminal/terminal_scrollback.dart';
import 'app_theme.dart';

/// Device-local "Scrollback" setting: how many lines each terminal opened
/// from now on keeps. Self-contained so both settings pages (cloud workspace
/// and local profile) embed it with a single line.
class TerminalScrollbackSetting extends StatelessWidget {
  const TerminalScrollbackSetting({
    this.controller,
    this.diskTier = !kIsWeb,
    super.key,
  });

  /// Defaults to the process-wide [TerminalScrollbackController.instance].
  final TerminalScrollbackController? controller;

  /// Whether history beyond the in-memory part is kept in an encrypted
  /// temporary file on this device (every build except the browser one, which
  /// keeps scrollback in memory only). Selects the matching description.
  final bool diskTier;

  @override
  Widget build(BuildContext context) {
    final scrollback = controller ?? TerminalScrollbackController.instance;
    return ListenableBuilder(
      listenable: scrollback,
      builder: (context, _) {
        final l10n = context.l10n;
        final numbers = NumberFormat.decimalPattern(l10n.localeName);
        final secondary = TextStyle(
          color: context.palette.muted,
          fontSize: 12,
          height: 1.35,
        );
        String label(int lines) {
          final count = numbers.format(lines);
          return lines == terminalScrollbackDefault
              ? l10n.terminalScrollbackLinesDefault(count)
              : l10n.terminalScrollbackLines(count);
        }

        return Column(
          key: const ValueKey('terminal_scrollback_setting'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.terminalScrollbackTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              diskTier
                  ? l10n.terminalScrollbackDescription
                  : l10n.terminalScrollbackDescriptionMemoryOnly,
              key: const ValueKey('terminal_scrollback_description'),
              style: secondary,
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              key: const ValueKey('terminal_scrollback_dropdown'),
              initialValue: scrollback.lines,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.terminalScrollbackFieldLabel,
              ),
              items: [
                for (final lines in terminalScrollbackChoices)
                  DropdownMenuItem<int>(
                    key: ValueKey('terminal_scrollback_option_$lines'),
                    value: lines,
                    child: Text(
                      label(lines),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (lines) {
                if (lines == null) return;
                unawaited(scrollback.select(lines));
              },
            ),
            const SizedBox(height: 8),
            Text(
              l10n.terminalScrollbackAppliesToNew,
              key: const ValueKey('terminal_scrollback_applies_note'),
              style: secondary,
            ),
            if (scrollback.writeFailed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n.syncSettingsPreferenceSaveFailed,
                    key: const ValueKey('terminal_scrollback_save_failed'),
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: context.palette.orange,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
