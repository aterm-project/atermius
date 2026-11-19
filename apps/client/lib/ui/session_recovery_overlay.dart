import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../terminal/session_recovery.dart';

/// `m:ss` until the automatic reconnect attempts stop, rounded up so the
/// display starts at the full limit and reaches 0:00 only when it is over.
String sessionRecoveryCountdown(Duration remaining) {
  final seconds = _ceilSeconds(remaining);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

int _ceilSeconds(Duration value) =>
    value <= Duration.zero ? 0 : (value.inMilliseconds + 999) ~/ 1000;

/// "Connection lost" card over an interrupted session. While automatic
/// attempts are being made it says so, with the time left until they stop and
/// the time until the next one; once the limit is used up it says the
/// connection could not be restored. "Restore connection" always retries now.
class SessionRecoveryOverlay extends StatefulWidget {
  const SessionRecoveryOverlay({
    super.key,
    required this.recovery,
    required this.child,
    this.onClose,
  });
  final SessionRecovery? recovery;
  final Widget child;

  /// Closes the interrupted tab; without it no Close action is offered.
  final VoidCallback? onClose;

  @override
  State<SessionRecoveryOverlay> createState() => _SessionRecoveryOverlayState();
}

class _SessionRecoveryOverlayState extends State<SessionRecoveryOverlay> {
  /// Repaints the countdown once a second, only while one is shown.
  Timer? _ticker;

  static String _t(
    BuildContext context, {
    required String zh,
    required String en,
    required String ja,
    required String ru,
  }) => switch (Localizations.localeOf(context).languageCode) {
    'zh' => zh,
    'ja' => ja,
    'ru' => ru,
    _ => en,
  };

  static String? _disconnectReasonLabel(BuildContext context, String? reason) =>
      switch (reason) {
        'keepalive_timeout' => _t(
          context,
          zh: '心跳保活超时（链路无响应）',
          en: 'Keepalive timed out (peer unresponsive)',
          ja: 'キープアライブ応答タイムアウト',
          ru: 'Тайм-аут keepalive (сервер не отвечает)',
        ),
        'transport_error' => _t(
          context,
          zh: '底层网络传输中断',
          en: 'Network transport interrupted',
          ja: 'ネットワーク転送が中断されました',
          ru: 'Сбой сетевого транспорта',
        ),
        'remote_closed' => _t(
          context,
          zh: '远端主机关闭了连接',
          en: 'Closed by remote host',
          ja: 'リモートホストにより切断されました',
          ru: 'Соединение закрыто удалённым хостом',
        ),
        _ => null,
      };

  @override
  void initState() {
    super.initState();
    widget.recovery?.addListener(_recoveryChanged);
    _syncTicker();
  }

  @override
  void didUpdateWidget(SessionRecoveryOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.recovery, widget.recovery)) {
      oldWidget.recovery?.removeListener(_recoveryChanged);
      widget.recovery?.addListener(_recoveryChanged);
      _syncTicker();
    }
  }

  @override
  void dispose() {
    widget.recovery?.removeListener(_recoveryChanged);
    _ticker?.cancel();
    super.dispose();
  }

  void _recoveryChanged() {
    _syncTicker();
    if (mounted) setState(() {});
  }

  void _syncTicker() {
    final model = widget.recovery;
    final counting =
        model != null &&
        model.interrupted &&
        (model.remaining != null || model.nextAttemptIn != null);
    if (!counting) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.recovery;
    if (model == null) return widget.child;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (model.interrupted)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: _card(context, model),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _card(BuildContext context, SessionRecovery model) {
    final l10n = context.l10n;
    final remaining = model.remaining, next = model.nextAttemptIn;
    final close = widget.onClose;
    final reasonLabel = _disconnectReasonLabel(
      context,
      model.lastDisconnectReason,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.connectionLost, textAlign: TextAlign.center),
        if (reasonLabel != null) ...[
          const SizedBox(height: 2),
          Text(
            reasonLabel,
            key: const ValueKey('session_recovery_reason'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (model.recoveryCount > 0) ...[
          const SizedBox(height: 2),
          Text(
            _t(
              context,
              zh: '本次会话已自动恢复 ${model.recoveryCount} 次',
              en: 'Recovered ${model.recoveryCount}× in this session',
              ja: 'このセッションで ${model.recoveryCount} 回自動復帰済み',
              ru: 'Восстановлено ${model.recoveryCount} раз за сессию',
            ),
            key: const ValueKey('session_recovery_count'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
        if (model.expired && !model.busy) ...[
          const SizedBox(height: 4),
          Semantics(
            liveRegion: true,
            child: Text(
              l10n.sessionReconnectGaveUp,
              key: const ValueKey('session_recovery_gave_up'),
              textAlign: TextAlign.center,
            ),
          ),
        ] else if (model.automaticEnabled && model.available) ...[
          const SizedBox(height: 4),
          Text(
            next == null
                ? l10n.sessionReconnectAutomatic
                : l10n.sessionReconnectNextAttempt(_ceilSeconds(next)),
            key: const ValueKey('session_recovery_automatic'),
            textAlign: TextAlign.center,
          ),
          if (remaining != null)
            Text(
              l10n.sessionReconnectTimeLeft(
                sessionRecoveryCountdown(remaining),
              ),
              key: const ValueKey('session_recovery_countdown'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
        ],
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey('session_restore_connection'),
              onPressed: model.busy || !model.available
                  ? null
                  : () => model.retry(),
              icon: model.busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(
                model.busy
                    ? l10n.terminalStateReconnecting
                    : l10n.restoreConnection,
              ),
            ),
            if (close != null)
              OutlinedButton.icon(
                key: const ValueKey('session_recovery_close'),
                onPressed: close,
                icon: const Icon(Icons.close),
                label: Text(l10n.close),
              ),
          ],
        ),
      ],
    );
  }
}
