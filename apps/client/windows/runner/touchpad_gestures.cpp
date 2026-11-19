#include "touchpad_gestures.h"

#include <flutter/standard_method_codec.h>

extern "C" {
#include <hidsdi.h>
}

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace {

constexpr USAGE kGenericDesktopPage = 0x01;
constexpr USAGE kUsageX = 0x30;
constexpr USAGE kUsageY = 0x31;
constexpr USAGE kDigitizerPage = 0x0D;
constexpr USAGE kUsageTouchpad = 0x05;
constexpr USAGE kUsageTipSwitch = 0x42;
constexpr USAGE kUsageConfidence = 0x47;
constexpr USAGE kUsageScanTime = 0x56;
constexpr USAGE kUsageContactId = 0x51;
constexpr USAGE kUsageContactCount = 0x54;
// More contacts than any touchpad reports; guards the frame assembly.
constexpr ULONG kMaxContacts = 16;
// Devices seen in one run; raw input handles change when one is re-plugged.
constexpr size_t kMaxDevices = 16;

constexpr const wchar_t kSettingsKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\PrecisionTouchPad";

bool Covers(const HIDP_VALUE_CAPS &caps, USAGE usage) {
  return caps.IsRange
             ? usage >= caps.Range.UsageMin && usage <= caps.Range.UsageMax
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
  device.dwFlags = armed ? RIDEV_DEVNOTIFY : RIDEV_REMOVE;
  device.hwndTarget = armed ? window_ : nullptr;
  // Without a registration there are simply no gestures; nothing else fails.
  if (!RegisterRawInputDevices(&device, 1, sizeof(device)) && armed)
    return;
  armed_ = armed;
  CancelGesture();
  devices_.clear();
  active_device_ = nullptr;
}

void TouchpadGestures::HandleMessage(UINT message, WPARAM wparam,
                                     LPARAM lparam) {
  if (message == WM_INPUT) {
    if (armed_ && GetAncestor(GetForegroundWindow(), GA_ROOT) == window_)
      HandleInput(reinterpret_cast<HRAWINPUT>(lparam));
  } else if (message == WM_INPUT_DEVICE_CHANGE) {
    const auto device = reinterpret_cast<HANDLE>(lparam);
    devices_.erase(device);
    if (device == active_device_) {
      CancelGesture();
      active_device_ = nullptr;
    }
  } else if (message == WM_ACTIVATE) {
    if (LOWORD(wparam) == WA_INACTIVE) {
      CancelGesture();
      for (auto &entry : devices_)
        entry.second.frame.Reset();
    } else if (armed_) {
      channel_->InvokeMethod(
          "stateChanged", std::make_unique<flutter::EncodableValue>(State()));
    }
  } else if (message == WM_SETTINGCHANGE && armed_) {
    CancelGesture();
    channel_->InvokeMethod("stateChanged",
                           std::make_unique<flutter::EncodableValue>(State()));
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
  Device &device = DeviceFor(raw->header.hDevice);
  if (!device.touchpad)
    return;
  if (active_device_ != raw->header.hDevice) {
    CancelGesture();
    device.frame.Reset();
    active_device_ = raw->header.hDevice;
  }
  for (DWORD i = 0; i < count; i++) {
    ReadReport(device, buffer_.data() + offset + report_size * i, report_size);
  }
}

TouchpadGestures::Device &TouchpadGestures::DeviceFor(HANDLE handle) {
  auto known = devices_.find(handle);
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
                             device.preparsed.data(),
                             &size) == static_cast<UINT>(-1)) {
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
  const HIDP_VALUE_CAPS *count_cap = nullptr;
  const HIDP_VALUE_CAPS *scan_cap = nullptr;
  for (const auto &value : values) {
    if (value.UsagePage != kDigitizerPage)
      continue;
    if (Covers(value, kUsageContactCount))
      count_cap = &value;
    if (Covers(value, kUsageScanTime))
      scan_cap = &value;
  }
  if (!count_cap || !scan_cap || count_cap->ReportID != scan_cap->ReportID)
    return device;
  device.count_link = count_cap->LinkCollection;
  device.scan_link = scan_cap->LinkCollection;
  device.report_id = count_cap->ReportID;
  std::vector<HIDP_BUTTON_CAPS> buttons(caps.NumberInputButtonCaps);
  USHORT button_count = caps.NumberInputButtonCaps;
  if (button_count &&
      HidP_GetButtonCaps(HidP_Input, buttons.data(), &button_count,
                         preparsed) != HIDP_STATUS_SUCCESS)
    return device;
  buttons.resize(button_count);
  for (const auto &x : values) {
    if (x.UsagePage != kGenericDesktopPage || !Covers(x, kUsageX) ||
        x.ReportID != device.report_id || x.LogicalMax <= x.LogicalMin)
      continue;
    for (const auto &y : values) {
      if (y.UsagePage != kGenericDesktopPage || !Covers(y, kUsageY) ||
          y.LinkCollection != x.LinkCollection || y.ReportID != x.ReportID ||
          y.LogicalMax <= y.LogicalMin)
        continue;
      Finger finger{x.LinkCollection, x.ReportID,   false,       x.LogicalMin,
                    x.LogicalMax,     y.LogicalMin, y.LogicalMax};
      bool tip = false, id = false;
      for (const auto &value : values)
        if (value.LinkCollection == x.LinkCollection &&
            value.ReportID == x.ReportID && value.UsagePage == kDigitizerPage &&
            Covers(value, kUsageContactId))
          id = true;
      for (const auto &button : buttons) {
        if (button.LinkCollection != x.LinkCollection ||
            button.ReportID != x.ReportID || button.UsagePage != kDigitizerPage)
          continue;
        const auto has = [&](USAGE usage) {
          return button.IsRange ? usage >= button.Range.UsageMin &&
                                      usage <= button.Range.UsageMax
                                : button.NotRange.Usage == usage;
        };
        tip |= has(kUsageTipSwitch);
        finger.confidence |= has(kUsageConfidence);
      }
      if (!tip || !id)
        continue;
      // Normalize distance with physical dimensions when the descriptor
      // supplies them: X and Y need not have the same logical resolution.
      finger.aspect = static_cast<double>(y.LogicalMax - y.LogicalMin) /
                      (x.LogicalMax - x.LogicalMin);
      if (x.Units == y.Units && x.PhysicalMax > x.PhysicalMin &&
          y.PhysicalMax > y.PhysicalMin) {
        const auto exponent = [](ULONG value) {
          const int nibble = value & 0xf;
          return nibble < 8 ? nibble : nibble - 16;
        };
        finger.aspect =
            static_cast<double>(y.PhysicalMax - y.PhysicalMin) /
            (x.PhysicalMax - x.PhysicalMin) *
            std::pow(10.0, exponent(y.UnitsExp) - exponent(x.UnitsExp));
      }
      if (std::isfinite(finger.aspect) && finger.aspect > 0 &&
          finger.aspect <= 4)
        device.fingers.push_back(finger);
      break;
    }
  }
  device.touchpad =
      !device.fingers.empty() && device.fingers.size() <= kMaxContacts;
  return device;
}

void TouchpadGestures::ReadReport(Device &device, BYTE *report, ULONG length) {
  if (!length || report[0] != device.report_id)
    return;
  const auto preparsed =
      reinterpret_cast<PHIDP_PREPARSED_DATA>(device.preparsed.data());
  const auto bytes = reinterpret_cast<PCHAR>(report);
  ULONG count = 0, scan = 0;
  if (HidP_GetUsageValue(HidP_Input, kDigitizerPage, device.count_link,
                         kUsageContactCount, &count, preparsed, bytes,
                         length) != HIDP_STATUS_SUCCESS ||
      HidP_GetUsageValue(HidP_Input, kDigitizerPage, device.scan_link,
                         kUsageScanTime, &scan, preparsed, bytes,
                         length) != HIDP_STATUS_SUCCESS) {
    CancelGesture();
    device.frame.Reset();
    return;
  }
  std::vector<TouchpadFrameContact> slots;
  for (const auto &finger : device.fingers) {
    USAGE usages[32];
    ULONG usage_count = 32;
    ULONG id = 0, x = 0, y = 0;
    if (HidP_GetUsages(HidP_Input, kDigitizerPage, finger.link, usages,
                       &usage_count, preparsed, bytes,
                       length) != HIDP_STATUS_SUCCESS ||
        HidP_GetUsageValue(HidP_Input, kDigitizerPage, finger.link,
                           kUsageContactId, &id, preparsed, bytes,
                           length) != HIDP_STATUS_SUCCESS ||
        HidP_GetUsageValue(HidP_Input, kGenericDesktopPage, finger.link,
                           kUsageX, &x, preparsed, bytes,
                           length) != HIDP_STATUS_SUCCESS ||
        HidP_GetUsageValue(HidP_Input, kGenericDesktopPage, finger.link,
                           kUsageY, &y, preparsed, bytes,
                           length) != HIDP_STATUS_SUCCESS) {
      CancelGesture();
      device.frame.Reset();
      return;
    }
    const auto has = [&](USAGE usage) {
      return std::find(usages, usages + usage_count, usage) !=
             usages + usage_count;
    };
    const bool touching = has(kUsageTipSwitch);
    if (touching && (x > static_cast<ULONG>(finger.x_max) ||
                     y > static_cast<ULONG>(finger.y_max))) {
      CancelGesture();
      device.frame.Reset();
      return;
    }
    slots.push_back({id,
                     (static_cast<double>(x) - finger.x_min) /
                         (finger.x_max - finger.x_min),
                     (static_cast<double>(y) - finger.y_min) /
                         (finger.y_max - finger.y_min) * finger.aspect,
                     touching, !finger.confidence || has(kUsageConfidence)});
  }
  // A zero-count frame with no live contacts is the final lift. Unused
  // parallel slots must not look like an orphan hybrid continuation.
  if (!count && !device.frame.pending() &&
      std::none_of(slots.begin(), slots.end(),
                   [](const auto &c) { return c.touching; }))
    slots.clear();
  const auto result = device.frame.Add(count, scan, slots);
  if (result.cancelled) {
    CancelGesture();
    return;
  }
  if (!result.complete)
    return;
  contacts_ = result.contacts;
  if (contacts_.size() >= 3)
    gesture_ = true;
  if (!gesture_)
    return;
  if (contacts_.empty())
    gesture_ = false;
  EmitFrame();
}

void TouchpadGestures::CancelGesture() {
  contacts_.clear();
  if (!gesture_)
    return;
  gesture_ = false;
  channel_->InvokeMethod("cancel", nullptr);
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
