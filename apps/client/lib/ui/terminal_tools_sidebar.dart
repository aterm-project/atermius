import 'app_menu.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart'
    show
        CupertinoActivityIndicator,
        CupertinoSlidingSegmentedControl,
        CupertinoTextField,
        OverlayVisibilityMode;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../terminal/terminal_search.dart';
import '../terminal/terminal_tools.dart';
import 'app_motion.dart';
import 'app_theme.dart';
import 'app_density.dart';
import 'apple_hig.dart' show AppleHaptics;
import 'ios_native/ios_native.dart';
import 'surfaces.dart';
import 'workspace_controls.dart' show WorkspaceAction;
import '../l10n/l10n.dart';

/// Presentation state shared by the terminal panes in a workspace.
class TerminalToolsWorkspace {
  final query = TextEditingController();
  final focus = FocusNode(debugLabel: 'Workspace terminal search');
  final history = TerminalSearchHistory();
  bool open = false;
  bool showQuery = true;
  TerminalToolsSection section = TerminalToolsSection.search;

  void show(TerminalToolsSection value) {
    open = true;
    if (value == TerminalToolsSection.search) showQuery = true;
    section = value;
  }

  void toggleQuery(FocusNode terminalFocus) {
    if (open && showQuery) {
      history.remember(query.text);
      showQuery = false;
      terminalFocus.requestFocus();
      return;
    }
    if (!open) show(TerminalToolsSection.search);
    showQuery = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (open && showQuery && focus.context != null) focus.requestFocus();
    });
  }

  void close() {
    history.remember(query.text);
    focus.unfocus();
    query.clear();
    open = false;
    showQuery = true;
  }

  void dispose() {
    query.dispose();
    focus.dispose();
  }
}

/// Keep the terminal child mounted across opening/closing and width changes.
///
/// The sidebar is docked beside the terminal from [dockBreakpoint] and overlays
/// it below that. Its left edge is a drag handle (also arrow-key and
/// screen-reader adjustable). The user's preferred width lives in [width]
/// (default [sharedWidth]) and is only clamped for display, so a narrow
/// viewport never overwrites it and widening the window restores it.
class TerminalToolsLayout extends StatefulWidget {
  const TerminalToolsLayout({
    required this.child,
    this.sidebar,
    this.width,
    super.key,
  });
  final Widget child;
  final Widget? sidebar;

  /// Preferred sidebar width; defaults to [sharedWidth].
  final ValueNotifier<double>? width;

  static const double defaultWidth = 340;
  static const double minWidth = 260;

  /// Docked sidebars never squeeze the terminal below this width.
  static const double minTerminalWidth = 400;
  static const double dockBreakpoint = 760;
  static const double keyboardStep = 16;

  /// In-memory preferred width shared by every terminal workspace (account and
  /// local, every pane) for the app's lifetime. Not persisted.
  static final ValueNotifier<double> sharedWidth = ValueNotifier(defaultWidth);

  /// Displayable width range for a layout [viewport] wide.
  static ({double min, double max}) widthBounds(double viewport) {
    if (!viewport.isFinite || viewport <= 0) {
      return (min: minWidth, max: defaultWidth);
    }
    final min = math.min(minWidth, viewport);
    final max = viewport >= dockBreakpoint
        ? math.min(viewport * .6, viewport - minTerminalWidth)
        : viewport;
    return (min: min, max: math.max(min, max));
  }

  @override
  State<TerminalToolsLayout> createState() => _TerminalToolsLayoutState();
}

class _TerminalToolsLayoutState extends State<TerminalToolsLayout> {
  final _sidebarKey = GlobalKey(debugLabel: 'terminal-tools-sidebar-slot');
  ValueNotifier<double> get _preferred =>
      widget.width ?? TerminalToolsLayout.sharedWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => ValueListenableBuilder<double>(
      valueListenable: _preferred,
      builder: (context, preferred, _) {
        final iosPhone = isIosPhone(context);
        final sidebar = widget.sidebar;
        if (iosPhone) {
          final closeCallback = sidebar is TerminalToolsSidebar
              ? sidebar.onClose
              : null;
          return Stack(
            children: [
              Positioned.fill(child: widget.child),
              if (sidebar != null)
                Positioned.fill(
                  child: _IosTerminalToolsSheet(
                    maxHeight: constraints.maxHeight,
                    onDismiss: closeCallback,
                    child: KeyedSubtree(key: _sidebarKey, child: sidebar),
                  ),
                ),
            ],
          );
        }
        final viewport = constraints.maxWidth;
        final bounds = TerminalToolsLayout.widthBounds(viewport);
        final width = preferred.clamp(bounds.min, bounds.max).toDouble();
        final docked = viewport >= TerminalToolsLayout.dockBreakpoint;
        final extent = _touch(context) ? 20.0 : 8.0;
        final inset = _touch(context) ? 4.0 : 3.0;
        final handleLeft = viewport.isFinite
            ? (viewport - width - extent + inset)
                  .clamp(0.0, math.max(0.0, viewport - extent))
                  .toDouble()
            : 0.0;
        return Stack(
          children: [
            Positioned.fill(
              right: sidebar != null && docked ? width : 0,
              child: widget.child,
            ),
            if (sidebar != null)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: width,
                child: _TerminalToolsPlacement(
                  docked: docked,
                  child: KeyedSubtree(key: _sidebarKey, child: sidebar),
                ),
              ),
            if (sidebar != null)
              Positioned(
                top: 0,
                bottom: 0,
                left: handleLeft,
                width: extent,
                child: _SidebarResizeHandle(
                  key: const ValueKey('terminal-tools-resize-handle'),
                  width: width,
                  min: bounds.min,
                  max: bounds.max,
                  inset: inset,
                  sidebarContext: () => _sidebarKey.currentContext,
                  onResize: (value) => _preferred.value = value
                      .clamp(bounds.min, bounds.max)
                      .toDouble(),
                ),
              ),
          ],
        );
      },
    ),
  );
}

/// Whether the sidebar below sits beside the terminal ([docked]) or floats
/// over it (narrow layouts), where it casts a floating shadow.
class _TerminalToolsPlacement extends InheritedWidget {
  const _TerminalToolsPlacement({required this.docked, required super.child});

  final bool docked;

  /// True outside a [TerminalToolsLayout].
  static bool dockedOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_TerminalToolsPlacement>()
          ?.docked ??
      true;

  @override
  bool updateShouldNotify(_TerminalToolsPlacement oldWidget) =>
      docked != oldWidget.docked;
}

/// iOS Phone 终端工具底部毛玻璃 Sheet：支持半屏 / 全屏两档 detent 跟手切换与下拉收起。
class _IosTerminalToolsSheet extends StatefulWidget {
  const _IosTerminalToolsSheet({
    required this.maxHeight,
    required this.child,
    this.onDismiss,
  });

  final double maxHeight;
  final Widget child;
  final VoidCallback? onDismiss;

  @override
  State<_IosTerminalToolsSheet> createState() => _IosTerminalToolsSheetState();
}

class _IosTerminalToolsSheetState extends State<_IosTerminalToolsSheet> {
  static const double _halfDetent = 0.54;
  static const double _compactHalfDetent = 0.72;
  static const double _fullDetent = 0.94;

  bool _expandedToFull = false;
  double? _dragFraction;

  double _restingFraction(BuildContext context) {
    if (_expandedToFull) return _fullDetent;
    return isIosCompactHeight(context) ? _compactHalfDetent : _halfDetent;
  }

  void _onDragStart(DragStartDetails _) {
    setState(() => _dragFraction = _restingFraction(context));
  }

  void _onDragUpdate(DragUpdateDetails details, double totalHeight) {
    if (totalHeight <= 0) return;
    final current = _dragFraction ?? _restingFraction(context);
    final next = (current - details.delta.dy / totalHeight).clamp(0.22, 0.96);
    setState(() => _dragFraction = next);
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final half = isIosCompactHeight(context) ? _compactHalfDetent : _halfDetent;
    final current = _dragFraction ?? _restingFraction(context);
    setState(() => _dragFraction = null);

    // 快速向下甩动或拖至半屏明显下方时直接收起面板
    if (velocity > 850 || (current < half - 0.16 && velocity >= -100)) {
      if (_expandedToFull && velocity <= 1300 && current >= half * 0.85) {
        AppleHaptics.selection(context);
        setState(() => _expandedToFull = false);
        return;
      }
      if (widget.onDismiss != null) {
        AppleHaptics.light(context);
        widget.onDismiss!();
        return;
      }
    }

    final shouldExpand = velocity < -450
        ? true
        : velocity > 450
        ? false
        : current >= (half + _fullDetent) / 2;
    if (shouldExpand != _expandedToFull) {
      AppleHaptics.selection(context);
      setState(() => _expandedToFull = shouldExpand);
    }
  }

  void _toggleDetent() {
    AppleHaptics.selection(context);
    setState(() => _expandedToFull = !_expandedToFull);
  }

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final glass = iosGlassEnabled(context);
    final available = widget.maxHeight.isFinite && widget.maxHeight > 0
        ? widget.maxHeight
        : MediaQuery.sizeOf(context).height;
    final fraction = _dragFraction ?? _restingFraction(context);
    final targetHeight = (available * fraction)
        .clamp(math.min(180.0, available), available)
        .toDouble();
    final sheetFill = c.isDark
        ? const Color(0xD91C1C1E)
        : const Color(0xEBFFFFFF);
    final sheetRadius = BorderRadius.vertical(
      top: Radius.circular(AppDensity.of(context).radiusDialog),
    );

    Widget sheetSurface = ColoredBox(
      color: glass ? sheetFill : c.groupedBackground,
      child: Column(
        children: [
          GestureDetector(
            key: const ValueKey('ios-terminal-tools-grabber'),
            behavior: HitTestBehavior.opaque,
            onTap: _toggleDetent,
            onVerticalDragStart: _onDragStart,
            onVerticalDragUpdate: (d) => _onDragUpdate(d, available),
            onVerticalDragEnd: _onDragEnd,
            onVerticalDragCancel: () => setState(() => _dragFraction = null),
            child: const SizedBox(
              width: double.infinity,
              height: 22,
              child: IosSheetGrabber(),
            ),
          ),
          Expanded(child: widget.child),
        ],
      ),
    );

    if (glass) {
      sheetSurface = BackdropFilter.grouped(
        filter: iosGlassFilter(sigma: 24),
        child: sheetSurface,
      );
    }

    return Stack(
      children: [
        if (widget.onDismiss != null)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onDismiss,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: c.isDark ? 0.32 : 0.18),
              ),
            ),
          ),
        Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedContainer(
            duration: _dragFraction != null
                ? Duration.zero
                : const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            width: double.infinity,
            height: targetHeight,
            // No rim: the sheet's fill and shadow set it off.
            decoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(borderRadius: sheetRadius),
              shadows: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: c.isDark ? 0.42 : 0.14),
                  blurRadius: 28,
                  offset: const Offset(0, -6),
                ),
              ],
            ),
            child: ClipRSuperellipse(
              borderRadius: sheetRadius,
              child: sheetSurface,
            ),
          ),
        ),
      ],
    );
  }
}

/// Left-edge sidebar splitter. Dragging left widens the sidebar.
class _SidebarResizeHandle extends StatefulWidget {
  const _SidebarResizeHandle({
    required this.width,
    required this.min,
    required this.max,
    required this.inset,
    required this.sidebarContext,
    required this.onResize,
    super.key,
  });

  /// How far the hit area reaches into the sidebar past its left border.
  final double width, min, max, inset;
  final BuildContext? Function() sidebarContext;
  final ValueChanged<double> onResize;
  @override
  State<_SidebarResizeHandle> createState() => _SidebarResizeHandleState();
}

class _SidebarResizeHandleState extends State<_SidebarResizeHandle> {
  bool _hovered = false, _dragging = false, _focused = false;
  double _dragWidth = 0;
  FocusNode? _restoreFocus;

  // Ancestors (e.g. a pane's pointer-down listener) may move focus to the
  // terminal; give it back to this sidebar's field (search query, filter)
  // once the pointer interaction with the handle ends. Focus outside the
  // sidebar is left to the pane, as for any other click in it.
  void _pointerDown(PointerDownEvent _) {
    final node = FocusManager.instance.primaryFocus;
    final sidebar = widget.sidebarContext();
    var inside = false;
    if (node?.context != null && sidebar != null) {
      node!.context!.visitAncestorElements((element) {
        inside = identical(element, sidebar);
        return !inside;
      });
    }
    _restoreFocus = inside ? node : null;
  }

  void _pointerEnd(PointerEvent _) {
    final node = _restoreFocus;
    _restoreFocus = null;
    if (node == null) return;
    scheduleMicrotask(() {
      if (mounted && node.context != null && !node.hasFocus) {
        node.requestFocus();
      }
    });
  }

  // Repeated keys/actions before the next rebuild compound from the last
  // requested width rather than the stale displayed one.
  double? _pendingWidth;
  @override
  void didUpdateWidget(covariant _SidebarResizeHandle oldWidget) {
    super.didUpdateWidget(oldWidget);
    _pendingWidth = null;
  }

  void _nudge(double delta) {
    final next = ((_pendingWidth ?? widget.width) + delta)
        .clamp(widget.min, widget.max)
        .toDouble();
    _pendingWidth = next;
    widget.onResize(next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const step = TerminalToolsLayout.keyboardStep;
    final active = _hovered || _dragging || _focused;
    final colors = Theme.of(context).colorScheme;
    final value = widget.width.round();
    return Semantics(
      container: true,
      slider: true,
      label: l10n.sidebarResizeHandle,
      hint: l10n.sidebarResizeHint,
      value: l10n.sidebarResizeWidthValue(value),
      increasedValue: l10n.sidebarResizeWidthValue(
        math.min(widget.max, widget.width + step).round(),
      ),
      decreasedValue: l10n.sidebarResizeWidthValue(
        math.max(widget.min, widget.width - step).round(),
      ),
      onIncrease: widget.width < widget.max ? () => _nudge(step) : null,
      onDecrease: widget.width > widget.min ? () => _nudge(-step) : null,
      child: Focus(
        onFocusChange: (value) => setState(() => _focused = value),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.arrowLeft) {
            _nudge(step);
          } else if (key == LogicalKeyboardKey.arrowRight) {
            _nudge(-step);
          } else {
            return KeyEventResult.ignored;
          }
          return KeyEventResult.handled;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeColumn,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Listener(
            onPointerDown: _pointerDown,
            onPointerUp: _pointerEnd,
            onPointerCancel: _pointerEnd,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragStart: (_) => setState(() {
                _dragging = true;
                _dragWidth = widget.width;
              }),
              onHorizontalDragUpdate: (details) {
                _dragWidth -= details.delta.dx;
                widget.onResize(
                  _dragWidth.clamp(widget.min, widget.max).toDouble(),
                );
              },
              onHorizontalDragEnd: (_) => setState(() => _dragging = false),
              onHorizontalDragCancel: () => setState(() => _dragging = false),
              child: Padding(
                // The visible line sits on the sidebar's left border.
                padding: EdgeInsets.only(right: widget.inset - 1),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _touch(context) && !active
                      ? Container(
                          width: 4,
                          height: 32,
                          decoration: BoxDecoration(
                            color: context.palette.line,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        )
                      : AnimatedContainer(
                          duration: AppMotion.duration(
                            context,
                            MotionDurations.quick,
                          ),
                          width: 2,
                          color: active ? colors.primary : Colors.transparent,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TerminalToolsLauncher extends StatelessWidget {
  const TerminalToolsLauncher({required this.onOpen, super.key});
  final ValueChanged<TerminalToolsSection> onOpen;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextButton.icon(
        key: const ValueKey('terminal-tools-search'),
        onPressed: () => onOpen(TerminalToolsSection.search),
        icon: const Icon(Icons.search, size: 16),
        label: Text(context.l10n.search2),
      ),
      IconButton(
        key: const ValueKey('terminal-tools-commands'),
        tooltip: context.l10n.quickCommands,
        onPressed: () => onOpen(TerminalToolsSection.commands),
        icon: const Icon(Icons.bolt, size: 18),
      ),
      IconButton(
        key: const ValueKey('terminal-tools-history'),
        tooltip: context.l10n.inputHistory,
        onPressed: () => onOpen(TerminalToolsSection.history),
        icon: const Icon(Icons.history, size: 18),
      ),
    ],
  );
}

class TerminalToolsSidebar extends StatefulWidget {
  const TerminalToolsSidebar({
    required this.section,
    required this.onSection,
    required this.onClose,
    required this.query,
    required this.queryFocus,
    required this.onQuery,
    required this.searchStatus,
    required this.previous,
    required this.next,
    required this.searchHistory,
    required this.loadCommands,
    required this.editCommand,
    required this.deleteCommand,
    required this.history,
    required this.onInsert,
    required this.onConfigureHistory,
    required this.onClearHistory,
    this.historyNotice,
    this.historyChanges,
    this.onSearchKey,
    this.showQuery = true,
    super.key,
  });
  final TerminalToolsSection section;
  final bool showQuery;
  final ValueChanged<TerminalToolsSection> onSection;
  final VoidCallback onClose;
  final TextEditingController query;
  final FocusNode queryFocus;
  final ValueChanged<String> onQuery;
  final String searchStatus;
  final VoidCallback? previous, next;
  final TerminalSearchHistory searchHistory;
  final Future<List<TerminalCommandItem>> Function() loadCommands;
  final Future<void> Function(TerminalCommandItem?) editCommand;
  final Future<void> Function(TerminalCommandItem) deleteCommand;
  final List<TerminalCommandItem> Function() history;
  final bool Function(String) onInsert;
  final Future<void> Function() onConfigureHistory, onClearHistory;
  final String? Function()? historyNotice;
  final Listenable? historyChanges;
  final KeyEventResult Function(FocusNode, KeyEvent)? onSearchKey;
  @override
  State<TerminalToolsSidebar> createState() => _TerminalToolsSidebarState();
}

const _prefixConstraints = BoxConstraints(minWidth: 40, minHeight: 40);
const _fieldPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 10);
const _tilePadding = EdgeInsets.symmetric(horizontal: 12);
const _listDensity = VisualDensity(horizontal: 0, vertical: -2);

/// Icon section selector for the SSH tools sidebar. Each icon carries a
/// localized tooltip and an exclusive selected state for assistive tech; the
/// selected section's name is shown beside the icons.
class TerminalToolsSectionTabs extends StatelessWidget {
  const TerminalToolsSectionTabs({
    required this.section,
    required this.onSection,
    super.key,
  });
  final TerminalToolsSection section;
  final ValueChanged<TerminalToolsSection> onSection;

  static IconData iconFor(TerminalToolsSection section) => switch (section) {
    TerminalToolsSection.search => Icons.search,
    TerminalToolsSection.commands => Icons.bolt,
    TerminalToolsSection.history => Icons.history,
  };

  static String labelFor(BuildContext context, TerminalToolsSection section) =>
      switch (section) {
        TerminalToolsSection.search => context.l10n.search,
        TerminalToolsSection.commands => context.l10n.quickCommands,
        TerminalToolsSection.history => context.l10n.inputHistory,
      };

  @override
  Widget build(BuildContext context) {
    if (isIosPhone(context)) {
      final c = IosColors.of(context);
      return Column(
        key: const ValueKey('terminal-tools-sections'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoSlidingSegmentedControl<TerminalToolsSection>(
            groupValue: section,
            backgroundColor: c.fill,
            thumbColor: c.isDark ? const Color(0xFF636366) : Colors.white,
            onValueChanged: (value) {
              if (value != null) {
                AppleHaptics.selection(context);
                onSection(value);
              }
            },
            children: {
              for (final value in TerminalToolsSection.values)
                value: Semantics(
                  container: true,
                  button: true,
                  selected: value == section,
                  inMutuallyExclusiveGroup: true,
                  label: labelFor(context, value),
                  child: Padding(
                    key: ValueKey('terminal-tools-section-${value.name}'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 7,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          switch (value) {
                            TerminalToolsSection.search => IosIcons.search,
                            TerminalToolsSection.commands => IosIcons.bolt,
                            TerminalToolsSection.history =>
                              Icons.history_rounded,
                          },
                          size: 15,
                          color: c.label,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            labelFor(context, value),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: IosType.footnote.copyWith(
                              color: c.label,
                              fontWeight: value == section
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            },
          ),
          Offstage(
            child: Text(
              labelFor(context, section),
              key: const ValueKey('terminal-tools-section-title'),
            ),
          ),
        ],
      );
    }
    final colors = Theme.of(context).colorScheme;
    final density = AppDensity.of(context);
    // A filled control track (no outline); the selected icon is a block on
    // it, concentric with the track.
    return Row(
      key: const ValueKey('terminal-tools-sections'),
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: context.palette.fill,
            borderRadius: BorderRadius.circular(density.radiusMd),
          ),
          child: Padding(
            padding: const EdgeInsets.all(_sectionTrackInset),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final value in TerminalToolsSection.values)
                  _SectionIcon(
                    key: ValueKey('terminal-tools-section-${value.name}'),
                    icon: iconFor(value),
                    label: labelFor(context, value),
                    selected: value == section,
                    selectedColor: colors.primary,
                    onPressed: () => onSection(value),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ExcludeSemantics(
            child: Text(
              labelFor(context, section),
              key: const ValueKey('terminal-tools-section-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppDensity.of(context).textSize(12),
                color: context.palette.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Inset of the section icons in their track.
const _sectionTrackInset = 2.0;

/// A section icon's corners, concentric with the track around it.
BorderRadius _sectionIconRadius(BuildContext context) {
  final density = AppDensity.of(context);
  return BorderRadius.circular(
    concentricRadius(
      density.radiusMd,
      _sectionTrackInset,
      floor: density.radiusSm,
    ),
  );
}

bool _touch(BuildContext context) => switch (Theme.of(context).platform) {
  TargetPlatform.android || TargetPlatform.iOS => true,
  _ => false,
};

class _SectionIcon extends StatelessWidget {
  const _SectionIcon({
    required this.icon,
    required this.label,
    required this.selected,
    required this.selectedColor,
    required this.onPressed,
    super.key,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final Color selectedColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    selected: selected,
    inMutuallyExclusiveGroup: true,
    label: label,
    onTap: onPressed,
    child: ExcludeSemantics(
      child: Tooltip(
        message: label,
        child: Material(
          color: selected ? selectedColor : Colors.transparent,
          borderRadius: _sectionIconRadius(context),
          child: InkWell(
            borderRadius: _sectionIconRadius(context),
            onTap: onPressed,
            child: SizedBox(
              // Touch platforms keep a real 48x48 hit box.
              width: _touch(context) ? 48 : 40,
              height: _touch(context) ? 48 : 32,
              child: Icon(
                icon,
                size: 18,
                color: selected
                    ? context.palette.onAccent
                    : context.palette.muted,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _TerminalToolsSidebarState extends State<TerminalToolsSidebar> {
  Future<List<TerminalCommandItem>>? _commands;
  String _filter = '';
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    widget.historyChanges?.addListener(_refreshHistory);
  }

  @override
  void didUpdateWidget(covariant TerminalToolsSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.historyChanges != widget.historyChanges) {
      oldWidget.historyChanges?.removeListener(_refreshHistory);
      widget.historyChanges?.addListener(_refreshHistory);
    }
  }

  @override
  void dispose() {
    widget.historyChanges?.removeListener(_refreshHistory);
    super.dispose();
  }

  void _refreshHistory() {
    if (mounted) setState(() {});
  }

  void _remember() =>
      setState(() => widget.searchHistory.remember(widget.query.text));
  void _move(VoidCallback? action) {
    _remember();
    action?.call();
  }

  KeyEventResult _queryKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _remember();
      widget.onClose();
      return KeyEventResult.handled;
    }
    final keys = HardwareKeyboard.instance;
    if ((event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !keys.isControlPressed &&
        !keys.isAltPressed &&
        !keys.isMetaPressed &&
        !keys.isShiftPressed &&
        widget.query.value.composing.isCollapsed) {
      _move(widget.next);
      return KeyEventResult.handled;
    }
    return widget.onSearchKey?.call(node, event) ?? KeyEventResult.ignored;
  }

  Future<void> _action(
    Future<void> Function() work, {
    bool reload = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.theActionDidntCompleteRefreshAnd);
      }
    } finally {
      if (mounted)
        setState(() {
          _busy = false;
          if (reload) _commands = null;
        });
    }
  }

  void _insert(String command) {
    if (!isSafeTerminalCommand(command) || !widget.onInsert(command)) {
      setState(() => _error = context.l10n.cantInsertSelectASessionThat);
    }
  }

  @override
  Widget build(BuildContext context) {
    return isIosPhone(context) ? _buildIos(context) : _buildMaterial(context);
  }

  Widget _pinnedHeader({
    required Color color,
    required Widget controls,
    required Widget query,
  }) => PinnedHeaderSliver(
    child: ColoredBox(
      color: color,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [controls, if (widget.showQuery) query],
      ),
    ),
  );

  Widget _buildMaterial(BuildContext context) {
    final density = AppDensity.of(context);
    final palette = context.palette;
    // A block inset from the sidebar's edges, so the terminal and the tools
    // are told apart by a gap instead of a rule. Over the terminal (narrow
    // layouts) it floats with a soft shadow; it is never glass there.
    final radius = density.radiusLg;
    Widget block = Material(
      color: palette.surface,
      shape: appBlockShape(context, radius),
      clipBehavior: Clip.antiAlias,
      child: CustomScrollView(
        key: const ValueKey('terminal-tools-scroll'),
        slivers: [
          // Section tabs and close share one compact row that stays pinned so
          // close never scrolls away in short (keyboard-open) viewports.
          _pinnedHeader(
            color: context.palette.surface,
            query: _searchField(),
            controls: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 4, 2),
              child: Row(
                children: [
                  Expanded(
                    child: TerminalToolsSectionTabs(
                      section: widget.section,
                      onSection: (value) {
                        if (value == widget.section && widget.showQuery) return;
                        if (widget.section == TerminalToolsSection.search) {
                          _remember();
                        }
                        setState(() {
                          _filter = '';
                          _error = null;
                        });
                        widget.onSection(value);
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.closeSidebar,
                    key: const ValueKey('terminal-tools-close'),
                    visualDensity: _touch(context)
                        ? null
                        : VisualDensity.compact,
                    onPressed: () {
                      _remember();
                      widget.onClose();
                    },
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
          ),
          if (_busy) const SliverToBoxAdapter(child: LinearProgressIndicator()),
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _error!,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          ...switch (widget.section) {
            TerminalToolsSection.search => _search(),
            TerminalToolsSection.commands => _quickCommands(),
            TerminalToolsSection.history => _history(),
          },
        ],
      ),
    );
    if (!_TerminalToolsPlacement.dockedOf(context)) {
      block = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: appFloatingShadow(palette),
        ),
        child: block,
      );
    }
    // Transparent but still hit-opaque, as the whole sidebar area was.
    return Material(
      key: const ValueKey('terminal-tools-sidebar'),
      color: Colors.transparent,
      child: Padding(padding: EdgeInsets.all(density.blockInset), child: block),
    );
  }

  Widget _buildIos(BuildContext context) {
    final c = IosColors.of(context);
    return Material(
      key: const ValueKey('terminal-tools-sidebar'),
      type: MaterialType.transparency,
      child: CustomScrollView(
        key: const ValueKey('terminal-tools-scroll'),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          _pinnedHeader(
            color: c.isDark ? const Color(0xE61C1C1E) : const Color(0xF2FFFFFF),
            query: _iosSearchField(context, c),
            controls: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 10, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TerminalToolsSectionTabs(
                      section: widget.section,
                      onSection: (value) {
                        if (value == widget.section && widget.showQuery) return;
                        if (widget.section == TerminalToolsSection.search) {
                          _remember();
                        }
                        setState(() {
                          _filter = '';
                          _error = null;
                        });
                        widget.onSection(value);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: context.l10n.closeSidebar,
                    child: GestureDetector(
                      key: const ValueKey('terminal-tools-close'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        AppleHaptics.light(context);
                        _remember();
                        widget.onClose();
                      },
                      child: SizedBox.square(
                        dimension: 44,
                        child: Center(
                          child: SizedBox.square(
                            dimension: 30,
                            child: DecoratedBox(
                              decoration: ShapeDecoration(
                                color: c.fill,
                                shape: const CircleBorder(),
                              ),
                              child: Icon(
                                IosIcons.close,
                                size: 17,
                                color: c.secondaryLabel,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_busy)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(child: CupertinoActivityIndicator()),
              ),
            ),
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(
                  _error!,
                  style: IosType.footnote.copyWith(color: c.destructive),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 6)),
          ...switch (widget.section) {
            TerminalToolsSection.search => _iosSearch(context, c),
            TerminalToolsSection.commands => _iosQuickCommands(context, c),
            TerminalToolsSection.history => _iosHistory(context, c),
          },
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.paddingOf(context).bottom + 24,
            ),
          ),
        ],
      ),
    );
  }

  Widget _iosSearchField(BuildContext context, IosColors c) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Focus(
      onKeyEvent: _queryKey,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: widget.query,
        builder: (context, value, _) => DecoratedBox(
          decoration: ShapeDecoration(
            color: c.fill,
            shape: const StadiumBorder(),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 6, 4),
            child: Row(
              children: [
                Icon(IosIcons.search, size: 18, color: c.secondaryLabel),
                const SizedBox(width: 8),
                Expanded(
                  child: CupertinoTextField(
                    key: const ValueKey('terminal-sidebar-query'),
                    controller: widget.query,
                    focusNode: widget.queryFocus,
                    autofocus: widget.section == TerminalToolsSection.search,
                    maxLength: terminalSearchMaxQueryGraphemes,
                    maxLengthEnforcement: MaxLengthEnforcement.enforced,
                    onChanged: widget.onQuery,
                    onEditingComplete:
                        () {}, // Keep the input focused for repeated Enter.
                    onSubmitted: (_) => _move(widget.next),
                    textInputAction: TextInputAction.search,
                    autocorrect: false,
                    clearButtonMode: OverlayVisibilityMode.never,
                    decoration: null,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    placeholder: context.l10n.searchCurrentTerminalOutput,
                    placeholderStyle: IosType.subheadline.copyWith(
                      color: c.secondaryLabel,
                    ),
                    style: IosType.body.copyWith(color: c.label),
                    cursorColor: c.tint,
                  ),
                ),
                if (value.text.isNotEmpty)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      widget.query.clear();
                      widget.onQuery('');
                    },
                    child: SizedBox.square(
                      dimension: 34,
                      child: Icon(
                        IosIcons.clear,
                        size: 18,
                        color: c.secondaryLabel,
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

  List<Widget> _iosSearch(BuildContext context, IosColors c) => [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 12, 6),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  widget.searchStatus,
                  style: IosType.footnote.copyWith(color: c.secondaryLabel),
                ),
              ),
            ),
            IconButton(
              tooltip: context.l10n.previousMatch,
              onPressed: widget.previous == null
                  ? null
                  : () {
                      AppleHaptics.selection(context);
                      _move(widget.previous);
                    },
              icon: Icon(
                Icons.keyboard_arrow_up_rounded,
                size: 24,
                color: widget.previous == null ? c.tertiaryLabel : c.tint,
              ),
            ),
            IconButton(
              tooltip: context.l10n.nextMatch,
              onPressed: widget.next == null
                  ? null
                  : () {
                      AppleHaptics.selection(context);
                      _move(widget.next);
                    },
              icon: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 24,
                color: widget.next == null ? c.tertiaryLabel : c.tint,
              ),
            ),
          ],
        ),
      ),
    ),
    if (widget.searchHistory.items.isEmpty)
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              context.l10n.searchTermsAreRecordedWhenYou,
              textAlign: TextAlign.center,
              style: IosType.subheadline.copyWith(color: c.secondaryLabel),
            ),
          ),
        ),
      )
    else
      SliverToBoxAdapter(
        child: IosListSection(
          headerWidget: IosSectionHeader(
            context.l10n.searchHistory,
            trailing: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(widget.searchHistory.clear),
              child: Text(
                context.l10n.clear,
                style: IosType.footnote.copyWith(
                  color: c.tint,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          children: [
            for (final value in widget.searchHistory.items)
              IosListRow(
                leading: Icon(
                  Icons.history_rounded,
                  size: 18,
                  color: c.secondaryLabel,
                ),
                title: Text(value),
                trailing: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      setState(() => widget.searchHistory.remove(value)),
                  child: SizedBox.square(
                    dimension: 36,
                    child: Icon(
                      IosIcons.close,
                      size: 16,
                      color: c.tertiaryLabel,
                    ),
                  ),
                ),
                onTap: () {
                  widget.query.text = value;
                  widget.onQuery(value);
                  _remember();
                  widget.queryFocus.requestFocus();
                },
              ),
          ],
        ),
      ),
  ];

  Widget _iosFilterField(BuildContext context, IosColors c, String hint) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: c.fill,
            shape: const StadiumBorder(),
          ),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 12, 4),
            child: Row(
              children: [
                Icon(IosIcons.search, size: 18, color: c.secondaryLabel),
                const SizedBox(width: 8),
                Expanded(
                  child: CupertinoTextField(
                    key: ValueKey('terminal-${widget.section.name}-filter'),
                    autofocus: false,
                    onChanged: (value) => setState(() => _filter = value),
                    autocorrect: false,
                    clearButtonMode: OverlayVisibilityMode.never,
                    decoration: null,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    placeholder: hint,
                    placeholderStyle: IosType.subheadline.copyWith(
                      color: c.secondaryLabel,
                    ),
                    style: IosType.body.copyWith(color: c.label),
                    cursorColor: c.tint,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  List<Widget> _iosQuickCommands(BuildContext context, IosColors c) => [
    SliverToBoxAdapter(
      child: _iosFilterField(context, c, context.l10n.filterByNameOrCommand),
    ),
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.saveEncryptedAsSnippets,
                style: IosType.footnote.copyWith(color: c.secondaryLabel),
              ),
            ),
            IconButton(
              tooltip: context.l10n.refreshQuickCommands,
              onPressed: () => setState(() => _commands = null),
              icon: Icon(Icons.refresh_rounded, size: 20, color: c.tint),
            ),
            IconButton(
              key: const ValueKey('terminal-quick-add'),
              tooltip: context.l10n.addQuickCommand,
              onPressed: _busy
                  ? null
                  : () => _action(() => widget.editCommand(null), reload: true),
              icon: Icon(
                IosIcons.add,
                size: 22,
                color: _busy ? c.tertiaryLabel : c.tint,
              ),
            ),
          ],
        ),
      ),
    ),
    FutureBuilder<List<TerminalCommandItem>>(
      future: _commands ??= widget.loadCommands(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  context.l10n.couldntReadQuickCommandsRefreshAnd,
                  textAlign: TextAlign.center,
                  style: IosType.subheadline.copyWith(color: c.secondaryLabel),
                ),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CupertinoActivityIndicator()),
          );
        }
        return _iosCommandSection(
          context,
          c,
          _filtered(snapshot.data!),
          editable: true,
          footer: context.l10n.clickToInsertPressEnterTo,
        );
      },
    ),
  ];

  List<Widget> _iosHistory(BuildContext context, IosColors c) => [
    SliverToBoxAdapter(
      child: _iosFilterField(context, c, context.l10n.filterInputHistory),
    ),
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: IosListSection(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            IosListActionRow(
              icon: Icons.tune_rounded,
              label: context.l10n.recordingSettings,
              onTap: _busy ? null : () => _action(widget.onConfigureHistory),
            ),
            IosListActionRow(
              icon: IosIcons.delete,
              label: context.l10n.clearLocalHistory,
              destructive: true,
              onTap: _busy ? null : () => _action(widget.onClearHistory),
            ),
          ],
        ),
      ),
    ),
    _iosCommandSection(
      context,
      c,
      _filtered(widget.history()),
      footer:
          widget.historyNotice?.call() ??
          context.l10n.showsCommandsCompletedOnTheCurrent,
    ),
  ];

  Widget _iosCommandSection(
    BuildContext context,
    IosColors c,
    List<TerminalCommandItem> items, {
    bool editable = false,
    String? footer,
  }) {
    if (items.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              context.l10n.noMatchingEntries,
              style: IosType.subheadline.copyWith(color: c.secondaryLabel),
            ),
          ),
        ),
      );
    }
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: IosListSection(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          footer: footer,
          children: [
            for (final item in items)
              IosListRow(
                key: ValueKey('terminal-command-${item.id}'),
                title: Text(item.title),
                subtitle: Text(item.command, maxLines: 2),
                monoSubtitle: true,
                onTap: () {
                  AppleHaptics.light(context);
                  _insert(item.command);
                },
                trailing: editable
                    ? IosPullDownButton(
                        semanticLabel: context.l10n.quickCommandActions,
                        sections: () => [
                          [
                            WorkspaceAction(
                              'edit_cmd_${item.id}',
                              context.l10n.edit,
                              IosIcons.edit,
                              () => _action(
                                () => widget.editCommand(item),
                                reload: true,
                              ),
                            ),
                          ],
                          [
                            WorkspaceAction(
                              'delete_cmd_${item.id}',
                              context.l10n.delete,
                              IosIcons.delete,
                              () => _action(
                                () => widget.deleteCommand(item),
                                reload: true,
                              ),
                              destructive: true,
                            ),
                          ],
                        ],
                        child: SizedBox.square(
                          dimension: 40,
                          child: Icon(
                            IosIcons.more,
                            size: 20,
                            color: c.secondaryLabel,
                          ),
                        ),
                      )
                    : Icon(
                        Icons.north_west_rounded,
                        size: 17,
                        color: c.tertiaryLabel,
                      ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _searchField() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Focus(
      onKeyEvent: _queryKey,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: widget.query,
        builder: (context, value, _) => TextField(
          key: const ValueKey('terminal-sidebar-query'),
          controller: widget.query,
          focusNode: widget.queryFocus,
          autofocus: widget.section == TerminalToolsSection.search,
          maxLength: terminalSearchMaxQueryGraphemes,
          maxLengthEnforcement: MaxLengthEnforcement.enforced,
          onChanged: widget.onQuery,
          onEditingComplete:
              () {}, // Keep the input focused for repeated Enter.
          onSubmitted: (_) => _move(widget.next),
          textInputAction: TextInputAction.search,
          textAlign: value.text.isEmpty ? TextAlign.center : TextAlign.start,
          textAlignVertical: TextAlignVertical.center,
          style: TextStyle(fontSize: AppDensity.of(context).textSize(13)),
          decoration: InputDecoration(
            hintText: context.l10n.searchCurrentTerminalOutput,
            hintStyle: TextStyle(
              fontSize: AppDensity.of(context).textSize(12),
              color: context.palette.muted,
            ),
            hintMaxLines: 1,
            prefixIcon: const Icon(Icons.search, size: 16),
            prefixIconConstraints: _prefixConstraints,
            // Equal icon gutters center the empty prompt within the border,
            // not just within the space left over after the search icon.
            suffixIcon: value.text.isEmpty ? const SizedBox(width: 40) : null,
            suffixIconConstraints: _prefixConstraints,
            contentPadding: _fieldPadding,
            constraints: BoxConstraints(minHeight: _touch(context) ? 48 : 40),
            counterText: '',
            isDense: true,
          ),
        ),
      ),
    ),
  );

  List<Widget> _search() => [
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Text(
                  widget.searchStatus,
                  style: TextStyle(
                    fontSize: AppDensity.of(context).textSize(11),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: context.l10n.previousMatch,
              visualDensity: VisualDensity.compact,
              onPressed: widget.previous == null
                  ? null
                  : () => _move(widget.previous),
              icon: const Icon(Icons.keyboard_arrow_up, size: 20),
            ),
            IconButton(
              tooltip: context.l10n.nextMatch,
              visualDensity: VisualDensity.compact,
              onPressed: widget.next == null ? null : () => _move(widget.next),
              icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            ),
          ],
        ),
      ),
    ),
    SliverToBoxAdapter(
      child: Row(
        children: [
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.searchHistory,
              style: TextStyle(
                fontSize: AppDensity.of(context).textSize(12),
                color: context.palette.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: widget.searchHistory.items.isEmpty
                ? null
                : () => setState(widget.searchHistory.clear),
            child: Text(context.l10n.clear),
          ),
        ],
      ),
    ),
    widget.searchHistory.items.isEmpty
        ? SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  context.l10n.searchTermsAreRecordedWhenYou,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.palette.muted,
                    fontSize: AppDensity.of(context).textSize(12),
                  ),
                ),
              ),
            ),
          )
        : SliverList.builder(
            itemCount: widget.searchHistory.items.length,
            itemBuilder: (_, index) {
              final value = widget.searchHistory.items[index];
              return ListTile(
                dense: true,
                visualDensity: _listDensity,
                contentPadding: _tilePadding,
                minLeadingWidth: 20,
                horizontalTitleGap: 8,
                leading: const Icon(Icons.history, size: 16),
                title: Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  widget.query.text = value;
                  widget.onQuery(value);
                  _remember();
                  widget.queryFocus.requestFocus();
                },
                trailing: IconButton(
                  tooltip: context.l10n.removeSearchTerm,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 15),
                  onPressed: () =>
                      setState(() => widget.searchHistory.remove(value)),
                ),
              );
            },
          ),
  ];

  Widget _filterField(String hint) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: TextField(
      key: ValueKey('terminal-${widget.section.name}-filter'),
      autofocus: true,
      onChanged: (value) => setState(() => _filter = value),
      textAlign: _filter.isEmpty ? TextAlign.center : TextAlign.start,
      textAlignVertical: TextAlignVertical.center,
      style: TextStyle(fontSize: AppDensity.of(context).textSize(13)),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
          fontSize: AppDensity.of(context).textSize(12),
          color: context.palette.muted,
        ),
        hintMaxLines: 1,
        prefixIcon: const Icon(Icons.filter_list, size: 16),
        prefixIconConstraints: _prefixConstraints,
        suffixIcon: _filter.isEmpty ? const SizedBox(width: 40) : null,
        suffixIconConstraints: _prefixConstraints,
        contentPadding: _fieldPadding,
        constraints: BoxConstraints(minHeight: _touch(context) ? 48 : 40),
        isDense: true,
      ),
    ),
  );
  List<TerminalCommandItem> _filtered(List<TerminalCommandItem> items) {
    final query = _filter.toLowerCase();
    return items
        .where(
          (item) =>
              '${item.title}\n${item.command}'.toLowerCase().contains(query),
        )
        .toList();
  }

  List<Widget> _quickCommands() => [
    SliverToBoxAdapter(child: _filterField(context.l10n.filterByNameOrCommand)),
    SliverToBoxAdapter(
      child: Row(
        children: [
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.l10n.saveEncryptedAsSnippets,
              style: TextStyle(
                fontSize: AppDensity.of(context).textSize(11),
                color: context.palette.muted,
              ),
            ),
          ),
          IconButton(
            tooltip: context.l10n.refreshQuickCommands,
            onPressed: () => setState(() => _commands = null),
            icon: const Icon(Icons.refresh, size: 18),
          ),
          IconButton(
            key: const ValueKey('terminal-quick-add'),
            tooltip: context.l10n.addQuickCommand,
            onPressed: _busy
                ? null
                : () => _action(() => widget.editCommand(null), reload: true),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    ),
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          context.l10n.clickToInsertPressEnterTo,
          style: TextStyle(
            fontSize: AppDensity.of(context).textSize(11),
            color: context.palette.muted,
          ),
        ),
      ),
    ),
    FutureBuilder<List<TerminalCommandItem>>(
      future: _commands ??= widget.loadCommands(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(context.l10n.couldntReadQuickCommandsRefreshAnd),
            ),
          );
        }
        if (!snapshot.hasData)
          return const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          );
        return _commandList(_filtered(snapshot.data!), editable: true);
      },
    ),
  ];
  List<Widget> _history() => [
    SliverToBoxAdapter(child: _filterField(context.l10n.filterInputHistory)),
    SliverToBoxAdapter(
      child: Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: _busy ? null : () => _action(widget.onConfigureHistory),
            icon: const Icon(Icons.tune, size: 16),
            label: Text(context.l10n.recordingSettings),
          ),
          TextButton(
            onPressed: _busy ? null : () => _action(widget.onClearHistory),
            child: Text(context.l10n.clearLocalHistory),
          ),
        ],
      ),
    ),
    SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          widget.historyNotice?.call() ??
              context.l10n.showsCommandsCompletedOnTheCurrent,
          style: TextStyle(
            fontSize: AppDensity.of(context).textSize(11),
            color: context.palette.muted,
          ),
        ),
      ),
    ),
    _commandList(_filtered(widget.history())),
  ];
  Widget _commandList(
    List<TerminalCommandItem> items, {
    bool editable = false,
  }) => items.isEmpty
      ? SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              context.l10n.noMatchingEntries,
              style: TextStyle(color: context.palette.muted),
            ),
          ),
        )
      : SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return ListTile(
              dense: true,
              visualDensity: _listDensity,
              contentPadding: _tilePadding,
              key: ValueKey('terminal-command-${item.id}'),
              title: Text(
                item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppDensity.of(context).textSize(11),
                  color: context.palette.muted,
                ),
              ),
              subtitle: Text(
                item.command,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              onTap: () => _insert(item.command),
              trailing: editable
                  ? PopupMenuButton<String>(
                      popUpAnimationStyle: AppMotion.menuStyle(context),
                      tooltip: context.l10n.quickCommandActions,
                      onSelected: (value) {
                        if (value == 'edit')
                          _action(() => widget.editCommand(item), reload: true);
                        if (value == 'delete')
                          _action(
                            () => widget.deleteCommand(item),
                            reload: true,
                          );
                      },
                      itemBuilder: (_) => [
                        appMenuItem(
                          context,
                          value: 'edit',
                          child: Text(context.l10n.edit),
                        ),
                        appMenuItem(
                          context,
                          value: 'delete',
                          child: Text(context.l10n.delete),
                        ),
                      ],
                    )
                  : IconButton(
                      tooltip: context.l10n.insertIntoTerminal,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.north_west, size: 16),
                      onPressed: () => _insert(item.command),
                    ),
            );
          },
        );
}

Future<SnippetRecord?> editTerminalQuickCommand(
  BuildContext context, {
  TerminalCommandItem? existing,
}) async {
  final title = TextEditingController(text: existing?.title);
  final command = TextEditingController(text: existing?.command);
  String? error;
  try {
    final iosPhone = isIosPhone(context);
    return await showAppDialog<SnippetRecord>(
      context: context,
      motion: iosPhone ? AppDialogMotion.sideSheet : AppDialogMotion.center,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          void submitQuickCommand() {
            if (title.text.trim().isEmpty ||
                !isSafeTerminalCommand(command.text)) {
              update(() => error = context.l10n.enterANameAndASingle);
              return;
            }
            Navigator.pop(
              context,
              SnippetRecord(
                id: existing?.id ?? const Uuid().v4(),
                title: title.text.trim(),
                body: command.text,
                shell: 'bash',
              ),
            );
          }

          if (isIosPhone(context)) {
            return IosSheetScaffold(
              title: existing == null
                  ? context.l10n.addQuickCommand
                  : context.l10n.editQuickCommand,
              cancelLabel: context.l10n.cancel,
              actionLabel: context.l10n.save2,
              onAction: submitQuickCommand,
              scrollController: PrimaryScrollController.maybeOf(context),
              children: [
                IosListSection(
                  children: [
                    IosTextFieldRow(
                      fieldKey: const ValueKey('quick-command-title'),
                      label: context.l10n.name,
                      placeholder: context.l10n.name,
                      controller: title,
                      autofocus: true,
                      inputFormatters: [LengthLimitingTextInputFormatter(128)],
                    ),
                    IosTextFieldRow(
                      fieldKey: const ValueKey('quick-command-body'),
                      label: context.l10n.singleLineCommand,
                      placeholder: context.l10n.singleLineCommand,
                      controller: command,
                      mono: true,
                      errorText: error,
                      inputFormatters: [LengthLimitingTextInputFormatter(4096)],
                      onSubmitted: (_) => submitQuickCommand(),
                    ),
                  ],
                ),
              ],
            );
          }

          return AlertDialog(
            title: Text(
              existing == null
                  ? context.l10n.addQuickCommand
                  : context.l10n.editQuickCommand,
            ),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const ValueKey('quick-command-title'),
                    controller: title,
                    autofocus: true,
                    maxLength: 128,
                    decoration: InputDecoration(labelText: context.l10n.name),
                  ),
                  TextField(
                    key: const ValueKey('quick-command-body'),
                    controller: command,
                    maxLength: 4096,
                    decoration: InputDecoration(
                      labelText: context.l10n.singleLineCommand,
                    ),
                  ),
                  if (error != null)
                    Text(error!, style: TextStyle(color: context.palette.red)),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.cancel),
              ),
              FilledButton(
                onPressed: submitQuickCommand,
                child: Text(context.l10n.save2),
              ),
            ],
          );
        },
      ),
    );
  } finally {
    title.dispose();
    command.dispose();
  }
}
