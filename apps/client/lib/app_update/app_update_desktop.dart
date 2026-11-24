import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'app_update_backend.dart';
import 'app_update_channel.dart';
import 'app_update_download.dart';
import 'app_update_state.dart';
import 'release_tag.dart';

// How a desktop copy of Atermius replaces itself
// ----------------------------------------------
// 1. While the app runs, the new release is downloaded, verified and
//    unpacked next to the updater's state (never into the installed copy).
// 2. To switch, the *new* version is started from that unpacked copy with
//    [appUpdateApplyFlag]. It waits until the installed copy is no longer in
//    use, moves the old program files aside, copies itself in, and starts the
//    installed copy again. If anything fails the old files are moved back.
// 3. The switch happens when the user restarts from the banner, or by itself
//    the next time the app is started.
// Only one process may run from the installed directory while it is being
// replaced; [AppUpdateInstanceLock] is how the windows of one user know
// about each other.

const _flagPrefix = '--atermius-update-';

/// Starts the unpacked new version as the installer of itself.
const appUpdateApplyFlag = '${_flagPrefix}apply';

/// Set on the app when an attempt to switch just ended: do not try again
/// during this start.
const appUpdateSkipFlag = '${_flagPrefix}skip';
const _installArg = '${_flagPrefix}install=';
const _rootArg = '${_flagPrefix}root=';
const _tagArg = '${_flagPrefix}tag=';
const _pidArg = '${_flagPrefix}pid=';

/// How often one release may be tried before it is skipped for good.
const _maxAttempts = 2;
final _safeTag = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$');

/// Where the updater keeps its files and which installed copy it serves.
class AppUpdateDesktopLayout {
  AppUpdateDesktopLayout({
    required this.root,
    required this.installDir,
    required this.executableName,
    bool? windows,
  }) : windows = windows ?? Platform.isWindows;

  /// Null when this platform or environment has no place for updates.
  static AppUpdateDesktopLayout? current() {
    final env = Platform.environment;
    String? base;
    if (Platform.isWindows) {
      base = env['LOCALAPPDATA'];
      if (base != null && base.isNotEmpty) base = p.join(base, 'Atermius');
    } else if (Platform.isLinux) {
      final cache = env['XDG_CACHE_HOME'], home = env['HOME'];
      if (cache != null && p.isAbsolute(cache)) {
        base = p.join(cache, 'atermius');
      } else if (home != null && p.isAbsolute(home)) {
        base = p.join(home, '.cache', 'atermius');
      }
    }
    if (base == null || base.isEmpty) return null;
    final executable = File(Platform.resolvedExecutable);
    return AppUpdateDesktopLayout(
      root: Directory(p.join(base, 'updates')),
      installDir: executable.parent,
      executableName: p.basename(executable.path),
    );
  }

  final Directory root;
  final Directory installDir;
  final String executableName;
  final bool windows;

  File get stateFile => File(p.join(root.path, 'state.json'));
  File get instanceLockFile => File(p.join(root.path, 'instances.lock'));
  File get workLockFile => File(p.join(root.path, 'download.lock'));
  File get ackFile => File(p.join(root.path, 'switch.ack'));
  Directory releaseDir(String tag) => Directory(p.join(root.path, tag));
  Directory get backupDir =>
      Directory(p.join(installDir.path, '.atermius-old'));
  String get installedExecutable => p.join(installDir.path, executableName);

  /// A complete unpacked copy of the app for this platform.
  bool isBundle(Directory dir) =>
      File(p.join(dir.path, executableName)).existsSync() &&
      Directory(p.join(dir.path, 'data', 'flutter_assets')).existsSync() &&
      File(
        windows
            ? p.join(dir.path, 'data', 'app.so')
            : p.join(dir.path, 'lib', 'libapp.so'),
      ).existsSync();
}

/// The staged release when it is usable and newer than [currentTag].
AppUpdateStaged? _usable(
  AppUpdateState state,
  AppUpdateDesktopLayout layout,
  String currentTag,
) {
  final staged = state.staged;
  if (staged == null ||
      !_safeTag.hasMatch(staged.release.tag) ||
      state.blocked.contains(staged.release.tag) ||
      !isNewerRelease(staged.release.tag, currentTag)) {
    return null;
  }
  final dir = Directory(staged.path);
  // Only ever a copy this updater unpacked itself.
  if (!p.equals(
        dir.path,
        p.join(layout.releaseDir(staged.release.tag).path, 'app'),
      ) ||
      !layout.isBundle(dir)) {
    return null;
  }
  return staged;
}

Future<void> _unpackInBackground(String package, String outDir) =>
    // Its own function: the closure must not capture anything but strings.
    Isolate.run(() => unpackAppUpdatePackage(package, outDir));

/// Lets the main windows of one user see each other across processes: each
/// holds a shared lock for as long as it runs, and whoever gets the lock
/// exclusively knows it is alone. Remote-desktop and terminal child windows
/// do not take part; they end with the window that opened them.
class AppUpdateInstanceLock {
  AppUpdateInstanceLock(this._path);

  final File _path;
  RandomAccessFile? _file;

  RandomAccessFile _open() {
    _path.parent.createSync(recursive: true);
    // Kept open for the life of the process: on POSIX closing any handle of
    // the file would drop the lock.
    return _file ??= _path.openSync(mode: FileMode.append);
  }

  /// Drops this process's share and tries to be the only holder.
  bool tryExclusive() {
    try {
      final file = _open();
      try {
        file.unlockSync();
      } on FileSystemException {
        // Nothing was held.
      }
      file.lockSync(FileLock.exclusive);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Marks this process as a running window. Best effort.
  void share() {
    try {
      final file = _open();
      try {
        file.unlockSync();
      } on FileSystemException {
        // Nothing was held.
      }
      file.lockSync(FileLock.shared);
    } on FileSystemException {
      // An installer holds it right now; this window then goes uncounted.
    }
  }

  void release() {
    final file = _file;
    _file = null;
    try {
      file?.closeSync();
    } on FileSystemException {
      // Already gone.
    }
  }
}

AppUpdateState _read(AppUpdateDesktopLayout layout) =>
    AppUpdateState.read(layout.stateFile);

AppUpdateInstanceLock? _processLock;
AppUpdateDesktopLayout? _processLayout;

AppUpdateInstanceLock? _instanceLock(AppUpdateDesktopLayout layout) =>
    _processLock ??= AppUpdateInstanceLock(layout.instanceLockFile);

bool get _desktop => Platform.isWindows || Platform.isLinux;

/// First thing in `main`. Returns the arguments without the updater's own.
///
/// * Started as the installer of itself ([appUpdateApplyFlag]): replaces the
///   installed copy and never returns.
/// * Started normally while a newer release is unpacked and nothing else of
///   Atermius runs: hands over to that release and never returns.
Future<List<String>> appUpdateStartup(List<String> arguments) async {
  final own = arguments.where((a) => a.startsWith(_flagPrefix)).toList();
  final rest = arguments.where((a) => !a.startsWith(_flagPrefix)).toList();
  if (!_desktop) return rest;
  if (own.contains(appUpdateApplyFlag)) {
    exit(await runAppUpdateSwitch(own, rest));
  }
  try {
    final layout = _processLayout = AppUpdateDesktopLayout.current();
    // Only a plain start of a release build switches by itself: extra
    // windows and file windows belong to an app that is already running.
    if (layout == null ||
        atermiusReleaseTag.isEmpty ||
        rest.isNotEmpty ||
        own.contains(appUpdateSkipFlag) ||
        !layout.stateFile.existsSync()) {
      return rest;
    }
    final staged = _usable(_read(layout), layout, atermiusReleaseTag);
    if (staged == null || !_writable(layout.installDir)) return rest;
    final lock = _instanceLock(layout)!;
    if (!lock.tryExclusive()) return rest;
    if (await _handOver(layout, staged, const [])) {
      lock.release();
      exit(0);
    }
    lock.release();
    _processLock = null;
  } catch (_) {
    // Updating must never keep the app from starting.
  }
  return rest;
}

/// Called once the process is known to be a main window: counts it as a
/// running window for other processes.
void appUpdateHoldInstance() {
  if (!_desktop || atermiusReleaseTag.isEmpty) return;
  try {
    final layout = _processLayout ??= AppUpdateDesktopLayout.current();
    if (layout != null) _instanceLock(layout)!.share();
  } catch (_) {
    // Best effort.
  }
}

bool _writable(Directory dir) {
  try {
    final probe = File(p.join(dir.path, '.atermius-write-test-$pid'));
    probe.writeAsBytesSync(const [], flush: true);
    probe.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Starts the staged version as installer and waits until it reports that
/// it is running. False (and the release blocked) when it never does: the
/// current version then simply keeps running.
Future<bool> _handOver(
  AppUpdateDesktopLayout layout,
  AppUpdateStaged staged,
  List<String> restartArguments, {
  Duration ackTimeout = const Duration(seconds: 20),
}) async {
  final ack = layout.ackFile;
  try {
    if (ack.existsSync()) ack.deleteSync();
  } on FileSystemException {
    // A stale acknowledgement only matters if it names this release.
  }
  // Counted before the attempt: if the installer dies without a word, the
  // next start must not hand over to it for ever.
  try {
    final state = _read(layout);
    final tag = staged.release.tag;
    final attempts = state.failedTag == tag ? state.failures : 0;
    if (attempts >= _maxAttempts) {
      _block(layout, tag);
      return false;
    }
    state
      ..failedTag = tag
      ..failures = attempts + 1
      ..write();
  } on FileSystemException {
    return false;
  }
  final Process process;
  try {
    process = await Process.start(
      p.join(staged.path, layout.executableName),
      [
        appUpdateApplyFlag,
        '$_installArg${layout.installDir.path}',
        '$_rootArg${layout.root.path}',
        '$_tagArg${staged.release.tag}',
        '$_pidArg$pid',
        ...restartArguments,
      ],
      workingDirectory: staged.path,
      mode: ProcessStartMode.detached,
    );
  } on ProcessException {
    _block(layout, staged.release.tag);
    return false;
  }
  final deadline = DateTime.now().add(ackTimeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    try {
      if (ack.existsSync() &&
          ack.readAsStringSync().trim() == staged.release.tag) {
        return true;
      }
    } on FileSystemException {
      // Being written; read again.
    }
  }
  // The new version cannot even start here: never try it again.
  Process.killPid(process.pid);
  _block(layout, staged.release.tag);
  return false;
}

void _block(AppUpdateDesktopLayout layout, String tag) {
  try {
    final state = _read(layout);
    state.blocked.add(tag);
    if (state.staged?.release.tag == tag) state.staged = null;
    state.result = AppUpdateResult(tag: tag, succeeded: false);
    state.write();
  } catch (_) {
    // Nothing else to do; the next check will find it again.
  }
}

/// The installer side: runs in the new version, started from its unpacked
/// copy. Returns the process exit code.
Future<int> runAppUpdateSwitch(List<String> own, List<String> rest) async {
  String? value(String prefix) {
    final match = own.where((a) => a.startsWith(prefix));
    return match.length == 1 ? match.single.substring(prefix.length) : null;
  }

  final install = value(_installArg),
      root = value(_rootArg),
      tag = value(_tagArg);
  if (install == null ||
      root == null ||
      tag == null ||
      !_safeTag.hasMatch(tag) ||
      !p.isAbsolute(install) ||
      !p.isAbsolute(root)) {
    return 64;
  }
  final executable = File(Platform.resolvedExecutable);
  final layout = AppUpdateDesktopLayout(
    root: Directory(root),
    installDir: Directory(install),
    executableName: p.basename(executable.path),
  );
  final staged = executable.parent;
  final oldPid = int.tryParse(value(_pidArg) ?? '');
  var outcome = AppUpdateSwitchOutcome.failed;
  try {
    layout.ackFile.writeAsStringSync(tag, flush: true);
    outcome = await switchInstalledCopy(
      layout: layout,
      staged: staged,
      tag: tag,
      oldPid: oldPid,
    );
  } catch (_) {
    outcome = AppUpdateSwitchOutcome.failed;
  }
  try {
    final state = _read(layout);
    switch (outcome) {
      case AppUpdateSwitchOutcome.done:
        state
          ..result = AppUpdateResult(tag: tag, succeeded: true)
          ..failedTag = null
          ..failures = 0;
      case AppUpdateSwitchOutcome.busy:
        // Nothing changed and nothing is wrong with the release: the
        // attempt does not count and the banner offers the restart again.
        if (state.failedTag == tag && state.failures > 0) state.failures--;
      case AppUpdateSwitchOutcome.failed:
        // Already counted when the attempt started.
        state.result = AppUpdateResult(tag: tag, succeeded: false);
        if (state.failedTag == tag && state.failures >= _maxAttempts) {
          state.blocked.add(tag);
          state.staged = null;
        }
    }
    state.write();
  } catch (_) {
    // The app starts either way.
  }
  try {
    if (layout.ackFile.existsSync()) layout.ackFile.deleteSync();
  } on FileSystemException {
    // Harmless leftover.
  }
  // Whatever happened, the installed copy (new, or the old one moved back)
  // is started again, told not to try once more during this start.
  try {
    await Process.start(
      layout.installedExecutable,
      [appUpdateSkipFlag, ...rest],
      workingDirectory: layout.installDir.path,
      mode: ProcessStartMode.detached,
    );
  } on ProcessException {
    return 70;
  }
  return outcome == AppUpdateSwitchOutcome.done ? 0 : 1;
}

/// How replacing the installed copy ended. [busy]: something still runs
/// from it and nothing was changed.
enum AppUpdateSwitchOutcome { done, busy, failed }

/// Replaces the program files in [AppUpdateDesktopLayout.installDir] with
/// the ones in [staged]. Other files in that directory are left alone.
Future<AppUpdateSwitchOutcome> switchInstalledCopy({
  required AppUpdateDesktopLayout layout,
  required Directory staged,
  required String tag,
  int? oldPid,
  Duration waitForExit = const Duration(seconds: 40),
}) async {
  if (p.equals(staged.path, layout.installDir.path) ||
      !layout.isBundle(staged) ||
      !layout.isBundle(layout.installDir)) {
    return AppUpdateSwitchOutcome.failed;
  }
  final lock = AppUpdateInstanceLock(layout.instanceLockFile);
  try {
    final deadline = DateTime.now().add(waitForExit);
    // The window that started us is closing; nothing else may be running.
    while (!lock.tryExclusive() || !_installedCopyIdle(layout, oldPid)) {
      if (DateTime.now().isAfter(deadline)) return AppUpdateSwitchOutcome.busy;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return _replaceProgramFiles(layout, staged)
        ? AppUpdateSwitchOutcome.done
        : AppUpdateSwitchOutcome.failed;
  } finally {
    lock.release();
  }
}

bool _installedCopyIdle(AppUpdateDesktopLayout layout, int? oldPid) {
  if (layout.windows) {
    // Windows refuses write access to a program that is still running.
    try {
      File(layout.installedExecutable).openSync(mode: FileMode.append).closeSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }
  return oldPid == null || !Directory('/proc/$oldPid').existsSync();
}

bool _replaceProgramFiles(AppUpdateDesktopLayout layout, Directory staged) {
  final install = layout.installDir, backup = layout.backupDir;
  // Exactly the top-level entries the new version ships; anything else in
  // the directory is not ours to touch.
  final names = [
    for (final entity in staged.listSync(followLinks: false))
      p.basename(entity.path),
  ];
  final moved = <String>[];
  try {
    if (backup.existsSync()) _retry(() => backup.deleteSync(recursive: true));
    backup.createSync();
    for (final name in names) {
      final current = p.join(install.path, name);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      final target = p.join(backup.path, name);
      _retry(
        () => type == FileSystemEntityType.directory
            ? Directory(current).renameSync(target)
            : File(current).renameSync(target),
      );
      moved.add(name);
    }
    for (final name in names) {
      _copy(p.join(staged.path, name), p.join(install.path, name));
    }
    if (!layout.isBundle(install)) {
      throw const FileSystemException('incomplete');
    }
  } catch (_) {
    // Put the previous version back exactly as it was.
    for (final name in names) {
      final partial = p.join(install.path, name);
      try {
        final type = FileSystemEntity.typeSync(partial, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          Directory(partial).deleteSync(recursive: true);
        } else if (type != FileSystemEntityType.notFound) {
          File(partial).deleteSync();
        }
      } on FileSystemException {
        // The move back below reports what could not be restored.
      }
    }
    for (final name in moved) {
      final saved = p.join(backup.path, name), current = p.join(install.path, name);
      try {
        _retry(
          () => FileSystemEntity.isDirectorySync(saved)
              ? Directory(saved).renameSync(current)
              : File(saved).renameSync(current),
        );
      } on FileSystemException {
        // Left in the backup directory.
      }
    }
    return false;
  }
  try {
    backup.deleteSync(recursive: true);
  } on FileSystemException {
    // Removed by the app's cleanup later.
  }
  return true;
}

void _copy(String from, String to) {
  if (FileSystemEntity.isDirectorySync(from)) {
    Directory(to).createSync(recursive: true);
    for (final entity in Directory(from).listSync(followLinks: false)) {
      _copy(entity.path, p.join(to, p.basename(entity.path)));
    }
    return;
  }
  final source = File(from);
  _retry(() => source.copySync(to));
  if (File(to).lengthSync() != source.lengthSync()) {
    throw FileSystemException('short copy', to);
  }
}

/// Antivirus scanners and indexers briefly hold freshly written files.
void _retry(void Function() action) {
  for (var attempt = 0; ; attempt++) {
    try {
      action();
      return;
    } on FileSystemException {
      if (attempt >= 12) rethrow;
      sleep(const Duration(milliseconds: 250));
    }
  }
}

/// Unpacks a release package into [outDir], which must not exist yet. Runs
/// synchronously; call it from a background isolate.
///
/// Every entry has to stay inside [outDir]; links are refused. A single
/// top-level directory, as the release archives have, is dropped.
void unpackAppUpdatePackage(String package, String outDir) {
  const maxEntries = 20000, maxBytes = 2 * 1024 * 1024 * 1024;
  final out = Directory(outDir)..createSync(recursive: true);
  final scratch = <File>[];
  final streams = <InputFileStream>[];
  Archive? archive;
  try {
    final lower = package.toLowerCase();
    if (lower.endsWith('.zip')) {
      final input = InputFileStream(package);
      streams.add(input);
      archive = ZipDecoder().decodeStream(input);
    } else if (lower.endsWith('.tar.gz')) {
      final tar = File('$outDir.tar');
      scratch.add(tar);
      final input = InputFileStream(package);
      streams.add(input);
      final output = OutputFileStream(tar.path);
      try {
        GZipDecoder().decodeStream(input, output);
      } finally {
        output.closeSync();
      }
      final tarInput = InputFileStream(tar.path);
      streams.add(tarInput);
      archive = TarDecoder().decodeStream(tarInput);
    } else {
      throw const FormatException('unknown package type');
    }
    if (archive.length > maxEntries) {
      throw const FormatException('too many entries');
    }
    final entries = <(List<String>, ArchiveFile)>[];
    var total = 0;
    for (final entry in archive) {
      if (entry.isSymbolicLink) throw const FormatException('link in package');
      final parts = entry.name
          .replaceAll('\\', '/')
          .split('/')
          .where((part) => part.isNotEmpty && part != '.')
          .toList();
      if (parts.isEmpty) continue;
      if (entry.name.startsWith('/') ||
          parts.any(
            (part) =>
                part == '..' ||
                part.contains(':') ||
                part.contains(RegExp(r'[\x00-\x1f]')),
          )) {
        throw const FormatException('unsafe path in package');
      }
      if (entry.isFile) {
        total += entry.size;
        if (total > maxBytes) throw const FormatException('package too large');
      }
      entries.add((parts, entry));
    }
    final roots = {for (final (parts, _) in entries) parts.first};
    final strip =
        roots.length == 1 &&
        entries.every((e) => e.$1.length > 1 || !e.$2.isFile);
    final executables = <String>[];
    for (final (parts, entry) in entries) {
      final relative = strip ? parts.sublist(1) : parts;
      if (relative.isEmpty) continue;
      final path = p.joinAll([out.path, ...relative]);
      if (!p.isWithin(out.path, path)) {
        throw const FormatException('unsafe path in package');
      }
      if (!entry.isFile) {
        Directory(path).createSync(recursive: true);
        continue;
      }
      Directory(p.dirname(path)).createSync(recursive: true);
      final output = OutputFileStream(path);
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      if (File(path).lengthSync() != entry.size) {
        throw const FormatException('damaged package');
      }
      if (!Platform.isWindows && entry.unixPermissions & 0x49 != 0) {
        executables.add(path);
      }
    }
    if (executables.isNotEmpty) {
      final chmod = Process.runSync('chmod', ['755', ...executables]);
      if (chmod.exitCode != 0) throw const FormatException('chmod failed');
    }
  } finally {
    archive?.clearSync();
    for (final stream in streams) {
      stream.closeSync();
    }
    for (final file in scratch) {
      try {
        if (file.existsSync()) file.deleteSync();
      } on FileSystemException {
        // Removed with the release directory.
      }
    }
  }
}

/// The updater on Windows and Linux.
class DesktopAppUpdateBackend implements AppUpdateBackend {
  DesktopAppUpdateBackend({
    required this.layout,
    required http.Client client,
    required Future<void> Function() quit,
    this.currentTag = atermiusReleaseTag,
    this.switchAckTimeout = const Duration(seconds: 20),
    AppUpdateInstanceLock? instanceLock,
  }) : _client = client,
       _quit = quit,
       _lock = instanceLock ?? _instanceLock(layout)!;

  final AppUpdateDesktopLayout layout;

  /// The release this process runs.
  final String currentTag;

  /// How long the new version gets to report that it started.
  final Duration switchAckTimeout;
  final http.Client _client;
  final Future<void> Function() _quit;
  final AppUpdateInstanceLock _lock;

  @override
  Future<bool> canInstall() async =>
      layout.isBundle(layout.installDir) && _writable(layout.installDir);

  @override
  Future<AppUpdateStaged?> staged(String currentTag) async =>
      _usable(_read(layout), layout, currentTag);

  @override
  Future<Set<String>> blockedTags() async => _read(layout).blocked;

  @override
  Future<AppUpdateResult?> takeResult() async {
    final state = _read(layout);
    final result = state.result;
    if (result == null) return null;
    state.result = null;
    try {
      state.write();
    } on FileSystemException {
      // Reported again next time.
    }
    return result;
  }

  @override
  Future<bool> metered() async => false;

  @override
  Stream<AppUpdateApplyProblem> get problems => const Stream.empty();

  @override
  Future<AppUpdateStaged?> stage(
    AppUpdateRelease release, {
    required void Function(double fraction) onProgress,
  }) async {
    if (!_safeTag.hasMatch(release.tag)) {
      throw const FormatException('unexpected release tag');
    }
    return _exclusiveWork(() async {
      final current = _read(layout);
      final ready = current.staged;
      if (ready != null &&
          ready.release.tag == release.tag &&
          layout.isBundle(Directory(ready.path))) {
        return ready;
      }
      final dir = layout.releaseDir(release.tag);
      final package = File(p.join(dir.path, release.assetName));
      await downloadVerified(
        client: _client,
        url: release.assetUrl,
        target: package,
        size: release.size,
        sha256Hex: release.sha256,
        onProgress: (received) => onProgress(received / release.size),
      );
      final app = Directory(p.join(dir.path, 'app'));
      final unpacking = Directory(p.join(dir.path, 'app.unpacking'));
      for (final leftover in [app, unpacking]) {
        if (await leftover.exists()) await leftover.delete(recursive: true);
      }
      await _unpackInBackground(package.path, unpacking.path);
      if (!layout.isBundle(unpacking)) {
        await unpacking.delete(recursive: true);
        await package.delete();
        throw const FormatException('package is not an Atermius bundle');
      }
      await unpacking.rename(app.path);
      await package.delete();
      final staged = AppUpdateStaged(release: release, path: app.path);
      _read(layout)
        ..staged = staged
        ..write();
      await _removeReleaseDirs(keep: (tag) => tag == release.tag);
      return staged;
    });
  }

  @override
  Future<AppUpdateApplyProblem?> apply(AppUpdateStaged staged) async {
    final usable = _usable(_read(layout), layout, currentTag);
    if (usable == null || usable.release.tag != staged.release.tag) {
      return AppUpdateApplyProblem.stagedMissing;
    }
    if (!_lock.tryExclusive()) {
      _lock.share();
      return AppUpdateApplyProblem.otherWindowsOpen;
    }
    // The installer takes the lock over as soon as this process lets go.
    if (!await _handOver(
      layout,
      usable,
      const [],
      ackTimeout: switchAckTimeout,
    )) {
      _lock.share();
      return AppUpdateApplyProblem.failed;
    }
    _lock.release();
    await _quit();
    return null;
  }

  @override
  Future<void> cleanup(String currentTag) async {
    await _exclusiveWork(() async {
      final state = _read(layout);
      final keep = _usable(state, layout, currentTag)?.release.tag;
      if (state.staged != null && keep == null) {
        state
          ..staged = null
          ..write();
      }
      // Kept: the staged release, and a newer one that is still downloading.
      await _removeReleaseDirs(
        keep: (tag) =>
            tag == keep ||
            (!state.blocked.contains(tag) &&
                isNewerRelease(tag, keep ?? currentTag)),
      );
      try {
        if (await layout.backupDir.exists()) {
          await layout.backupDir.delete(recursive: true);
        }
      } on FileSystemException {
        // Not writable or in use.
      }
      return null;
    });
  }

  Future<void> _removeReleaseDirs({required bool Function(String) keep}) async {
    if (!await layout.root.exists()) return;
    await for (final entity in layout.root.list(followLinks: false)) {
      if (entity is! Directory || keep(p.basename(entity.path))) continue;
      try {
        await entity.delete(recursive: true);
      } on FileSystemException {
        // Still in use; removed next time.
      }
    }
  }

  /// Runs [work] unless another window of this user is already downloading
  /// or cleaning up; null then.
  Future<T?> _exclusiveWork<T>(Future<T?> Function() work) async {
    await layout.root.create(recursive: true);
    final handle = await layout.workLockFile.open(mode: FileMode.append);
    try {
      try {
        await handle.lock(FileLock.exclusive);
      } on FileSystemException {
        return null;
      }
      return await work();
    } finally {
      await handle.close();
    }
  }
}
