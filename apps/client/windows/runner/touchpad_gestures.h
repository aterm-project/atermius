#ifndef RUNNER_TOUCHPAD_GESTURES_H_
#define RUNNER_TOUCHPAD_GESTURES_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <map>
#include <memory>
#include <vector>

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
  // What is needed to read one touchpad's reports.
  struct Device {
    bool touchpad = false;
    std::vector<BYTE> preparsed;
    // Link collections that describe one finger each.
    std::vector<USHORT> fingers;
    LONG x_min = 0, x_max = 0, y_min = 0;
  };
  struct Contact {
    ULONG id;
    double x, y;
  };

  void HandleCall(
      const flutter::MethodCall<flutter::EncodableValue> &call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  flutter::EncodableValue State() const;
  void SetArmed(bool armed);
  void HandleInput(HRAWINPUT input);
  const Device &DeviceFor(HANDLE handle);
  void ReadReport(const Device &device, BYTE *report, ULONG length);
  void EmitFrame();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  const HWND window_;
  bool armed_ = false;
  std::map<HANDLE, Device> devices_;
  // The frame being assembled: a touchpad may spread one frame over several
  // reports (hybrid mode), the first of which carries the contact count.
  std::vector<Contact> contacts_;
  ULONG expected_ = 0, seen_ = 0;
  // A gesture with three or more fingers is in progress: its frames are sent
  // until every finger has lifted.
  bool gesture_ = false;
  std::vector<BYTE> buffer_;
};

#endif // RUNNER_TOUCHPAD_GESTURES_H_
