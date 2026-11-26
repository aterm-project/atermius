import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../mcp/mcp_call_summary.dart';
import '../mcp/mcp_notices.dart';
import '../mcp/mcp_service.dart';
import 'app_density.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'responsive_layout.dart';
import 'window_caption.dart' show WindowBarMetrics;
import 'workspace_controls.dart' show workspaceMenuBorder;

/// How long the top-bar button stays after the last call while MCP is not
/// listening: in-process gateways call without the HTTP listener.
const mcpActivityRecentWindow = Duration(minutes: 2);

/// Below this window width the activity panel is a bottom sheet.
const _sheetBreakpoint = 600.0;

/// The top-bar entry point to what AI clients do through MCP. Shown while MCP
/// listens, while a call runs and for [mcpActivityRecentWindow] after the
/// last one. A running call shows a progress ring (and, with [showLabel], the
/// tool's title); tapping opens the list of recent calls.
///
/// It also presents `ui_notify` messages, once per message however many bars
/// are mounted.
class McpActivityButton extends StatefulWidget {
  const McpActivityButton({
    super.key,
    this.service,
    this.metrics,
    this.showLabel = false,
    this.liveSessionIds = const {},
    this.onFocusSession,
    this.onOpenSettings,
  });

  /// [McpService.instance] when null.
  final McpService? service;
  final WindowBarMetrics? metrics;

  /// Whether the bar has room for the running tool's title.
  final bool showLabel;

  /// Sessions open in this window: calls on them can be focused.
  final Set<String> liveSessionIds;
  final ValueChanged<String>? onFocusSession;
  final VoidCallback? onOpenSettings;

  @override
  State<McpActivityButton> createState() => _McpActivityButtonState();
}

class _McpActivityButtonState extends State<McpActivityButton> {
  /// Mounted buttons, oldest first. One of them presents each notice.
  static final _presenters = <_McpActivityButtonState>[];
  static StreamSubscription<McpNotice>? _notices;

  McpService get _service => widget.service ?? McpService.instance;
  Timer? _expiry;

  @override
  void initState() {
    super.initState();
    _service.addListener(_changed);
    _presenters.add(this);
    _notices ??= McpNotices.stream.listen(_present);
  }

  @override
  void didUpdateWidget(McpActivityButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.service ?? McpService.instance;
    if (!identical(old, _service)) {
      old.removeListener(_changed);
      _service.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _service.removeListener(_changed);
    _presenters.remove(this);
    if (_presenters.isEmpty) {
      unawaited(_notices?.cancel());
      _notices = null;
    }
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// The bar of the window in front presents a notice: the most recently
  /// mounted button whose subtree is active, else any mounted one.
  static void _present(McpNotice notice) {
    _McpActivityButtonState? chosen;
    for (final presenter in _presenters.reversed) {
      if (!presenter.mounted) continue;
      chosen ??= presenter;
      if (TickerMode.getValuesNotifier(presenter.context).value.enabled) {
        chosen = presenter;
        break;
      }
    }
    chosen?._showNotice(notice);
  }

  bool _visible(DateTime now) {
    final service = _service;
    if (service.running || service.activeCalls.isNotEmpty) return true;
    final last = service.lastActivity;
    return last != null && now.difference(last) < mcpActivityRecentWindow;
  }

  /// Rebuilds when the recent-call window ends, so the button goes away.
  void _scheduleExpiry(DateTime now) {
    _expiry?.cancel();
    _expiry = null;
    final service = _service;
    final last = service.lastActivity;
    if (service.running || service.activeCalls.isNotEmpty || last == null) {
      return;
    }
    final left = mcpActivityRecentWindow - now.difference(last);
    if (left <= Duration.zero) return;
    _expiry = Timer(left + const Duration(milliseconds: 50), _changed);
  }

  void _showNotice(McpNotice notice) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final palette = context.palette;
    final l10n = context.l10n;
    final (icon, iconColor, background, foreground) = switch (notice.level) {
      McpNoticeLevel.info => (
        Icons.smart_toy_outlined,
        palette.accentText,
        null,
        palette.text,
      ),
      McpNoticeLevel.success => (
        Icons.check_circle_outline,
        palette.accentText,
        null,
        palette.text,
      ),
      McpNoticeLevel.warning => (
        Icons.warning_amber_rounded,
        palette.orange,
        palette.warningContainer,
        palette.text,
      ),
      McpNoticeLevel.error => (
        Icons.error_outline,
        palette.onErrorContainer,
        palette.errorContainer,
        palette.onErrorContainer,
      ),
    };
    final serious =
        notice.level == McpNoticeLevel.warning ||
        notice.level == McpNoticeLevel.error;
    messenger.showSnackBar(
      SnackBar(
        key: ValueKey('mcp_notice_${notice.level.name}'),
        backgroundColor: background,
        duration: Duration(seconds: serious ? 8 : 5),
        content: Row(
          children: [
            Icon(icon, size: 20, color: iconColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.mcpNoticeFromAi(mcpPlainNoticeText(notice.message)),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: foreground),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          key: const ValueKey('mcp_notice_view'),
          label: l10n.mcpNoticeView,
          textColor: notice.level == McpNoticeLevel.error
              ? palette.onErrorContainer
              : palette.accentText,
          onPressed: () {
            if (mounted) _open();
          },
        ),
      ),
    );
  }

  bool _canFocus(String id) =>
      mounted &&
      widget.onFocusSession != null &&
      widget.liveSessionIds.contains(id);

  void _focus(String id) {
    if (_canFocus(id)) widget.onFocusSession!(id);
  }

  void _openSettings() {
    if (mounted) widget.onOpenSettings?.call();
  }

  Widget _panel(BuildContext context, VoidCallback close) => McpActivityPanel(
    service: _service,
    canFocus: _canFocus,
    onFocusSession: (id) {
      close();
      _focus(id);
    },
    onOpenSettings: widget.onOpenSettings == null
        ? null
        : () {
            close();
            _openSettings();
          },
    onClose: close,
  );

  void _open() {
    final platform = Theme.of(context).platform;
    final size = MediaQuery.sizeOf(context);
    final navigator = Navigator.of(context);
    if (isTouchPlatform(platform) || size.width < _sheetBreakpoint) {
      unawaited(
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          backgroundColor: context.palette.surface,
          constraints: BoxConstraints(
            maxHeight: size.height * .85,
            maxWidth: 640,
          ),
          builder: (sheet) => _panel(sheet, () => Navigator.of(sheet).pop()),
        ),
      );
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    final overlay = navigator.overlay?.context.findRenderObject() as RenderBox?;
    var anchor = Rect.fromLTWH(size.width - 8, 48, 0, 0);
    if (box != null && box.hasSize && overlay != null) {
      final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
      anchor = topLeft & box.size;
    }
    unawaited(
      navigator.push(
        _McpPopoverRoute(
          anchor: anchor,
          themes: InheritedTheme.capture(from: context, to: navigator.context),
          barrierLabel: MaterialLocalizations.of(context)
              .modalBarrierDismissLabel,
          builder: (popover) {
            final palette = popover.palette;
            return Material(
              key: const ValueKey('mcp_activity_popover'),
              color: palette.surfaceRaised,
              surfaceTintColor: Colors.transparent,
              elevation: 8,
              shadowColor: Colors.black.withValues(
                alpha: palette.isDark ? .45 : .14,
              ),
              shape: workspaceMenuBorder(popover),
              clipBehavior: Clip.antiAlias,
              child: _panel(popover, () => Navigator.of(popover).maybePop()),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = clock.now();
    _scheduleExpiry(now);
    if (!_visible(now)) return const SizedBox.shrink();
    final l10n = context.l10n;
    final palette = context.palette;
    final metrics = widget.metrics;
    final dense = metrics?.dense ?? false;
    final service = _service;
    final active = service.activeCalls;
    final current = active.isEmpty ? null : active.last;
    final title = current == null ? null : mcpToolTitle(current.tool);
    final tooltip = current == null
        ? l10n.mcpActivityTitle
        : current.target == null
        ? l10n.mcpActivityRunning(title!)
        : l10n.mcpActivityRunningOn(title!, current.target!);
    final iconSize = dense ? 17.0 : 21.0;
    final color = current != null || service.running
        ? palette.accentText
        : palette.muted;

    if (current != null && widget.showLabel) {
      final radius = BorderRadius.circular(AppDensity.of(context).radiusMd);
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 4,
          vertical: metrics?.tabInset ?? 8,
        ),
        child: Tooltip(
          message: tooltip,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: const ValueKey('mcp_activity_button'),
              borderRadius: radius,
              onTap: _open,
              child: Container(
                height: metrics?.tabHeight ?? 32,
                constraints: const BoxConstraints(maxWidth: 240),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  borderRadius: radius,
                  color: palette.accent.withValues(
                    alpha: palette.isDark ? .22 : .12,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox.square(
                      dimension: 14,
                      child: CircularProgressIndicator(
                        key: const ValueKey('mcp_activity_spinner'),
                        strokeWidth: 2,
                        color: palette.accentText,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        l10n.mcpActivityLabel(title!),
                        key: const ValueKey('mcp_activity_label'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: dense ? 12.5 : 13,
                          fontWeight: FontWeight.w600,
                          color: palette.accentText,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget glyph = Icon(Icons.smart_toy_outlined, size: iconSize, color: color);
    if (current != null) {
      glyph = SizedBox.square(
        dimension: iconSize + 9,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CircularProgressIndicator(
                key: const ValueKey('mcp_activity_spinner'),
                strokeWidth: 2,
                color: palette.accentText,
                backgroundColor: palette.accentText.withValues(alpha: .15),
              ),
            ),
            Icon(Icons.smart_toy_outlined, size: iconSize - 4, color: color),
          ],
        ),
      );
    }
    return IconButton(
      key: const ValueKey('mcp_activity_button'),
      tooltip: tooltip,
      onPressed: _open,
      icon: glyph,
    );
  }
}

/// Text an AI client asked to show, as one plain paragraph: control and
/// direction-override characters become spaces.
String mcpPlainNoticeText(String message) => message
    .replaceAll(
      RegExp(
        '[\u0000-\u0009\u000b-\u001f\u007f-\u009f'
        '\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]',
      ),
      ' ',
    )
    .trim();

/// Recent MCP calls, newest first, with the listener's state. Shown in the
/// top-bar popover or bottom sheet.
class McpActivityPanel extends StatelessWidget {
  const McpActivityPanel({
    super.key,
    required this.service,
    this.canFocus,
    this.onFocusSession,
    this.onOpenSettings,
    this.onClose,
  });

  final McpService service;

  /// Whether a call's session is open in this window.
  final bool Function(String sessionId)? canFocus;
  final ValueChanged<String>? onFocusSession;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final l10n = context.l10n;
      final palette = context.palette;
      final entries = service.audit;
      final endpoint = service.endpoint;
      return Column(
        key: const ValueKey('mcp_activity_panel'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 6, 4),
            child: Row(
              children: [
                Icon(
                  Icons.smart_toy_outlined,
                  size: 20,
                  color: palette.accentText,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    l10n.mcpActivityTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: palette.text,
                    ),
                  ),
                ),
                if (onOpenSettings != null)
                  IconButton(
                    key: const ValueKey('mcp_activity_settings'),
                    tooltip: l10n.mcpActivityOpenSettings,
                    onPressed: onOpenSettings,
                    icon: const Icon(Icons.settings_outlined, size: 20),
                  ),
                if (onClose != null)
                  IconButton(
                    key: const ValueKey('mcp_activity_close'),
                    tooltip: l10n.close,
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 20),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: endpoint == null
                ? Text(
                    l10n.mcpActivityNotListening,
                    key: const ValueKey('mcp_activity_not_listening'),
                    style: TextStyle(color: palette.muted, fontSize: 12.5),
                  )
                : Container(
                    padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
                    decoration: BoxDecoration(
                      color: palette.codeBackground,
                      borderRadius: BorderRadius.circular(
                        AppDensity.of(context).radiusMd,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: palette.accentText,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.mcpActivityListening(endpoint.toString()),
                            key: const ValueKey('mcp_activity_endpoint'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: palette.codeText,
                            ),
                          ),
                        ),
                        TextButton(
                          key: const ValueKey('mcp_activity_stop'),
                          style: TextButton.styleFrom(
                            foregroundColor: palette.red,
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: () => unawaited(service.stop()),
                          child: Text(l10n.mcpActivityStop),
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 1),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
              child: Text(
                l10n.mcpActivityEmpty,
                key: const ValueKey('mcp_activity_empty'),
                style: TextStyle(color: palette.muted, height: 1.4),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final session = entry.focusSessionId;
                  final focusable =
                      session != null &&
                      onFocusSession != null &&
                      (canFocus?.call(session) ?? false);
                  return McpCallTile(
                    key: ValueKey('mcp_activity_entry_${entry.id}'),
                    entry: entry,
                    onTap: focusable ? () => onFocusSession!(session) : null,
                  );
                },
              ),
            ),
          const SizedBox(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              l10n.onlyTheLast50ToolNames,
              style: TextStyle(color: palette.hint, fontSize: 11, height: 1.35),
            ),
          ),
        ],
      );
    },
  );
}

/// One MCP call: status, tool title and target, the argument summary in
/// monospace and when it ran, how long it took and how it ended.
class McpCallTile extends StatelessWidget {
  const McpCallTile({
    super.key,
    required this.entry,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
  });

  final McpAuditEntry entry;

  /// Shows the call's session; null when it is not open here.
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final palette = context.palette;
    final failed = !entry.running && !entry.success;
    final status = entry.running
        ? SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.accentText,
            ),
          )
        : Icon(
            entry.success ? Icons.check_circle_outline : Icons.error_outline,
            size: 18,
            color: entry.success ? palette.accentText : palette.red,
          );
    final muted = TextStyle(color: palette.muted, fontSize: 11.5);
    final meta = <InlineSpan>[
      TextSpan(text: mcpClockTime(entry.at)),
      if (entry.running)
        TextSpan(text: ' · ${l10n.mcpActivityInProgress}')
      else if (entry.duration case final duration?)
        TextSpan(text: ' · ${mcpCallDuration(l10n, duration)}'),
      if (failed)
        TextSpan(
          text: ' · ${l10n.mcpActivityFailed(entry.error ?? '?')}',
          style: TextStyle(color: palette.red, fontWeight: FontWeight.w600),
        )
      else if (entry.result case final result?)
        TextSpan(
          text: ' · $result',
          style: TextStyle(color: palette.text, fontWeight: FontWeight.w500),
        ),
      if (entry.source != mcpExternalCaller)
        TextSpan(text: ' · ${l10n.mcpActivityVia(entry.source)}'),
    ];
    final content = Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: SizedBox(width: 20, child: Center(child: status)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: mcpToolTitle(entry.tool),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: palette.text,
                        ),
                      ),
                      if (entry.target case final target?)
                        TextSpan(
                          text: ' · $target',
                          style: TextStyle(color: palette.muted),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
                if (entry.summary.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: palette.codeBackground,
                      borderRadius: BorderRadius.circular(
                        AppDensity.of(context).radiusSm,
                      ),
                    ),
                    child: Text(
                      entry.summary,
                      key: ValueKey('mcp_call_summary_${entry.id}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        height: 1.35,
                        color: palette.codeText,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text.rich(
                  TextSpan(children: meta),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              ],
            ),
          ),
          if (onTap != null)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 1),
              child: Tooltip(
                message: l10n.mcpActivityShowSession,
                child: Icon(
                  Icons.open_in_new_rounded,
                  size: 16,
                  color: palette.muted,
                ),
              ),
            ),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(AppDensity.of(context).radiusMd),
      onTap: onTap,
      child: content,
    );
  }
}

/// `HH:mm:ss` in local time; calls are minutes apart at most, so the clock
/// reads better than a relative time that would need refreshing.
String mcpClockTime(DateTime at) {
  final local = at.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String mcpCallDuration(AppLocalizations l10n, Duration duration) {
  final ms = duration.inMilliseconds;
  if (ms < 1000) return l10n.mcpActivityDurationMs(math.max(ms, 0));
  final seconds = ms / 1000;
  return l10n.mcpActivityDurationSeconds(
    seconds < 10 ? seconds.toStringAsFixed(1) : seconds.round().toString(),
  );
}

/// A panel under its anchor (the top-bar button), right-aligned to it and
/// kept inside the window.
class _McpPopoverRoute extends PopupRoute<void> {
  _McpPopoverRoute({
    required this.anchor,
    required this.themes,
    required this.builder,
    required this.barrierLabel,
  });

  final Rect anchor;
  final CapturedThemes themes;
  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => MotionDurations.standard;

  @override
  Duration get reverseTransitionDuration => MotionDurations.quick;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => CustomSingleChildLayout(
    delegate: _PopoverLayout(anchor, MediaQuery.paddingOf(context)),
    child: themes.wrap(Builder(builder: builder)),
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (AppMotion.reduced(context)) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: MotionCurves.enter,
      reverseCurve: MotionCurves.exit,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, -.02),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

class _PopoverLayout extends SingleChildLayoutDelegate {
  _PopoverLayout(this.anchor, this.padding);
  final Rect anchor;
  final EdgeInsets padding;

  static const _gap = 6.0;
  static const _margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(440.0, constraints.maxWidth - 2 * _margin);
    final available =
        constraints.maxHeight - anchor.bottom - _gap - _margin - padding.bottom;
    return BoxConstraints(
      minWidth: width,
      maxWidth: width,
      maxHeight: math.max(160.0, math.min(560.0, available)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = (anchor.right - childSize.width)
        .clamp(
          _margin,
          math.max(_margin, size.width - childSize.width - _margin),
        )
        .toDouble();
    return Offset(left, anchor.bottom + _gap);
  }

  @override
  bool shouldRelayout(_PopoverLayout oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
}
