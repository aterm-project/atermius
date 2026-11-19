#include "clipboard_bridge.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <string>

namespace {
using flutter::EncodableMap;
using flutter::EncodableValue;

EncodableValue Status(const char *status) {
  return EncodableValue(
      EncodableMap{{EncodableValue("status"), EncodableValue(status)}});
}
} // namespace

ClipboardBridge::ClipboardBridge(flutter::BinaryMessenger *messenger,
                                 HWND window)
    : window_(window), excluded_format_(RegisterClipboardFormatW(
                           L"ExcludeClipboardContentFromMonitorProcessing")),
      listening_(AddClipboardFormatListener(window) != FALSE) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "atermius/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue> &call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == "state") {
          result->Success(State());
        } else if (call.method_name() == "read") {
          int max_bytes = 65536;
          bool automatic = true;
          const auto args = call.arguments();
          if (const auto map =
                  args ? std::get_if<EncodableMap>(args) : nullptr) {
            const auto limit = map->find(EncodableValue("maxBytes"));
            if (limit != map->end()) {
              if (const auto value = std::get_if<int32_t>(&limit->second))
                max_bytes = std::clamp(*value, 1, 16 * 1024 * 1024);
            }
            const auto uris = map->find(EncodableValue("uris"));
            if (uris != map->end()) {
              if (const auto value = std::get_if<bool>(&uris->second))
                automatic = !*value;
            }
          }
          result->Success(Read(max_bytes, automatic));
        } else {
          result->NotImplemented();
        }
      });
}

ClipboardBridge::~ClipboardBridge() {
  if (listening_)
    RemoveClipboardFormatListener(window_);
  channel_->SetMethodCallHandler(nullptr);
}

bool ClipboardBridge::Focused() const {
  const auto foreground = GetForegroundWindow();
  return foreground &&
         GetAncestor(foreground, GA_ROOT) == GetAncestor(window_, GA_ROOT);
}

bool ClipboardBridge::Sensitive() const {
  return excluded_format_ && IsClipboardFormatAvailable(excluded_format_);
}

EncodableValue ClipboardBridge::State() const {
  return EncodableValue(EncodableMap{
      {EncodableValue("focused"), EncodableValue(Focused())},
      {EncodableValue("allowed"), EncodableValue(true)},
      {EncodableValue("hasClip"), EncodableValue(CountClipboardFormats() != 0)},
      {EncodableValue("stamp"),
       EncodableValue(static_cast<int64_t>(GetClipboardSequenceNumber()))},
      {EncodableValue("sensitive"), EncodableValue(Sensitive())},
  });
}

EncodableValue ClipboardBridge::Read(int max_bytes, bool automatic) const {
  if (!Focused())
    return Status("unfocused");
  if (automatic && Sensitive())
    return Status("noText");
  if (!IsClipboardFormatAvailable(CF_UNICODETEXT))
    return Status("empty");
  if (!OpenClipboard(window_))
    return Status("busy");
  const auto data = GetClipboardData(CF_UNICODETEXT);
  const auto capacity = data ? GlobalSize(data) / sizeof(wchar_t) : 0;
  const auto text =
      data ? static_cast<const wchar_t *>(GlobalLock(data)) : nullptr;
  EncodableValue result = Status("noText");
  if (text) {
    const auto bound = std::min(capacity, static_cast<size_t>(max_bytes) + 1);
    size_t length = 0;
    while (length < bound && text[length])
      ++length;
    if (length == bound && length != 0) {
      result = Status("tooLarge");
    } else if (length == 0) {
      result = Status("empty");
    } else {
      const int bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text,
                                            static_cast<int>(length), nullptr,
                                            0, nullptr, nullptr);
      if (bytes > max_bytes) {
        result = Status("tooLarge");
      } else if (bytes > 0) {
        std::string utf8(bytes, '\0');
        WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text,
                            static_cast<int>(length), utf8.data(), bytes,
                            nullptr, nullptr);
        result = EncodableValue(EncodableMap{
            {EncodableValue("status"), EncodableValue("text")},
            {EncodableValue("text"), EncodableValue(utf8)},
            {EncodableValue("stamp"), EncodableValue(static_cast<int64_t>(
                                          GetClipboardSequenceNumber()))},
        });
      }
    }
    GlobalUnlock(data);
  }
  CloseClipboard();
  return result;
}

void ClipboardBridge::HandleMessage(UINT message) {
  if (message == WM_CLIPBOARDUPDATE && Focused())
    channel_->InvokeMethod("changed", nullptr);
}
