import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'app_update_backend.dart';
import 'app_update_channel.dart';
import 'app_update_download.dart';
import 'app_update_state.dart';
import 'release_tag.dart';

/// Text of the notification Android shows once the new version is
/// installed (the app cannot reopen itself).
typedef AppUpdateDoneNotice = ({String title, String body});

/// The updater on Android: the verified package waits in the app's cache;
/// the system installer replaces the app when the user restarts from the
/// banner. Android ends the app's process as part of that.
class AndroidAppUpdateBackend implements AppUpdateBackend {
  AndroidAppUpdateBackend({
    required http.Client client,
    required Future<Directory> Function() cacheDirectory,
    required AppUpdateDoneNotice Function() doneNotice,
    MethodChannel channel = const MethodChannel('atermius/app_update'),
  }) : _client = client,
       _cacheDirectory = cacheDirectory,
       _doneNotice = doneNotice,
       _channel = channel {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'installStatus') return;
      _problems.add(
        call.arguments == 'cancelled'
            ? AppUpdateApplyProblem.cancelled
            : AppUpdateApplyProblem.failed,
      );
    });
  }

  final http.Client _client;
  final Future<Directory> Function() _cacheDirectory;
  final AppUpdateDoneNotice Function() _doneNotice;
  final MethodChannel _channel;
  final _problems = StreamController<AppUpdateApplyProblem>.broadcast();
  static final _safeTag = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$');

  Future<Directory> _root() async =>
      Directory(p.join((await _cacheDirectory()).path, 'app-updates'));

  Future<AppUpdateState> _state() async =>
      AppUpdateState.read(File(p.join((await _root()).path, 'state.json')));

  @override
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('supported') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<AppUpdateStaged?> staged(String currentTag) async {
    final staged = (await _state()).staged;
    if (staged == null || !isNewerRelease(staged.release.tag, currentTag)) {
      return null;
    }
    // Verified when it was stored; the cache may have been cleared since.
    final file = File(staged.path);
    if (!p.isWithin((await _root()).path, file.path) ||
        !await file.exists() ||
        await file.length() != staged.release.size) {
      return null;
    }
    return staged;
  }

  @override
  Future<Set<String>> blockedTags() async => (await _state()).blocked;

  @override
  Future<AppUpdateResult?> takeResult() async => null;

  @override
  Future<bool> metered() async {
    try {
      return await _channel.invokeMethod<bool>('metered') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Stream<AppUpdateApplyProblem> get problems => _problems.stream;

  @override
  Future<AppUpdateStaged?> stage(
    AppUpdateRelease release, {
    required void Function(double fraction) onProgress,
  }) async {
    if (!_safeTag.hasMatch(release.tag) ||
        release.assetName.contains(RegExp(r'[/\\]'))) {
      throw const FormatException('unexpected release');
    }
    final root = await _root();
    final package = File(p.join(root.path, release.tag, release.assetName));
    await downloadVerified(
      client: _client,
      url: release.assetUrl,
      target: package,
      size: release.size,
      sha256Hex: release.sha256,
      onProgress: (received) => onProgress(received / release.size),
    );
    final staged = AppUpdateStaged(release: release, path: package.path);
    (await _state())
      ..staged = staged
      ..write();
    await _removeOthers(root, keep: release.tag);
    return staged;
  }

  @override
  Future<AppUpdateApplyProblem?> apply(AppUpdateStaged staged) async {
    if (await this.staged('') == null &&
        !await File(staged.path).exists()) {
      return AppUpdateApplyProblem.stagedMissing;
    }
    final notice = _doneNotice();
    try {
      await _channel.invokeMethod<void>('install', {
        'path': staged.path,
        'doneTitle': notice.title,
        'doneBody': notice.body,
      });
      return null;
    } on PlatformException catch (error) {
      if (error.code == 'not_newer' || error.code == 'invalid_package') {
        // This package can never be installed over the running app.
        final state = await _state();
        state
          ..blocked.add(staged.release.tag)
          ..staged = null
          ..write();
        return AppUpdateApplyProblem.stagedMissing;
      }
      return AppUpdateApplyProblem.failed;
    } on MissingPluginException {
      return AppUpdateApplyProblem.failed;
    }
  }

  @override
  Future<void> cleanup(String currentTag) async {
    final root = await _root();
    final state = await _state();
    final keep = (await staged(currentTag))?.release.tag;
    if (state.staged != null && keep == null) {
      state
        ..staged = null
        ..write();
    }
    // A newer partial download is kept so it can continue.
    await _removeOthers(
      root,
      keep: keep,
      also: (tag) =>
          !state.blocked.contains(tag) &&
          isNewerRelease(tag, keep ?? currentTag),
    );
  }

  Future<void> _removeOthers(
    Directory root, {
    required String? keep,
    bool Function(String tag)? also,
  }) async {
    if (!await root.exists()) return;
    await for (final entity in root.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is! Directory || name == keep || (also?.call(name) ?? false)) {
        continue;
      }
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        // Removed next time.
      }
    }
  }
}
