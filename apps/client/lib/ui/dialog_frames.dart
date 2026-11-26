import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Window-level dialogs: a dialog opens over the frame it belongs to (one
/// session pane, or the Home area), never over the whole application window.
///
/// Every frame has a [Navigator] of its own (its "host") in a layer above the
/// workspace content ([DialogFrameLayer]). The host follows the frame's
/// position with a [CompositedTransformFollower] and takes the frame's size,
/// so a dialog's barrier, a side sheet's height and a centred dialog's room
/// are the frame's. The tab row and the other panes stay usable.
///
/// The host is not part of the frame's subtree. A tab that is switched away
/// keeps its open dialogs, with their state, hidden; they show again when the
/// tab comes back. Only the owner ends a frame (its tab was closed); the
/// frame's open dialogs are popped then.
///
/// A dialog goes to the frame [showAppDialog]'s context is in (a pane, the
/// Home area, or a dialog already in a frame). A context outside every frame
/// (the tab row, the ☰ menu, the shell itself) uses the owner's current
/// frame: the selected pane, or the Home area. `frameId` names a frame
/// explicitly (a prompt for one tab), and `useRootNavigator: true` keeps the
/// old window-wide behaviour.
mixin DialogFrameOwner<T extends StatefulWidget> on State<T> {
  DialogFrameController get dialogFrames;
}

/// Lookup helpers for frame-scoped dialogs.
abstract final class DialogFrames {
  /// The frame controller [context] belongs to, or null outside a workspace
  /// that hosts frame-scoped dialogs.
  static DialogFrameController? controllerOf(BuildContext context) {
    final marker = context.getInheritedWidgetOfExactType<_DialogFrameMarker>();
    if (marker?.controller case final controller?) return controller;
    if (context is StatefulElement && context.state is DialogFrameOwner) {
      return (context.state as DialogFrameOwner).dialogFrames;
    }
    return context.findAncestorStateOfType<DialogFrameOwner>()?.dialogFrames;
  }

  /// A context that stays mounted as long as the workspace does, for a dialog
  /// shown after the widget that started it may be gone (its dialogs use the
  /// current frame). Outside a workspace: the root navigator's context.
  static BuildContext stableContextOf(BuildContext context) {
    if (context is StatefulElement && context.state is DialogFrameOwner) {
      return context;
    }
    return context.findAncestorStateOfType<DialogFrameOwner>()?.context ??
        Navigator.of(context, rootNavigator: true).context;
  }

  static const _zoneKey = #atermiusDialogFrame;

  /// Runs [body] so that dialogs it opens with a context outside every
  /// frame — also after an await — go to the frame [context] is in. A pane's
  /// handle menu builds its actions with the session page's context; run
  /// through its own context they open in that pane, whichever pane is
  /// selected and however the menu was used (pointer or screen reader).
  static FutureOr<T> runInFrameOf<T>(
    BuildContext context,
    FutureOr<T> Function() body,
  ) => runInFrame(context.mounted ? frameIdOf(context) : null, body);

  /// [runInFrameOf] with a frame looked up beforehand: a menu closes (and
  /// its button may leave the tree) before the chosen action runs.
  static FutureOr<T> runInFrame<T>(String? frame, FutureOr<T> Function() body) {
    if (frame == null) return body();
    return runZoned(body, zoneValues: {_zoneKey: frame});
  }

  /// The frame [context] is in, or null outside every frame.
  static String? frameIdOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_DialogFrameMarker>()?.frameId;

  /// Where a dialog opened from [context] goes.
  ///
  /// - [frameId], or the frame [context] is in: that frame, even while its
  ///   tab is hidden (the dialog waits with it). [later] completes once the
  ///   frame's host is built, with null if the frame ended first.
  /// - From outside every frame (tab row, menus, the shell itself): the
  ///   current frame if it is on screen with its host built, else the whole
  ///   window — a prompt for a tab that is not shown yet must not wait unseen.
  /// - Outside a workspace: the whole window.
  ///
  /// [now] is the frame host to use at once; both null means the root
  /// navigator.
  static ({NavigatorState? now, Future<NavigatorState?>? later}) placementOf(
    BuildContext context, {
    String? frameId,
  }) {
    const window = (now: null, later: null);
    final controller = controllerOf(context);
    if (controller == null || controller._disposed) return window;
    final named =
        frameId ?? frameIdOf(context) ?? Zone.current[_zoneKey] as String?;
    // From outside every frame: the frame the user just pressed in (a pane's
    // own handle menu runs with the session page's context), else the
    // owner's current frame.
    final frame =
        named ??
        controller._justClosedFrame ??
        controller._pressedFrame ??
        controller.currentFrame;
    if (frame == null) return window;
    final now = controller.navigatorNow(frame);
    if (named == null) {
      return now != null && controller.isVisible(frame)
          ? (now: now, later: null)
          : window;
    }
    if (now != null) return (now: now, later: null);
    return (now: null, later: controller.navigatorFor(frame));
  }

  /// The navigator for a dialog opened from [context] when it must be known
  /// now: the frame host if it is ready, else the root navigator.
  static NavigatorState navigatorNow(BuildContext context, {String? frameId}) =>
      placementOf(context, frameId: frameId).now ??
      Navigator.of(context, rootNavigator: true);

  /// The navigator for a dialog opened from [context] (see [placementOf]).
  /// Completes with null when its frame ended before the host was ready.
  static Future<NavigatorState?> navigatorFor(
    BuildContext context, {
    String? frameId,
  }) {
    final placement = placementOf(context, frameId: frameId);
    if (placement.now case final now?) return SynchronousFuture(now);
    return placement.later ??
        SynchronousFuture(Navigator.of(context, rootNavigator: true));
  }

  /// Themes for a route pushed from [from] onto [navigator]. A frame host is
  /// not an ancestor of the frame's content, so everything up to the root
  /// is captured then.
  static CapturedThemes captureThemes(
    BuildContext from,
    NavigatorState navigator,
  ) {
    var ancestor = false;
    from.visitAncestorElements((element) {
      ancestor = identical(element, navigator.context);
      return !ancestor;
    });
    return InheritedTheme.capture(
      from: from,
      to: ancestor ? navigator.context : null,
    );
  }
}

class _DialogFrameEntry {
  _DialogFrameEntry(this.id, DialogFrameController controller)
    : observer = _DialogFrameObserver(controller);

  final String id;
  final link = LayerLink();
  late final navigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'dialog frame $id',
  );
  final _DialogFrameObserver observer;
  late final hostKey = GlobalObjectKey(this);
  Size? size;
  bool visible = false;
  RenderBox? area;
  final waiters = <Completer<NavigatorState?>>[];

  /// Focus may enter the host only while it shows a dialog. An empty host
  /// (every pane has one) must never hold focus: the shell's focus history
  /// would hand focus back to it instead of the terminal being typed into.
  /// Set synchronously when a dialog is pushed, so the dialog and its
  /// autofocus field get focus as they would on the root navigator.
  final gate = FocusNode(
    debugLabel: 'dialog frame gate',
    canRequestFocus: false,
    skipTraversal: true,
    descendantsAreFocusable: false,
    descendantsAreTraversable: false,
  );

  /// Opens the gate while the frame is on screen with a dialog. Returns
  /// whether it just opened.
  bool updateGate() {
    final open = visible && routes.isNotEmpty;
    if (gate.descendantsAreFocusable == open) return false;
    gate
      ..descendantsAreFocusable = open
      ..descendantsAreTraversable = open;
    return open;
  }

  List<Route<dynamic>> get routes => observer.routes;
}

class _DialogFrameObserver extends NavigatorObserver {
  _DialogFrameObserver(this.controller);

  final DialogFrameController controller;
  final routes = <Route<dynamic>>[];
  late _DialogFrameEntry frame;

  void _changed() {
    frame.updateGate();
    controller._scheduleNotify();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is _DialogFrameBaseRoute) return;
    routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!routes.remove(route)) return;
    controller._noteClosed(frame.id);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (routes.remove(route)) _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        routes.removeAt(index);
      } else {
        routes[index] = newRoute;
      }
    } else if (newRoute != null && newRoute is! _DialogFrameBaseRoute) {
      routes.add(newRoute);
    }
    _changed();
  }
}

/// The frames of one workspace window and their dialog hosts.
class DialogFrameController extends ChangeNotifier {
  DialogFrameController({required String? Function() currentFrame})
    : _currentFrame = currentFrame;

  final String? Function() _currentFrame;
  final Map<String, _DialogFrameEntry> _frames = {};
  bool _notifyScheduled = false;
  bool _checkScheduled = false;
  bool _disposed = false;
  String? _lastPressed;
  String? _lastClosed;
  final _sinceClosed = Stopwatch();

  /// A frame whose dialog closed a moment ago: a dialog that closes itself
  /// and opens the next one (Properties → Edit host, a confirmation → the
  /// next step) keeps the chain in its frame, however the button was used.
  String? get _justClosedFrame {
    final id = _lastClosed;
    if (id == null || _sinceClosed.elapsed > const Duration(seconds: 1)) {
      return null;
    }
    return (_frames[id]?.visible ?? false) ? id : null;
  }

  void _noteClosed(String id) {
    _lastClosed = id;
    _sinceClosed
      ..reset()
      ..start();
  }

  /// The visible frame the last pointer press landed in, if any.
  String? get _pressedFrame {
    final id = _lastPressed;
    return id != null && (_frames[id]?.visible ?? false) ? id : null;
  }

  /// Remembers which frame (if any) a press at [position] landed in.
  void _notePress(Offset position) {
    // A press is newer than any dialog that closed before it (the close a
    // press causes comes after it).
    _lastClosed = null;
    _lastPressed = null;
    for (final frame in _frames.values) {
      final area = frame.area;
      // The Home area keeps one reporter while its frame (the page) changes:
      // it counts only for the frame it reports now.
      if (!frame.visible ||
          area == null ||
          !area.attached ||
          !area.hasSize ||
          (area is _RenderDialogFrameReporter && area._frameId != frame.id)) {
        continue;
      }
      final rect = MatrixUtils.transformRect(
        area.getTransformTo(null),
        Offset.zero & area.size,
      );
      if (rect.contains(position)) {
        _lastPressed = frame.id;
        return;
      }
    }
  }

  /// The frame a dialog from outside every frame goes to.
  String? get currentFrame => _currentFrame();

  _DialogFrameEntry _frame(String id) => _frames.putIfAbsent(id, () {
    final frame = _DialogFrameEntry(id, this);
    frame.observer.frame = frame;
    return frame;
  });

  /// Frames that have a host (for tests and diagnostics).
  @visibleForTesting
  Iterable<String> get frameIds => _frames.keys;

  /// Whether [id] has an open dialog (shown or, in a hidden tab, waiting).
  bool hasDialogs(String id) => _frames[id]?.routes.isNotEmpty ?? false;

  /// Whether [id] is on screen.
  bool isVisible(String id) => _frames[id]?.visible ?? false;

  /// The host of [id] if it is mounted.
  NavigatorState? navigatorNow(String id) {
    final state = _frames[id]?.navigatorKey.currentState;
    return state != null && state.mounted ? state : null;
  }

  /// The host of [id], once it is mounted. Null when the frame ends first.
  Future<NavigatorState?> navigatorFor(String id) {
    final now = navigatorNow(id);
    if (now != null) return SynchronousFuture(now);
    if (_disposed) return SynchronousFuture(null);
    final waiter = Completer<NavigatorState?>();
    _frame(id).waiters.add(waiter);
    _scheduleNotify();
    return waiter.future;
  }

  /// Makes sure [ids] have a host, so one is built together with a new tab:
  /// a prompt that arrives as the tab opens (a login challenge) shows at once.
  void ensure(Iterable<String> ids) {
    if (_disposed) return;
    var added = false;
    for (final id in ids) {
      if (_frames.containsKey(id)) continue;
      _frame(id);
      added = true;
    }
    if (added) _scheduleNotify();
  }

  /// Ends every frame [alive] rejects: its open dialogs are popped (their
  /// callers see a cancel) and its host goes away.
  void retain(bool Function(String id) alive) {
    var changed = false;
    for (final frame in _frames.values.toList()) {
      if (alive(frame.id)) continue;
      changed = true;
      _frames.remove(frame.id);
      final navigator = frame.navigatorKey.currentState;
      if (navigator != null && navigator.mounted && frame.routes.isNotEmpty) {
        navigator.popUntil((route) => route is _DialogFrameBaseRoute);
      }
      for (final waiter in frame.waiters) {
        if (!waiter.isCompleted) waiter.complete(null);
      }
      frame.waiters.clear();
      // The host leaves the tree on the next build; then the gate goes.
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => frame.gate.dispose(),
      );
    }
    if (changed) _scheduleNotify();
  }

  void _reportSize(String id, Size size) {
    final frame = _frames[id];
    if (frame == null || frame.size == size) return;
    frame.size = size;
    _scheduleNotify();
  }

  void _scheduleCheck() {
    if (_checkScheduled || _disposed) return;
    _checkScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (_disposed) return;
      if (_updateVisibility()) _notifyNow();
    });
  }

  void _scheduleNotify() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (_disposed) return;
      _updateVisibility();
      _notifyNow();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _notifyNow() {
    notifyListeners();
  }

  /// A frame is on screen when its target was composited in the last frame.
  /// Returns whether anything changed.
  bool _updateVisibility() {
    var changed = false;
    for (final frame in _frames.values) {
      final visible = frame.link.leader != null;
      if (visible == frame.visible) continue;
      changed = true;
      frame.visible = visible;
      if (frame.updateGate()) {
        // Focus left the dialog when its tab was hidden; it comes back with
        // the tab, once the host stops excluding focus.
        SchedulerBinding.instance.addPostFrameCallback((_) {
          final navigator = frame.navigatorKey.currentState;
          if (navigator == null || !navigator.mounted || !frame.visible) return;
          // Each route's focus scope sits under the navigator's node; the
          // last one is the dialog on top, and it remembers its own focus.
          navigator.focusNode.children
              .whereType<FocusScopeNode>()
              .lastOrNull
              ?.requestFocus();
        });
      }
    }
    return changed;
  }

  /// Hosts whose navigator just mounted release their waiting dialogs.
  void _hostsBuilt() {
    for (final frame in _frames.values) {
      if (frame.waiters.isEmpty) continue;
      final navigator = frame.navigatorKey.currentState;
      if (navigator == null || !navigator.mounted) continue;
      final waiters = List.of(frame.waiters);
      frame.waiters.clear();
      for (final waiter in waiters) {
        if (!waiter.isCompleted) waiter.complete(navigator);
      }
    }
  }

  /// Whether a dialog is on screen in one of the frames (Back closes it).
  bool get hasVisibleDialog => _anyVisibleDialog;

  bool get _anyVisibleDialog =>
      _frames.values.any((frame) => frame.visible && frame.routes.isNotEmpty);

  /// System back: the dialog of the current frame first, else any dialog on
  /// screen.
  void _popVisibleDialog() {
    final current = _frames[currentFrame ?? ''];
    final frame =
        current != null && current.visible && current.routes.isNotEmpty
        ? current
        : _frames.values
              .where((frame) => frame.visible && frame.routes.isNotEmpty)
              .lastOrNull;
    frame?.navigatorKey.currentState?.maybePop();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final frame in _frames.values) {
      for (final waiter in frame.waiters) {
        if (!waiter.isCompleted) waiter.complete(null);
      }
      final gate = frame.gate;
      SchedulerBinding.instance.addPostFrameCallback((_) => gate.dispose());
    }
    super.dispose();
  }
}

/// The empty first route of a frame host: paints nothing and lets every
/// pointer through to the frame below. It never takes focus: a host appears
/// whenever a pane does, and the terminal being typed into keeps the focus.
class _DialogFrameBaseRoute extends OverlayRoute<void> {
  _DialogFrameBaseRoute() : super(requestFocus: false);

  @override
  Iterable<OverlayEntry> createOverlayEntries() => [
    OverlayEntry(builder: (_) => const SizedBox.shrink()),
  ];
}

class _DialogFrameMarker extends InheritedWidget {
  const _DialogFrameMarker({
    required this.controller,
    required this.frameId,
    required super.child,
  });

  final DialogFrameController? controller;
  final String? frameId;

  @override
  bool updateShouldNotify(_DialogFrameMarker oldWidget) =>
      controller != oldWidget.controller || frameId != oldWidget.frameId;
}

/// Marks [child] as the frame [id]: dialogs opened from inside it, or for it,
/// are confined to its area. A null [id] marks an area that is no frame of
/// its own (dialogs from it use the current frame). Outside a
/// [DialogFrameOwner] this is only [child].
class DialogFrame extends StatefulWidget {
  const DialogFrame({super.key, required this.id, required this.child});

  final String? id;
  final Widget child;

  @override
  State<DialogFrame> createState() => _DialogFrameState();
}

class _DialogFrameState extends State<DialogFrame> {
  // A target always stays in the tree, so a frame id coming and going never
  // remounts the content; without a frame it leads a link nobody follows.
  final _inertLink = LayerLink();

  @override
  Widget build(BuildContext context) {
    final controller = DialogFrames.controllerOf(context);
    final id = widget.id;
    final frame = controller == null || id == null || controller._disposed
        ? null
        : controller._frame(id);
    final content = _DialogFrameReporter(
      controller: frame == null ? null : controller,
      frameId: frame?.id,
      child: widget.child,
    );
    return _DialogFrameMarker(
      controller: controller,
      frameId: frame?.id,
      child: CompositedTransformTarget(
        link: frame?.link ?? _inertLink,
        // While the frame shows a dialog, assistive technology reads the
        // dialog only, as under a window-wide dialog's barrier. The same
        // widgets either way, so the content is never remounted.
        child: ListenableBuilder(
          listenable: controller ?? const _NoChanges(),
          builder: (context, child) => ExcludeSemantics(
            excluding: frame != null && controller!.hasDialogs(frame.id),
            child: child,
          ),
          child: content,
        ),
      ),
    );
  }
}

class _DialogFrameReporter extends SingleChildRenderObjectWidget {
  const _DialogFrameReporter({
    required this.controller,
    required this.frameId,
    super.child,
  });

  final DialogFrameController? controller;
  final String? frameId;

  @override
  _RenderDialogFrameReporter createRenderObject(BuildContext context) =>
      _RenderDialogFrameReporter(controller, frameId);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderDialogFrameReporter renderObject,
  ) {
    renderObject
      ..controller = controller
      ..frameId = frameId;
  }
}

class _RenderDialogFrameReporter extends RenderProxyBox {
  _RenderDialogFrameReporter(this._controller, this._frameId);

  DialogFrameController? _controller;
  set controller(DialogFrameController? value) {
    if (identical(value, _controller)) return;
    // The frame this reported for is no longer here: its visibility must be
    // looked at again, and its area is not this box any more.
    final previous = _controller;
    final frame = previous?._frames[_frameId ?? ''];
    if (identical(frame?.area, this)) frame!.area = null;
    previous?._scheduleCheck();
    _controller = value;
    markNeedsLayout();
  }

  String? _frameId;
  set frameId(String? value) {
    if (value == _frameId) return;
    final previous = _controller?._frames[_frameId ?? ''];
    if (identical(previous?.area, this)) previous!.area = null;
    _frameId = value;
    markNeedsLayout();
    _controller?._scheduleCheck();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _controller?._scheduleCheck();
  }

  @override
  void detach() {
    _controller?._scheduleCheck();
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    if (_frameId case final id?) {
      _controller?._reportSize(id, size);
      _controller?._frames[id]?.area = this;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _controller?._scheduleCheck();
  }
}

/// The layer above a workspace's content that holds its frames' dialog
/// hosts. Wrap the area that contains every frame (the tab row may be inside
/// it: hosts only cover their frames).
class DialogFrameLayer extends StatefulWidget {
  const DialogFrameLayer({
    super.key,
    required this.controller,
    required this.child,
  });

  final DialogFrameController controller;
  final Widget child;

  @override
  State<DialogFrameLayer> createState() => _DialogFrameLayerState();
}

class _DialogFrameLayerState extends State<DialogFrameLayer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(DialogFrameLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final media = MediaQuery.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller._disposed) controller._hostsBuilt();
    });
    return PopScope(
      canPop: !controller._anyVisibleDialog,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) controller._popVisibleDialog();
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) => controller._notePress(event.position),
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              for (final frame in controller._frames.values)
                _host(
                  controller,
                  frame,
                  frame.size ?? constraints.biggest,
                  constraints.biggest,
                  media,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _host(
    DialogFrameController controller,
    _DialogFrameEntry frame,
    Size size,
    Size window,
    MediaQueryData media,
  ) {
    final scale = dialogFrameScale(size, window);
    final room = Size(size.width / scale, size.height / scale);
    return Positioned(
      key: frame.hostKey,
      left: 0,
      top: 0,
      width: size.width,
      height: size.height,
      child: CompositedTransformFollower(
        link: frame.link,
        showWhenUnlinked: false,
        child: Focus.withExternalFocusNode(
          focusNode: frame.gate,
          includeSemantics: false,
          // A hidden tab's dialog keeps its state and finishes its animations
          // (a dialog popped as its tab was left must still go away), but is
          // not painted or hit (the follower) and not read out. With a dialog
          // it is a semantics container of its own: the barrier then blocks
          // what lies under it in the frame (see DialogFrame), never the tab
          // row. An empty host adds no semantics node at all.
          child: Semantics(
            container: frame.routes.isNotEmpty,
            explicitChildNodes: frame.routes.isNotEmpty,
            child: _FrameHostVisibility(
              link: frame.link,
              visible: frame.visible,
              // A pane smaller than a dialog's minimum room shows the dialog
              // scaled down to fit instead of overflowing. Always the same
              // widgets, so a resized pane never remounts its dialogs.
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: room.width,
                maxWidth: room.width,
                minHeight: room.height,
                maxHeight: room.height,
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: MediaQuery(
                    // The frame is the dialog's screen: centred dialogs, side
                    // sheets and anything sized from MediaQuery use its room.
                    data: media.copyWith(size: room, displayFeatures: const []),
                    child: _DialogFrameMarker(
                      controller: controller,
                      frameId: frame.id,
                      child: Navigator(
                        key: frame.navigatorKey,
                        observers: [frame.observer],
                        onGenerateInitialRoutes: (_, _) => [
                          _DialogFrameBaseRoute(),
                        ],
                      ),
                    ),
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

/// The least room a dialog is laid out in: dialogs were made for a window
/// at least this big (or the whole window, when the window is smaller).
const dialogFrameMinRoom = Size(360, 600);

/// How much a frame of [frame] size in a window of [window] size scales its
/// dialogs: 1 when the frame has [dialogFrameMinRoom], less for a small pane.
double dialogFrameScale(Size frame, Size window) {
  if (frame.isEmpty) return 1;
  final width = math.min(dialogFrameMinRoom.width, window.width);
  final height = math.min(dialogFrameMinRoom.height, window.height);
  return math.min(1.0, math.min(frame.width / width, frame.height / height));
}

/// Leaves a hidden frame's host out of semantics (and, for tests, out of the
/// on-screen widgets) from the frame it is hidden in: the follower above it
/// already stops painting and hit testing then.
class _FrameHostVisibility extends SingleChildRenderObjectWidget {
  const _FrameHostVisibility({
    required this.link,
    required this.visible,
    super.child,
  });

  final LayerLink link;

  /// The frame's visibility as of the last frame; a change refreshes the
  /// semantics.
  final bool visible;

  @override
  SingleChildRenderObjectElement createElement() =>
      _FrameHostVisibilityElement(this);

  @override
  _RenderFrameHostVisibility createRenderObject(BuildContext context) =>
      _RenderFrameHostVisibility(link, visible);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFrameHostVisibility renderObject,
  ) {
    renderObject
      ..link = link
      ..visible = visible;
  }
}

class _FrameHostVisibilityElement extends SingleChildRenderObjectElement {
  _FrameHostVisibilityElement(_FrameHostVisibility super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    if ((widget as _FrameHostVisibility).link.leader == null) return;
    super.debugVisitOnstageChildren(visitor);
  }
}

class _RenderFrameHostVisibility extends RenderProxyBox {
  _RenderFrameHostVisibility(this.link, this._visible);

  LayerLink link;

  bool _visible;
  set visible(bool value) {
    if (value == _visible) return;
    _visible = value;
    markNeedsSemanticsUpdate();
  }

  // Semantics follow the visibility settled after each frame: deciding from
  // the link itself would change the children mid-frame without marking them.
  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (!_visible) return;
    super.visitChildrenForSemantics(visitor);
  }
}

class _NoChanges implements Listenable {
  const _NoChanges();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
