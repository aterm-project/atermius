# Build and install on Android

[中文](android.md) · [Install overview](../INSTALLATION.en.md) · [README](../../README.md)

First complete repository access, cloning and the Flutter toolchain in the [install overview](../INSTALLATION.en.md). Paths below are relative to the repository root.

## Development APK

Install Android Studio/SDK command-line tools, the platform/build tools selected by the pinned Flutter Gradle plugin, and **JDK 17**. This project targets Java/Kotlin 17 and uses AGP 9.1.0; resolve Android-toolchain issues in `flutter doctor -v`. Accept Android SDK licenses interactively. Enable USB debugging or use an emulator.

```sh
cd apps/client
flutter doctor -v
flutter doctor --android-licenses
flutter pub get --enforce-lockfile
flutter build apk --debug
adb devices
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

The application ID is `com.atermius.aterm_client`. The output path above is relative to `apps/client`. `adb install -r` requests an update while retaining data, but requires a compatible signing identity. Do not uninstall a differently signed existing app before exporting its data.

## Release distribution

The checked-in `release` Gradle variant currently uses **debug signing**. Merely running `flutter build apk --release` does not create a production-signed distribution. Configure your own keystore/signing configuration following [Flutter Android signing](https://docs.flutter.dev/deployment/android#sign-the-app), keep keys/password files outside Git and preserve that identity for updates.

After signing has been configured:

```sh
flutter build apk --release
flutter build appbundle --release
```

Outputs are `build/app/outputs/flutter-apk/app-release.apk` and `build/app/outputs/bundle/release/app-release.aab`. App Bundles are for a store/distributor, not directly installed with `adb install`. No current Play Store release is provided by this repository.

Building and packaging the Android native RDP engine `libatermius_rdp.so` is described under "Android 直接连接" (Android direct connection) in [remote desktop](../REMOTE-DESKTOP.md).

## First use and scope

Choose local data or your HTTPS self-hosted instance. SSH uses the native transport; local shell/serial Console and the Windows native RDP engine are not Android features. Temporary guest links can be opened in a supported browser. Mobile OS background limits may interrupt sessions/forwarding. Optional [push hints](../MOBILE-PUSH.md) require separate provider configuration.

Before updating an existing build, read "Update an existing build" in the [install overview](../INSTALLATION.en.md).

Remote desktop (RDP) requests no permission at app startup. It asks only when the user starts a connection or turns the matching switch on in a Host's RDP options: mapping local disks needs All files access (an in-app explanation comes before the system Settings page), and microphone or camera redirection needs the microphone or camera permission. If one is refused, the connection proceeds without that redirection; it can be allowed later in the system app settings. Devices without a microphone or camera can still install the app. See [Remote desktop](../REMOTE-DESKTOP.md#storage-mappings-and-direct-touch).

[First use](../GETTING_STARTED.en.md) · [Troubleshooting](../TROUBLESHOOTING.en.md) · [Developer checks](../DEVELOPMENT.md)
