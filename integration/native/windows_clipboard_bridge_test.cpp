// Run in an isolated Wine/Xvfb desktop: writes synthetic clipboard text only.
#include "../../apps/client/windows/runner/clipboard_bridge.h"
#include <cassert>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <iostream>
#include <string>

using flutter::EncodableMap;
using flutter::EncodableValue;
const auto &codec = flutter::StandardMethodCodec::GetInstance();
class Messenger : public flutter::BinaryMessenger {
public:
  mutable int changes = 0;
  flutter::BinaryMessageHandler handler;
  void Send(const std::string &, const uint8_t *bytes, size_t size,
            flutter::BinaryReply = nullptr) const override {
    const auto call = codec.DecodeMethodCall(bytes, size);
    if (call && call->method_name() == "changed")
      changes++;
  }
  void SetMessageHandler(const std::string &,
                         flutter::BinaryMessageHandler value) override {
    handler = std::move(value);
  }
  EncodableMap Call(const char *method, EncodableMap arguments = {}) {
    EncodableValue result;
    bool success = false;
    flutter::MethodResultFunctions<> capture(
        [&](const auto *value) {
          result = *value;
          success = true;
        },
        [](const auto &, const auto &, const auto *) { assert(false); },
        [] { assert(false); });
    const auto message =
        codec.EncodeMethodCall(flutter::MethodCall<EncodableValue>(
            method, std::make_unique<EncodableValue>(arguments)));
    handler(
        message->data(), message->size(),
        [&](const uint8_t *bytes, size_t size) {
          assert(codec.DecodeAndProcessResponseEnvelope(bytes, size, &capture));
        });
    assert(success);
    return std::get<EncodableMap>(result);
  }
};

void Copy(HWND window, const wchar_t *text, bool sensitive = false) {
  assert(OpenClipboard(window));
  EmptyClipboard();
  const size_t bytes = (wcslen(text) + 1) * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
  assert(memory);
  memcpy(GlobalLock(memory), text, bytes);
  GlobalUnlock(memory);
  assert(SetClipboardData(CF_UNICODETEXT, memory));
  if (sensitive) {
    HGLOBAL marker = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, 4);
    assert(
        SetClipboardData(RegisterClipboardFormatW(
                             L"ExcludeClipboardContentFromMonitorProcessing"),
                         marker));
  }
  CloseClipboard();
}

int main() {
  const auto window = CreateWindowW(
      L"STATIC", L"Clipboard bridge test", WS_OVERLAPPEDWINDOW, 0, 0, 400, 250,
      nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
  assert(window);
  ShowWindow(window, SW_SHOW);
  SetForegroundWindow(window);
  Messenger messenger;
  {
    ClipboardBridge bridge(&messenger, window);
    Copy(window, L"RDP clipboard: 中文 😀\r\nline two");
    auto state = messenger.Call("state");
    assert(std::get<bool>(state[EncodableValue("focused")]));
    assert(std::get<bool>(state[EncodableValue("hasClip")]));
    auto read = messenger.Call(
        "read", {{EncodableValue("maxBytes"), EncodableValue(65536)}});
    assert(std::get<std::string>(read[EncodableValue("status")]) == "text");
    assert(std::get<std::string>(read[EncodableValue("text")]) ==
           u8"RDP clipboard: 中文 😀\r\nline two");
    auto small = messenger.Call(
        "read", {{EncodableValue("maxBytes"), EncodableValue(4)}});
    assert(std::get<std::string>(small[EncodableValue("status")]) ==
           "tooLarge");
    bridge.HandleMessage(WM_CLIPBOARDUPDATE);
    assert(messenger.changes == 1);
    Copy(window, L"synthetic secret", true);
    state = messenger.Call("state");
    assert(std::get<bool>(state[EncodableValue("sensitive")]));
    read = messenger.Call("read");
    assert(std::get<std::string>(read[EncodableValue("status")]) == "noText");
    read = messenger.Call("read",
                          {{EncodableValue("uris"), EncodableValue(true)}});
    assert(std::get<std::string>(read[EncodableValue("status")]) == "text");
    const auto other =
        CreateWindowW(L"STATIC", L"Other app", WS_OVERLAPPEDWINDOW, 20, 20, 400,
                      250, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
    ShowWindow(other, SW_SHOW);
    SetForegroundWindow(other);
    read = messenger.Call("read");
    assert(std::get<std::string>(read[EncodableValue("status")]) ==
           "unfocused");
    bridge.HandleMessage(WM_CLIPBOARDUPDATE);
    assert(messenger.changes == 1);
    DestroyWindow(other);
  }
  DestroyWindow(window);
  std::cout << "Windows clipboard bridge passed\n";
}
