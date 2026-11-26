import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../terminal/paste_safety.dart';
import 'app_density.dart';
import 'app_theme.dart';
import 'apple_hig.dart';
import 'surfaces.dart';

/// 在向终端粘贴高危命令或未受括号粘贴保护的多行文本前弹出安全确认弹窗。
///
/// 返回最终应写入终端的字符串；若用户取消则返回 `null`。
Future<String?> confirmTerminalPaste(
  BuildContext context,
  String text, {
  bool bracketedPasteActive = false,
  PasteSafetyController? controller,
}) async {
  final guard = controller ?? PasteSafetyController.instance;
  if (!guard.enabled) return text;
  final analysis = analyzeTerminalPaste(
    text,
    bracketedPasteActive: bracketedPasteActive,
  );
  if (analysis.isSafe) return text;

  AppleHaptics.light(context);
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    requestFocus: true,
    builder: (dialogContext) =>
        _PasteSafetyDialog(originalText: text, analysis: analysis),
  );
}

class _PasteSafetyDialog extends StatelessWidget {
  const _PasteSafetyDialog({
    required this.originalText,
    required this.analysis,
  });

  final String originalText;
  final PasteSafetyAnalysis analysis;

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

  static String _riskChipLabel(BuildContext context, String riskId) =>
      switch (riskId) {
        'rm_rf' => _t(
          context,
          zh: '强制递归删除 (rm -rf)',
          en: 'Recursive delete (rm -rf)',
          ja: '再帰削除 (rm -rf)',
          ru: 'Удаление (rm -rf)',
        ),
        'disk_format' => _t(
          context,
          zh: '磁盘格式化/覆写',
          en: 'Disk format / overwrite',
          ja: 'ディスク初期化/上書き',
          ru: 'Форматирование диска',
        ),
        'power_control' => _t(
          context,
          zh: '系统关机/重启',
          en: 'Shutdown / Reboot',
          ja: 'シャットダウン/再起動',
          ru: 'Выключение / Перезагрузка',
        ),
        'chmod_777' => _t(
          context,
          zh: '全权限递归修改 (chmod -R 777)',
          en: 'Recursive chmod 777',
          ja: '再帰 chmod 777',
          ru: 'Рекурсивный chmod 777',
        ),
        'firewall_flush' => _t(
          context,
          zh: '清空防火墙规则',
          en: 'Firewall rules flush',
          ja: 'ファイアウォール規則消去',
          ru: 'Сброс правил firewall',
        ),
        'sql_drop' => _t(
          context,
          zh: '数据库删库/清表',
          en: 'Database DROP / FLUSH',
          ja: 'DB 削除 / フラッシュ',
          ru: 'Удаление БД / FLUSH',
        ),
        'k8s_delete_ns' => _t(
          context,
          zh: 'K8s 命名空间批量删除',
          en: 'K8s namespace delete',
          ja: 'K8s 名前空間削除',
          ru: 'Удаление namespace K8s',
        ),
        'pipe_shell' => _t(
          context,
          zh: '远程脚本管道直跑 (curl|sh)',
          en: 'Remote script pipe to shell',
          ja: 'リモートスクリプト直接実行',
          ru: 'Запуск скрипта из сети',
        ),
        'fork_bomb' => _t(
          context,
          zh: 'Fork 炸弹特征',
          en: 'Fork bomb pattern',
          ja: 'フォークボム検知',
          ru: 'Fork-бомба',
        ),
        _ => riskId,
      };

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final destructive = analysis.level == PasteRiskLevel.destructive;
    final accent = destructive ? palette.red : palette.orange;
    final canPasteWithoutNewline =
        analysis.hasTrailingNewline &&
        analysis.strippedTrailingNewline.isNotEmpty &&
        !analysis.strippedTrailingNewline.contains('\n');

    final title = destructive
        ? _t(
            context,
            zh: '高危生产命令粘贴警告',
            en: 'High-risk command paste warning',
            ja: '高リスクコマンド貼り付け警告',
            ru: 'Опасная команда в буфере обмена',
          )
        : _t(
            context,
            zh: '多行命令粘贴确认',
            en: 'Multi-line paste confirmation',
            ja: '複数行の貼り付け確認',
            ru: 'Подтверждение многострочной вставки',
          );

    final subtitle = destructive
        ? _t(
            context,
            zh: '检测到可能影响线上系统或数据的命令特征，请确认当前终端目标主机无误后再继续。',
            en: 'Destructive command pattern detected. Verify the active production host before continuing.',
            ja: 'システムやデータに影響する危険なコマンドを検出しました。接続先ホストを確認してください。',
            ru: 'Обнаружена потенциально разрушительная команда. Проверьте активный сервер перед вставкой.',
          )
        : _t(
            context,
            zh: '剪贴板包含 ${analysis.lineCount} 行内容（含换行符），在当前终端粘贴可能会立即自动执行。',
            en: 'Clipboard contains ${analysis.lineCount} line(s) with line breaks that may execute immediately.',
            ja: 'クリップボードに改行を含む ${analysis.lineCount} 行があり、貼り付け直後に自動実行される可能性があります。',
            ru: 'В буфере ${analysis.lineCount} строк(и) с переносами — команды могут выполниться сразу после вставки.',
          );

    final previewText = [
      ...analysis.previewLines,
      if (analysis.lineCount > analysis.previewLines.length)
        _t(
          context,
          zh: '… 其余 ${analysis.lineCount - analysis.previewLines.length} 行已折叠',
          en: '… ${analysis.lineCount - analysis.previewLines.length} more line(s)',
          ja: '… 他 ${analysis.lineCount - analysis.previewLines.length} 行',
          ru: '… ещё ${analysis.lineCount - analysis.previewLines.length} строк(и)',
        ),
    ].join('\n');

    // Arrow keys move focus between the buttons; the focused one shows a
    // stronger fill instead of a ring.
    WidgetStateProperty<Color?> focusFill(Color color) =>
        WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused) ? color : null,
        );
    final focusStyle = ButtonStyle(
      overlayColor: focusFill(
        Theme.of(context).colorScheme.primary.withValues(alpha: .22),
      ),
    );
    final filledFocusStyle = ButtonStyle(
      overlayColor: focusFill(Colors.white.withValues(alpha: .24)),
    );
    final density = AppDensity.of(context);
    final dialog = AlertDialog(
      key: const ValueKey('paste_safety_dialog'),
      title: Row(
        children: [
          Icon(
            destructive
                ? Icons.gpp_maybe_rounded
                : Icons.warning_amber_rounded,
            color: accent,
            size: 22,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                subtitle,
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              if (analysis.matchedRisks.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  key: const ValueKey('paste_safety_risk_chips'),
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final risk in analysis.matchedRisks)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(density.radiusMd),
                        ),
                        child: Text(
                          _riskChipLabel(context, risk),
                          style: TextStyle(
                            color: accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Container(
                key: const ValueKey('paste_safety_preview'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(
                    SurfaceScope.concentric(
                      context,
                      fallback: density.radiusMd,
                      floor: density.radiusMd,
                    ),
                  ),
                ),
                child: Text(
                  previewText,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('paste_safety_cancel'),
          autofocus: !canPasteWithoutNewline,
          style: focusStyle,
          onPressed: () => Navigator.of(context).pop(null),
          child: Text(
            _t(context, zh: '取消', en: 'Cancel', ja: 'キャンセル', ru: 'Отмена'),
          ),
        ),
        if (canPasteWithoutNewline)
          OutlinedButton(
            key: const ValueKey('paste_safety_strip_newline'),
            autofocus: true,
            style: focusStyle,
            onPressed: () =>
                Navigator.of(context).pop(analysis.strippedTrailingNewline),
            child: Text(
              _t(
                context,
                zh: '去除回车粘贴',
                en: 'Paste without Enter',
                ja: '改行なしで貼り付け',
                ru: 'Вставить без Enter',
              ),
            ),
          ),
        FilledButton(
          key: const ValueKey('paste_safety_confirm'),
          style: filledFocusStyle.merge(
            destructive
                ? FilledButton.styleFrom(
                    backgroundColor: palette.red,
                    foregroundColor: Colors.white,
                  )
                : null,
          ),
          onPressed: () => Navigator.of(context).pop(originalText),
          child: Text(
            destructive
                ? _t(
                    context,
                    zh: '确认风险并粘贴',
                    en: 'Paste anyway',
                    ja: 'リスクを承知で貼り付け',
                    ru: 'Всё равно вставить',
                  )
                : _t(
                    context,
                    zh: '确认粘贴',
                    en: 'Paste',
                    ja: '貼り付け',
                    ru: 'Вставить',
                  ),
          ),
        ),
      ],
    );
    return FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowLeft): PreviousFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowRight): NextFocusIntent(),
        },
        child: dialog,
      ),
    );
  }
}
