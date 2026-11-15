import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../domain/vault_preference.dart';
import '../l10n/l10n.dart';
import '../terminal/keyword_highlighter.dart';
import 'app_menu.dart';
import 'app_theme.dart';
import 'terminal_palette.dart';

/// The localized name of a highlight group: built-in groups are named here,
/// custom groups carry the name the user gave them.
String keywordHighlightGroupLabel(
  AppLocalizations l10n,
  KeywordHighlightGroup group,
) => switch (group.builtin) {
  KeywordHighlightBuiltin.error => l10n.keywordHighlightGroupError,
  KeywordHighlightBuiltin.warning => l10n.keywordHighlightGroupWarning,
  KeywordHighlightBuiltin.success => l10n.keywordHighlightGroupSuccess,
  KeywordHighlightBuiltin.info => l10n.keywordHighlightGroupInfo,
  KeywordHighlightBuiltin.address => l10n.keywordHighlightGroupAddress,
  KeywordHighlightBuiltin.url => l10n.keywordHighlightGroupUrl,
  null => group.name,
};

String _colorLabel(AppLocalizations l10n, KeywordHighlightColor color) =>
    switch (color) {
      KeywordHighlightColor.red => l10n.keywordHighlightColorRed,
      KeywordHighlightColor.green => l10n.keywordHighlightColorGreen,
      KeywordHighlightColor.yellow => l10n.keywordHighlightColorYellow,
      KeywordHighlightColor.blue => l10n.keywordHighlightColorBlue,
      KeywordHighlightColor.magenta => l10n.keywordHighlightColorMagenta,
      KeywordHighlightColor.cyan => l10n.keywordHighlightColorCyan,
    };

/// Device-local keyword highlighting settings (account and local settings):
/// master switch, a live preview on the current terminal palette, and per
/// group a switch, a color and (for keyword groups) the editable word list.
/// Every change applies to open terminals at once.
class TerminalKeywordHighlightSettings extends StatefulWidget {
  const TerminalKeywordHighlightSettings({
    required this.synced,
    this.controller,
    super.key,
  });

  /// The synced terminal theme; with the device palette overlay it decides
  /// the colors shown in the preview and the color menus.
  final VaultTerminalThemeChoice synced;
  final TerminalKeywordHighlighter? controller;

  @override
  State<TerminalKeywordHighlightSettings> createState() =>
      _TerminalKeywordHighlightSettingsState();
}

class _TerminalKeywordHighlightSettingsState
    extends State<TerminalKeywordHighlightSettings> {
  final _expanded = <String>{};
  bool _limitHit = false;

  TerminalKeywordHighlighter get _highlighter =>
      widget.controller ?? TerminalKeywordHighlighter.instance;

  Future<void> _addGroup() async {
    if (_highlighter.settings.customGroups.length >=
        KeywordHighlightLimits.maxCustomGroups) {
      setState(() => _limitHit = true);
      return;
    }
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _GroupNameDialog(),
    );
    if (name == null || !mounted) return;
    final id = _highlighter.addGroup(name);
    if (id != null) setState(() => _expanded.add(id));
  }

  Future<void> _restoreDefaults() async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.keywordHighlightRestoreDefaults),
        content: Text(l10n.keywordHighlightRestoreConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('keyword_highlight_restore_confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.keywordHighlightRestoreDefaults),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _expanded.clear();
      _limitHit = false;
    });
    unawaited(_highlighter.restoreDefaults());
  }

  @override
  Widget build(BuildContext context) {
    final highlighter = _highlighter;
    final theme = terminalColorThemeOf(context, widget.synced);
    return ListenableBuilder(
      listenable: highlighter,
      builder: (context, _) {
        final l10n = context.l10n;
        final palette = context.palette;
        final settings = highlighter.settings;
        return Column(
          key: const ValueKey('keyword_highlight_settings'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.highlight_outlined, size: 20, color: palette.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.keywordHighlightTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Semantics(
                  label: l10n.keywordHighlightEnable,
                  child: Switch(
                    key: const ValueKey('keyword_highlight_enabled'),
                    value: settings.enabled,
                    onChanged: (value) =>
                        unawaited(highlighter.setEnabled(value)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l10n.keywordHighlightDescription,
              style: TextStyle(
                color: palette.muted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: KeywordHighlightPreview(
                key: const ValueKey('keyword_highlight_preview'),
                theme: theme,
                settings: settings,
              ),
            ),
            if (highlighter.writeFailed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  l10n.keywordHighlightSaveFailed,
                  key: const ValueKey('keyword_highlight_save_failed'),
                  style: TextStyle(fontSize: 12, color: palette.orange),
                ),
              ),
            const SizedBox(height: 6),
            for (final group in settings.groups)
              _GroupSection(
                key: ValueKey('keyword_highlight_group_${group.id}'),
                highlighter: highlighter,
                group: group,
                theme: theme,
                expanded: _expanded.contains(group.id),
                onToggle: () => setState(() {
                  if (!_expanded.remove(group.id)) _expanded.add(group.id);
                }),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('keyword_highlight_add_group'),
                  onPressed: _addGroup,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l10n.keywordHighlightAddGroup),
                ),
                TextButton.icon(
                  key: const ValueKey('keyword_highlight_restore'),
                  onPressed: settings.isDefault ? null : _restoreDefaults,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: Text(l10n.keywordHighlightRestoreDefaults),
                ),
              ],
            ),
            if (_limitHit &&
                settings.customGroups.length >=
                    KeywordHighlightLimits.maxCustomGroups)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n.keywordHighlightGroupLimit(
                      KeywordHighlightLimits.maxCustomGroups,
                    ),
                    key: const ValueKey('keyword_highlight_group_limit'),
                    style: TextStyle(fontSize: 12, color: palette.orange),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Sample output drawn the way a terminal with [theme] and [settings] shows
/// it: the same matcher and the same colors as the real terminal views.
class KeywordHighlightPreview extends StatelessWidget {
  const KeywordHighlightPreview({
    required this.theme,
    required this.settings,
    super.key,
  });
  final TerminalTheme theme;
  final KeywordHighlightSettings settings;

  // Program output, the same in every language.
  static const _lines = [
    '[ OK ] Started sshd.service, 12 passed',
    'WARNING: retry in 5s (timed out)',
    'error: connection refused by 10.0.0.2',
    'INFO see https://example.com/docs',
  ];

  static const _mono = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Cascadia Mono', 'Consolas', 'Menlo', 'monospace'],
    fontSize: 11.5,
    height: 1.3,
  );

  @override
  Widget build(BuildContext context) {
    final matcher = KeywordHighlightMatcher.compile(settings);
    final looks = [
      for (final group in matcher.groups)
        TerminalKeywordHighlighter.appearanceOf(theme, group.color),
    ];
    TextSpan line(String text) {
      final spans = <TextSpan>[];
      var position = 0;
      matcher.match(text, (start, end, slot) {
        if (start > position) {
          spans.add(TextSpan(text: text.substring(position, start)));
        }
        final look = looks[slot];
        spans.add(
          TextSpan(
            text: text.substring(start, end),
            style: TextStyle(
              color: look.color,
              fontWeight: look.bold ? FontWeight.bold : null,
              decoration:
                  matcher.groups[slot].builtin == KeywordHighlightBuiltin.url
                  ? TextDecoration.underline
                  : null,
              decorationColor: look.color,
            ),
          ),
        );
        position = end;
      });
      if (position < text.length) {
        spans.add(TextSpan(text: text.substring(position)));
      }
      return TextSpan(children: spans);
    }

    return ExcludeSemantics(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        color: theme.background,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final text in _lines)
              Text.rich(
                line(text),
                style: _mono.copyWith(color: theme.foreground),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
              ),
          ],
        ),
      ),
    );
  }
}

class _GroupSection extends StatefulWidget {
  const _GroupSection({
    required this.highlighter,
    required this.group,
    required this.theme,
    required this.expanded,
    required this.onToggle,
    super.key,
  });
  final TerminalKeywordHighlighter highlighter;
  final KeywordHighlightGroup group;
  final TerminalTheme theme;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<_GroupSection> createState() => _GroupSectionState();
}

class _GroupSectionState extends State<_GroupSection> {
  final _input = TextEditingController();
  KeywordAddResult? _lastAdd;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _add() {
    if (_input.text.trim().isEmpty) return;
    final result = widget.highlighter.addKeyword(widget.group.id, _input.text);
    setState(() {
      _lastAdd = result;
      if (result == KeywordAddResult.added) _input.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final group = widget.group;
    final highlighter = widget.highlighter;
    final label = keywordHighlightGroupLabel(l10n, group);
    final summary = switch (group.builtin) {
      KeywordHighlightBuiltin.address => l10n.keywordHighlightAddressHint,
      KeywordHighlightBuiltin.url => l10n.keywordHighlightUrlHint,
      _ => l10n.keywordHighlightKeywordCount(group.keywords.length),
    };
    // Pattern groups have nothing to expand: what they do is one sentence.
    final expandable = !group.isPattern;
    final heading = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  summary,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.3,
                    color: palette.muted,
                  ),
                ),
              ],
            ),
          ),
          if (expandable)
            Icon(
              widget.expanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: palette.muted,
            ),
        ],
      ),
    );
    final error = switch (_lastAdd) {
      KeywordAddResult.duplicate => l10n.keywordHighlightDuplicate,
      KeywordAddResult.full => l10n.keywordHighlightGroupFull(
        KeywordHighlightLimits.maxKeywordsPerGroup,
      ),
      _ => null,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Divider(height: 1, color: palette.line),
        Row(
          children: [
            _ColorButton(
              key: ValueKey('keyword_highlight_color_${group.id}'),
              theme: widget.theme,
              color: group.color,
              onSelected: (color) =>
                  unawaited(highlighter.setGroupColor(group.id, color)),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: expandable
                  ? Semantics(
                      button: true,
                      expanded: widget.expanded,
                      child: InkWell(
                        key: ValueKey('keyword_highlight_expand_${group.id}'),
                        borderRadius: BorderRadius.circular(8),
                        onTap: widget.onToggle,
                        child: heading,
                      ),
                    )
                  : heading,
            ),
            const SizedBox(width: 4),
            Semantics(
              label: l10n.keywordHighlightGroupSwitch(label),
              child: Switch(
                key: ValueKey('keyword_highlight_switch_${group.id}'),
                value: group.enabled,
                onChanged: (value) =>
                    unawaited(highlighter.setGroupEnabled(group.id, value)),
              ),
            ),
          ],
        ),
        if (expandable && widget.expanded)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (group.keywords.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final keyword in group.keywords)
                          InputChip(
                            key: ValueKey(
                              'keyword_highlight_chip_${group.id}_$keyword',
                            ),
                            label: Text(keyword),
                            // Literal terminal text, so it reads as such.
                            labelStyle: TextStyle(
                              fontFamily: 'monospace',
                              fontFamilyFallback: const [
                                'Cascadia Mono',
                                'Consolas',
                                'Menlo',
                                'monospace',
                              ],
                              fontSize: 12.5,
                              color: palette.text,
                            ),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            deleteButtonTooltipMessage: l10n
                                .keywordHighlightRemoveKeyword(keyword),
                            onDeleted: () => unawaited(
                              highlighter.removeKeyword(group.id, keyword),
                            ),
                          ),
                      ],
                    ),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('keyword_highlight_input_${group.id}'),
                        controller: _input,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(
                            KeywordHighlightLimits.maxKeywordLength,
                          ),
                        ],
                        onChanged: (_) {
                          if (_lastAdd != null) setState(() => _lastAdd = null);
                        },
                        onSubmitted: (_) => _add(),
                        decoration: InputDecoration(
                          hintText: l10n.keywordHighlightAddKeywordHint,
                          errorText: error,
                          errorMaxLines: 3,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      key: ValueKey('keyword_highlight_add_${group.id}'),
                      tooltip: l10n.keywordHighlightAddKeyword,
                      onPressed: _add,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                if (group.builtin == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: TextButton.icon(
                      key: ValueKey('keyword_highlight_delete_${group.id}'),
                      onPressed: () =>
                          unawaited(highlighter.removeGroup(group.id)),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: Text(l10n.keywordHighlightDeleteGroup),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A swatch that opens the color menu. Swatches show what the color looks
/// like on the current terminal palette.
class _ColorButton extends StatelessWidget {
  const _ColorButton({
    required this.theme,
    required this.color,
    required this.onSelected,
    super.key,
  });
  final TerminalTheme theme;
  final KeywordHighlightColor color;
  final ValueChanged<KeywordHighlightColor> onSelected;

  Widget _swatch(BuildContext context, KeywordHighlightColor color) =>
      Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: theme.background,
          shape: BoxShape.circle,
          border: Border.all(color: context.palette.line),
        ),
        alignment: Alignment.center,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: TerminalKeywordHighlighter.appearanceOf(theme, color).color,
            shape: BoxShape.circle,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopupMenuButton<KeywordHighlightColor>(
      tooltip: '${l10n.keywordHighlightColor}: ${_colorLabel(l10n, color)}',
      initialValue: color,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final choice in KeywordHighlightColor.values)
          appMenuItem(
            context,
            key: ValueKey('keyword_highlight_color_option_${choice.id}'),
            value: choice,
            child: Row(
              children: [
                _swatch(context, choice),
                const SizedBox(width: 10),
                Flexible(child: Text(_colorLabel(l10n, choice))),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(9),
        child: _swatch(context, color),
      ),
    );
  }
}

class _GroupNameDialog extends StatefulWidget {
  const _GroupNameDialog();

  @override
  State<_GroupNameDialog> createState() => _GroupNameDialogState();
}

class _GroupNameDialogState extends State<_GroupNameDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = normalizeHighlightGroupName(_name.text);
    if (name != null) Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.keywordHighlightAddGroup),
      content: TextField(
        key: const ValueKey('keyword_highlight_group_name'),
        controller: _name,
        autofocus: true,
        textInputAction: TextInputAction.done,
        inputFormatters: [
          LengthLimitingTextInputFormatter(
            KeywordHighlightLimits.maxGroupNameLength,
          ),
        ],
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(labelText: l10n.keywordHighlightGroupName),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('keyword_highlight_group_create'),
          onPressed: normalizeHighlightGroupName(_name.text) == null
              ? null
              : _submit,
          child: Text(l10n.keywordHighlightAddGroup),
        ),
      ],
    );
  }
}
