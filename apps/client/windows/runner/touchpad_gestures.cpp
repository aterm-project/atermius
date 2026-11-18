#include "touchpad_gestures.h"

#include <flutter/standard_method_codec.h>

extern "C" {
#include <hidsdi.h>
}

#include <algorithm>
#include <cstddef>

namespace {

constexpr USAGE kGenericDesktopPage = 0x01;
constexpr USAGE kUsageX = 0x30;
constexpr USAGE kUsageY = 0x31;
constexpr USAGE kDigitizerPage = 0x0D;
constexpr USAGE kUsageTouchpad = 0x05;
constexpr USAGE kUsageTipSwitch = 0x42;
constexpr USAGE kUsageContactId = 0x51;
constexpr USAGE kUsageContactCount = 0x54;
// More contacts than any touchpad reports; guards the frame assembly.
constexpr ULONG kMaxContacts = 16;
// Devices seen in one run; raw input handles change when one is re-plugged.
constexpr size_t kMaxDevices = 16;

constexpr const wchar_t kSettingsKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\PrecisionTouchPad";

bool Covers(const HIDP_VALUE_CAPS &caps, USAGE usage) {
  return caps.IsRange ? usage >= caps.Range.UsageMin &&
                            usage <= caps.Range.UsageMax
                      : caps.NotRange.Usage == usage;
}

// What the local system does with a gesture (0 = nothing); -1 when unset.
int Setting(const wchar_t *name) {
  DWORD value = 0;
  DWORD size = sizeof(value);
  if (RegGetValueW(HKEY_CURRENT_USER, kSettingsKey, name, RRF_RT_REG_DWORD,
                   nullptr, &value, &size) != ERROR_SUCCESS) {
    return -1;
  }
  return static_cast<int>(value);
}

} // namespace

TouchpadGestures::TouchpadGestures(flutter::BinaryMessenger *messenger,
                                   HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "atermius/touchpad_gestures",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue> &call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleCall(call, std::move(result)); });
}

TouchpadGestures::~TouchpadGestures() {
  SetArmed(false);
  channel_->SetMethodCallHandler(nullptr);
}

void TouchpadGestures::HandleCall(
    const flutter::MethodCall<flutter::EncodableValue> &call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto &method = call.method_name();
  if (method == "configure") {
    bool armed = false;
    const auto args = call.arguments();
    if (const auto map =
            args ? std::get_if<flutter::EncodableMap>(args) : nullptr) {
      const auto item = map->find(flutter::EncodableValue("armed"));
      if (item != map->end()) {
        if (const auto value = std::get_if<bool>(&item->second))
          armed = *value;
      }
    }
    SetArmed(armed);
    result->Success(State());
  } else if (method == "getState") {
    result->Success(State());
  } else {
    result->NotImplemented();
  }
}

flutter::EncodableValue TouchpadGestures::State() const {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("supported"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("armed"), flutter::EncodableValue(armed_)},
      {flutter::EncodableValue("threeFingerSlide"),
       flutter::EncodableValue(Setting(L"ThreeFingerSlideEnabled"))},
      {flutter::EncodableValue("threeFingerTap"),
       flutter::EncodableValue(Setting(L"ThreeFingerTapEnabled"))},
      {flutter::EncodableValue("fourFingerSlide"),
       flutter::EncodableValue(Setting(L"FourFingerSlideEnabled"))},
      {flutter::EncodableValue("fourFingerTap"),
       flutter::EncodableValue(Setting(L"FourFingerTapEnabled"))},
  });
}

void TouchpadGestures::SetArmed(bool armed) {
  if (armed == armed_ || !window_)
    return;
  RAWINPUTDEVICE device{};
  device.usUsagePage = kDigitizerPage;
  device.usUsage = kUsageTouchpad;
  device.dwFlags = armed ? 0 : RIDEV_REMOVE;
  device.hwndTarget = armed ? window_ : nullptr;
  // Without a registration there are simply no gestures; nothing else fails.
  if (!RegisterRawInputDevices(&device, 1, sizeof(device)) && armed)
    return;
  armed_ = armed;
  contacts_.clear();
  expected_ = seen_ = 0;
  if (gesture_) {
    // Tell Dart that the gesture it was following is over.
    gesture_ = false;
    EmitFrame();
  }
}

void TouchpadGestures::HandleMessage(UINT message, WPARAM wparam,
                                     LPARAM lparam) {
  if (message == WM_INPUT) {
    if (armed_)
      HandleInput(reinterpret_cast<HRAWINPUT>(lparam));
  } else if (message == WM_SETTINGCHANGE) {
    // The user may just have changed the touchpad gestures in Settings.
    if (armed_) {
      channel_->InvokeMethod(
          "stateChanged", std::make_unique<flutter::EncodableValue>(State()));
    }
  }
}

void TouchpadGestures::HandleInput(HRAWINPUT input) {
  UINT size = 0;
  if (GetRawInputData(input, RID_INPUT, nullptr, &size,
                      sizeof(RAWINPUTHEADER)) != 0 ||
      size < sizeof(RAWINPUTHEADER) || size > (1u << 20)) {
    return;
  }
  buffer_.resize(size);
  if (GetRawInputData(input, RID_INPUT, buffer_.data(), &size,
                      sizeof(RAWINPUTHEADER)) != size) {
    return;
  }
  const auto raw = reinterpret_cast<RAWINPUT *>(buffer_.data());
  if (raw->header.dwType != RIM_TYPEHID || !raw->header.hDevice)
    return;
  const DWORD report_size = raw->data.hid.dwSizeHid;
  const DWORD count = raw->data.hid.dwCount;
  const size_t offset = offsetof(RAWINPUT, data.hid.bRawData);
  if (report_size == 0 || count == 0 ||
      offset + static_cast<size_t>(report_size) * count > buffer_.size()) {
    return;
  }
  const Device &device = DeviceFor(raw->header.hDevice);
  if (!device.touchpad)
    return;
  for (DWORD i = 0; i < count; i++) {
    ReadReport(device, buffer_.data() + offset + report_size * i, report_size);
  }
}

const TouchpadGestures::Device &TouchpadGestures::DeviceFor(HANDLE handle) {
  const auto known = devices_.find(handle);
  if (known != devices_.end())
    return known->second;
  if (devices_.size() >= kMaxDevices)
    devices_.clear();
  Device &device = devices_[handle];

  RID_DEVICE_INFO info{};
  info.cbSize = sizeof(info);
  UINT info_size = sizeof(info);
  if (GetRawInputDeviceInfoW(handle, RIDI_DEVICEINFO, &info, &info_size) ==
          static_cast<UINT>(-1) ||
      info.dwType != RIM_TYPEHID || info.hid.usUsagePage != kDigitizerPage ||
      info.hid.usUsage != kUsageTouchpad) {
    return device;
  }
  UINT size = 0;
  if (GetRawInputDeviceInfoW(handle, RIDI_PREPARSEDDATA, nullptr, &size) != 0 ||
      size == 0 || size > (1u << 20)) {
    return device;
  }
  device.preparsed.resize(size);
  if (GetRawInputDeviceInfoW(handle, RIDI_PREPARSEDDATA,
                             device.preparsed.data(), &size) ==
      static_cast<UINT>(-1)) {
    return device;
  }
  const auto preparsed =
      reinterpret_cast<PHIDP_PREPARSED_DATA>(device.preparsed.data());
  HIDP_CAPS caps{};
  if (HidP_GetCaps(preparsed, &caps) != HIDP_STATUS_SUCCESS ||
      caps.NumberInputValueCaps == 0) {
    return device;
  }
  std::vector<HIDP_VALUE_CAPS> values(caps.NumberInputValueCaps);
  USHORT value_count = caps.NumberInputValueCaps;
  if (HidP_GetValueCaps(HidP_Input, values.data(), &value_count, preparsed) !=
      HIDP_STATUS_SUCCESS) {
    return device;
  }
  values.resize(value_count);
  // Every finger is a collection of its own with an X and a Y value.
  bool ranges = false;
  for (const auto &x : values) {
    if (x.UsagePage != kGenericDesktopPage || !Covers(x, kUsageX))
      continue;
    for (const auto &y : values) {
      if (y.UsagePage != kGenericDesktopPage || !Covers(y, kUsageY) ||
          y.LinkCollection != x.LinkCollection) {
        continue;
      }
      if (std::find(device.fingers.begin(), device.fingers.end(),
                    x.LinkCollection) == device.fingers.end()) {
        device.fingers.push_back(x.LinkCollection);
      }
      if (!ranges && x.LogicalMax > x.LogicalMin) {
        ranges = true;
        device.x_min = x.LogicalMin;
        device.x_max = x.LogicalMax;
        device.y_min = y.LogicalMin;
      }
    }
  }
  std::sort(device.fingers.begin(), device.fingers.end());
  device.touchpad = ranges && !device.fingers.empty();
  return device;
}

void TouchpadGestures::ReadReport(const Device &device, BYTE *report,
                                  ULONG length) {
  const auto preparsed = reinterpret_cast<PHIDP_PREPARSED_DATA>(
      const_cast<BYTE *>(device.preparsed.data()));
  const auto bytes = reinterpret_cast<PCHAR>(report);
  ULONG count = 0;
  if (HidP_GetUsageValue(HidP_Input, kDigitizerPage, 0, kUsageContactCount,
                         &count, preparsed, bytes,
                         length) != HIDP_STATUS_SUCCESS) {
    count = 0;
  }
  // A report with a contact count starts a frame; the reports that complete
  // it carry zero. All fingers up may arrive as a lone report with zero.
  if (count > 0 || seen_ >= expected_) {
    contacts_.clear();
    expected_ = std::min(count, kMaxContacts);
    seen_ = 0;
  }
  const double width = static_cast<double>(device.x_max - device.x_min);
  for (const USHORT finger : device.fingers) {
    if (seen_ >= expected_)
      break;
    seen_++;
    USAGE usages[8];
    ULONG usage_count = 8;
    if (HidP_GetUsages(HidP_Input, kDigitizerPage, finger, usages,
                       &usage_count, preparsed, bytes,
                       length) != HIDP_STATUS_SUCCESS) {
      continue;
    }
    if (std::find(usages, usages + usage_count, kUsageTipSwitch) ==
        usages + usage_count) {
      continue; // This contact has just lifted.
    }
    ULONG id = 0, x = 0, y = 0;
    if (HidP_GetUsageValue(HidP_Input, kDigitizerPage, finger, kUsageContactId,
                           &id, preparsed, bytes,
                           length) != HIDP_STATUS_SUCCESS ||
        HidP_GetUsageValue(HidP_Input, kGenericDesktopPage, finger, kUsageX, &x,
                           preparsed, bytes, length) != HIDP_STATUS_SUCCESS ||
        HidP_GetUsageValue(HidP_Input, kGenericDesktopPage, finger, kUsageY, &y,
                           preparsed, bytes, length) != HIDP_STATUS_SUCCESS) {
      continue;
    }
    // Both axes in units of the pad's width (they share one resolution).
    contacts_.push_back(
        {id, (static_cast<double>(x) - device.x_min) / width,
         (static_cast<double>(y) - device.y_min) / width});
  }
  if (seen_ < expected_)
    return; // The next report continues this frame.
  if (contacts_.size() >= 3)
    gesture_ = true;
  if (!gesture_)
    return;
  if (contacts_.empty())
    gesture_ = false;
  EmitFrame();
}

void TouchpadGestures::EmitFrame() {
  flutter::EncodableList contacts;
  if (armed_) {
    for (const auto &contact : contacts_) {
      contacts.emplace_back(static_cast<double>(contact.id));
      contacts.emplace_back(contact.x);
      contacts.emplace_back(contact.y);
    }
  }
  channel_->InvokeMethod(
      "frame",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("contacts"),
           flutter::EncodableValue(contacts)},
          {flutter::EncodableValue("time"),
           flutter::EncodableValue(static_cast<int64_t>(GetTickCount64()))},
      }));
}
