# First workspace and connection

[中文](GETTING_STARTED.md) · [Install](INSTALLATION.en.md) · [Feature matrix](FEATURES.md)

## 1. Choose where your data lives

Use a **local profile** for work kept on this device, or a **server account** for a self-hosted synchronized Vault. The app retains your choice; change it in settings. The browser build has no local profile: it signs in to the server that serves it. A fresh browser has its own storage and may need first-run setup. Manual lock and device secure-storage availability affect whether a profile can be reopened automatically.

For server mode, enter your instance's exact HTTPS origin. HTTP is a loopback-only development option. The first account needs the operator's one-use bootstrap token; later accounts follow the server's registration/invitation policy. An organization join link does not bypass account registration. Keep the recovery material created by the account flow somewhere you can recover independently of this device.

### Development servers: "Allow insecure connection"

For development only, the sign-in page has an **Allow insecure connection** switch below the server address. It is off by default and asks for confirmation. Turned on for one server, it lets this device connect to that exact address (scheme, host and port) although its certificate cannot be verified (for example a self-signed or internal-CA certificate), or over plain `http://` to a non-loopback address. Never use it with real data: anyone on the network path can read or change everything that is sent, including the account password proof and synchronized data.

- It applies to that one server only. Every other server, SSH host keys, RDP certificate prompts and the end-to-end encryption of Vault data are unchanged.
- It is stored with the saved server on this device only; it is not synchronized and is not part of a Vault. Changing to another server address does not carry it over. To turn it off, sign out, choose **Change server** and connect again with the switch off.
- While it is in use, an "Insecure connection — development only" warning stays on the sign-in page, the locked screen, the workspace and Account settings; it shows the server it applies to and cannot be dismissed.
- A browser cannot skip certificate checks and blocks mixed content, so in the Web client the switch can only allow a plain `http://` server where the browser itself permits it. For a self-signed HTTPS development server, trust the certificate in the browser or operating system, or use a native client.

For anything but development, give the server a certificate the device trusts instead; see the [server guide](install/server.en.md).

## 2. Save a Host

Open Home and add a Host. Set its label, protocol, address and port, then enter the username/password or choose a saved private key in the Host editor. Authentication remains associated with the Host; the Keychain entry manages reusable login keys. Review inherited group/jump-host dependencies when using them.

Use the Host card's connect action to open a session. The menu contains edit, share and file actions. Home search filters as you type and accepts supported quick-connect expressions; see [quick connect](QUICK-CONNECT.md). A quick connection is not a replacement for saving a Host you want to reuse.

## 3. Trust the target, then work

For SSH, compare the displayed host-key fingerprint with a trusted source. For RDP, review and save the target certificate fingerprint when prompted; a changed fingerprint needs another decision. A generic TLS failure is not automatically a certificate-trust failure.

Terminal tabs/panes keep their own sessions. Use the pane handle/menu to split, clone, detach or close where the platform supports it. Saved window sets can be reopened from Home; unavailable protocols still require their platform/server prerequisites. The SSH right sidebar provides output search, snippets and input history. A snippet fills input for review before execution. See [terminal tools](TERMINAL-SIDEBAR.md).

Open **SFTP** or **SCP** from the Host/session menu for a file workspace. Confirm the remote path and destination before transfer or replacement. See [features](FEATURES.md) for platform boundaries. Local shells and OS serial Console are desktop features.

## 4. Optional sync and sharing

A local profile does not silently upload itself to a server. Use the explicit migration/import workflow when moving data. Keep backups before changing a profile, deleting an account or replacing a device.

In server mode, organizations are under Account settings. A Host's **Share…** action supports members/teams or temporary access when the server advertises those capabilities. See [sharing](SHARING.en.md). Browser regular SSH requires a configured Relay; temporary guest links require the separate trusted gateway.

## 5. Keep the workspace useful

Group Hosts, save reusable commands, adjust terminal palettes/key bindings and save layouts in the app's settings/sidebar. Terminals color words such as `error`, `warning` and `ok`, IP addresses and links in plain output; tune or switch this off under Settings → Theme → Keyword highlighting ([details](FEATURES.md#terminal-keyword-highlighting--终端关键词高亮)). Use the SSH forwarding entry to manage rules; creating a rule does not start a tunnel until you activate it. Browser builds cannot open OS TCP listeners. Mobile foreground/background limits can interrupt live tunnels and sessions.

If a connection fails, use the session/log information and [troubleshooting](TROUBLESHOOTING.en.md). Do not put passwords, private keys or complete access links in issue reports.
