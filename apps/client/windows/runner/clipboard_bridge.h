#ifndef RUNNER_CLIPBOARD_BRIDGE_H_
#define RUNNER_CLIPBOARD_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>

// Text clipboard notifications and bounded reads for remote desktop sync.
// No clipboard contents are read while the window is in the background.
class ClipboardBridge {
public:
  ClipboardBridge(flutter::BinaryMessenger *messenger, HWND window);
  ~ClipboardBridge();
  void HandleMessage(UINT message, WPARAM wparam);

private:
  bool Focused() const;
  bool Sensitive() const;
  flutter::EncodableValue State() const;
  flutter::EncodableValue Read(int max_bytes, bool automatic) const;
  flutter::EncodableValue Write(const std::string &text) const;
  HWND window_;
  UINT excluded_format_;
  bool listening_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif
