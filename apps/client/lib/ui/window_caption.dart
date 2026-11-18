import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../platform/window_chrome.dart';
import 'terminal_palette.dart';
import 'workspace_controls.dart';
import '../l10n/l10n.dart';

class WindowChromeScope extends InheritedWidget {
  const WindowChromeScope({
    super.key,
    required this.controller,
    required super.child,
    this.menuContext,
  });
  final WindowChromeController controller;
  final BuildContext? Function()? menuContext;
  static WindowChromeController of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<WindowChromeScope>()
          ?.controller ??
      WindowChromeController.instance;
  @override
  bool updateShouldNotify(WindowChromeScope oldWidget) =>
      controller != oldWidget.controller;
}

/// Wrap in MaterialApp.builder so startup, authentication and both workspaces
/// share one caption. Unsupported/missing native runners retain their frame.
class WindowsWindowChrome extends StatefulWidget {
  const WindowsWindowChrome({
    super.key,
    required this.child,
    this.title = '',
    this.leading,
    this.actions = const [],
    this.controller,
    this.navigationState,
    this.navigationEmbedded,
  });

  final Widget child;
  final String title;
  final Widget? leading;
  final List<Widget> actions;
  final WindowChromeController? controller;
  final Listenable? navigationState;
  final bool Function()? navigationEmbedded;

  @override
  State<WindowsWindowChrome> createState() => _WindowsWindowChromeState();
}

class _WindowsWindowChromeState extends State<WindowsWindowChrome> {
  final _contentKey = GlobalKey();
  WindowChromeController get controller =>
      widget.controller ?? WindowChromeController.instance;

  BuildContext? _findMenuContext() {
    // MaterialApp.builder sits above its Navigator. Use only the Navigator
    // contained in this window when its fallback caption opens an app menu.
    BuildContext? result;
    void visit(Element element) {
      if (result != null) return;
      if (element is StatefulElement && element.state is NavigatorState) {
        final overlay =
            (element.state as NavigatorState).overlay?.context as Element?;
        overlay?.visitChildElements((child) => result ??= child);
        return;
      }
      element.visitChildElements(visit);
    }

    (_contentKey.currentContext as Element?)?.visitChildElements(visit);
    return result;
  }

  @override
  void initState() {
    super.initState();
    unawaited(controller.start());
  }

  @override
  void didUpdateWidget(WindowsWindowChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(controller.start());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([controller, widget.navigationState]),
    builder: (context, _) {
      return WindowChromeScope(
        controller: controller,
        menuContext: _findMenuContext,
        // App-root presentation scope: every MaterialApp root wraps its
        // content in this chrome, so terminal views rebuild in place when the
        // device-local palette overlay changes.
        child: TerminalPaletteScope(
          notifier: TerminalPaletteController.instance,
          child: Overlay.wrap(
          child: Column(
            children: [
              if (controller.supported &&
                  (controller.state.customFrame ||
                      controller.state.leadingInset > 0) &&
                  !(widget.navigationEmbedded?.call() ?? false))
                WindowCaption(
                  controller: controller,
                  title: widget.title,
                  leading: widget.leading,
                  actions: widget.actions,
                ),
              Expanded(
                child: KeyedSubtree(key: _contentKey, child: widget.child),
              ),
            ],
          ),
        ),
        ),
      );
    },
  );
}

/// Sizes for the single merged Windows top bar (caption, drag region, Home and
/// session tabs, search/tools icons and caption buttons share one row).
///
/// On a custom-chrome Windows window the row height is the runner-reported
/// native caption metric ([WindowChromeState.captionHeight]); it follows DPI,
/// non-client metric and theme changes through `stateChanged`. It only grows
/// beyond the metric when the user's text scale would otherwise clip the tab
/// label. Elsewhere (Android/iOS/web/macOS/Linux, or Windows with the system
/// frame) the existing 48 px touch-sized bar is kept unchanged.
@immutable
class WindowBarMetrics {
  const WindowBarMetrics._({
    required this.height,
    required this.dense,
    required this.tabHeight,
    required this.tabInset,
    required this.iconSize,
    required this.actionWidth,
  });

  /// Touch-sized bar used when the native caption is not merged.
  static const touch = WindowBarMetrics._(
    height: 48,
    dense: false,
    tabHeight: 32,
    tabInset: 8,
    iconSize: 18,
    actionWidth: 48,
  );

  /// Used only if a custom-chrome runner does not report the metric.
  static const fallbackCaptionHeight = 32.0;

  /// Unified compact title-bar height on macOS (HIG standard 38 pt).
  static const macosCaptionHeight = 38.0;

  /// Label font size inside dense native-height tabs.
  static const denseLabelSize = 13.5;

  factory WindowBarMetrics.of(
    BuildContext context,
    WindowChromeController controller,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    if (controller.supported && controller.state.customFrame) {
      return WindowBarMetrics.native(
        controller.state.captionHeight ?? fallbackCaptionHeight,
        scaler,
      );
    }
    if ((controller.supported && controller.state.leadingInset > 0) ||
        Theme.of(context).platform == TargetPlatform.macOS) {
      return WindowBarMetrics.macos(
        controller.state.captionHeight ?? macosCaptionHeight,
        scaler,
      );
    }
    return touch;
  }

  /// [captionHeight] is the native metric in logical pixels.
  factory WindowBarMetrics.native(double captionHeight, TextScaler scaler) {
    const inset = 4.0;
    // Strut-forced label line + 1 px borders: the minimum that never clips.
    final label = scaler.scale(denseLabelSize) * _labelLineHeight + 2;
    final height = math.max(captionHeight, label + inset * 2);
    return WindowBarMetrics._(
      height: height,
      dense: true,
      tabHeight: height - inset * 2,
      tabInset: inset,
      iconSize: 17,
      actionWidth: 42,
    );
  }

  /// Compact macOS unified title-bar metrics (38 pt bar, 30 pt tabs).
  factory WindowBarMetrics.macos(double captionHeight, TextScaler scaler) {
    const inset = 4.0;
    final label = scaler.scale(13.0) * _labelLineHeight + 2;
    final height = math.max(captionHeight, label + inset * 2);
    return WindowBarMetrics._(
      height: height,
      dense: true,
      tabHeight: height - inset * 2,
      tabInset: inset,
      iconSize: 16,
      actionWidth: 36,
    );
  }

  static const _labelLineHeight = 1.3;

  /// Strut that pins the tab label line box so CJK/Cyrillic fallback fonts
  /// cannot grow it past [tabHeight].
  static const denseLabelStrut = StrutStyle(
    fontSize: denseLabelSize,
    height: _labelLineHeight,
    forceStrutHeight: true,
  );

  final double height;
  final bool dense;
  final double tabHeight;
  final double tabInset;
  final double iconSize;
  final double actionWidth;
}

class WindowCaption extends StatelessWidget {
  const WindowCaption({
    super.key,
    required this.controller,
    this.title = '',
    this.leading,
    this.actions = const [],
  });

  /// Height when the runner did not report a native metric.
  static const height = WindowBarMetrics.fallbackCaptionHeight;
  final WindowChromeController controller;
  final String title;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final metrics = WindowBarMetrics.of(context, controller);
      return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        key: const ValueKey('windows_window_caption'),
        height: metrics.height,
        child: Row(
          children: [
            if (controller.state.leadingInset > 0)
              SizedBox(width: controller.state.leadingInset),
            ?leading,
            Expanded(
              child: WindowDragArea(
                controller: controller,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: controller.state.focused
                            ? null
                            : Theme.of(context).disabledColor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ...actions,
            WindowCaptionControls(
              controller: controller,
              height: metrics.height,
            ),
          ],
        ),
      ),
    );
    },
  );
}

/// Only the unused navigation area initiates a window drag; tab gestures keep
/// their existing drag-to-reorder/split behavior.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({
    super.key,
    required this.controller,
    required this.child,
  });
  final WindowChromeController controller;
  final Widget child;
  @override
  Widget build(BuildContext context) => GestureDetector(
    key: const ValueKey('window_caption_drag_area'),
    behavior: HitTestBehavior.opaque,
    onPanStart: (_) => unawaited(controller.beginDrag()),
    onDoubleTap: () => unawaited(controller.toggleMaximize()),
    onSecondaryTapDown: (event) {
      final target = Navigator.maybeOf(context) != null
          ? context
          : context
                .getInheritedWidgetOfExactType<WindowChromeScope>()
                ?.menuContext
                ?.call();
      if (target == null || !target.mounted) return;
      unawaited(
        showWorkspaceContextMenu(target, event.globalPosition, [
          WorkspaceAction(
            'window_restore',
            context.l10n.restore2,
            Icons.filter_none,
            controller.toggleMaximize,
            enabled: controller.state.maximized,
          ),
          WorkspaceAction(
            'window_minimize',
            context.l10n.minimize2,
            Icons.remove,
            controller.minimize,
          ),
          WorkspaceAction(
            'window_maximize',
            context.l10n.maximize2,
            Icons.crop_square,
            controller.toggleMaximize,
            enabled: !controller.state.maximized,
          ),
          WorkspaceAction(
            'window_close',
            context.l10n.closeWindow2,
            Icons.close,
            controller.close,
          ),
        ]),
      );
    },
    child: child,
  );
}

class WindowCaptionControls extends StatelessWidget {
  const WindowCaptionControls({
    super.key,
    required this.controller,
    this.height,
  });
  final WindowChromeController controller;

  /// Null follows the native caption metric of [controller].
  final double? height;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.supported || !controller.state.customFrame) {
        return const SizedBox.shrink();
      }
      final height =
          this.height ?? WindowBarMetrics.of(context, controller).height;
      return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CaptionButton(
                height: height,
                id: 'minimize',
                label: context.l10n.minimize,
                glyph: _CaptionGlyph.minimize,
                focused: controller.state.focused,
                rounded: controller.state.roundedCaptionGlyphs,
                onPressed: controller.minimize,
              ),
              _CaptionButton(
                height: height,
                id: 'maximize',
                label: controller.state.maximized
                    ? context.l10n.restore
                    : context.l10n.maximize,
                glyph: controller.state.maximized
                    ? _CaptionGlyph.restore
                    : _CaptionGlyph.maximize,
                focused: controller.state.focused,
                rounded: controller.state.roundedCaptionGlyphs,
                onPressed: controller.toggleMaximize,
                native: controller.state.nativeMaximizeButton
                    ? controller
                    : null,
              ),
              _CaptionButton(
                height: height,
                id: 'close',
                label: context.l10n.closeWindow,
                glyph: _CaptionGlyph.close,
                focused: controller.state.focused,
                rounded: controller.state.roundedCaptionGlyphs,
                onPressed: controller.close,
              ),
            ],
          );
    },
  );
}

enum _CaptionGlyph { minimize, maximize, restore, close }

/// One of the three window buttons, drawn the way Windows draws its own:
/// 46 px wide and as tall as the caption, a 10 px hairline glyph (rounded on
/// Windows 11, square on Windows 10), the system's subtle hover and pressed
/// fills, the red Close fill, and dimmed glyphs while the window is inactive.
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.id,
    required this.label,
    required this.glyph,
    required this.onPressed,
    required this.height,
    required this.focused,
    required this.rounded,
    this.native,
  });

  /// Set for the maximize button on Windows 11: the runner then answers for
  /// this spot so Windows offers snap layouts on hover, and reports the
  /// pointer state back, because Flutter no longer sees the mouse here.
  final WindowChromeController? native;
  final String id;
  final String label;
  final _CaptionGlyph glyph;
  final Future<void> Function() onPressed;
  final double height;
  final bool focused, rounded;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false, _pressed = false;
  WindowChromeController? _reportedTo;

  /// Reports where the button is, after every layout that shows it.
  void _reportGeometry() {
    final native = widget.native;
    if (native == null) {
      _stopReporting();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.native != native) return;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize || !box.attached) return;
      final view = View.of(context);
      final scale = view.devicePixelRatio;
      final origin = box.localToGlobal(Offset.zero);
      final right = (origin.dx + box.size.width) * scale;
      _reportedTo = native;
      unawaited(
        native.setMaximizeButton(
          this,
          rightInset: math.max(0, (view.physicalSize.width - right).round()),
          top: math.max(0, (origin.dy * scale).round()),
          width: (box.size.width * scale).round(),
          height: (box.size.height * scale).round(),
        ),
      );
    });
  }

  void _stopReporting() {
    final reported = _reportedTo;
    _reportedTo = null;
    if (reported != null) unawaited(reported.clearMaximizeButton(this));
  }

  @override
  void dispose() {
    _stopReporting();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _reportGeometry();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final close = widget.glyph == _CaptionGlyph.close;
    final nativeState = widget.native?.state;
    final pressed = _pressed || (nativeState?.maximizePressed ?? false);
    final hovered = _hovered || (nativeState?.maximizeHovered ?? false);
    final active = hovered || pressed;
    // Windows 11 caption button colours (WinUI title bar resources).
    final Color fill = !active
        ? Colors.transparent
        : close
        ? (pressed ? const Color(0xE6C42B1C) : const Color(0xFFC42B1C))
        : dark
        ? (pressed ? const Color(0x0AFFFFFF) : const Color(0x0FFFFFFF))
        : (pressed ? const Color(0x06000000) : const Color(0x09000000));
    final Color ink = close && active
        ? (pressed ? const Color(0xB3FFFFFF) : Colors.white)
        : !widget.focused && !active
        ? (dark ? const Color(0x5DFFFFFF) : const Color(0x5C000000))
        : dark
        ? Colors.white
        : const Color(0xE4000000);
    return Tooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        button: true,
        label: widget.label,
        onTap: () => unawaited(widget.onPressed()),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = _pressed = false),
          child: GestureDetector(
            key: ValueKey('window_caption_${widget.id}'),
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: () {
              setState(() => _pressed = false);
              unawaited(widget.onPressed());
            },
            child: ColoredBox(
              color: fill,
              child: SizedBox(
                width: 46,
                height: widget.height,
                child: CustomPaint(
                  painter: _CaptionGlyphPainter(
                    widget.glyph,
                    ink,
                    rounded: widget.rounded,
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

class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter(this.glyph, this.color, {required this.rounded});
  final _CaptionGlyph glyph;
  final Color color;
  final bool rounded;

  @override
  void paint(Canvas canvas, Size size) {
    // A 10 px glyph centred in the button, snapped to whole pixels so the
    // one-pixel strokes stay crisp.
    final left = ((size.width - 10) / 2).floorToDouble() + .5;
    final top = ((size.height - 10) / 2).floorToDouble() + .5;
    canvas.translate(left, top);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..isAntiAlias = true;
    final corner = Radius.circular(rounded ? 1.5 : 0);
    switch (glyph) {
      case _CaptionGlyph.minimize:
        canvas.drawLine(const Offset(0, 5), const Offset(10, 5), pen);
      case _CaptionGlyph.maximize:
        canvas.drawRRect(
          RRect.fromLTRBR(0, 0, 10, 10, corner),
          pen,
        );
      case _CaptionGlyph.restore:
        final front = RRect.fromLTRBR(0, 2, 8, 10, corner);
        canvas.drawRRect(front, pen);
        // The window behind: only what shows past the front one.
        canvas.save();
        canvas.clipPath(
          Path.combine(
            PathOperation.difference,
            Path()..addRect(const Rect.fromLTRB(-1, -1, 11, 11)),
            Path()..addRect(const Rect.fromLTRB(-1, 1.5, 8.5, 11)),
          ),
        );
        canvas.drawRRect(
          RRect.fromLTRBR(2, 0, 10, 8, Radius.circular(rounded ? 2.5 : 0)),
          pen,
        );
        canvas.restore();
      case _CaptionGlyph.close:
        canvas.drawLine(Offset.zero, const Offset(10, 10), pen);
        canvas.drawLine(const Offset(10, 0), const Offset(0, 10), pen);
    }
  }

  @override
  bool shouldRepaint(_CaptionGlyphPainter oldDelegate) =>
      glyph != oldDelegate.glyph ||
      color != oldDelegate.color ||
      rounded != oldDelegate.rounded;
}
