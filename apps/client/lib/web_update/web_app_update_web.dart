import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'web_app_update_monitor.dart';

@JS('atermiusWebBuildId')
external JSString get _currentBuildId;

@JS('atermiusProbeWebBuild')
external JSPromise<JSString> _probeWebBuild();

@JS('atermiusPrepareWebBuild')
external JSPromise<JSString> _prepareWebBuild(JSString buildId);

@JS('atermiusActivateWebBuild')
external JSPromise<JSAny?> _activateWebBuild(JSString buildId);

WebAppUpdateMonitor createWebAppUpdateMonitor() => WebAppUpdateMonitor(
  currentBuildId: _currentBuildId.toDart,
  probeBuildId: () async => (await _probeWebBuild().toDart).toDart,
  reload: () async => web.window.location.reload(),
  // Completes for 'ready' and for 'unsupported' (no bundle cache in this
  // browser: the reload fetches the new build from the server as before).
  prepareBuild: (buildId) async {
    await _prepareWebBuild(buildId.toJS).toDart;
  },
  activateBuild: (buildId) async {
    await _activateWebBuild(buildId.toJS).toDart;
  },
);
