import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_update/app_update_backend.dart';
import '../app_update/app_update_channel.dart';
import '../app_update/app_update_controller.dart';
import '../app_update/release_tag.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';
import 'app_motion.dart';
import 'app_theme.dart';

bool get _android => defaultTargetPlatform == TargetPlatform.android;

Future<void> _openReleasePage(BuildContext context, AppUpdateRelease release) async {
  try {
    await launchUrl(release.page, mode: LaunchMode.externalApplication);
  } on Exception {
    // No browser registered: nothing to show the page with.
  }
}

String _problemText(BuildContext context, AppUpdateApplyProblem problem) =>
    switch (problem) {
      AppUpdateApplyProblem.otherWindowsOpen =>
        context.l10n.appUpdateOtherWindows,
      AppUpdateApplyProblem.cancelled => context.l10n.appUpdateCancelled,
      AppUpdateApplyProblem.stagedMissing ||
      AppUpdateApplyProblem.failed => context.l10n.appUpdateFailed,
    };

String _waitText(BuildContext context, AppUpdateWaitReason reason) =>
    switch (reason) {
      AppUpdateWaitReason.manualInstall =>
        context.l10n.appUpdateManualInstallBody,
      AppUpdateWaitReason.automaticOff => context.l10n.appUpdateAutomaticOffBody,
      AppUpdateWaitReason.metered => context.l10n.appUpdateMeteredBody,
    };

/// Asks before the app closes for the update, then switches to the new
/// version. On desktop the app ends inside this call when it works.
///
/// Desktop always asks: the app closes, with every open session and every
/// other Atermius window of the user (also one hidden in the notification
/// area), which are closed for the user instead of being left in the way.
/// Android asks only when sessions are open; the system asks before
/// installing anyway.
Future<void> restartForAppUpdate(
  BuildContext context,
  AppUpdateController controller, {
  required int openSessions,
}) async {
  final sessions = openSessions;
  final ready = controller.ready;
  if (ready == null) return;
  final others = !_android && await controller.othersRunning();
  if (!context.mounted) return;
  if (!_android || sessions > 0) {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final l10n = dialogContext.l10n;
        final lines = [
          if (!_android)
            l10n.appUpdateCloseConfirmBody(releaseLabel(ready.tag)),
          if (sessions > 0) l10n.appUpdateRestartConfirmBody(sessions),
          if (others) l10n.appUpdateCloseOthersBody,
        ];
        return AlertDialog(
          key: const ValueKey('app_update_restart_confirmation'),
          icon: const Icon(Icons.system_update_alt_rounded),
          title: Text(
            _android
                ? l10n.appUpdateRestartConfirmTitle
                : l10n.appUpdateCloseConfirmTitle,
          ),
          content: SizedBox(
            width: appDialogWidth(dialogContext, 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, line) in lines.indexed)
                  Padding(
                    padding: EdgeInsets.only(top: index == 0 ? 0 : 8),
                    child: Text(line),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('app_update_restart_cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancel2),
            ),
            FilledButton(
              key: const ValueKey('app_update_restart_confirm'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(
                _android
                    ? l10n.appUpdateInstallAndRestart
                    : l10n.appUpdateCloseAndUpdate,
              ),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
  }
  await controller.restart(closeOthers: !_android);
}

/// The Home strip that says a new version is installed and waits for a
/// restart. Also announces a version that could not be installed
/// automatically, and the outcome right after an update.
class AppUpdateBanner extends StatelessWidget {
  const AppUpdateBanner({
    required this.controller,
    required this.openSessions,
    super.key,
  });

  final AppUpdateController controller;

  /// Sessions a restart would cut off, counted when the user asks for it.
  final int Function() openSessions;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l10n = context.l10n;
      final ready = controller.ready;
      final found = controller.found;
      final reason = controller.waitReason;
      final result = controller.result;
      final String title;
      final String body;
      final actions = <Widget>[];
      VoidCallback? onDismiss;
      if (ready != null) {
        final version = releaseLabel(ready.tag);
        title = l10n.appUpdateReadyTitle;
        body = controller.applying
            ? l10n.appUpdateInstalling
            : _android
            ? l10n.appUpdateReadyBodyAndroid(version)
            : l10n.appUpdateReadyBody(version);
        actions
          ..add(
            TextButton(
              key: const ValueKey('app_update_whats_new'),
              onPressed: () => unawaited(_openReleasePage(context, ready)),
              child: Text(l10n.appUpdateWhatsNew),
            ),
          )
          ..add(
            FilledButton.icon(
              key: const ValueKey('app_update_restart'),
              onPressed: controller.applying
                  ? null
                  : () => unawaited(
                      restartForAppUpdate(
                        context,
                        controller,
                        openSessions: openSessions(),
                      ),
                    ),
              icon: controller.applying
                  ? const SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restart_alt_rounded, size: 17),
              label: Text(
                _android
                    ? l10n.appUpdateInstallAndRestart
                    : l10n.appUpdateRestartNow,
              ),
            ),
          );
      } else if (controller.downloading && controller.downloadRequested) {
        final release = found;
        if (release == null) return const SizedBox.shrink();
        title = l10n.appUpdateDownloading(
          releaseLabel(release.tag),
          (controller.progress * 100).floor(),
        );
        body = '';
      } else if (found != null && reason != null) {
        title = l10n.appUpdateAvailableTitle(releaseLabel(found.tag));
        body = _waitText(context, reason);
        actions.add(
          TextButton(
            key: const ValueKey('app_update_whats_new'),
            onPressed: () => unawaited(_openReleasePage(context, found)),
            child: Text(
              reason == AppUpdateWaitReason.manualInstall
                  ? l10n.appUpdateOpenDownloadPage
                  : l10n.appUpdateWhatsNew,
            ),
          ),
        );
        if (reason != AppUpdateWaitReason.manualInstall) {
          actions.add(
            FilledButton.icon(
              key: const ValueKey('app_update_download'),
              onPressed: () => unawaited(controller.downloadNow()),
              icon: const Icon(Icons.download_rounded, size: 17),
              label: Text(l10n.appUpdateDownload),
            ),
          );
        }
      } else if (result != null) {
        title = result.succeeded
            ? l10n.appUpdateUpdatedTo(releaseLabel(result.tag))
            : l10n.appUpdateFailed;
        body = '';
        onDismiss = controller.dismissResult;
      } else {
        return const SizedBox.shrink();
      }
      final problem = ready != null ? controller.problem : null;
      final failed = ready == null && result != null && !result.succeeded;
      return Semantics(
        key: const ValueKey('app_update_banner'),
        container: true,
        liveRegion: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          color: failed
              ? context.palette.errorContainer
              : context.palette.lime.withValues(alpha: .13),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 14,
            runSpacing: 6,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      key: const ValueKey('app_update_banner_title'),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: failed ? context.palette.onErrorContainer : null,
                      ),
                    ),
                    if (body.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          body,
                          key: const ValueKey('app_update_banner_body'),
                          style: const TextStyle(fontSize: 12, height: 1.35),
                        ),
                      ),
                    if (problem != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          _problemText(context, problem),
                          key: const ValueKey('app_update_banner_problem'),
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.35,
                            color: context.palette.orange,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (actions.isNotEmpty || onDismiss != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (index, action) in actions.indexed) ...[
                      if (index > 0) const SizedBox(width: 8),
                      action,
                    ],
                    if (onDismiss != null)
                      IconButton(
                        key: const ValueKey('app_update_dismiss'),
                        tooltip: l10n.close,
                        visualDensity: VisualDensity.compact,
                        onPressed: onDismiss,
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                  ],
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Settings: which version runs, what the updater is doing, and whether it
/// installs by itself.
class AppUpdateSettingsCard extends StatelessWidget {
  const AppUpdateSettingsCard({
    required this.controller,
    required this.openSessions,
    super.key,
  });

  final AppUpdateController controller;
  final int Function() openSessions;

  String _status(BuildContext context) {
    final l10n = context.l10n;
    final ready = controller.ready, found = controller.found;
    if (controller.applying) return l10n.appUpdateInstalling;
    if (ready != null) {
      final version = releaseLabel(ready.tag);
      return _android
          ? l10n.appUpdateReadyBodyAndroid(version)
          : l10n.appUpdateReadyBody(version);
    }
    if (controller.downloading && found != null) {
      return l10n.appUpdateDownloading(
        releaseLabel(found.tag),
        (controller.progress * 100).floor(),
      );
    }
    if (controller.checking) return l10n.appUpdateStatusChecking;
    if (found != null && controller.waitReason != null) {
      return '${l10n.appUpdateAvailableTitle(releaseLabel(found.tag))} '
          '${_waitText(context, controller.waitReason!)}';
    }
    if (controller.downloadFailed) return l10n.appUpdateStatusDownloadFailed;
    if (controller.checkFailed) return l10n.appUpdateStatusCheckFailed;
    if (controller.checkedOnce) return l10n.appUpdateStatusCurrent;
    return '';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final l10n = context.l10n;
      final status = _status(context);
      final ready = controller.ready, found = controller.found;
      final problem = ready != null ? controller.problem : null;
      final busy =
          controller.checking || controller.downloading || controller.applying;
      return Semantics(
        liveRegion: true,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(17),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.appUpdateSettingsTitle,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 7),
                Text(
                  l10n.appUpdateCurrentVersion(
                    releaseLabel(controller.currentTag),
                  ),
                  key: const ValueKey('app_update_current_version'),
                  style: TextStyle(color: context.palette.muted, fontSize: 12),
                ),
                if (status.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    status,
                    key: const ValueKey('app_update_status'),
                    style: TextStyle(
                      color: context.palette.muted,
                      height: 1.4,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (problem != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _problemText(context, problem),
                    style: TextStyle(
                      color: context.palette.orange,
                      height: 1.4,
                      fontSize: 12,
                    ),
                  ),
                ],
                SwitchListTile.adaptive(
                  key: const ValueKey('app_update_automatic'),
                  contentPadding: EdgeInsets.zero,
                  value: controller.automatic,
                  onChanged: (value) =>
                      unawaited(controller.setAutomatic(value)),
                  title: Text(l10n.appUpdateAutomatic),
                  subtitle: Text(l10n.appUpdateAutomaticHelp),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('app_update_check'),
                      onPressed: busy
                          ? null
                          : () => unawaited(controller.checkNow()),
                      icon: controller.checking
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh_rounded),
                      label: Text(l10n.checkForUpdates),
                    ),
                    if (ready == null &&
                        found != null &&
                        controller.waitReason != null &&
                        controller.waitReason !=
                            AppUpdateWaitReason.manualInstall)
                      FilledButton.icon(
                        key: const ValueKey('app_update_settings_download'),
                        onPressed: busy
                            ? null
                            : () => unawaited(controller.downloadNow()),
                        icon: const Icon(Icons.download_rounded, size: 17),
                        label: Text(l10n.appUpdateDownload),
                      ),
                    if (ready == null &&
                        found != null &&
                        controller.waitReason ==
                            AppUpdateWaitReason.manualInstall)
                      FilledButton.icon(
                        key: const ValueKey('app_update_settings_page'),
                        onPressed: () =>
                            unawaited(_openReleasePage(context, found)),
                        icon: const Icon(Icons.open_in_new_rounded, size: 17),
                        label: Text(l10n.appUpdateOpenDownloadPage),
                      ),
                    if (ready != null)
                      FilledButton.icon(
                        key: const ValueKey('app_update_settings_restart'),
                        onPressed: controller.applying
                            ? null
                            : () => unawaited(
                                restartForAppUpdate(
                        context,
                        controller,
                        openSessions: openSessions(),
                      ),
                              ),
                        icon: const Icon(Icons.restart_alt_rounded, size: 17),
                        label: Text(
                          _android
                              ? l10n.appUpdateInstallAndRestart
                              : l10n.appUpdateRestartNow,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
