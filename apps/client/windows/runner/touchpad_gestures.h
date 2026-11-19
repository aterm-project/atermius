#ifndef RUNNER_TOUCHPAD_GESTURES_H_
#define RUNNER_TOUCHPAD_GESTURES_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <map>
#include <memory>
#include <vector>

#include "touchpad_frame.h"

// "atermius/touchpad_gestures": three- and four-finger gestures of a
// precision touchpad for remote desktop sessions. Windows keeps those
// gestures to itself (task view, switching apps and desktops) and Flutter
// never sees them, so while Dart has armed this, the window reads the
// touchpad's raw contact reports (HID digitizer page 0x0D, usage 0x05) and
// sends the frames of a gesture with three or more fingers to Dart, which
// recognizes swipes and taps and sends the matching shortcuts to the remote
// computer.
//
// An application cannot take these gestures away from Windows. The local
// system still performs whatever "Three-finger gestures" and "Four-finger
// gestures" are set to in Settings > Touchpad, so Dart only forwards a
// gesture whose local setting is "Nothing"; the settings are reported from
// HKCU\Software\Microsoft\Windows\CurrentVersion\PrecisionTouchPad (-1 when a
// value is absent). Raw input is registered without RIDEV_INPUTSINK: reports
// arrive only while this window is in the foreground.
//
// Contact positions only travel in memory to Dart; nothing is logged or
// stored.
class TouchpadGestures {
public:
  TouchpadGestures(flutter::BinaryMessenger *messenger, HWND window);
  ~TouchpadGestures();

  TouchpadGestures(const TouchpadGestures &) = delete;
  TouchpadGestures &operator=(const TouchpadGestures &) = delete;

  // Observes WM_INPUT and WM_SETTINGCHANGE of the top-level window. Never
  // consumes a message: the caller continues with its normal handling.
  void HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

private:
  struct Finger {
    USHORT link;
    UCHAR report_id;
    bool confidence = false;
    LONG x_min, x_max, y_min, y_max;
    double aspect = 1;
  };
  struct Device {
    bool touchpad = false;
    std::vector<BYTE> preparsed;
    std::vector<Finger> fingers;
    USHORT count_link = 0, scan_link = 0;
    UCHAR report_id = 0;
    TouchpadFrameAssembler frame;
  };

  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue> &call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  flutter::EncodableValue State() const;
  void SetArmed(bool armed);
  void HandleInput(HRAWINPUT input);
  Device &DeviceFor(HANDLE handle);
  void ReadReport(Device &device, BYTE *report, ULONG length);
  void CancelGesture();
  void EmitFrame();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  const HWND window_;
  bool armed_ = false;
  std::map<HANDLE, Device> devices_;
  std::vector<TouchpadFrameContact> contacts_;
  HANDLE active_device_ = nullptr;
  bool gesture_ = false;
  std::vector<BYTE> buffer_;
};

#endif // RUNNER_TOUCHPAD_GESTURES_H_
