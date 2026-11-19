import 'package:flutter/foundation.dart';

/// 终端粘贴风险等级。
enum PasteRiskLevel {
  /// 普通单行安全文本（或处于 bracketed paste 保护下的无害多行文本）。
  safe,

  /// 未启用 bracketed paste 时包含换行符的多行文本（粘贴即会逐行自动执行命令）。
  multiline,

  /// 命中商业生产环境高危破坏性命令特征（如 `rm -rf`、`DROP DATABASE`、`shutdown`、`curl|sh` 等）。
  destructive,
}

/// 终端粘贴安全分析结果。
@immutable
class PasteSafetyAnalysis {
  const PasteSafetyAnalysis({
    required this.level,
    required this.lineCount,
    required this.hasTrailingNewline,
    required this.matchedRisks,
    required this.previewLines,
    required this.strippedTrailingNewline,
  });

  final PasteRiskLevel level;
  final int lineCount;
  final bool hasTrailingNewline;

  /// 命中的风险标识码（例如 `rm_rf`、`disk_format`、`power_control`、`sql_drop`、`pipe_shell`）。
  final List<String> matchedRisks;

  /// 最多 6 行脱敏截断后的预览行。
  final List<String> previewLines;

  /// 去除末尾回车换行后的版本，允许运维人员粘贴到命令行先检查再按回车执行。
  final String strippedTrailingNewline;

  bool get isSafe => level == PasteRiskLevel.safe;
  bool get requiresConfirmation => level != PasteRiskLevel.safe;
}

final List<({String id, RegExp pattern})> _destructiveRules = [
  (
    id: 'rm_rf',
    pattern: RegExp(
      r'(^|[;&|\s])(sudo\s+)?rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f|rm\s+-[a-zA-Z]*f[a-zA-Z]*[rR]|rm\s+--no-preserve-root',
      caseSensitive: false,
      multiLine: true,
    ),
  ),
  (
    id: 'disk_format',
    pattern: RegExp(
      r'(^|[;&|\s])(sudo\s+)?(mkfs(\.[a-z0-9]+)?|fdisk|parted|wipefs|dd\s+if=)',
      caseSensitive: false,
      multiLine: true,
    ),
  ),
  (
    id: 'power_control',
    pattern: RegExp(
      r'(^|[;&|\s])(sudo\s+)?(shutdown|reboot|poweroff|halt|init\s+[06])(\s|$|[;&|])',
      caseSensitive: false,
      multiLine: true,
    ),
  ),
  (
    id: 'chmod_777',
    pattern: RegExp(
      r'(^|[;&|\s])(sudo\s+)?chmod\s+(-R|--recursive)\s+777\b',
      caseSensitive: false,
      multiLine: true,
    ),
  ),
  (
    id: 'firewall_flush',
    pattern: RegExp(
      r'(^|[;&|\s])(sudo\s+)?(iptables|ip6tables|nft)\s+(-F|--flush|flush\s+ruleset)',
      caseSensitive: false,
      multiLine: true,
    ),
  ),
  (
    id: 'sql_drop',
    pattern: RegExp(
      r'\b(DROP\s+(TABLE|DATABASE|SCHEMA)|TRUNCATE\s+TABLE|FLUSHALL|FLUSHDB)\b',
      caseSensitive: false,
    ),
  ),
  (
    id: 'k8s_delete_ns',
    pattern: RegExp(
      r'\bkubectl\s+delete\s+(ns|namespace|all\s+--all)\b',
      caseSensitive: false,
    ),
  ),
  (
    id: 'pipe_shell',
    pattern: RegExp(
      r'\b(curl|wget)\b[^\r\n|]*\|\s*(sudo\s+)?(sh|bash|zsh)\b',
      caseSensitive: false,
    ),
  ),
  (
    id: 'fork_bomb',
    pattern: RegExp(r':\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:'),
  ),
];

/// 分析即将粘贴进终端的剪贴板文本是否存在误执行或破坏性生产事故风险。
///
/// - 当 [bracketedPasteActive] 为 `true`（远端 Shell 已开启 `\x1b[?2004h`）时，
///   普通多行文本不会被自动执行，因此仅拦截命中破坏性命令规则的高危内容；
/// - 当 [bracketedPasteActive] 为 `false`（常见于老旧 Linux、Alpine/BusyBox、网络设备或
///   纯 `sh`）时，任何包含 `\n` 或 `\r` 的多行/带尾部回车文本都会立即触发执行风险提示。
PasteSafetyAnalysis analyzeTerminalPaste(
  String text, {
  bool bracketedPasteActive = false,
}) {
  if (text.isEmpty) {
    return const PasteSafetyAnalysis(
      level: PasteRiskLevel.safe,
      lineCount: 0,
      hasTrailingNewline: false,
      matchedRisks: [],
      previewLines: [],
      strippedTrailingNewline: '',
    );
  }

  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final hasNewline = normalized.contains('\n');
  final hasTrailingNewline = normalized.endsWith('\n');
  final stripped = normalized.replaceFirst(RegExp(r'\n+$'), '');
  final rawLines = stripped.isEmpty ? <String>[''] : stripped.split('\n');
  final lineCount = rawLines.length;

  final matchedRisks = <String>[];
  for (final rule in _destructiveRules) {
    if (rule.pattern.hasMatch(normalized)) {
      matchedRisks.add(rule.id);
    }
  }

  final previewLines = <String>[
    for (final line in rawLines.take(6))
      line.length > 140 ? '${line.substring(0, 140)}…' : line,
  ];

  final PasteRiskLevel level;
  if (matchedRisks.isNotEmpty) {
    level = PasteRiskLevel.destructive;
  } else if (hasNewline && !bracketedPasteActive) {
    level = PasteRiskLevel.multiline;
  } else {
    level = PasteRiskLevel.safe;
  }

  return PasteSafetyAnalysis(
    level: level,
    lineCount: lineCount,
    hasTrailingNewline: hasTrailingNewline,
    matchedRisks: List.unmodifiable(matchedRisks),
    previewLines: List.unmodifiable(previewLines),
    strippedTrailingNewline: stripped,
  );
}

/// 进程级粘贴安全护栏开关控制器（默认开启，商业生产运维防误触标准配置）。
class PasteSafetyController extends ChangeNotifier {
  PasteSafetyController({bool enabled = true}) : _enabled = enabled;

  static PasteSafetyController? _instance;

  static PasteSafetyController get instance =>
      _instance ??= PasteSafetyController();

  @visibleForTesting
  static set debugInstance(PasteSafetyController? controller) =>
      _instance = controller;

  bool _enabled;
  bool get enabled => _enabled;

  void setEnabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
  }
}
