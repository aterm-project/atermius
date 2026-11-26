#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <functional>
#include <string>

// The window's icon in the notification area while it runs in the background
// (MCP keeps listening after the window was closed and hidden). Clicking it
// opens the window again; its menu offers Open and Quit. Removed when this
// object is destroyed, so it never outlives the window.
class TrayIcon {
public:
  enum class Action { kOpen, kQuit };

  TrayIcon(HWND window, std::function<void(Action)> on_action);
  ~TrayIcon();

  TrayIcon(const TrayIcon &) = delete;
  TrayIcon &operator=(const TrayIcon &) = delete;

  // Adds the icon, or updates its texts when it is already shown. A non-empty
  // |notice| is shown once as a notification. Returns false when the shell
  // refused the icon (then the window must stay reachable some other way).
  bool Show(const std::wstring &tooltip, const std::wstring &open_label,
            const std::wstring &quit_label, const std::wstring &notice_title,
            const std::wstring &notice);

  void Remove();

  // Handles the icon's callback message and Explorer restarts. Returns true
  // when |message| was the icon's own and is fully handled.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

private:
  bool Add();
  void ShowMenu(int x, int y);

  HWND window_;
  std::function<void(Action)> on_action_;
  UINT taskbar_created_;
  HICON icon_ = nullptr;
  bool added_ = false;
  bool version4_ = false;
  std::wstring tooltip_;
  std::wstring open_label_;
  std::wstring quit_label_;
};

#endif // RUNNER_TRAY_ICON_H_
