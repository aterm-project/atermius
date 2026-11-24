# Automatic updates / 自动更新

Release builds for **Windows, Linux and Android** look for newer releases by themselves, install them in the background and show **"New version ready"** on Home. A restart starts the new version. The browser frontend is updated by the server that hosts it; iOS and macOS are not covered.

发布版的 **Windows、Linux、Android** 客户端会自己检查新版本，在后台装好，并在首页提示「新版本已就绪」，重启后生效。浏览器端由托管它的服务器更新；iOS 和 macOS 不在此列。

## What the user sees / 用户看到的

| State | Home | Settings → Notifications and updates |
| --- | --- | --- |
| Up to date | nothing | "Atermius is up to date." |
| New release found, downloading | nothing (it happens in the background) | "Downloading Atermius … 42%" |
| Installed in the background | **New version ready** · *What's new* · **Restart now** | the same, with a restart button |
| Automatic updates off, or metered connection (Android) | "Atermius … is available" · **Download** | the same |
| Linux copy in a directory the user cannot write to | "Atermius … is available" · **Open download page** | the same |
| First start after an update | "Updated to Atermius …" (dismissible) | — |

- **Restart now** asks first when sessions are open, because they are disconnected.
- Closing the app and starting it again also switches to the new version; no click needed.
- *Install updates automatically* (on by default) is a device-local setting. Off: releases are announced, the user starts the download.
- On Android the download does not start by itself on a metered connection.

## Where releases come from / 更新渠道

GitHub Releases of `aterm-project/atermius`, read anonymously (`GET /repos/…/releases`, one request per check: 20 seconds after start, then every 4 hours, or on *Check for updates*). The rest of the updater only talks to the `AppUpdateChannel` interface, so the channel can be replaced later.

A release is an update when all of this holds:

- it is published and not marked as a pre-release (daily test builds are pre-releases);
- its tag ends in `<yyyymmdd>.<n>-<commit>` and that stamp is later than the running build's (`local-20261124.3-…` is newer than `local-20261124.2-…`; the prefix does not matter);
- it has this platform's package: `atermius-desktop-windows-x64-*.zip`, `atermius-desktop-linux-x64-*.tar.gz` or `atermius-android-*.apk`;
- it has a `SHA256SUMS` file that lists that package.

If the newest release lacks the package for a platform, the newest one that has it is used.

After the download the app also checks that the new build carries its own release tag in its compiled program. A build made without `ATERMIUS_RELEASE_TAG` (or from code without the updater) could never update again, so it is skipped for good instead of being installed; the device stays on its current version and takes the next proper release.

The package is downloaded from `github.com/<repository>/releases/download/…` only, to a `.part` file that is continued after an interruption, and accepted only with exactly the announced size and SHA-256 digest. Android additionally refuses a package that is not this app, is not newer, or is not signed with the same key (the last check is the system's).

## How the installed copy is replaced / 如何替换已安装的版本

**Windows and Linux**

1. The package is unpacked into the user's own data, never into the installed directory: `%LOCALAPPDATA%\Atermius\updates\<tag>\app` or `~/.cache/atermius/updates/<tag>/app`. Archive entries that would leave that directory, and links, are refused.
2. To switch, the **new** version is started from that copy as its own installer. It reports that it runs, waits until nothing runs from the installed directory any more, moves the old program files into `.atermius-old`, copies itself in and starts the installed copy. Only the entries a release ships (`aterm_client[.exe]`, the libraries, `data/`) are touched; other files in the directory stay.
3. If copying fails, the old files are moved back and the old version starts again. After two failures, or if the new version cannot even start, that release is skipped for good and the next one is tried when it appears.

The switch happens on **Restart now**, or by itself the next time Atermius is started while no other Atermius window is open. Other open main windows run from the same files, so a restart from the banner asks to close them first.

When the user cannot write to the installed directory — the setup program installs to `C:\Program Files\Atermius` — downloading and unpacking still happen in the background, but the switch waits for **Restart now**: Windows then shows its administrator (UAC) prompt, the new version replaces the files with those rights and Atermius is started again through Explorer with the user's normal rights. Declining the prompt changes nothing; the banner stays. On Linux such a copy is only told that a new version exists.

安装在 `C:\Program Files` 这类普通权限写不进的目录时，下载和解包照样在后台完成；点「立即重启」后 Windows 弹出管理员授权（UAC），新版本以管理员权限替换文件，再经资源管理器以普通权限重新打开 Atermius。拒绝授权则什么都不变，横幅保留。Linux 上这种情况只提示有新版本。

**Android**

The verified APK waits in the app's cache. *Install and restart* hands it to the system installer. Android shows its own confirmation where it must (always before Android 12; on newer versions until the app is its own installer, i.e. after the first in-app update). Android closes the app while it replaces it and does not let it reopen itself; a notification "Atermius was updated" leads back if notifications are allowed.

## For people who publish releases / 发版要求

- Build with `--dart-define=ATERMIUS_RELEASE_TAG=<release tag>`. The recipes in `.github/daily-build/recipe` do this for Windows, Linux and Android. A build without the tag (any development build) never looks for updates, and installed copies skip a published release built without it.
- Keep the tag form `<prefix>-<yyyymmdd>.<n>-<commit>` and the package names above; publish `SHA256SUMS` with every release.
- Only mark a release as a normal (non-pre-release) release when installed copies should move to it.
- Android: `versionCode` must increase and the signing key must stay the same, or the system refuses the update.
- The Windows package is the portable ZIP. The files in it replace the files of the installed copy one to one; a release must not rely on files outside that tree.

`--dart-define=ATERMIUS_UPDATE_FEED=<origin>` points a test build at a server that answers like the GitHub API. It exists for testing the updater and must not be set for published builds.

## Code / 代码位置

`apps/client/lib/app_update/` — `app_update_channel.dart` (GitHub), `app_update_controller.dart` (when to check, download, offer), `app_update_desktop.dart` (staging, the switch, rollback), `app_update_android.dart` + `android/…/AppUpdateInstaller.kt` (system installer), `lib/ui/app_update_widgets.dart` (banner and settings card). Tests: `apps/client/test/app_update_*_test.dart`.
