# Android 构建与安装

[English](android.en.md) · [安装总览](../INSTALLATION.md) · [README](../../README.zh-CN.md)

先按[安装总览](../INSTALLATION.md)完成仓库权限、克隆与 Flutter 工具链准备。以下命令中的路径相对仓库根目录。

## 开发 APK

安装 Android Studio/SDK 命令行工具、固定 Flutter 插件要求的平台/构建工具，以及 **JDK 17**。项目的 Java/Kotlin 目标为 17，AGP 为 9.1.0；先解决 `flutter doctor -v` 的 Android 环境问题并交互确认 SDK 许可。启用设备 USB 调试或启动模拟器：

```sh
cd apps/client
flutter doctor -v
flutter doctor --android-licenses
flutter pub get --enforce-lockfile
flutter build apk --debug
adb devices
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

包名是 `com.atermius.aterm_client`，产物路径相对 `apps/client`。`adb install -r` 请求保留资料更新，但新旧包必须使用兼容签名；遇到签名不同，应先导出资料，不要直接卸载已有应用。

## 正式分发

仓库的 `release` Gradle 配置目前仍使用**调试签名**，仅执行 `flutter build apk --release` 不会得到正式签名发行包。先按 [Flutter Android 签名说明](https://docs.flutter.dev/deployment/android#sign-the-app)配置自己的 keystore 和 Gradle 签名，密钥/密码文件不提交 Git，后续更新保持签名身份。

完成签名配置后：

```sh
flutter build apk --release
flutter build appbundle --release
```

产物分别为 `build/app/outputs/flutter-apk/app-release.apk`、`build/app/outputs/bundle/release/app-release.aab`。AAB 用于商店/发行渠道，不能直接用 `adb install` 安装。本仓库当前没有提供 Play Store 发行版。

Android 原生 RDP 引擎 `libatermius_rdp.so` 的构建与打包步骤见[远程桌面](../REMOTE-DESKTOP.md)中的“Android 直接连接”。

RDP 会话可在本机播放远程音频，并可按主机设置重定向麦克风和摄像头：麦克风需要系统录音权限，摄像头需要相机权限，并依赖设备自带的 H.264 编码器（MediaCodec）。设备无法打开（例如未授权）时，该项不可用，连接照常进行。

## 首次使用与范围

选择本地资料或自己的 HTTPS 实例。SSH 使用原生传输；本机 Shell、串口 Console 和 Windows 原生 RDP 引擎不属于 Android 能力。临时访客链接可在支持的浏览器中打开，前后台策略可能中断会话/转发。[可选推送提示](../MOBILE-PUSH.md)需单独配置。

更新已有版本前请先阅读[安装总览](../INSTALLATION.md)中的“更新已有版本”。

远程桌面（RDP）不在应用启动时申请权限，只在用户发起连接或在主机 RDP 选项中打开相应开关时申请：映射本机磁盘需要“所有文件访问权限”（先显示应用内说明再打开系统设置），麦克风、摄像头重定向需要麦克风、相机权限。拒绝后连接照常进行，只是不含该重定向；可随时在系统的应用设置中开启。没有麦克风或摄像头的设备同样可以安装。详见[远程桌面](../REMOTE-DESKTOP.md#storage-mappings-and-direct-touch)。

[首次使用](../GETTING_STARTED.md) · [常见问题](../TROUBLESHOOTING.md) · [开发验证](../DEVELOPMENT.md)
