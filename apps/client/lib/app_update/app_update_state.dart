import 'dart:convert';
import 'dart:io';

import 'app_update_backend.dart';

/// What the updater remembers between runs, in one small JSON file shared by
/// every window of the user.
class AppUpdateState {
  AppUpdateState._(this._file);

  final File _file;

  /// The release that is ready to switch to.
  AppUpdateStaged? staged;

  /// The release whose installation last failed, and how often.
  String? failedTag;
  int failures = 0;

  /// Releases that are never tried again.
  Set<String> blocked = {};

  /// Outcome of the last switch, until the app has shown it.
  AppUpdateResult? result;

  static AppUpdateState read(File file) {
    final state = AppUpdateState._(file);
    try {
      if (!file.existsSync() || file.lengthSync() > 256 * 1024) return state;
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map) return state;
      state.staged = AppUpdateStaged.fromJson(json['staged']);
      final failed = json['failed'];
      if (failed is Map && failed['tag'] is String && failed['count'] is int) {
        state.failedTag = failed['tag'] as String;
        state.failures = failed['count'] as int;
      }
      final blocked = json['blocked'];
      if (blocked is List) state.blocked = blocked.whereType<String>().toSet();
      state.result = AppUpdateResult.fromJson(json['result']);
    } catch (_) {
      // An unreadable state is the same as none: the update is found again.
    }
    return state;
  }

  /// Replaces the file in one step so a reader never sees half of it.
  void write() {
    _file.parent.createSync(recursive: true);
    final next = File('${_file.path}.$pid.tmp');
    next.writeAsStringSync(
      jsonEncode({
        'v': 1,
        if (staged != null) 'staged': staged!.toJson(),
        if (failedTag != null) 'failed': {'tag': failedTag, 'count': failures},
        if (blocked.isNotEmpty) 'blocked': blocked.toList()..sort(),
        if (result != null) 'result': result!.toJson(),
      }),
      flush: true,
    );
    next.renameSync(_file.path);
  }
}
