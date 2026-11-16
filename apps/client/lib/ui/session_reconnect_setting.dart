import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../terminal/session_reconnect_policy.dart';
import 'app_theme.dart';

/// A reconnect interval or time limit in words ("30 seconds", "2 minutes",
/// "No limit").
String sessionReconnectDurationLabel(AppLocalizations l10n, int seconds) =>
    seconds == sessionReconnectNoLimit
    ? l10n.sessionReconnectNoLimit
    : seconds % 60 == 0
    ? l10n.sessionReconnectMinutes(seconds ~/ 60)
    : l10n.sessionReconnectSeconds(seconds);

/// Device-local "Automatic reconnect" setting: whether dropped sessions are
/// reconnected without the user, how often and for how long. Self-contained so
/// both settings pages (cloud workspace and local profile) embed it with a
/// single line.
class SessionReconnectSetting extends StatelessWidget {
  const SessionReconnectSetting({this.controller, super.key});

  /// Defaults to the process-wide [SessionReconnectController.instance].
  final SessionReconnectController? controller;

  @override
  Widget build(BuildContext context) {
    final reconnect = controller ?? SessionReconnectController.instance;
    return ListenableBuilder(
      listenable: reconnect,
      builder: (context, _) {
        final l10n = context.l10n;
        final policy = reconnect.policy;
        final secondary = TextStyle(
          color: context.palette.muted,
          fontSize: 12,
          height: 1.35,
        );
        String label(int seconds, int standard) {
          final text = sessionReconnectDurationLabel(l10n, seconds);
          return seconds == standard
              ? l10n.sessionReconnectChoiceDefault(text)
              : text;
        }

        List<DropdownMenuItem<int>> items(
          String name,
          List<int> choices,
          int standard,
        ) => [
          for (final seconds in choices)
            DropdownMenuItem<int>(
              key: ValueKey('session_reconnect_${name}_option_$seconds'),
              value: seconds,
              child: Text(
                label(seconds, standard),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ];

        return Column(
          key: const ValueKey('session_reconnect_setting'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.sessionReconnectTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.sessionReconnectDescription,
              key: const ValueKey('session_reconnect_description'),
              style: secondary,
            ),
            SwitchListTile(
              key: const ValueKey('session_reconnect_switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.sessionReconnectSwitch),
              value: policy.automatic,
              onChanged: (value) => unawaited(reconnect.setAutomatic(value)),
            ),
            const SizedBox(height: 4),
            DropdownButtonFormField<int>(
              key: const ValueKey('session_reconnect_interval_dropdown'),
              initialValue: policy.intervalSeconds,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.sessionReconnectIntervalLabel,
              ),
              items: items(
                'interval',
                sessionReconnectIntervalChoices,
                sessionReconnectIntervalDefault,
              ),
              onChanged: policy.automatic
                  ? (seconds) {
                      if (seconds == null) return;
                      unawaited(reconnect.setIntervalSeconds(seconds));
                    }
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey('session_reconnect_limit_dropdown'),
              initialValue: policy.limitSeconds,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.sessionReconnectLimitLabel,
              ),
              items: items(
                'limit',
                sessionReconnectLimitChoices,
                sessionReconnectLimitDefault,
              ),
              onChanged: policy.automatic
                  ? (seconds) {
                      if (seconds == null) return;
                      unawaited(reconnect.setLimitSeconds(seconds));
                    }
                  : null,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.sessionReconnectNote,
              key: const ValueKey('session_reconnect_note'),
              style: secondary,
            ),
            if (reconnect.writeFailed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n.syncSettingsPreferenceSaveFailed,
                    key: const ValueKey('session_reconnect_save_failed'),
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
