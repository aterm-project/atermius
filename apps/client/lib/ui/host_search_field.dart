import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/quick_connect.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'apple_hig.dart';
import 'ios_native/ios_native.dart';

Future<HostRecord?> chooseQuickConnectHost(
  BuildContext context,
  List<HostRecord> matches,
) async {
  if (matches.length == 1) return matches.single;
  if (isIosPhone(context)) {
    return showIosFormSheet<HostRecord>(
      context,
      builder: (sheetContext) => IosSheetScaffold(
        title: context.l10n.chooseAHostToConnectTo,
        children: [
          IosListSection(
            separatorIndent: IosListSection.indentForIcon(),
            children: [
              for (final host in matches)
                IosListRow(
                  leading: IosIconTile(
                    icon: IosIcons.hosts,
                    color: IosColors.of(sheetContext).tint,
                  ),
                  title: Text(host.name),
                  subtitle: Text(
                    '${host.username}@${host.address}:${host.port}',
                  ),
                  monoSubtitle: true,
                  accessory: IosRowAccessory.chevron,
                  onTap: () {
                    AppleHaptics.selection(sheetContext);
                    Navigator.of(sheetContext).pop(host);
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
  return showAppDialog<HostRecord>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(context.l10n.chooseAHostToConnectTo),
      children: [
        for (final host in matches)
          SimpleDialogOption(
            onPressed: () {
              AppleHaptics.selection(dialogContext);
              Navigator.pop(dialogContext, host);
            },
            child: Text(
              '${host.name}\n${host.username}@${host.address}:${host.port}',
            ),
          ),
      ],
    ),
  );
}

class HostSearchField extends StatefulWidget {
  const HostSearchField({
    super.key,
    required this.fieldKey,
    required this.controller,
    required this.onChanged,
    required this.onConnect,
    this.enabled = true,
    this.autofocus = false,
    this.onSearchSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<QuickConnectRequest> onConnect;
  final bool enabled;
  final bool autofocus;
  final VoidCallback? onSearchSubmitted;

  @override
  State<HostSearchField> createState() => _HostSearchFieldState();
}

class _HostSearchFieldState extends State<HostSearchField> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(covariant HostSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _clearSearch(BuildContext context) {
    AppleHaptics.selection(context);
    widget.controller.clear();
    widget.onChanged('');
  }

  void _submitConnect(BuildContext context, QuickConnectRequest command) {
    AppleHaptics.light(context);
    widget.onConnect(command);
  }

  @override
  Widget build(BuildContext context) {
    QuickConnectRequest? request;
    String? syntax;
    try {
      request = QuickConnectRequest.parse(widget.controller.text);
    } on FormatException catch (e) {
      syntax = e.message;
    }
    final command = request;
    if (isIosPhone(context)) {
      final c = IosColors.of(context);
      Widget iosField = buildIosSearchTextField(
        context,
        key: widget.fieldKey,
        controller: widget.controller,
        autofocus: widget.autofocus,
        placeholder: context.l10n.searchHostsOrTypeAnSsh,
        onChanged: widget.onChanged,
        onSuffixTap: () => AppleHaptics.selection(context),
        onSubmitted: !widget.enabled || syntax != null
            ? null
            : (_) => command != null
                  ? _submitConnect(context, command)
                  : widget.onSearchSubmitted?.call(),
      );
      if (!widget.enabled) {
        iosField = IgnorePointer(
          child: Opacity(opacity: 0.5, child: iosField),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          iosField,
          if (command != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRSuperellipse(
                borderRadius: BorderRadius.circular(18),
                child: ColoredBox(
                  color: c.cell,
                  child: IosListRow(
                    key: const ValueKey('quick_connect_action'),
                    leading: IosIconTile(icon: IosIcons.bolt, color: c.tint),
                    title: Text(
                      context.l10n.labelPressEnterToConnect(command.label),
                    ),
                    accessory: IosRowAccessory.none,
                    enabled: widget.enabled,
                    onTap: widget.enabled
                        ? () => _submitConnect(context, command)
                        : null,
                  ),
                ),
              ),
            ),
          if (syntax != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 12, right: 12),
              child: Text(
                syntax,
                style: IosType.footnote.copyWith(color: c.secondaryLabel),
              ),
            ),
        ],
      );
    }
    final platform = Theme.of(context).platform;
    final apple = isAppleContext(context);
    final palette = context.palette;
    final density = AppDensity.of(context);
    final hasText = widget.controller.text.isNotEmpty;

    final Widget searchField;
    if (apple) {
      final searchRadius = BorderRadius.circular(density.isCompact ? 10 : 12);
      final fillColor = palette.isDark
          ? (_focused
                ? palette.surfaceSoft.withValues(alpha: 0.92)
                : palette.surfaceRaised.withValues(alpha: 0.90))
          : (_focused ? palette.surface : palette.surfaceRaised);
      final borderColor = _focused
          ? palette.accentText.withValues(alpha: palette.isDark ? 0.65 : 0.55)
          : palette.line.withValues(alpha: palette.isDark ? 0.60 : 0.78);
      final clearButton = !hasText
          ? null
          : IconButton(
              tooltip: context.l10n.clearSearch,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              onPressed: () => _clearSearch(context),
              icon: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.muted.withValues(
                    alpha: palette.isDark ? 0.26 : 0.18,
                  ),
                  shape: BoxShape.circle,
                ),
                child: SizedBox.square(
                  dimension: 18,
                  child: Icon(
                    Icons.close,
                    size: 12,
                    color: palette.text.withValues(alpha: 0.88),
                  ),
                ),
              ),
            );
      searchField = Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (focused) {
          if (!mounted || _focused == focused) return;
          setState(() => _focused = focused);
        },
        child: AnimatedContainer(
          duration: AppMotion.duration(context, MotionDurations.quick),
          curve: MotionCurves.enter,
          decoration: ShapeDecoration(
            color: fillColor,
            shape: appleSquircleBorder(
              searchRadius,
              platform: platform,
              side: BorderSide(
                color: borderColor,
                width: _focused ? 1.0 : appleHairlineWidth(context),
              ),
            ),
            shadows: _focused
                ? [
                    BoxShadow(
                      color: palette.accent.withValues(
                        alpha: palette.isDark ? 0.22 : 0.14,
                      ),
                      blurRadius: 8,
                      spreadRadius: 0.5,
                    ),
                  ]
                : const [],
          ),
          child: TextField(
            key: widget.fieldKey,
            controller: widget.controller,
            autofocus: widget.autofocus,
            onChanged: widget.onChanged,
            textInputAction: TextInputAction.go,
            onSubmitted: !widget.enabled || syntax != null
                ? null
                : (_) => command != null
                      ? _submitConnect(context, command)
                      : widget.onSearchSubmitted?.call(),
            decoration: InputDecoration(
              filled: false,
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 12,
                vertical: density.isCompact ? 10 : 12,
              ),
              prefixIcon: Icon(
                Icons.search,
                size: 19,
                color: _focused ? palette.accentText : palette.muted,
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: 38,
                minHeight: 36,
              ),
              suffixIconConstraints: const BoxConstraints(
                minWidth: 38,
                minHeight: 36,
              ),
              hintText: context.l10n.searchHostsOrTypeAnSsh,
              hintStyle: TextStyle(color: palette.hint),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              suffixIcon: clearButton,
            ),
          ),
        ),
      );
    } else {
      searchField = TextField(
        key: widget.fieldKey,
        controller: widget.controller,
        autofocus: widget.autofocus,
        onChanged: widget.onChanged,
        textInputAction: TextInputAction.go,
        onSubmitted: !widget.enabled || syntax != null
            ? null
            : (_) => command != null
                  ? _submitConnect(context, command)
                  : widget.onSearchSubmitted?.call(),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search, size: 20),
          hintText: context.l10n.searchHostsOrTypeAnSsh,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: !hasText
              ? null
              : IconButton(
                  tooltip: context.l10n.clearSearch,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _clearSearch(context),
                ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        searchField,
        if (command != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: TextButton.icon(
              key: const ValueKey('quick_connect_action'),
              style: apple
                  ? TextButton.styleFrom(
                      backgroundColor: palette.accentContainer.withValues(
                        alpha: palette.isDark ? 0.45 : 0.65,
                      ),
                      foregroundColor: palette.accentText,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      shape: appleSquircleBorder(
                        BorderRadius.circular(10),
                        platform: platform,
                        side: BorderSide(
                          color: palette.accentText.withValues(alpha: 0.24),
                          width: appleHairlineWidth(context),
                        ),
                      ),
                    )
                  : null,
              onPressed: widget.enabled
                  ? () => _submitConnect(context, command)
                  : null,
              icon: const Icon(Icons.arrow_forward, size: 18),
              label: Text(context.l10n.labelPressEnterToConnect(command.label)),
            ),
          ),
        if (syntax != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(syntax, style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}
