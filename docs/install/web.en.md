# Build and deploy the browser frontend

[中文](web.md) · [Install overview](../INSTALLATION.en.md) · [README](../../README.md)

First complete repository access, cloning and the Flutter toolchain in the [install overview](../INSTALLATION.en.md). Every command below starts from the repository root.

## Build the site

```sh
cd apps/client
flutter pub get --enforce-lockfile
flutter build web --release --no-web-resources-cdn
dart run tool/web_cache_manifest.dart build/web
```

The second command writes `atermius-cache-manifest.json` (build identifier and SHA-256 of every file). With it the browser keeps a complete copy of the bundle:

- A second visit starts from the browser's cache instead of downloading the bundle again. Only files named in the manifest are stored, each checked against its hash; API answers, guest share pages and join links are never cached.
- When the server has a newer build, the open page keeps running its current build and downloads the new one in the background. Only once the new build is completely stored does the page offer the update; the reload the user confirms then starts from the stored new build. A reload before that still shows the old build.
- The cache needs a secure origin (HTTPS or `localhost`). Over plain `http://`, in a browser without service workers, or for a bundle built without the manifest, nothing is cached and the page loads from the server as before.

Serve `atermius-sw.js`, `flutter_bootstrap.js` and `atermius-cache-manifest.json` with `Cache-Control: no-cache` (the bundled `deploy/nginx.conf` does), and replace all files of a deployment together.

Deploy the complete **`apps/client/build/web/`** output. `--no-web-resources-cdn` keeps CanvasKit same-origin; the repository also bundles Unicode fallback fonts and their notices. Use a real HTTP server, not `file://`.

## Deploy with the API

The browser build belongs to the server that serves it: it opens straight on that server's sign-in page and asks only for the account and password. It has no local mode and no server address to type or change; the address is always the page's own origin (scheme, host and port). First-account setup, invited registration and account recovery remain on the sign-in page. When the page was loaded over plain `http://` from another computer the client still connects, and keeps the “Insecure connection” warning on screen. Local mode exists only in the desktop and mobile clients.

The recommended setup is the [server installation guide](server.en.md). The API and the frontend now live in the same repository: the server's `deploy/compose.web.yaml` builds the frontend image from the root `Dockerfile` and provides one browser origin for API/WebSocket traffic. A sibling `web` checkout is no longer needed.

For a manual image build, from the repository root:

```sh
docker build -t atermius-web:local .
```

The image listens on port **8080**, runs as nginx with `deploy/nginx.conf` and expects `server:8080` on its Docker network. A standalone `docker run` with no API service is not a complete deployment. Use the server Compose stack for networking, TLS and persistent API data. No published GHCR image or public hosted instance is assumed.

## Guest links and regular SSH

The supplied nginx serves `/s/*` and `/join` with no-store/referrer/CSP headers and proxies `/gateway/*` with WebSocket upgrade support. Preserve `share-bootstrap.js` before Flutter; it removes access-link fragments before routing/requests. Generic static hosting without these routes/proxy headers is insufficient for guest access.

Regular signed-in browser SSH needs the server Relay to be enabled. Guest SSH/RDP instead requires the separate trusted gateway. Cloud collaboration is SQLite-only; guest cookies require HTTPS. Local browser profiles cannot open direct OS TCP or local shells.

## Verify the built runtime

From the repository root, with Docker available:

```sh
python3 tools/verify_cloud_proxy.py --web-root apps/client/build/web
```

This starts only disposable loopback fixtures and checks real nginx headers, API forwarding and a WebSocket echo. It does not deploy a public service or replace a real guest/target test.

Before updating an existing build, read "Update an existing build" in the [install overview](../INSTALLATION.en.md).

[First use](../GETTING_STARTED.en.md) · [Troubleshooting](../TROUBLESHOOTING.en.md) · [Developer checks](../DEVELOPMENT.md)
