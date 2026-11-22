import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// Routes Android's classified touchpad gestures through the app's regular
/// pointer hit testing. The position stays fixed at the cursor for the gesture.
void initializeAndroidTrackpad() {
  const channel = MethodChannel('atermius/android_trackpad');
  final binding = GestureBinding.instance;
  final gestures = <int, _TrackpadGesture>{};
  var nextPointer = -1;

  channel.setMethodCallHandler((call) async {
    final view = binding.platformDispatcher.implicitView;
    if (view == null) return;
    final args = call.arguments as List<Object?>;
    final device = args[0] as int;
    final time = Duration(milliseconds: args[1] as int);
    Offset position() =>
        Offset(args[2] as double, args[3] as double) / view.devicePixelRatio;

    if (call.method == 'start' || call.method == 'end') {
      final previous = gestures.remove(device)?.start;
      if (previous != null) {
        binding.handlePointerEvent(
          PointerPanZoomEndEvent(
            viewId: previous.viewId,
            pointer: previous.pointer,
            device: previous.device,
            position: previous.position,
            timeStamp: time,
          ),
        );
      }
      if (call.method == 'start') {
        // The engine uses nonnegative identifiers for its pointer streams.
        final start = PointerPanZoomStartEvent(
          viewId: view.viewId,
          pointer: nextPointer--,
          device: -device - 1,
          position: position(),
          timeStamp: time,
        );
        gestures[device] = _TrackpadGesture(start);
        binding.handlePointerEvent(start);
      }
      return;
    }

    final gesture = gestures[device];
    if (gesture == null) return;
    final start = gesture.start;
    final previousPan = gesture.pan;
    switch (call.method) {
      case 'pan':
        gesture.pan = position() - start.position;
      case 'pinch':
        final scale = gesture.scale * (args[2] as double);
        if (!scale.isFinite || scale <= 0) return;
        gesture.scale = scale;
      default:
        return;
    }
    binding.handlePointerEvent(
      PointerPanZoomUpdateEvent(
        viewId: start.viewId,
        pointer: start.pointer,
        device: start.device,
        position: start.position,
        pan: gesture.pan,
        panDelta: gesture.pan - previousPan,
        scale: gesture.scale,
        timeStamp: time,
      ),
    );
  });
}

class _TrackpadGesture {
  _TrackpadGesture(this.start);

  final PointerPanZoomStartEvent start;
  Offset pan = Offset.zero;
  double scale = 1;
}
