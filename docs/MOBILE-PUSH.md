# Optional mobile background hints / 可选移动端后台提示

Push is disabled unless the user enables it in Settings and the app/server have provider configuration. It carries a generic synchronization hint; it is not background decryption of a locked Vault. Web never initializes Firebase for this feature. / 默认关闭，须用户在设置启用且客户端与服务端均已配置。推送只携带同步提示，不会在后台解密已锁定 Vault，Web 不初始化该功能的 Firebase。

Android uses FCM. iOS prefers its APNs token when available and can use FCM as configured fallback. The server keeps the active endpoint for the current device. / Android 使用 FCM；iOS 优先 APNs，可按配置回退 FCM。

Build defines are client configuration, not server private credentials:

```sh
flutter build apk --debug   --dart-define=ATERMIUS_FCM_API_KEY=YOUR_CLIENT_API_KEY   --dart-define=ATERMIUS_FCM_PROJECT_ID=YOUR_PROJECT_ID   --dart-define=ATERMIUS_FCM_SENDER_ID=YOUR_SENDER_ID   --dart-define=ATERMIUS_FCM_ANDROID_APP_ID=YOUR_ANDROID_APP_ID
```

For iOS use `ATERMIUS_FCM_IOS_APP_ID` and `ATERMIUS_FCM_IOS_BUNDLE_ID` with the common values. Configure the signing team's Push Notifications entitlement and matching sandbox/production provisioning. / iOS 使用对应 App ID、Bundle ID，配置签名团队、推送权限与正确环境。

In the Runner target's Xcode build settings, set `ATERMIUS_RUNNER_ENTITLEMENTS` to `Runner/RunnerPush.entitlements` for the configuration that uses push. Set `ATERMIUS_APS_ENVIRONMENT` to the provisioned APNs environment (`development` for sandbox or `production` for distribution). Enable background sync hints on a signed device after configuring Firebase and the server. / 启用推送的签名配置需在 Runner 的 Xcode Build Settings 中设置 `ATERMIUS_RUNNER_ENTITLEMENTS` 为 `Runner/RunnerPush.entitlements`，并让 `ATERMIUS_APS_ENVIRONMENT` 与描述文件的 APNs 环境相符。

The package/bundle identifier and Firebase project must match the server's configured provider. Keep service-account JSON and APNs private keys on the server, outside source and client bundles. Follow [server provider configuration](../deploy/README.md#mobile-background-sync-hints). / 服务端私钥不属于客户端构建参数，应按服务端指南独立保管。
