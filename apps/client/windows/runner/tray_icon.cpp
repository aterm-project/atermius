#include "tray_icon.h"

#include <shellapi.h>
#include <windowsx.h>

#include "resource.h"

// Older SDK headers (mingw-w64) may lack the Vista-era notification-area
// definitions; the values are fixed by the Windows ABI.
#ifndef NIF_SHOWTIP
#define NIF_SHOWTIP 0x00000080
#endif
#ifndef NOTIFYICON_VERSION_4
#define NOTIFYICON_VERSION_4 4
#endif
#ifndef NIN_SELECT
#define NIN_SELECT (WM_USER + 0)
#endif
#ifndef NINF_KEY
#define NINF_KEY 0x1
#endif
#ifndef NIN_KEYSELECT
#define NIN_KEYSELECT (NIN_SELECT | NINF_KEY)
#endif

namespace {

constexpr UINT kTrayCallback = WM_APP + 0x3A1;
constexpr UINT kTrayId = 1;
constexpr UINT kCommandOpen = 1;
constexpr UINT kCommandQuit = 2;

template <size_t N>
void Copy(wchar_t (&target)[N], const std::wstring &value) {
  lstrcpynW(target, value.c_str(), static_cast<int>(N));
}

NOTIFYICONDATAW BaseData(HWND window) {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window;
  data.uID = kTrayId;
  return data;
}

} // namespace

TrayIcon::TrayIcon(HWND window, std::function<void(Action)> on_action)
    : window_(window), on_action_(std::move(on_action)),
      taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")) {
  icon_ = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
}

TrayIcon::~TrayIcon() {
  Remove();
  if (icon_)
    DestroyIcon(icon_);
}

bool TrayIcon::Add() {
  auto data = BaseData(window_);
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayCallback;
  data.hIcon = icon_ ? icon_ : LoadIcon(nullptr, IDI_APPLICATION);
  Copy(data.szTip, tooltip_);
  if (!Shell_NotifyIconW(NIM_ADD, &data))
    return false;
  data.uVersion = NOTIFYICON_VERSION_4;
  version4_ = Shell_NotifyIconW(NIM_SETVERSION, &data) != FALSE;
  added_ = true;
  return true;
}

bool TrayIcon::Show(const std::wstring &tooltip, const std::wstring &open_label,
                    const std::wstring &quit_label,
                    const std::wstring &notice_title,
                    const std::wstring &notice) {
  tooltip_ = tooltip;
  open_label_ = open_label;
  quit_label_ = quit_label;
  if (!added_) {
    if (!Add())
      return false;
  } else {
    auto data = BaseData(window_);
    data.uFlags = NIF_TIP | NIF_SHOWTIP;
    Copy(data.szTip, tooltip_);
    Shell_NotifyIconW(NIM_MODIFY, &data);
  }
  if (!notice.empty()) {
    auto data = BaseData(window_);
    data.uFlags = NIF_INFO;
    data.dwInfoFlags = NIIF_INFO;
    Copy(data.szInfoTitle, notice_title);
    Copy(data.szInfo, notice);
    Shell_NotifyIconW(NIM_MODIFY, &data);
  }
  return true;
}

void TrayIcon::Remove() {
  if (!added_)
    return;
  auto data = BaseData(window_);
  Shell_NotifyIconW(NIM_DELETE, &data);
  added_ = false;
}

void TrayIcon::ShowMenu(int x, int y) {
  HMENU menu = CreatePopupMenu();
  if (!menu)
    return;
  AppendMenuW(menu, MF_STRING, kCommandOpen, open_label_.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCommandQuit, quit_label_.c_str());
  SetMenuDefaultItem(menu, kCommandOpen, FALSE);
  // Required so the menu closes when the user clicks elsewhere.
  SetForegroundWindow(window_);
  const UINT command =
      TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, x,
                     y, 0, window_, nullptr);
  PostMessage(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (command == kCommandOpen)
    on_action_(Action::kOpen);
  else if (command == kCommandQuit)
    on_action_(Action::kQuit);
}

bool TrayIcon::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == taskbar_created_ && taskbar_created_ != 0) {
    // Explorer restarted and forgot every icon: put ours back.
    if (added_) {
      added_ = false;
      Add();
    }
    return false;
  }
  if (message != kTrayCallback)
    return false;
  if (version4_) {
    // Version 4: LOWORD(lparam) is the event, HIWORD(lparam) the icon id and
    // wparam the anchor point.
    if (HIWORD(lparam) != kTrayId)
      return true;
    switch (LOWORD(lparam)) {
    case NIN_SELECT:
    case NIN_KEYSELECT:
    case WM_LBUTTONDBLCLK:
      on_action_(Action::kOpen);
      break;
    case WM_CONTEXTMENU:
      ShowMenu(GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam));
      break;
    default:
      break;
    }
    return true;
  }
  // Older shells: wparam is the icon id and lparam the mouse message.
  if (wparam != kTrayId)
    return true;
  if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
    on_action_(Action::kOpen);
  } else if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
    POINT point{};
    GetCursorPos(&point);
    ShowMenu(point.x, point.y);
  }
  return true;
}
