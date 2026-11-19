import 'dart:async';

import 'package:flutter/material.dart';

import '../ssh/ssh_keepalive_policy.dart';
import '../terminal/paste_safety.dart';
import 'app_theme.dart';

/// 设备级「长连接保活与链路健康」设置卡片（四语自适应）。
///
/// 覆盖商业运维常见痛点：
/// - 周期应用层 SSH Keepalive 间隔（穿透企业防火墙/NAT/CGNAT 空闲超时）；
/// - 连续丢包判定僵死上限（对齐 OpenSSH `ServerAliveCountMax`，消灭半开假在线）；
/// - 休眠唤醒 / 前台切回秒级主动探活；
/// - 商业长连接自动密钥轮换（RFC 4253 §9）。
class SshKeepaliveSetting extends StatelessWidget {
  const SshKeepaliveSetting({this.controller, super.key});

  /// 默认绑定进程级单例 [SshKeepaliveController.instance]。
  final SshKeepaliveController? controller;

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

  static String _intervalLabel(BuildContext context, int seconds) {
    if (seconds == 0) {
      return _t(
        context,
        zh: '关闭',
        en: 'Off',
        ja: 'オフ',
        ru: 'Выкл.',
      );
    }
    final base = _t(
      context,
      zh: '$seconds 秒',
      en: '$seconds seconds',
      ja: '$seconds 秒',
      ru: '$seconds с',
    );
    return seconds == sshKeepaliveIntervalDefault
        ? _defaultSuffix(context, base)
        : base;
  }

  static String _maxMissedLabel(BuildContext context, int count) {
    final base = _t(
      context,
      zh: '连续 $count 次无响应',
      en: '$count missed replies',
      ja: '$count 回連続無応答',
      ru: '$count пропущенных ответов',
    );
    return count == sshKeepaliveMaxMissedDefault
        ? _defaultSuffix(context, base)
        : base;
  }

  static String _rekeyLabel(BuildContext context, int minutes) {
    if (minutes == 0) {
      return _t(
        context,
        zh: '仅跟随服务端',
        en: 'Server default only',
        ja: 'サーバー任せ',
        ru: 'Только по серверу',
      );
    }
    final hours = minutes ~/ 60;
    final base = _t(
      context,
      zh: '每 $hours 小时轮换会话密钥',
      en: hours == 1 ? 'Every 1 hour' : 'Every $hours hours',
      ja: '$hours 時間ごとに鍵更新',
      ru: hours == 1 ? 'Каждый час' : 'Каждые $hours ч',
    );
    return minutes == sshKeepaliveRekeyMinutesDefault
        ? _defaultSuffix(context, base)
        : base;
  }

  static String _defaultSuffix(BuildContext context, String text) => _t(
    context,
    zh: '$text（默认）',
    en: '$text (default)',
    ja: '$text（既定）',
    ru: '$text (по умолчанию)',
  );

  @override
  Widget build(BuildContext context) {
    final keepalive = controller ?? SshKeepaliveController.instance;
    final pasteSafety = PasteSafetyController.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([keepalive, pasteSafety]),
      builder: (context, _) {
        final policy = keepalive.policy;
        final secondary = TextStyle(
          color: context.palette.muted,
          fontSize: 12,
          height: 1.35,
        );
        return Column(
          key: const ValueKey('ssh_keepalive_setting'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _t(
                context,
                zh: 'SSH 长连接保活与链路监测',
                en: 'SSH keepalive & link health',
                ja: 'SSH キープアライブと回線監視',
                ru: 'Keepalive SSH и контроль канала',
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              _t(
                context,
                zh: '通过定时应用层心跳穿透防火墙/NAT 空闲超时，主动识别半开僵尸连接并交由自动重连恢复。',
                en: 'Send periodic SSH keepalives across NAT/firewalls and close half-open zombie links so automatic reconnect recovers quickly.',
                ja: '定期的な SSH ハートビートで NAT やファイアウォールの切断を防ぎ、半開き状態のゾンビ接続を自動検出します。',
                ru: 'Периодические пакеты keepalive удерживают NAT-сессии и быстро выявляют зависшие соединения для автопереподключения.',
              ),
              key: const ValueKey('ssh_keepalive_description'),
              style: secondary,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey('ssh_keepalive_interval_dropdown'),
              initialValue: policy.intervalSeconds,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: _t(
                  context,
                  zh: '保活心跳间隔',
                  en: 'Keepalive interval',
                  ja: 'ハートビート間隔',
                  ru: 'Интервал keepalive',
                ),
              ),
              items: [
                for (final seconds in sshKeepaliveIntervalChoices)
                  DropdownMenuItem<int>(
                    key: ValueKey('ssh_keepalive_interval_option_$seconds'),
                    value: seconds,
                    child: Text(
                      _intervalLabel(context, seconds),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (seconds) {
                if (seconds == null) return;
                unawaited(keepalive.setIntervalSeconds(seconds));
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey('ssh_keepalive_max_missed_dropdown'),
              initialValue: policy.maxMissed,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: _t(
                  context,
                  zh: '僵死断流判定阈值',
                  en: 'Dead peer threshold',
                  ja: '無応答切断しきい値',
                  ru: 'Порог обрыва связи',
                ),
              ),
              items: [
                for (final count in sshKeepaliveMaxMissedChoices)
                  DropdownMenuItem<int>(
                    key: ValueKey('ssh_keepalive_max_missed_option_$count'),
                    value: count,
                    child: Text(
                      _maxMissedLabel(context, count),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: policy.enabled
                  ? (count) {
                      if (count == null) return;
                      unawaited(keepalive.setMaxMissed(count));
                    }
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey('ssh_keepalive_rekey_dropdown'),
              initialValue: policy.rekeyMinutes,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: _t(
                  context,
                  zh: '长连接会话密钥轮换',
                  en: 'Long-session key rotation (rekey)',
                  ja: '長時間セッションの鍵ローテーション',
                  ru: 'Ротация ключей сессии (rekey)',
                ),
              ),
              items: [
                for (final minutes in sshKeepaliveRekeyMinutesChoices)
                  DropdownMenuItem<int>(
                    key: ValueKey('ssh_keepalive_rekey_option_$minutes'),
                    value: minutes,
                    child: Text(
                      _rekeyLabel(context, minutes),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (minutes) {
                if (minutes == null) return;
                unawaited(keepalive.setRekeyMinutes(minutes));
              },
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              key: const ValueKey('ssh_keepalive_probe_on_resume_switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                _t(
                  context,
                  zh: '切回前台或唤醒时立即探活',
                  en: 'Probe live sessions on app resume',
                  ja: '復帰時に接続を即時チェック',
                  ru: 'Проверять канал при возврате в приложение',
                ),
              ),
              value: policy.probeOnResume,
              onChanged: (value) => unawaited(keepalive.setProbeOnResume(value)),
            ),
            SwitchListTile(
              key: const ValueKey('paste_safety_guard_switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                _t(
                  context,
                  zh: '生产高危与多行粘贴二次确认',
                  en: 'Confirm risky & multi-line pastes',
                  ja: '危険・複数行貼り付け前の確認',
                  ru: 'Подтверждение опасной и многострочной вставки',
                ),
              ),
              value: pasteSafety.enabled,
              onChanged: (value) => unawaited(pasteSafety.setEnabled(value)),
            ),
            Text(
              _t(
                context,
                zh: '仅对新建 SSH 连接及跳板链生效；所有连接已自动启用 TCP_NODELAY 低延迟传输。',
                en: 'Applies to new SSH sessions and jump chains; TCP_NODELAY is always enabled for responsive typing.',
                ja: '新規 SSH 接続と踏み台チェーンに適用されます。低遅延な TCP_NODELAY は常時有効です。',
                ru: 'Применяется к новым SSH-сессиям и jump-цепочкам; TCP_NODELAY всегда включён.',
              ),
              key: const ValueKey('ssh_keepalive_note'),
              style: secondary,
            ),
            if (keepalive.writeFailed || pasteSafety.writeFailed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _t(
                      context,
                      zh: '保存偏好失败；当前会话内仍已生效。',
                      en: 'Could not save preference; active for this run.',
                      ja: '設定の保存に失敗しました（現在のセッションでは有効です）。',
                      ru: 'Не удалось сохранить настройку; действует в текущей сессии.',
                    ),
                    key: const ValueKey('ssh_keepalive_save_failed'),
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
