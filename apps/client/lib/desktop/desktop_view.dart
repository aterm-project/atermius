import '../ui/app_menu.dart';
import '../ui/session_workspace.dart';
import '../ui/fullscreen_menu.dart';
import '../platform/fullscreen.dart';
import '../platform/wheel_scroll_lines.dart';
import '../domain/models.dart';
import 'desktop_mobile_controls.dart';
import 'desktop_keyboard_mode.dart';
import 'keyboard_capture.dart';
import 'desktop_touch_input.dart';
import 'desktop_direct_touch.dart';
import '../ui/app_motion.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb, precisionErrorTolerance;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/local_clipboard.dart';
import '../ui/clipboard_paste.dart';
import 'desktop_clipboard_sync.dart';
import 'desktop_display.dart';
import 'desktop_resolution.dart';
import 'desktop_resolution_dialog.dart';
import 'desktop_session.dart';
import 'desktop_wheel.dart';
import 'rdp_folder_picker.dart';
import 'rdp_storage.dart';
import 'touchpad_gestures.dart';
import 'local/local_desktop.dart';
import '../l10n/l10n.dart';
import '../ui/app_density.dart';

class DesktopView extends StatefulWidget {
  const DesktopView({
    required this.session,
    super.key,
    this.onDetach,
    this.onOpenMonitorWindows,
    this.viewport,
    this.embeddedMenu = true,
  });
  final DesktopSession session;

  /// Move this session into its own window (provided by the hosting page).
  final VoidCallback? onDetach;

  /// Open one window per remote monitor (multi-monitor sessions only).
  final VoidCallback? onOpenMonitorWindows;

  /// Show only this rectangle of the remote desktop (a monitor window).
  final Rect? viewport;

  /// False when the host places [DesktopViewState.menuButton] elsewhere.
  /// Inside a workspace pane the menu sits in the actions of the pane's white
  /// handle on desktop platforms, so it never covers the remote screen; only
  /// a view without such a pane floats it over its top right corner.
  final bool embeddedMenu;
  @override
  State<DesktopView> createState() => DesktopViewState();
}

class DesktopViewState extends State<DesktopView> with WidgetsBindingObserver {
  final _mobile = GlobalKey<DesktopMobileControlsState>();
  bool _keyboardOpen = false;
  bool _pointerInside = false;
  late final DesktopTouchInput _touch;
  final _directTouch = DesktopDirectTouch();
  bool get _mobilePlatform =>
      Theme.of(context).platform == TargetPlatform.android ||
      Theme.of(context).platform == TargetPlatform.iOS;
  bool get _useLegacyWheel =>
      Theme.of(context).platform == TargetPlatform.android;
  void _sendMouse(Offset point, int buttons) {
    _buttons = buttons;
    session.display.movePointer(point);
    session.send(['mouse', point.dx.round(), point.dy.round(), buttons]);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _touch.reset();
      _directTouch.reset();
      _release();
    } else if (_focus.hasFocus) {
      // Back from another app (on Android "resumed" also means the window
      // has focus again, so the clipboard is readable): text copied there
      // goes to the remote desktop in front.
      _localClipboardMayHaveChanged();
    }
  }

  StreamSubscription<void>? _clipboardChanges;
  LocalClipboard? _clipboardSource;

  void _listenClipboard() {
    final source = session.deviceClipboard;
    if (identical(source, _clipboardSource)) return;
    unawaited(_clipboardChanges?.cancel());
    _clipboardSource = source;
    // Windows and Android notify us while the desktop is in front.
    _clipboardChanges = source.changes.listen((_) {
      if (_focus.hasFocus) _localClipboardMayHaveChanged();
    });
  }

  void _localClipboardMayHaveChanged() =>
      unawaited(session.clipboardSync.localMayHaveChanged());

  @override
  void didChangeMetrics() {
    if (mounted && _mobilePlatform) setState(() {});
  }

  final _focus = FocusNode();
  final Map<PhysicalKeyboardKey, int> _pressed = {};

  /// Full keyboard mapping: OS-reserved shortcuts swallowed by the runner
  /// while this view is the focus-rule target arrive as keysyms here.
  late final KeyboardCaptureTarget _capture;
  KeyboardCaptureSend _captureSend(DesktopSession receiver) => (sym, down) {
    receiver.send(['key', sym, down ? 1 : 0]);
    // Like [_key]: a released non-modifier consumes latched keybar modifiers.
    const modifiers = {
      0xffe1,
      0xffe2,
      0xffe3,
      0xffe4,
      0xffe9,
      0xffea,
      0xffeb,
      0xffec,
    };
    if (!down && !modifiers.contains(sym)) {
      _mobile.currentState?.consumeModifiers();
    }
  };

  /// Only a connected session takes the system shortcuts away from the OS.
  void _captureSessionChanged() =>
      _capture.update(enabled: session.state == 'connected');
  int _buttons = 0;
  Size? _lastSize;
  int _generation = -1;
  Offset _panLimit = Offset.zero;
  Size _panArea = Size.zero;

  Widget _panBar(Axis axis, {double bottomInset = 0}) {
    final horizontal = axis == Axis.horizontal;
    final limit = horizontal ? _panLimit.dx : _panLimit.dy;
    final extent = horizontal ? _panArea.width : _panArea.height;
    if (limit <= 0 || extent <= 0) {
      // Must stay positioned: a non-positioned child would size the Stack.
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }
    final thumb = math.max(32.0, extent * extent / (extent + limit));
    final position =
        (horizontal ? _pan.dx : _pan.dy) / limit * (extent - thumb);
    final color = Theme.of(context).colorScheme.onSurface
        .withValues(alpha: 0.45);
    return Positioned(
      left: horizontal ? position : null,
      top: horizontal ? null : position,
      right: horizontal ? null : 2,
      bottom: horizontal ? 2 + bottomInset : null,
      child: GestureDetector(
        key: ValueKey('desktop_pan_${axis.name}'),
        onPanUpdate: (d) => setState(() {
          final delta =
              (horizontal ? d.delta.dx : d.delta.dy) /
              math.max(1, extent - thumb) *
              limit;
          _pan += horizontal ? Offset(delta, 0) : Offset(0, delta);
        }),
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Container(
            width: horizontal ? thumb : 8,
            height: horizontal ? 8 : thumb,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
    );
  }

  Offset _pan = Offset.zero;

  // Temporary translation of the painted desktop, in local logical pixels.
  // The normal actual-size scroll position is restored when the IME closes.
  Offset _keyboardPan = Offset.zero;
  Rect _keyboardPanBounds = Rect.zero;

  Rect _keyboardTravel(
    Rect picture,
    Size area,
    double covered, {
    required bool fourWay,
  }) {
    final visible = Size(area.width, math.max(0.0, area.height - covered));
    final hiddenBottom = math.max(0.0, picture.bottom - visible.height);
    if (!fourWay) {
      return Rect.fromLTRB(0, -math.min(hiddenBottom, covered), 0, 0);
    }

    // An oversized desktop can travel edge to edge. A fitted desktop can
    // also move sideways (e.g. around a floating IME); keep its centre in
    // the pane so the picture can always be brought back.
    final wide = picture.width - visible.width > precisionErrorTolerance;
    final left = wide ? visible.width - picture.right : -picture.center.dx;
    final right = wide ? -picture.left : visible.width - picture.center.dx;
    final hiddenTop = math.max(0.0, -picture.top);
    if (hiddenBottom > precisionErrorTolerance ||
        hiddenTop > precisionErrorTolerance) {
      return Rect.fromLTRB(left, -hiddenBottom, right, hiddenTop);
    }
    return Rect.fromLTRB(
      left,
      -picture.center.dy,
      right,
      visible.height - picture.center.dy,
    );
  }

  Offset _clampKeyboardPan(Offset pan, Rect bounds) => Offset(
    pan.dx.clamp(bounds.left, bounds.right),
    pan.dy.clamp(bounds.top, bounds.bottom),
  );

  void _slideUnderKeyboard(Offset delta) {
    final next = _clampKeyboardPan(_keyboardPan + delta, _keyboardPanBounds);
    if (next != _keyboardPan) setState(() => _keyboardPan = next);
  }

  Widget _keyboardPanHandle({required bool fourWay}) {
    final colors = Theme.of(context).colorScheme;
    final bounds = _keyboardPanBounds;
    final stepY = math.max(24.0, bounds.height / 4);
    final stepX = math.max(24.0, bounds.width / 4);
    String percent(double y) => bounds.height <= 0
        ? '0%'
        : '${((bounds.bottom - y.clamp(bounds.top, bounds.bottom)) / bounds.height * 100).round()}%';
    return Semantics(
      slider: true,
      label: context.l10n.desktopKeyboardPan,
      value: percent(_keyboardPan.dy),
      increasedValue: percent(_keyboardPan.dy - stepY),
      decreasedValue: percent(_keyboardPan.dy + stepY),
      onIncrease: () => _slideUnderKeyboard(Offset(0, -stepY)),
      onDecrease: () => _slideUnderKeyboard(Offset(0, stepY)),
      onScrollLeft: fourWay
          ? () => _slideUnderKeyboard(Offset(-stepX, 0))
          : null,
      onScrollRight: fourWay
          ? () => _slideUnderKeyboard(Offset(stepX, 0))
          : null,
      child: GestureDetector(
        key: const ValueKey('desktop_keyboard_pan'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        dragStartBehavior: DragStartBehavior.down,
        onPanUpdate: fourWay
            ? (details) => _slideUnderKeyboard(details.delta)
            : null,
        onVerticalDragUpdate: fourWay
            ? null
            : (details) => _slideUnderKeyboard(Offset(0, details.delta.dy)),
        child: Material(
          color: colors.surfaceContainerHigh.withValues(alpha: 0.86),
          shape: const StadiumBorder(),
          elevation: 2,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(
              fourWay ? Icons.open_with : Icons.swap_vert,
              color: colors.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Timer? _resizeTimer;
  DialogRoute<void>? _certificateDialog;
  DesktopSession get session => widget.session;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _touch = DesktopTouchInput(
      pointer: () => session.display.pointer,
      send: _sendMouse,
    );
    _focus.addListener(_focusChanged);
    _capture = KeyboardCaptureController.instance.register(
      _captureSend(session),
      onMenuShortcut: () {
        _release();
        _openMenu();
      },
    );
    session.addListener(_captureSessionChanged);
    _captureSessionChanged();
    // Windows: three- and four-finger touchpad gestures for the desktop
    // under the pointer (they never reach Flutter).
    TouchpadGestureController.instance.attach();
    TouchpadGestureController.instance.usedLocally.addListener(
      _touchpadGestureUsedLocally,
    );
    session.onNotice = _showNotice;
    session.onFilesSaved = _filesSaved;
    session.addListener(_certificateChanged);
    _certificateChanged();
    _listenClipboard();
  }

  void _filesSaved(List<String> paths) {
    final copied = writeClipboardFilePaths(paths);
    _showNotice(
      copied
          ? context.l10n.savedCountItemsAndPlacedThem(paths.length)
          : context.l10n.savedCountItems(paths.length),
    );
  }

  Future<void> _sendCopiedFiles() async {
    final paths = readClipboardFilePaths();
    if (paths.isEmpty) {
      _showNotice(context.l10n.thereAreNoCopiedFilesOn);
      return;
    }
    session.offerLocalFiles(paths);
  }

  Future<void> _pickFilesToSend() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final paths = [
      for (final file in result?.files ?? const <PlatformFile>[])
        if (file.path != null) file.path!,
    ];
    if (paths.isNotEmpty && mounted) session.offerLocalFiles(paths);
  }

  Future<void> _saveRemoteFiles() async {
    final source = session;
    try {
      final folder = await pickLocalRdpFolder(
        context.l10n.saveRemoteClipboardFiles,
      );
      if (folder != null && mounted && identical(session, source)) {
        source.saveRemoteFiles(folder);
      }
    } on RdpStorageException catch (error) {
      _showNotice(error.message);
    } on PlatformException {
      if (mounted) _showNotice(context.l10n.rdpStoragePickerFailed);
    }
  }

  void _certificateChanged() {
    if (!mounted ||
        session.certificateRequest == null ||
        _certificateDialog != null)
      return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _certificateDialog != null) return;
      final reviewedSession = session;
      final request = reviewedSession.certificateRequest;
      if (request == null) return;
      final navigator = Navigator.of(context, rootNavigator: true);
      final route = AppDialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AnimatedBuilder(
          animation: reviewedSession,
          // The live dialog context shadows State.context: the owner can be
          // deactivated (pane closed) while this route is still animating out.
          builder: (context, _) => PopScope(
            canPop: !reviewedSession.savingCertificate,
            child: AlertDialog(
              key: const ValueKey('rdp_certificate_dialog'),
              title: Text(
                request.changed
                    ? context.l10n.rdpCertificateFingerprintChanged
                    : context.l10n.trustThisRdpCertificate,
              ),
              content: SizedBox(
                width: appDialogWidth(context, 520),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${request.host.address}:${request.host.port}'),
                      const SizedBox(height: 12),
                      Text(
                        request.changed
                            ? context.l10n.theServerCertificateDiffersFromThe
                            : context.l10n.thisCertificateIsntTrustedYetVerify,
                      ),
                      if (request.changed) ...[
                        const SizedBox(height: 16),
                        Text(context.l10n.savedSha256),
                        SelectableText(request.host.rdpCertificateSha256!),
                      ],
                      const SizedBox(height: 16),
                      Text(context.l10n.currentCertificateSha256),
                      SelectableText(request.sha256),
                      if (reviewedSession.error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          reviewedSession.error!,
                          style: TextStyle(
                            color: Theme.of(dialogContext).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: reviewedSession.savingCertificate
                      ? null
                      : () {
                          reviewedSession.rejectCertificate(request);
                          Navigator.of(dialogContext).pop();
                        },
                  child: Text(context.l10n.cancel),
                ),
                FilledButton(
                  key: const ValueKey('rdp_certificate_accept'),
                  onPressed: reviewedSession.savingCertificate
                      ? null
                      : () async {
                          final accepted = await reviewedSession
                              .trustCertificate(request);
                          if (accepted && dialogContext.mounted)
                            Navigator.of(dialogContext).pop();
                        },
                  child: Text(
                    reviewedSession.savingCertificate
                        ? context.l10n.saving
                        : request.changed
                        ? context.l10n.updateAndConnect
                        : context.l10n.trustAndSave,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      _certificateDialog = route;
      unawaited(
        navigator.push(route).whenComplete(() {
          if (identical(_certificateDialog, route)) _certificateDialog = null;
          if (!mounted) return;
          reviewedSession.rejectCertificate(request);
          _certificateChanged();
        }),
      );
    });
  }

  void _removeCertificateDialog() {
    final route = _certificateDialog;
    _certificateDialog = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
  }

  /// Shown once per run: the hint stays long enough to be read after the
  /// local gesture (task view, app switching) has run its course.
  static bool _touchpadHintShown = false;
  void _touchpadGestureUsedLocally() {
    if (_touchpadHintShown || !mounted || session.state != 'connected') return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    _touchpadHintShown = true;
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 12),
        content: Text(context.l10n.touchpadGestureUsedByWindows),
      ),
    );
  }

  void _showNotice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void didUpdateWidget(covariant DesktopView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.embeddedMenu != widget.embeddedMenu) _syncPaneSlot();
    if (!identical(oldWidget.session, session)) {
      _directTouch.reset();
      _mobile.currentState?.releaseInput(notify: false);
      _keyboardOpen = false;
      DesktopKeyboardController.instance.keyboardVisible(this, false);
      _release(oldWidget.session);
      _capture.retarget(_captureSend(session));
      oldWidget.session.removeListener(_captureSessionChanged);
      session.addListener(_captureSessionChanged);
      _captureSessionChanged();
      oldWidget.session.removeListener(_certificateChanged);
      _removeCertificateDialog();
      if (oldWidget.session.onNotice == _showNotice)
        oldWidget.session.onNotice = null;
      if (oldWidget.session.onFilesSaved == _filesSaved) {
        oldWidget.session.onFilesSaved = null;
      }
      session.onNotice = _showNotice;
      session.onFilesSaved = _filesSaved;
      session.addListener(_certificateChanged);
      _certificateChanged();
      _listenClipboard();
      if (_focus.hasFocus) _localClipboardMayHaveChanged();
    }
  }

  void _focusAfterActivation() {
    _focus.requestFocus();
    // Pane selection removes ExcludeFocus on the next build. A single click
    // must focus the newly active desktop after that update has completed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _focusChanged() {
    _capture.update(focused: _focus.hasFocus);
    if (_focus.hasFocus) {
      // Coming back to this desktop (another tab, pane or window, or a
      // closed menu): offer what was copied meanwhile.
      _localClipboardMayHaveChanged();
    } else {
      DesktopKeyboardController.instance.keyboardVisible(
        this,
        false,
        focus: _focus,
      );
      _touch.reset();
      _directTouch.reset();
      _release();
    }
  }

  // Touchpad gestures and the high-resolution wheel of desktop platforms and
  // the web. Android and iOS never get here: their touch input has its own
  // scrolling and a wheel there keeps sending single notches.
  final _wheel = DesktopWheelAccumulator();
  final _touchpad = DesktopTouchpadGesture();

  /// Wheel units went out since the last end-of-gesture marker.
  bool _wheelOpen = false;

  /// Left Ctrl is held down remotely by this view for a touchpad pinch.
  bool _pinchControl = false;
  static const _controlLeft = 0xffe3, _controlRight = 0xffe4;

  /// Releases that Ctrl when a pinch stops zooming without ending (fingers
  /// resting, or a system that never reports the end); the next zoom step
  /// presses it again.
  Timer? _pinchIdle;
  static const _pinchIdleAfter = Duration(seconds: 1);

  DesktopWheelScale _wheelScale() => DesktopWheelScale.of(
    platform: Theme.of(context).platform,
    web: kIsWeb,
    devicePixelRatio: View.of(context).devicePixelRatio,
    windowsScrollLines: systemWheelScrollLines,
  );

  /// Diagonal of the window in logical pixels: how far from the window's
  /// corner the fixed point of a touchpad zoom can be.
  double _windowDiagonal() {
    final view = View.of(context);
    final ratio = view.devicePixelRatio;
    if (!ratio.isFinite || ratio <= 0) return 0;
    final size = view.physicalSize / ratio;
    return Offset(size.width, size.height).distance;
  }

  /// Turns the remote wheel at [point] by fractional wheel [units] (x, y).
  /// Whole units are sent; the rest waits for the next event.
  void _turnWheel(Offset point, (double, double) units) {
    final whole = _wheel.add(units.$1, units.$2);
    if (whole == null) return;
    _wheelOpen = true;
    session.display.movePointer(point);
    session.send([
      'wheel',
      point.dx.round(),
      point.dy.round(),
      whole.$1,
      whole.$2,
    ]);
  }

  /// Zooms by [steps] the way Windows reports a touchpad pinch to
  /// applications: Ctrl held with one vertical wheel notch per step. With
  /// [hold] Ctrl stays down until [_endWheel] (the end of the gesture, or
  /// anything that releases input) or until the pinch has rested for
  /// [_pinchIdleAfter]; otherwise it is released at once.
  void _zoom(Offset point, int steps, {required bool hold}) {
    if (steps == 0) return;
    // A Ctrl the user holds already does the job and is theirs to release.
    if (!_pinchControl &&
        !_pressed.containsValue(_controlLeft) &&
        !_pressed.containsValue(_controlRight)) {
      session.send(['key', _controlLeft, 1]);
      _pinchControl = true;
    }
    session.display.movePointer(point);
    session.send([
      'wheel',
      point.dx.round(),
      point.dy.round(),
      0,
      steps.clamp(-32, 32).toInt() * DesktopWheelUnits.notch,
    ]);
    if (!hold) {
      _releasePinchControl(session);
    } else if (_pinchControl) {
      _pinchIdle?.cancel();
      _pinchIdle = Timer(_pinchIdleAfter, () {
        if (mounted) _releasePinchControl(session);
      });
    }
  }

  void _releasePinchControl(DesktopSession receiver) {
    _pinchIdle?.cancel();
    _pinchIdle = null;
    if (!_pinchControl) return;
    _pinchControl = false;
    // Left Ctrl pressed by the user during the pinch stays down until they
    // release it.
    if (_pressed.containsValue(_controlLeft)) return;
    receiver.send(['key', _controlLeft, 0]);
  }

  /// Ends the touchpad gesture and the wheel run: releases the Ctrl of a
  /// pinch, forgets fractional units and tells notch-counting transports to
  /// forget theirs. Later updates of the same gesture do nothing.
  void _endWheel(DesktopSession receiver) {
    _touchpad.end();
    _wheel.reset();
    _releasePinchControl(receiver);
    if (!_wheelOpen) return;
    _wheelOpen = false;
    receiver.send([
      'wheel',
      receiver.display.pointer.dx.round(),
      receiver.display.pointer.dy.round(),
      0,
      0,
    ]);
  }

  void _release([DesktopSession? target]) {
    final receiver = target ?? session;
    _endWheel(receiver);
    for (final key in _pressed.values) {
      receiver.send(['key', key, 0]);
    }
    _pressed.clear();
    _buttons = 0;
    receiver.send([
      'mouse',
      receiver.display.pointer.dx.round(),
      receiver.display.pointer.dy.round(),
      0,
    ]);
  }

  @override
  void dispose() {
    DesktopKeyboardController.instance.keyboardVisible(this, false);
    session.removeListener(_captureSessionChanged);
    TouchpadGestureController.instance.usedLocally.removeListener(
      _touchpadGestureUsedLocally,
    );
    session.removeListener(_certificateChanged);
    _removeCertificateDialog();
    if (session.onNotice == _showNotice) session.onNotice = null;
    if (session.onFilesSaved == _filesSaved) session.onFilesSaved = null;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_clipboardChanges?.cancel());
    _directTouch.reset();
    _touch.dispose();
    _capture.unregister();
    _paneSlot?.detach(this);
    _paneSlot = null;
    _release();
    _resizeTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  final _menu = GlobalKey<PopupMenuButtonState<String>>();

  /// The hosting pane's handle actions, when the menu lives there.
  SessionPaneActionSlot? _paneSlot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPaneSlot();
  }

  void _syncPaneSlot() {
    final slot = widget.embeddedMenu && !_mobilePlatform
        ? SessionPaneActionSlot.maybeOf(context)
        : null;
    if (identical(slot, _paneSlot)) return;
    _paneSlot?.detach(this);
    _paneSlot = slot;
    slot?.attach(this, (_) => menuButton(inPaneActions: true));
  }

  /// Opens the session menu from the keyboard. In a pane the handle actions
  /// are shown first, since the menu button is one of them.
  void _openMenu() {
    final slot = _paneSlot;
    if (slot == null) {
      _menu.currentState?.showButtonMenu();
      return;
    }
    slot.hold();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final button = _menu.currentState;
      if (button == null) {
        slot.release();
      } else {
        button.showButtonMenu();
      }
    });
  }

  /// Ctrl+Alt+Home is kept local (as in the Windows Remote Desktop client) so
  /// the session menu is reachable from the keyboard while every other key
  /// goes to the remote computer.
  bool _isMenuShortcut(KeyEvent event) {
    final keys = HardwareKeyboard.instance;
    return event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.home &&
        keys.isControlPressed &&
        keys.isAltPressed;
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (_isMenuShortcut(event)) {
      // Release the modifiers already sent so the remote does not see them
      // held while the local menu is open.
      _release();
      _openMenu();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.home &&
        event is! KeyUpEvent &&
        HardwareKeyboard.instance.isControlPressed &&
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.handled; // repeat of the menu shortcut
    }
    final held = _pressed[event.physicalKey];
    if (event is KeyRepeatEvent && held != null) {
      // Auto-repeat keeps the keysym of the original press whatever the
      // modifiers are now, so the release always matches it remotely. The
      // Delete sent for Ctrl+Alt+End is never repeated.
      if (held != 0xffff || event.logicalKey != LogicalKeyboardKey.end) {
        session.send(['key', held, 1]);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.end &&
        event is! KeyUpEvent &&
        _capture.controlAndAltHeld) {
      // Ctrl+Alt+Delete cannot be captured on Windows: Ctrl+Alt+End sends
      // Delete while Ctrl+Alt stay held remotely (mstsc convention). The
      // End release then releases Delete.
      if (event is KeyDownEvent) {
        _pressed[event.physicalKey] = 0xffff;
        session.send(['key', 0xffff, 1]);
      }
      return KeyEventResult.handled;
    }
    final mapped = desktopKeysym(event);
    if (event is KeyUpEvent) {
      final sym = _pressed.remove(event.physicalKey);
      if (sym != null) {
        session.send(['key', sym, 0]);
        if (!const {
          0xffe1,
          0xffe2,
          0xffe3,
          0xffe4,
          0xffe9,
          0xffea,
          0xffeb,
          0xffec,
        }.contains(sym)) {
          _mobile.currentState?.consumeModifiers();
        }
      }
    } else if (mapped != null) {
      _pressed[event.physicalKey] = mapped;
      session.send(['key', mapped, 1]);
    }
    return mapped == null ? KeyEventResult.ignored : KeyEventResult.handled;
  }

  void _resize(Size size) {
    // Monitor windows show a fixed region; fixed or server-chosen sizes are
    // never replaced by the widget bounds.
    if (session.state != 'connected' ||
        widget.viewport != null ||
        !session.followsWindowSize) {
      return;
    }
    // A minimized window has no area (Windows reports an empty view), which
    // is not a size the user chose: the remote keeps its resolution, and the
    // restored window asks for nothing when it comes back unchanged.
    if (size.isEmpty || View.of(context).physicalSize.isEmpty) return;
    if (_generation != session.displayGeneration) {
      _generation = session.displayGeneration;
      _lastSize = null;
    }
    final requested = Size(
      size.width.clamp(320, 4096).floorToDouble(),
      size.height.clamp(200, 4096).floorToDouble(),
    );
    if (_lastSize == requested) return;
    _lastSize = requested;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(
      const Duration(milliseconds: 250),
      () => session.send([
        'size',
        requested.width.toInt(),
        requested.height.toInt(),
      ]),
    );
  }

  /// The session menu. A workspace pane shows it in its handle actions
  /// ([inPaneActions]), a child window in its caption row (one navigation
  /// row); only a view without either floats it over the desktop corner.
  Widget menuButton({bool inPaneActions = false}) {
    return PopupMenuButton<String>(
      popUpAnimationStyle: AppMotion.menuStyle(context),
      key: _menu,
      tooltip: context.l10n.remoteDesktopMenu,
      // The pane's own overflow menu already uses the three dots.
      icon: inPaneActions
          ? Icon(Icons.desktop_windows_outlined, size: appMenuIconSize(context))
          : const Icon(Icons.more_horiz),
      padding: inPaneActions ? EdgeInsets.zero : const EdgeInsets.all(8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      // The pane hides its actions when the pointer leaves; they must stay
      // while this menu is open, or its choice would have no receiver.
      onCanceled: () => _paneSlot?.release(),
      onSelected: (value) async {
        _paneSlot?.release();
        if (value == 'fullscreen') {
          await toggleAppFullscreen(context);
        } else if (value == 'cad') {
          for (final key in [65507, 65513, 65535]) {
            session.send(['key', key, 1]);
          }
          for (final key in [65535, 65513, 65507]) {
            session.send(['key', key, 0]);
          }
        } else if (value == 'paste') {
          // Explains an empty or refused clipboard instead of doing nothing.
          final text = await readClipboardForPaste(
            context,
            maxBytes: desktopClipboardMaxBytes,
            clipboard: session.deviceClipboard,
          );
          if (!mounted || text == null) return;
          try {
            session.paste(text);
          } catch (error) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  error is FormatException
                      ? error.message
                      : context.l10n.couldntSendClipboardText,
                ),
              ),
            );
          }
        } else if (value == 'copy') {
          final text = session.display.clipboard;
          if (text.isEmpty) {
            _showNotice(context.l10n.desktopRemoteClipboardEmpty);
          } else {
            final receiver = session;
            final result = await receiver.deviceClipboard.writeText(text);
            if (result.written) {
              receiver.clipboardSync.copiedLocally(text, stamp: result.stamp);
            } else if (mounted) {
              _showNotice(context.l10n.desktopClipboardWriteFailed);
            }
          }
        } else if (value == 'send_copied_files') {
          await _sendCopiedFiles();
        } else if (value == 'send_files') {
          await _pickFilesToSend();
        } else if (value == 'save_files') {
          await _saveRemoteFiles();
        } else if (value == 'display') {
          if (mounted) await showDesktopResolutionDialog(context, session);
        } else if (value == 'detach') {
          widget.onDetach?.call();
        } else if (value == 'monitors') {
          widget.onOpenMonitorWindows?.call();
        }
        if (mounted) _focus.requestFocus();
      },
      onOpened: () {
        _paneSlot?.hold();
        unawaited(FullscreenController.instance.refresh());
      },
      itemBuilder: (_) => [
        if (FullscreenController.instance.supported)
          appMenuItem(
            context,
            key: const ValueKey('desktop_fullscreen_menu'),
            value: 'fullscreen',
            enabled: !FullscreenController.instance.busy,
            child: Text(
              FullscreenController.instance.enabled
                  ? context.l10n.exitFullscreen
                  : context.l10n.enterFullscreen,
            ),
          ),
        appMenuItem(
          context,
          value: 'cad',
          enabled: session.state == 'connected',
          child: Text(context.l10n.sendCtrlAltDelete),
        ),
        const PopupMenuDivider(height: 8),
        appMenuItem(
          context,
          value: 'paste',
          enabled: session.state == 'connected',
          child: Text(context.l10n.pasteLocalClipboardText),
        ),
        appMenuItem(
          context,
          value: 'copy',
          child: Text(context.l10n.copyRemoteClipboardText),
        ),
        if (session.protocol != null) const PopupMenuDivider(height: 8),
        if (session.protocol != null)
          appMenuItem(
            context,
            key: const ValueKey('desktop_display_menu'),
            value: 'display',
            enabled: session.state == 'connected',
            child: Text(context.l10n.resolutionAndScaling2),
          ),
        if (session.fileClipboardEnabled) ...[
          const PopupMenuDivider(height: 8),
          if (supportsFileClipboardInterop)
            appMenuItem(
              context,
              value: 'send_copied_files',
              enabled: session.state == 'connected',
              child: Text(context.l10n.sendLocallyCopiedFiles),
            ),
          appMenuItem(
            context,
            value: 'send_files',
            enabled: session.state == 'connected',
            child: Text(context.l10n.chooseFilesForTheRemoteClipboard),
          ),
          appMenuItem(
            context,
            key: const ValueKey('rdp_save_remote_files'),
            value: 'save_files',
            enabled:
                session.state == 'connected' &&
                session.remoteFiles != null &&
                session.transfer == null,
            child: Text(
              session.remoteFiles == null
                  ? context.l10n.saveRemoteClipboardFiles2
                  : context.l10n.saveRemoteClipboardFilesFilecountFiles(
                      session.remoteFiles!.fileCount,
                      formatTransferBytes(session.remoteFiles!.totalBytes),
                    ),
            ),
          ),
        ],
        if (widget.onDetach != null || widget.onOpenMonitorWindows != null)
          const PopupMenuDivider(height: 8),
        if (widget.onDetach != null)
          appMenuItem(
            context,
            value: 'detach',
            child: Text(context.l10n.openInNewWindow),
          ),
        if (widget.onOpenMonitorWindows != null &&
            (session.rdpConfig?.monitors.length ?? 0) > 1)
          appMenuItem(
            context,
            value: 'monitors',
            child: Text(context.l10n.oneWindowPerMonitor),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, pane) {
      return AnimatedBuilder(
        animation: Listenable.merge([
          session,
          session.display,
          FullscreenController.instance,
          DesktopKeyboardController.instance,
        ]),
        builder: (context, _) {
          final overlay =
              _mobilePlatform &&
              DesktopKeyboardController.instance.mode ==
                  DesktopKeyboardMode.overlay;
          final keyboardOverlay = overlay && _keyboardOpen;
          final fourWay = Theme.of(context).platform == TargetPlatform.android;
          final view = View.of(context);
          final box = context.findRenderObject() as RenderBox?;
          final top = box != null && box.hasSize
              ? box.localToGlobal(Offset.zero).dy
              : 0.0;
          final keyboardTop =
              (view.physicalSize.height - view.viewInsets.bottom) /
              view.devicePixelRatio;
          final overlap = keyboardOverlay
              ? (top + pane.maxHeight - keyboardTop).clamp(0.0, pane.maxHeight)
              : 0.0;
          final visibleHeight = math.max(0.0, pane.maxHeight - overlap);
          final keybarHeight = _mobilePlatform && _keyboardOpen
              ? (visibleHeight >= 280 ? 96.0 : 48.0)
              : 0.0;
          final panInKeybar =
              keyboardOverlay && fourWay && visibleHeight - keybarHeight < 56;
          return Stack(
            children: [
              Positioned.fill(
                bottom: overlay ? 0 : keybarHeight,
                child: LayoutBuilder(
                  key: const ValueKey('desktop_remote_surface'),
                  builder: (context, constraints) {
                    final area = constraints.biggest;
                    _resize(area);
                    final viewport = widget.viewport;
                    final origin = viewport?.topLeft ?? Offset.zero;
                    final size = viewport?.size ?? session.display.size;
                    final actual =
                        viewport == null &&
                        session.localScaling == DesktopLocalScaling.actualSize;
                    final double scale = actual
                        ? 1.0
                        : math.min(
                            area.width / math.max(1, size.width),
                            area.height / math.max(1, size.height),
                          );
                    final maxPan = Offset(
                      math.max(0, size.width - area.width),
                      math.max(0, size.height - area.height),
                    );
                    _pan = actual
                        ? Offset(
                            _pan.dx.clamp(0, maxPan.dx),
                            _pan.dy.clamp(0, maxPan.dy),
                          )
                        : Offset.zero;
                    final placed = actual
                        ? Offset(
                            maxPan.dx > 0
                                ? -_pan.dx
                                : (area.width - size.width) / 2,
                            maxPan.dy > 0
                                ? -_pan.dy
                                : (area.height - size.height) / 2,
                          )
                        : Offset(
                            (area.width - size.width * scale) / 2,
                            (area.height - size.height * scale) / 2,
                          );
                    final bounds = keyboardOverlay
                        ? _keyboardTravel(
                            placed & (size * scale),
                            area,
                            overlap + keybarHeight,
                            fourWay: fourWay,
                          )
                        : Rect.zero;
                    _keyboardPan = _clampKeyboardPan(_keyboardPan, bounds);
                    final offset = placed + _keyboardPan;
                    // Where a point of this surface lies on the remote
                    // desktop.
                    Offset remote(Offset local) =>
                        origin +
                        Offset(
                          ((local.dx - offset.dx) / scale).clamp(
                            0,
                            math.max(0, size.width - 1),
                          ),
                          ((local.dy - offset.dy) / scale).clamp(
                            0,
                            math.max(0, size.height - 1),
                          ),
                        );
                    void mouse(PointerEvent event, {int? wheel}) {
                      if (_mobilePlatform &&
                          _touch.trackpad &&
                          event.kind == PointerDeviceKind.touch) {
                        if (event is PointerDownEvent) _focusAfterActivation();
                        _touch.handle(
                          event,
                          bounds: origin & size,
                          scale: scale,
                        );
                        return;
                      }
                      final point = remote(event.localPosition);
                      if (_mobilePlatform &&
                          event.kind == PointerDeviceKind.touch) {
                        if (event is PointerDownEvent) _focusAfterActivation();
                        final receiver = session;
                        _directTouch.handle(
                          event,
                          remotePoint: point,
                          nativeTouch: receiver.nativeTouch,
                          sendNative: (id, phase, point) => receiver.send([
                            'touch',
                            id,
                            phase,
                            point.dx.round(),
                            point.dy.round(),
                          ]),
                          sendMouse: (point, buttons) {
                            receiver.display.movePointer(point);
                            receiver.send([
                              'mouse',
                              point.dx.round(),
                              point.dy.round(),
                              buttons,
                            ]);
                          },
                        );
                        return;
                      }
                      if (event is PointerDownEvent) _focusAfterActivation();
                      _buttons =
                          (event.buttons & kPrimaryButton != 0 ? 1 : 0) |
                          (event.buttons & kSecondaryButton != 0 ? 4 : 0) |
                          (event.buttons & kMiddleMouseButton != 0 ? 2 : 0);
                      session.display.movePointer(point);
                      session.send([
                        'mouse',
                        point.dx.round(),
                        point.dy.round(),
                        _buttons | (wheel ?? 0),
                      ]);
                      if (wheel != null)
                        session.send([
                          'mouse',
                          point.dx.round(),
                          point.dy.round(),
                          _buttons,
                        ]);
                    }

                    final limit = actual ? maxPan : Offset.zero;
                    if (limit != _panLimit ||
                        area != _panArea ||
                        bounds != _keyboardPanBounds) {
                      // Pan bars and the slide handle live outside this
                      // LayoutBuilder; refresh them once layout has produced
                      // the new bounds.
                      _panLimit = limit;
                      _panArea = area;
                      _keyboardPanBounds = bounds;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) setState(() {});
                      });
                    }
                    return Focus(
                      focusNode: _focus,
                      autofocus: true,
                      onKeyEvent: _key,
                      child: MouseRegion(
                        cursor: SystemMouseCursors.none,
                        onEnter: (_) {
                          _capture.update(hovered: true);
                          setState(() => _pointerInside = true);
                        },
                        onExit: (_) {
                          _capture.update(hovered: false);
                          _endWheel(session);
                          setState(() => _pointerInside = false);
                        },
                        child: Listener(
                          onPointerDown: mouse,
                          onPointerUp: mouse,
                          onPointerMove: mouse,
                          onPointerHover: mouse,
                          onPointerCancel: (_) {
                            _touch.reset();
                            _directTouch.reset();
                            _release();
                          },
                          onPointerSignal: (e) {
                            final signals =
                                GestureBinding.instance.pointerSignalResolver;
                            if (e is PointerScrollEvent) {
                              signals.register(e, (_) {
                                if (_useLegacyWheel) {
                                  // Android's discrete wheel events use one
                                  // vertical notch per event.
                                  mouse(
                                    e,
                                    wheel: e.scrollDelta.dy < 0 ? 8 : 16,
                                  );
                                  return;
                                }
                                // Wheels, tilt wheels and touchpads without
                                // gesture events: as far as the device said,
                                // on both axes.
                                _turnWheel(
                                  remote(e.localPosition),
                                  _wheelScale().ofScroll(
                                    e.scrollDelta,
                                    wheelClick:
                                        e.kind == PointerDeviceKind.mouse,
                                  ),
                                );
                              });
                            } else if (e is PointerScaleEvent &&
                                !_useLegacyWheel) {
                              // iPadOS and browsers can deliver scale signals
                              // without a corresponding end event.
                              signals.register(
                                e,
                                (_) => _zoom(
                                  remote(e.localPosition),
                                  _touchpad.scaleSignal(e.scale),
                                  hold: false,
                                ),
                              );
                            }
                          },
                          // Touchpad gestures (Windows precision touchpads,
                          // Apple and Linux touchpads): two fingers scroll,
                          // a pinch zooms. Taps and pointer movement arrive
                          // as mouse events above.
                          onPointerPanZoomStart: (_) {
                            if (_useLegacyWheel) return;
                            _endWheel(session);
                            _touchpad.start();
                          },
                          onPointerPanZoomUpdate: (e) {
                            if (_useLegacyWheel) return;
                            final step = _touchpad.update(
                              e.pan,
                              e.scale,
                              reach: _windowDiagonal(),
                            );
                            final point = remote(e.localPosition);
                            if (step.pan != Offset.zero) {
                              _turnWheel(point, _wheelScale().ofPan(step.pan));
                            }
                            _zoom(point, step.zoom, hold: true);
                          },
                          onPointerPanZoomEnd: (_) {
                            if (!_useLegacyWheel) _endWheel(session);
                          },
                          child: ClipRect(
                            child: CustomPaint(
                              size: area,
                              painter: _DesktopPainter(
                                session.display,
                                scale,
                                offset - origin * scale,
                                showCursor: _touch.trackpad || _pointerInside,
                                clip: viewport == null
                                    ? null
                                    : offset & (size * scale),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              _panBar(Axis.horizontal, bottomInset: keybarHeight),
              _panBar(Axis.vertical),
              if (session.error != null && session.certificateRequest == null)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            context.l10n.connectionLost,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            session.error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          if (session.state == 'disconnected' &&
                              session.canReconnect) ...[
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              key: const ValueKey('desktop_restore_connection'),
                              // The session resolves the Host saved now
                              // (DesktopSession.latestHost), not the one it
                              // was first opened with.
                              onPressed: () => session.reconnect(),
                              icon: const Icon(Icons.refresh),
                              label: Text(context.l10n.restoreConnection),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              if (session.state == 'connecting')
                const Center(child: CircularProgressIndicator()),
              if (session.transfer != null)
                Positioned(
                  left: 12,
                  right: 56,
                  top: 8,
                  child: Material(
                    key: const ValueKey('rdp_file_transfer'),
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.l10n.savingRemoteFilesDoneTotal(
                                    session.transfer!.done,
                                    session.transfer!.total,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                LinearProgressIndicator(
                                  value: session.transfer!.total == 0
                                      ? null
                                      : session.transfer!.done /
                                            session.transfer!.total,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: context.l10n.cancel,
                            icon: const Icon(Icons.close),
                            onPressed: session.cancelFileTransfer,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_mobilePlatform)
                Positioned.fill(
                  bottom: overlap,
                  child: DesktopMobileControls(
                    key: _mobile,
                    focus: _focus,
                    unicodeText: session.protocol != HostProtocol.vnc,
                    onActivate: _focusAfterActivation,
                    send: session.send,
                    connected: session.state == 'connected',
                    trackpad: _touch.trackpad,
                    keybarHeight: keybarHeight,
                    panHandle: panInKeybar
                        ? _keyboardPanHandle(fourWay: true)
                        : null,
                    menu: widget.embeddedMenu ? menuButton() : null,
                    onKeyboardChanged: (value) {
                      DesktopKeyboardController.instance.keyboardVisible(
                        this,
                        value,
                        focus: _focus,
                      );
                      if (mounted && _keyboardOpen != value)
                        setState(() => _keyboardOpen = value);
                    },
                    onTogglePointer: () {
                      _focusAfterActivation();
                      _touch.reset();
                      _directTouch.reset();
                      _release();
                      setState(() => _touch.trackpad = !_touch.trackpad);
                      if (_touch.trackpad &&
                          session.display.pointer == Offset.zero) {
                        _sendMouse(session.display.size.center(Offset.zero), 0);
                      }
                    },
                  ),
                ),
              if (keyboardOverlay &&
                  !panInKeybar &&
                  (fourWay || _keyboardPanBounds.height > 0))
                Positioned(
                  key: const ValueKey('desktop_keyboard_pan_slot'),
                  // Keep the grip clear of IME preedit text and the edge dock.
                  right: fourWay
                      ? math.min(56.0, math.max(0.0, pane.maxWidth - 48))
                      : 8,
                  bottom: overlap + keybarHeight + 8,
                  child: _keyboardPanHandle(fourWay: fourWay),
                ),
              if (widget.embeddedMenu && !_mobilePlatform && _paneSlot == null)
                Positioned(
                  top: 4,
                  right: 4,
                  // A translucent backing keeps the control visible over any remote
                  // content (light or dark desktops).
                  child: Material(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh
                        .withValues(alpha: 0.78),
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: menuButton(),
                  ),
                ),
            ],
          );
        },
      );
    },
  );
}

class _DesktopPainter extends CustomPainter {
  _DesktopPainter(
    this.display,
    this.scale,
    this.offset, {
    this.clip,
    required this.showCursor,
  }) : super(repaint: display);
  final DesktopDisplay display;
  final double scale;
  final Offset offset;
  final Rect? clip;
  final bool showCursor;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(Colors.black, BlendMode.src);
    canvas.save();
    if (clip != null) canvas.clipRect(clip!);
    canvas.translate(offset.dx, offset.dy);
    canvas.scale(scale);
    display.paint(canvas, includeCursor: false);
    canvas.restore();
    if (showCursor) {
      canvas.save();
      if (clip != null) canvas.clipRect(clip!);
      display.paintPointer(canvas, offset + display.pointer * scale);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_DesktopPainter old) =>
      old.scale != scale ||
      old.offset != offset ||
      old.clip != clip ||
      old.showCursor != showCursor ||
      old.display != display;
}

/// X11 keysyms are shared by the Guacamole RDP and VNC clients.
int? desktopKeysym(KeyEvent event) {
  final key = event.logicalKey;
  final special = <LogicalKeyboardKey, int>{
    LogicalKeyboardKey.backspace: 0xff08,
    LogicalKeyboardKey.tab: 0xff09,
    LogicalKeyboardKey.enter: 0xff0d,
    LogicalKeyboardKey.numpadEnter: 0xff8d,
    LogicalKeyboardKey.escape: 0xff1b,
    LogicalKeyboardKey.delete: 0xffff,
    LogicalKeyboardKey.insert: 0xff63,
    LogicalKeyboardKey.home: 0xff50,
    LogicalKeyboardKey.end: 0xff57,
    LogicalKeyboardKey.arrowLeft: 0xff51,
    LogicalKeyboardKey.arrowUp: 0xff52,
    LogicalKeyboardKey.arrowRight: 0xff53,
    LogicalKeyboardKey.arrowDown: 0xff54,
    LogicalKeyboardKey.pageUp: 0xff55,
    LogicalKeyboardKey.pageDown: 0xff56,
    LogicalKeyboardKey.shiftLeft: 0xffe1,
    LogicalKeyboardKey.shiftRight: 0xffe2,
    LogicalKeyboardKey.controlLeft: 0xffe3,
    LogicalKeyboardKey.controlRight: 0xffe4,
    LogicalKeyboardKey.altLeft: 0xffe9,
    LogicalKeyboardKey.altRight: 0xffea,
    LogicalKeyboardKey.metaLeft: 0xffeb,
    LogicalKeyboardKey.metaRight: 0xffec,
    LogicalKeyboardKey.capsLock: 0xffe5,
    LogicalKeyboardKey.numLock: 0xff7f,
    LogicalKeyboardKey.f1: 0xffbe,
    LogicalKeyboardKey.f2: 0xffbf,
    LogicalKeyboardKey.f3: 0xffc0,
    LogicalKeyboardKey.f4: 0xffc1,
    LogicalKeyboardKey.f5: 0xffc2,
    LogicalKeyboardKey.f6: 0xffc3,
    LogicalKeyboardKey.f7: 0xffc4,
    LogicalKeyboardKey.f8: 0xffc5,
    LogicalKeyboardKey.f9: 0xffc6,
    LogicalKeyboardKey.f10: 0xffc7,
    LogicalKeyboardKey.f11: 0xffc8,
    LogicalKeyboardKey.f12: 0xffc9,
  };
  if (special.containsKey(key)) return special[key];
  final char = event.character;
  if (char != null && char.runes.length == 1 && char.runes.first >= 32) {
    final rune = char.runes.first;
    return rune <= 255 ? rune : 0x01000000 | rune;
  }
  if (key.keyLabel.runes.length == 1)
    return key.keyLabel.toLowerCase().runes.first;
  return null;
}

/// Compact byte count for consent labels (B, KB, MB, GB, TB).
String formatTransferBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0
      ? '$bytes B'
      : '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}
