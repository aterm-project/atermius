@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:aterm_client/app_update/app_update_backend.dart';
import 'package:aterm_client/app_update/app_update_channel.dart';
import 'package:aterm_client/app_update/app_update_desktop.dart';
import 'package:aterm_client/app_update/app_update_download.dart';
import 'package:aterm_client/app_update/app_update_state.dart';
import 'package:aterm_client/app_update/release_marker.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:path/path.dart' as p;

const _current = 'local-20261124.2-178e1a78f57b';
const _next = 'local-20261124.3-0123456789ab';

/// The files of a Linux release, with [marker] in each so versions differ.
Map<String, String> _bundle(String marker, {Map<String, String> extra = const {}}) =>
    {
      'aterm_client': '#!/bin/sh\necho $marker\n',
      // A real build carries its release tag in its compiled program.
      'lib/libapp.so': 'app $marker built as $_next',
      'lib/libflutter_linux_gtk.so': 'engine $marker',
      'data/icudtl.dat': 'icu $marker',
      'data/flutter_assets/AssetManifest.bin': 'assets $marker',
      ...extra,
    };

void _write(Directory dir, Map<String, String> files) {
  for (final entry in files.entries) {
    final file = File(p.join(dir.path, entry.key))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(entry.value);
    if (entry.key == 'aterm_client') {
      Process.runSync('chmod', ['755', file.path]);
    }
  }
}

Map<String, String> _read(Directory dir) => {
  for (final entity in dir.listSync(recursive: true, followLinks: false))
    if (entity is File)
      p.relative(entity.path, from: dir.path): entity.readAsStringSync(),
};

/// The backup directories a switch left in [dir].
List<String> _backups(Directory dir) => [
  for (final entity in dir.listSync(followLinks: false))
    if (AppUpdateDesktopLayout.isBackupName(p.basename(entity.path)))
      p.basename(entity.path),
];

final _root = Process.runSync('id', ['-u']).stdout.toString().trim() == '0';

/// Makes the directory [path] impossible to rename, delete, or add to or
/// remove from, the way a file held by an antivirus scanner or owned by
/// another user is: immutable for root, read-only for anyone else.
void _pin(String path) {
  final result = _root
      ? Process.runSync('chattr', ['+i', path])
      : Process.runSync('chmod', ['555', path]);
  if (result.exitCode != 0) throw StateError('cannot pin $path: ${result.stderr}');
  addTearDown(() => _unpin(path));
}

void _unpin(String path) {
  if (!FileSystemEntity.isDirectorySync(path)) return;
  _root
      ? Process.runSync('chattr', ['-i', path])
      : Process.runSync('chmod', ['755', path]);
}

/// Null when [_pin] works on this file system, else why it does not.
String? _pinningUnsupported() {
  final dir = Directory.systemTemp.createTempSync('atermius-pin-test-');
  final inner = Directory(p.join(dir.path, 'inner'))..createSync();
  try {
    final pin = _root
        ? Process.runSync('chattr', ['+i', inner.path])
        : Process.runSync('chmod', ['555', inner.path]);
    if (pin.exitCode != 0) return 'cannot make directories immutable here';
    try {
      inner.renameSync(p.join(dir.path, 'moved'));
      return 'a pinned directory can still be moved here';
    } on FileSystemException {
      return null;
    }
  } catch (_) {
    return 'chattr/chmod unavailable';
  } finally {
    _unpin(inner.path);
    _unpin(p.join(dir.path, 'moved'));
    dir.deleteSync(recursive: true);
  }
}

List<int> _tarGz(Map<String, String> files, {String prefix = 'atermius-linux-x64/'}) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.add(
      ArchiveFile.bytes('$prefix${entry.key}', bytes)
        ..mode = entry.key == 'aterm_client' ? 0x1ed : 0x1a4,
    );
  }
  return GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive));
}

List<int> _zip(Map<String, String> files, {String prefix = 'atermius-windows-x64/'}) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes('$prefix${entry.key}', utf8.encode(entry.value)));
  }
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  late Directory temp;
  late AppUpdateDesktopLayout layout;
  late HttpServer server;
  late http.Client client;
  final served = <String, List<int>>{};
  final ranges = <String?>[];
  var truncateAt = -1;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('atermius-update-test-');
    layout = AppUpdateDesktopLayout(
      root: Directory(p.join(temp.path, 'state', 'updates')),
      installDir: Directory(p.join(temp.path, 'install'))..createSync(),
      executableName: 'aterm_client',
      windows: false,
    );
    served.clear();
    ranges.clear();
    truncateAt = -1;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = served[request.uri.path];
      final response = request.response;
      if (body == null) {
        response.statusCode = 404;
        await response.close();
        return;
      }
      final range = request.headers.value('range');
      ranges.add(range);
      var start = 0;
      if (range != null) {
        start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)![1]!);
        response.statusCode = 206;
        response.headers.set(
          'content-range',
          'bytes $start-${body.length - 1}/${body.length}',
        );
      }
      var end = body.length;
      if (truncateAt >= 0 && range == null) {
        // Announce everything, send a part, then drop the connection.
        end = truncateAt;
        final socket = await response.detachSocket(writeHeaders: false);
        socket.write(
          'HTTP/1.1 200 OK\r\ncontent-length: ${body.length}\r\n\r\n',
        );
        socket.add(body.sublist(start, end));
        await socket.flush();
        socket.destroy();
        return;
      }
      response.add(body.sublist(start, end));
      await response.close();
    });
    client = IOClient(HttpClient());
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
    await temp.delete(recursive: true);
  });

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  AppUpdateRelease release(String tag, String name, List<int> bytes) =>
      AppUpdateRelease(
        tag: tag,
        title: 'Atermius $tag',
        page: Uri.parse('https://example.invalid/$tag'),
        assetName: name,
        assetUrl: url('/$name'),
        size: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );

  DesktopAppUpdateBackend backend({
    Future<void> Function()? quit,
    Duration closeOthersTimeout = const Duration(seconds: 10),
  }) => DesktopAppUpdateBackend(
    layout: layout,
    client: client,
    quit: quit ?? () async {},
    currentTag: _current,
    switchAckTimeout: const Duration(seconds: 3),
    closeOthersTimeout: closeOthersTimeout,
    closeRequestPoll: const Duration(milliseconds: 50),
    instanceLock: AppUpdateInstanceLock(layout.instanceLockFile),
  );

  /// Another main window, as a separate process (file locks are per
  /// process): holds a share of the instance lock until it ends. With
  /// [obey] it ends as soon as a close request appears, as a window does.
  Future<Process> otherWindow({bool obey = false}) async {
    layout.root.createSync(recursive: true);
    final process = await Process.start('python3', [
      '-c',
      '''
import fcntl, os, sys, time
lock, request, obey = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
f = open(lock, "a+")
fcntl.lockf(f, fcntl.LOCK_SH)
print("held", flush=True)
end = time.time() + 30
while time.time() < end:
    if obey and os.path.exists(request):
        break
    time.sleep(0.05)
''',
      layout.instanceLockFile.path,
      layout.closeRequestFile.path,
      obey ? '1' : '0',
    ]);
    addTearDown(process.kill);
    await process.stdout.transform(utf8.decoder).firstWhere(
      (line) => line.contains('held'),
    );
    return process;
  }

  /// A stand-in for the new version that acknowledges like the real one
  /// and writes down its arguments.
  Map<String, String> recordingBundle() => {
    ..._bundle('new'),
    'aterm_client': r'''#!/bin/sh
for a in "$@"; do
  case "$a" in
    --atermius-update-root=*) root="${a#--atermius-update-root=}";;
    --atermius-update-tag=*) tag="${a#--atermius-update-tag=}";;
  esac
done
printf '%s\n' "$@" > "$root/switch.args"
printf %s "$tag" > "$root/switch.ack"
''',
  };

  File switchArgs() => File(p.join(layout.root.path, 'switch.args'));

  group('download', () {
    test('accepts exactly the announced bytes and digest', () async {
      final bytes = List<int>.generate(70000, (i) => i % 251);
      served['/pkg'] = bytes;
      final target = File(p.join(temp.path, 'dl', 'pkg'));
      final seen = <int>[];
      await downloadVerified(
        client: client,
        url: url('/pkg'),
        target: target,
        size: bytes.length,
        sha256Hex: sha256.convert(bytes).toString(),
        onProgress: seen.add,
      );
      expect(await target.readAsBytes(), bytes);
      expect(seen.last, bytes.length);
      expect(File('${target.path}.part').existsSync(), isFalse);
    });

    test('a wrong digest is deleted, never kept', () async {
      served['/pkg'] = utf8.encode('tampered package');
      final target = File(p.join(temp.path, 'dl', 'pkg'));
      await expectLater(
        downloadVerified(
          client: client,
          url: url('/pkg'),
          target: target,
          size: served['/pkg']!.length,
          sha256Hex: 'a' * 64,
        ),
        throwsA(isA<AppUpdateDownloadException>()),
      );
      expect(target.existsSync(), isFalse);
      expect(File('${target.path}.part').existsSync(), isFalse);
    });

    test('more data than announced is refused', () async {
      served['/pkg'] = List<int>.filled(5000, 7);
      final target = File(p.join(temp.path, 'dl', 'pkg'));
      await expectLater(
        downloadVerified(
          client: client,
          url: url('/pkg'),
          target: target,
          size: 100,
          sha256Hex: 'a' * 64,
        ),
        throwsA(isA<AppUpdateDownloadException>()),
      );
      expect(target.existsSync(), isFalse);
    });

    test('an interrupted download continues where it stopped', () async {
      final bytes = List<int>.generate(200000, (i) => (i * 7) % 253);
      served['/pkg'] = bytes;
      truncateAt = 60000;
      final target = File(p.join(temp.path, 'dl', 'pkg'));
      Future<void> run() => downloadVerified(
        client: client,
        url: url('/pkg'),
        target: target,
        size: bytes.length,
        sha256Hex: sha256.convert(bytes).toString(),
      );
      await expectLater(run(), throwsA(anything));
      final part = File('${target.path}.part');
      expect(part.lengthSync(), 60000);
      truncateAt = -1;
      await run();
      expect(ranges, [null, 'bytes=60000-']);
      expect(await target.readAsBytes(), bytes);
    });
  });

  group('unpack', () {
    test('a Linux tarball loses its top directory and keeps the executable bit',
        () {
      final package = File(p.join(temp.path, 'a.tar.gz'))
        ..writeAsBytesSync(_tarGz(_bundle('new')));
      final out = Directory(p.join(temp.path, 'out'));
      unpackAppUpdatePackage(package.path, out.path);
      expect(_read(out), _bundle('new'));
      expect(File(p.join(out.path, 'aterm_client')).statSync().mode & 0x49, isNot(0));
      expect(File(p.join(out.path, 'lib/libapp.so')).statSync().mode & 0x49, 0);
      expect(File('${out.path}.tar').existsSync(), isFalse);
    });

    test('a Windows ZIP unpacks the same way', () {
      final files = {
        'aterm_client.exe': 'exe',
        'flutter_windows.dll': 'dll',
        'data/app.so': 'app',
        'data/flutter_assets/AssetManifest.bin': 'assets',
      };
      final package = File(p.join(temp.path, 'a.zip'))
        ..writeAsBytesSync(_zip(files));
      final out = Directory(p.join(temp.path, 'out'));
      unpackAppUpdatePackage(package.path, out.path);
      expect(_read(out), files);
    });

    test('entries that would leave the directory are refused', () {
      for (final name in ['../evil', 'a/../../evil', '/abs/evil', 'C:/evil']) {
        final package = File(p.join(temp.path, 'bad.zip'))
          ..writeAsBytesSync(_zip({'ok': 'x', name: 'x'}, prefix: ''));
        final out = Directory(p.join(temp.path, 'out-bad'));
        expect(
          () => unpackAppUpdatePackage(package.path, out.path),
          throwsFormatException,
          reason: name,
        );
        if (out.existsSync()) out.deleteSync(recursive: true);
        expect(File(p.join(temp.path, 'evil')).existsSync(), isFalse);
      }
    });

    test('links are refused', () {
      final archive = Archive()
        ..add(ArchiveFile.bytes('top/aterm_client', utf8.encode('x')))
        ..add(ArchiveFile.symlink('top/link', '/etc/passwd'));
      final package = File(p.join(temp.path, 'link.tar.gz'))
        ..writeAsBytesSync(
          GZipEncoder().encodeBytes(TarEncoder().encodeBytes(archive)),
        );
      expect(
        () => unpackAppUpdatePackage(package.path, p.join(temp.path, 'out')),
        throwsFormatException,
      );
    });
  });

  group('replacing the installed copy', () {
    late Directory staged;
    final pinning = _pinningUnsupported();
    final newFiles = {
      ..._bundle('new', extra: {'lib/libadded_plugin.so': 'added'}),
      'notes.txt': 'mine',
      'uninstall.exe': 'installer file',
    };

    setUp(() {
      _write(layout.installDir, {
        ..._bundle('old', extra: {'lib/libremoved_plugin.so': 'gone in new'}),
        // Not part of any release: must survive.
        'notes.txt': 'mine',
        'uninstall.exe': 'installer file',
      });
      staged = Directory(p.join(layout.releaseDir(_next).path, 'app'));
      _write(staged, _bundle('new', extra: {'lib/libadded_plugin.so': 'added'}));
    });

    Future<AppUpdateSwitchOutcome> switchNow() =>
        switchInstalledCopy(layout: layout, staged: staged, tag: _next);

    test('swaps the program files and leaves everything else alone', () async {
      final outcome = await switchNow();
      expect(outcome, AppUpdateSwitchOutcome.done);
      expect(_read(layout.installDir), newFiles);
      expect(_backups(layout.installDir), isEmpty);
      expect(
        File(layout.installedExecutable).statSync().mode & 0x49,
        isNot(0),
      );
      // The staged copy is only copied from.
      expect(_read(staged)['aterm_client'], contains('new'));
    });

    test('a failing copy puts the old version back untouched', () async {
      final before = _read(layout.installDir);
      // New in this release, and copied before the failure: taken out again.
      File(p.join(staged.path, 'a_new_file')).writeAsStringSync('new');
      // A file that cannot be copied; lib/ comes after it and was only moved.
      Link(p.join(staged.path, 'data', 'broken')).createSync('/nonexistent/x');
      expect(await switchNow(), AppUpdateSwitchOutcome.failed);
      expect(_read(layout.installDir), before);
      expect(_backups(layout.installDir), isEmpty);
    });

    test('an entry that cannot be moved aside leaves the old version whole',
        () async {
      // More top-level files, as a Windows build has.
      for (final name in ['flutter_windows.dll', 'plugin_a.dll', 'zlib1.dll']) {
        _write(layout.installDir, {name: 'old $name'});
        _write(staged, {name: 'new $name'});
      }
      final before = _read(layout.installDir);
      // Held by another program: what sorts before it was moved aside
      // already, what sorts after it (lib/, plugin_a.dll, zlib1.dll) is
      // never touched.
      _pin(p.join(layout.installDir.path, 'data'));
      expect(await switchNow(), AppUpdateSwitchOutcome.failed);
      expect(_read(layout.installDir), before);
      expect(layout.isBundle(layout.installDir), isTrue);
      expect(_backups(layout.installDir), isEmpty);
      // Once it is free, the next attempt goes through.
      _unpin(p.join(layout.installDir.path, 'data'));
      expect(await switchNow(), AppUpdateSwitchOutcome.done);
      expect(_read(layout.installDir), {
        ...newFiles,
        for (final name in ['flutter_windows.dll', 'plugin_a.dll', 'zlib1.dll'])
          name: 'new $name',
      });
    }, skip: pinning);

    test('a leftover backup that cannot be removed is not in the way',
        () async {
      final leftover = Directory(
        p.join(layout.installDir.path, AppUpdateDesktopLayout.backupPrefix),
      )..createSync();
      File(p.join(leftover.path, 'aterm_client')).writeAsStringSync('older');
      _pin(leftover.path);
      expect(await switchNow(), AppUpdateSwitchOutcome.done);
      expect(_read(layout.installDir), {
        ...newFiles,
        '.atermius-old/aterm_client': 'older',
      });
      expect(_backups(layout.installDir), ['.atermius-old']);
      // Removed once it can be.
      _unpin(leftover.path);
      final update = backend();
      await update.cleanup(_next);
      expect(_backups(layout.installDir), isEmpty);
    }, skip: pinning);

    test('a leftover backup that cannot be removed, then a failing copy',
        () async {
      final leftover = Directory(
        p.join(layout.installDir.path, '.atermius-old-abc123'),
      )..createSync();
      File(p.join(leftover.path, 'data')).writeAsStringSync('older');
      _pin(leftover.path);
      final before = _read(layout.installDir);
      Link(p.join(staged.path, 'lib', 'broken')).createSync('/nonexistent/x');
      expect(await switchNow(), AppUpdateSwitchOutcome.failed);
      expect(_read(layout.installDir), before);
      expect(_backups(layout.installDir), ['.atermius-old-abc123']);
    }, skip: pinning);

    test('no room for a backup: nothing is touched', () async {
      final before = _read(layout.installDir);
      _pin(layout.installDir.path);
      expect(await switchNow(), AppUpdateSwitchOutcome.failed);
      expect(_read(layout.installDir), before);
      expect(_backups(layout.installDir), isEmpty);
    }, skip: pinning);

    test('nothing changes while the old process is still running', () async {
      final before = _read(layout.installDir);
      final outcome = await switchInstalledCopy(
        layout: layout,
        staged: staged,
        tag: _next,
        oldPid: pid,
        waitForExit: const Duration(milliseconds: 600),
      );
      expect(outcome, AppUpdateSwitchOutcome.busy);
      expect(_read(layout.installDir), before);
    });

    test('refuses directories that are not an Atermius copy', () async {
      File(p.join(layout.installDir.path, 'aterm_client')).deleteSync();
      expect(
        await switchInstalledCopy(layout: layout, staged: staged, tag: _next),
        AppUpdateSwitchOutcome.failed,
      );
      expect(_read(layout.installDir)['notes.txt'], 'mine');
      expect(_read(layout.installDir)['lib/libapp.so'], _bundle('old')['lib/libapp.so']);
    });
  });

  test('the account that asked for an elevated update is recognised', () {
    const row =
        '"aterm_client.exe","4321","Console","1","182,344 K","Running",'
        '"DESKTOP-7Q\\Administrator","0:00:09","Atermius"\r\n';
    expect(
      tasklistNamesAccount(row, pid: 4321, account: 'desktop-7q\\administrator\r\n'),
      isTrue,
    );
    // Someone else's window (a standard user who was given the password),
    // another process, nothing found, or no user name shown.
    expect(
      tasklistNamesAccount(row, pid: 4321, account: 'desktop-7q\\alice'),
      isFalse,
    );
    expect(
      tasklistNamesAccount(row, pid: 4322, account: 'desktop-7q\\administrator'),
      isFalse,
    );
    expect(
      tasklistNamesAccount(
        'INFO: No tasks are running which match the specified criteria.',
        pid: 4321,
        account: 'desktop-7q\\administrator',
      ),
      isFalse,
    );
    expect(
      tasklistNamesAccount(
        '"aterm_client.exe","4321","Console","1","1 K","Unknown","N/A","0:00:00","N/A"',
        pid: 4321,
        account: 'n/a',
      ),
      isFalse,
    );
  });

  group('backend', () {
    setUp(() => _write(layout.installDir, _bundle('old')));

    test('stages a verified release once and offers it to every window',
        () async {
      final bytes = _tarGz(_bundle('new'));
      served['/next.tar.gz'] = bytes;
      final update = backend();
      expect(await update.canInstall(), isTrue);
      expect(await update.staged(_current), isNull);
      final progress = <double>[];
      final staged = await update.stage(
        release(_next, 'next.tar.gz', bytes),
        onProgress: progress.add,
      );
      expect(progress.last, 1.0);
      expect(_read(Directory(staged!.path)), _bundle('new'));
      // The package itself is not kept.
      expect(
        File(p.join(layout.releaseDir(_next).path, 'next.tar.gz')).existsSync(),
        isFalse,
      );
      // Another window (a second backend on the same files) sees it.
      final other = backend();
      expect((await other.staged(_current))!.release.tag, _next);
      // Asked again, nothing is downloaded twice.
      ranges.clear();
      await other.stage(release(_next, 'next.tar.gz', bytes), onProgress: (_) {});
      expect(ranges, isEmpty);
      // Not an update for a build that already is that release.
      expect(await other.staged(_next), isNull);
    });

    test('a package that is not an Atermius bundle is rejected', () async {
      final bytes = _tarGz({'readme.txt': 'hello'});
      served['/bad.tar.gz'] = bytes;
      final update = backend();
      await expectLater(
        update.stage(release(_next, 'bad.tar.gz', bytes), onProgress: (_) {}),
        throwsFormatException,
      );
      expect(await update.staged(_current), isNull);
    });

    test('a build without its own release tag is never installed', () async {
      final bytes = _tarGz({..._bundle('new'), 'lib/libapp.so': 'no tag here'});
      served['/next.tar.gz'] = bytes;
      final update = backend();
      await expectLater(
        update.stage(release(_next, 'next.tar.gz', bytes), onProgress: (_) {}),
        throwsA(isA<AppUpdateDeadEndRelease>()),
      );
      expect(await update.staged(_current), isNull);
      expect(await update.blockedTags(), {_next});
      expect(layout.releaseDir(_next).listSync(), isEmpty);
    });

    test('cleanup drops what the running release no longer needs', () async {
      final bytes = _tarGz(_bundle('new'));
      served['/next.tar.gz'] = bytes;
      final update = backend();
      await update.stage(release(_next, 'next.tar.gz', bytes), onProgress: (_) {});
      Directory(p.join(layout.root.path, 'local-20261120.1-aaaaaaaaaaaa', 'app'))
          .createSync(recursive: true);
      // Backups of earlier switches, in the old and the current naming.
      for (final name in ['.atermius-old', '.atermius-old-x1y2z3']) {
        File(p.join(layout.installDir.path, name, 'aterm_client'))
          ..parent.createSync()
          ..writeAsStringSync('older');
      }
      // Still older than the staged release: only leftovers go.
      await update.cleanup(_current);
      expect(layout.releaseDir(_next).existsSync(), isTrue);
      expect(
        layout.releaseDir('local-20261120.1-aaaaaaaaaaaa').existsSync(),
        isFalse,
      );
      expect(_backups(layout.installDir), isEmpty);
      // Now running the staged release: it is not needed any more.
      await update.cleanup(_next);
      expect(layout.releaseDir(_next).existsSync(), isFalse);
      expect(AppUpdateState.read(layout.stateFile).staged, isNull);
    });

    test('a read-only install directory cannot update itself', () async {
      final update = DesktopAppUpdateBackend(
        layout: AppUpdateDesktopLayout(
          root: layout.root,
          installDir: Directory(p.join(temp.path, 'missing')),
          executableName: 'aterm_client',
          windows: false,
        ),
        client: client,
        quit: () async {},
        currentTag: _current,
        instanceLock: AppUpdateInstanceLock(layout.instanceLockFile),
      );
      expect(await update.canInstall(), isFalse);
    });

    test('restart hands over to the staged version and then quits', () async {
      final bytes = _tarGz({
        ..._bundle('new'),
        // Stands in for the new version: acknowledges like the real one.
        'aterm_client': r'''#!/bin/sh
for a in "$@"; do
  case "$a" in
    --atermius-update-root=*) root="${a#--atermius-update-root=}";;
    --atermius-update-tag=*) tag="${a#--atermius-update-tag=}";;
  esac
done
printf '%s\n' "$@" > "$root/switch.args"
printf %s "$tag" > "$root/switch.ack"
''',
      });
      served['/next.tar.gz'] = bytes;
      var quits = 0;
      final update = backend(quit: () async => quits++);
      final staged = await update.stage(
        release(_next, 'next.tar.gz', bytes),
        onProgress: (_) {},
      );
      expect(await update.apply(staged!), isNull);
      expect(quits, 1);
      final args = File(p.join(layout.root.path, 'switch.args')).readAsLinesSync();
      expect(args, contains(appUpdateApplyFlag));
      expect(args, contains('--atermius-update-install=${layout.installDir.path}'));
      expect(args, contains('--atermius-update-tag=$_next'));
    });

    test('a new version that never starts is blocked and the app stays',
        () async {
      final bytes = _tarGz({..._bundle('new'), 'aterm_client': '#!/bin/sh\nexit 3\n'});
      served['/next.tar.gz'] = bytes;
      var quits = 0;
      final update = backend(quit: () async => quits++);
      final staged = await update.stage(
        release(_next, 'next.tar.gz', bytes),
        onProgress: (_) {},
      );
      expect(await update.apply(staged!), AppUpdateApplyProblem.failed);
      expect(quits, 0);
      expect(await update.blockedTags(), {_next});
      expect(await update.staged(_current), isNull);
      expect((await update.takeResult())!.succeeded, isFalse);
      expect(await update.takeResult(), isNull);
    });

    test('an installer that dies after starting is tried twice, not for ever',
        () async {
      // Acknowledges and then vanishes without replacing anything.
      final bytes = _tarGz({
        ..._bundle('new'),
        'aterm_client': r'''#!/bin/sh
for a in "$@"; do
  case "$a" in
    --atermius-update-root=*) root="${a#--atermius-update-root=}";;
    --atermius-update-tag=*) tag="${a#--atermius-update-tag=}";;
  esac
done
printf %s "$tag" > "$root/switch.ack"
''',
      });
      served['/next.tar.gz'] = bytes;
      var quits = 0;
      final update = backend(quit: () async => quits++);
      final staged = await update.stage(
        release(_next, 'next.tar.gz', bytes),
        onProgress: (_) {},
      );
      expect(await update.apply(staged!), isNull);
      expect(await update.apply(staged), isNull);
      expect(quits, 2);
      // The third start keeps the running version and skips the release.
      expect(await update.apply(staged), AppUpdateApplyProblem.failed);
      expect(quits, 2);
      expect(await update.blockedTags(), {_next});
      expect(await update.staged(_current), isNull);
    });

    test('closing the app switches quietly and leaves the rest to the end',
        () async {
      final bytes = _tarGz(recordingBundle());
      served['/next.tar.gz'] = bytes;
      var quits = 0;
      final update = backend(quit: () async => quits++);
      await update.stage(release(_next, 'next.tar.gz', bytes), onProgress: (_) {});
      expect(await update.applyOnExit(), isTrue);
      // The app is already closing: it is neither quit again nor restarted.
      expect(quits, 0);
      final args = switchArgs().readAsLinesSync();
      expect(args, contains(appUpdateApplyFlag));
      expect(args, contains('--atermius-update-quiet'));
      expect(args, contains('--atermius-update-tag=$_next'));
    });

    test('closing one of several windows leaves the switch to the last',
        () async {
      final bytes = _tarGz(recordingBundle());
      served['/next.tar.gz'] = bytes;
      final update = backend();
      await update.stage(release(_next, 'next.tar.gz', bytes), onProgress: (_) {});
      final other = await otherWindow();
      expect(await update.othersRunning(), isTrue);
      expect(await update.applyOnExit(), isFalse);
      expect(switchArgs().existsSync(), isFalse);
      other.kill();
      await other.exitCode;
      expect(await update.othersRunning(), isFalse);
      expect(await update.applyOnExit(), isTrue);
    });

    test('closing does nothing without a ready release or a writable copy',
        () async {
      final update = backend();
      expect(await update.applyOnExit(), isFalse);
      final bytes = _tarGz(recordingBundle());
      served['/next.tar.gz'] = bytes;
      await update.stage(release(_next, 'next.tar.gz', bytes), onProgress: (_) {});
      final unsupported = _pinningUnsupported();
      if (unsupported != null) {
        markTestSkipped(unsupported);
        return;
      }
      // Where only an administrator may write, the banner asks instead.
      _pin(layout.installDir.path);
      expect(await update.applyOnExit(), isFalse);
      expect(switchArgs().existsSync(), isFalse);
    });

    test('a restart asks the other windows to close and then switches',
        () async {
      final bytes = _tarGz(recordingBundle());
      served['/next.tar.gz'] = bytes;
      var quits = 0;
      final update = backend(quit: () async => quits++);
      final staged = await update.stage(
        release(_next, 'next.tar.gz', bytes),
        onProgress: (_) {},
      );
      final other = await otherWindow(obey: true);
      final own = <void>[];
      final sub = update.closeRequests.listen(own.add);
      addTearDown(sub.cancel);
      // Without the user's agreement nothing is closed.
      expect(
        await update.apply(staged!),
        AppUpdateApplyProblem.otherWindowsOpen,
      );
      expect(layout.closeRequestFile.existsSync(), isFalse);
      expect(await update.apply(staged, closeOthers: true), isNull);
      expect(await other.exitCode, 0);
      expect(quits, 1);
      expect(switchArgs().readAsLinesSync(), contains(appUpdateApplyFlag));
      // Not quiet: the app opens again after this switch.
      expect(
        switchArgs().readAsLinesSync(),
        isNot(contains('--atermius-update-quiet')),
      );
      // Its own request is not one for this window, and it is gone.
      expect(own, isEmpty);
      expect(layout.closeRequestFile.existsSync(), isFalse);
    });

    test('a window that does not close in time is reported', () async {
      final bytes = _tarGz(recordingBundle());
      served['/next.tar.gz'] = bytes;
      var quits = 0;
      final update = backend(
        quit: () async => quits++,
        closeOthersTimeout: const Duration(milliseconds: 800),
      );
      final staged = await update.stage(
        release(_next, 'next.tar.gz', bytes),
        onProgress: (_) {},
      );
      await otherWindow();
      expect(
        await update.apply(staged!, closeOthers: true),
        AppUpdateApplyProblem.otherWindowsOpen,
      );
      expect(quits, 0);
      expect(switchArgs().existsSync(), isFalse);
      expect(layout.closeRequestFile.existsSync(), isFalse);
      // Still ready for the next try.
      expect((await update.staged(_current))!.release.tag, _next);
    });

    test('close requests reach windows that ran before them, once', () async {
      final window = backend();
      final requests = <void>[];
      final sub = window.closeRequests.listen(requests.add);
      addTearDown(sub.cancel);
      void request(DateTime at) {
        layout.root.createSync(recursive: true);
        layout.closeRequestFile.writeAsStringSync(
          jsonEncode({'id': 'another-window', 'at': at.millisecondsSinceEpoch}),
        );
      }

      // A leftover from before this window started is not for it.
      request(DateTime.now().subtract(const Duration(minutes: 1)));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(requests, isEmpty);
      request(DateTime.now());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(requests, hasLength(1));
      // A window that is closing for another one never switches itself.
      expect(await window.applyOnExit(), isFalse);
      request(DateTime.now());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(requests, hasLength(1));
      // A window started after the request (the new version) stays.
      final later = backend();
      final laterRequests = <void>[];
      final laterSub = later.closeRequests.listen(laterRequests.add);
      addTearDown(laterSub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(laterRequests, isEmpty);
    });

    test('a staged copy that vanished is reported as missing', () async {
      final bytes = _tarGz(_bundle('new'));
      served['/next.tar.gz'] = bytes;
      final update = backend();
      final staged = await update.stage(
        release(_next, 'next.tar.gz', bytes),
        onProgress: (_) {},
      );
      Directory(staged!.path).deleteSync(recursive: true);
      expect(await update.apply(staged), AppUpdateApplyProblem.stagedMissing);
    });
  });
}
