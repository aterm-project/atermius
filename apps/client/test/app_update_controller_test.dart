import 'dart:async';

import 'package:aterm_client/app_update/app_update_backend.dart';
import 'package:aterm_client/app_update/app_update_channel.dart';
import 'package:aterm_client/app_update/app_update_controller.dart';
import 'package:aterm_client/app_update/release_marker.dart';
import 'package:flutter_test/flutter_test.dart';

const _current = 'local-20261124.2-178e1a78f57b';
const _next = 'local-20261124.3-0123456789ab';
const _later = 'local-20261125.1-abcdef012345';

AppUpdateRelease _release(String tag) => AppUpdateRelease(
  tag: tag,
  title: 'Atermius $tag',
  page: Uri.parse('https://example.invalid/$tag'),
  assetName: 'atermius-$tag.zip',
  assetUrl: Uri.parse('https://example.invalid/$tag.zip'),
  size: 100,
  sha256: 'a' * 64,
);

class _Channel implements AppUpdateChannel {
  AppUpdateRelease? release;
  Object? error;
  int calls = 0;

  @override
  Future<AppUpdateRelease?> latest({
    required String currentTag,
    required AppUpdateTarget target,
  }) async {
    calls++;
    if (error case final error?) throw error;
    return release;
  }
}

class _Backend implements AppUpdateBackend {
  bool installable = true;
  bool isMetered = false;
  AppUpdateStaged? stagedNow;
  Set<String> blocked = {};
  AppUpdateResult? result;
  Object? stageError;
  bool stageElsewhere = false;
  Completer<void>? stageGate;
  AppUpdateApplyProblem? applyProblem;
  final stagedTags = <String>[];
  final applied = <String>[];
  final cleaned = <String>[];
  final problemEvents = StreamController<AppUpdateApplyProblem>.broadcast();

  @override
  Future<bool> canInstall() async => installable;
  @override
  Future<AppUpdateStaged?> staged(String currentTag) async => stagedNow;
  @override
  Future<Set<String>> blockedTags() async => blocked;
  @override
  Future<AppUpdateResult?> takeResult() async {
    final value = result;
    result = null;
    return value;
  }

  @override
  Future<bool> metered() async => isMetered;
  @override
  Stream<AppUpdateApplyProblem> get problems => problemEvents.stream;

  @override
  Future<AppUpdateStaged?> stage(
    AppUpdateRelease release, {
    required void Function(double fraction) onProgress,
  }) async {
    stagedTags.add(release.tag);
    onProgress(.5);
    await stageGate?.future;
    if (stageError case final error?) throw error;
    if (stageElsewhere) return null;
    onProgress(1);
    return stagedNow = AppUpdateStaged(release: release, path: '/x/${release.tag}');
  }

  @override
  Future<AppUpdateApplyProblem?> apply(AppUpdateStaged staged) async {
    applied.add(staged.release.tag);
    return applyProblem;
  }

  @override
  Future<void> cleanup(String currentTag) async => cleaned.add(currentTag);
}

void main() {
  late _Channel channel;
  late _Backend backend;
  late MemoryAppUpdateSettingStore settings;

  AppUpdateController controller() {
    final controller = AppUpdateController(
      currentTag: _current,
      target: AppUpdateTarget.linuxX64,
      channel: channel,
      backend: backend,
      settings: settings,
      startDelay: const Duration(days: 1),
      checkInterval: const Duration(days: 1),
      stagedPollInterval: const Duration(days: 1),
      applyWatchdog: const Duration(milliseconds: 50),
    );
    addTearDown(controller.dispose);
    return controller;
  }

  setUp(() {
    channel = _Channel();
    backend = _Backend();
    settings = MemoryAppUpdateSettingStore();
  });

  test('a newer release is installed in the background and then ready',
      () async {
    channel.release = _release(_next);
    final update = controller();
    final states = <String>[];
    update.addListener(() {
      states.add(
        update.checking
            ? 'checking'
            : update.downloading
            ? 'downloading'
            : update.ready != null
            ? 'ready'
            : 'idle',
      );
    });
    await update.start();
    expect(backend.cleaned, [_current]);
    expect(update.ready, isNull);
    await update.checkNow();
    expect(backend.stagedTags, [_next]);
    expect(update.ready!.tag, _next);
    expect(update.found, isNull);
    expect(update.downloading, isFalse);
    expect(states, containsAllInOrder(['checking', 'downloading', 'ready']));
    // Nothing restarts by itself.
    expect(backend.applied, isEmpty);
  });

  test('the current release needs nothing', () async {
    final update = controller();
    await update.start();
    await update.checkNow();
    expect(update.checkedOnce, isTrue);
    expect(update.checkFailed, isFalse);
    expect(update.ready, isNull);
    expect(update.found, isNull);
    expect(backend.stagedTags, isEmpty);
  });

  test('an update staged earlier (or by another window) is ready at start',
      () async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    final update = controller();
    await update.start();
    expect(update.ready!.tag, _next);
    channel.release = _release(_next);
    await update.checkNow();
    // Already staged: not downloaded again.
    expect(backend.stagedTags, isEmpty);
    expect(update.ready!.tag, _next);
  });

  test('a release newer than the staged one replaces it', () async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    channel.release = _release(_later);
    final update = controller();
    await update.start();
    backend.stageGate = Completer<void>();
    final check = update.checkNow();
    await pumpEventQueue();
    // The older staged release stays offered while the newer one downloads.
    expect(update.downloading, isTrue);
    expect(update.ready!.tag, _next);
    backend.stageGate!.complete();
    await check;
    expect(update.ready!.tag, _later);
  });

  test('a failed check says so and keeps what was ready', () async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    channel.error = StateError('offline: private detail');
    final update = controller();
    await update.start();
    await update.checkNow();
    expect(update.checkFailed, isTrue);
    expect(update.ready!.tag, _next);
    expect(backend.stagedTags, isEmpty);
  });

  test('a failed download is reported and tried again at the next check',
      () async {
    channel.release = _release(_next);
    backend.stageError = StateError('connection reset');
    final update = controller();
    await update.start();
    await update.checkNow();
    expect(update.downloadFailed, isTrue);
    expect(update.ready, isNull);
    backend.stageError = null;
    await update.checkNow();
    expect(update.downloadFailed, isFalse);
    expect(update.ready!.tag, _next);
    expect(backend.stagedTags, [_next, _next]);
  });

  test('a release that could not update itself is dropped quietly', () async {
    channel.release = _release(_next);
    backend.stageError = const AppUpdateDeadEndRelease(_next);
    final update = controller();
    await update.start();
    await update.checkNow();
    expect(update.found, isNull);
    expect(update.ready, isNull);
    expect(update.downloadFailed, isFalse);
  });

  test('with automatic updates off the release is only announced', () async {
    settings.value = false;
    channel.release = _release(_next);
    final update = controller();
    await update.start();
    expect(update.automatic, isFalse);
    await update.checkNow();
    expect(update.found!.tag, _next);
    expect(update.waitReason, AppUpdateWaitReason.automaticOff);
    expect(backend.stagedTags, isEmpty);
    await update.downloadNow();
    expect(update.ready!.tag, _next);
    expect(update.waitReason, isNull);
  });

  test('turning automatic updates on is remembered and checks at once',
      () async {
    settings.value = false;
    channel.release = _release(_next);
    final update = controller();
    await update.start();
    await update.setAutomatic(true);
    await pumpEventQueue();
    expect(settings.value, isTrue);
    expect(update.ready!.tag, _next);
  });

  test('a metered connection waits for the user', () async {
    backend.isMetered = true;
    channel.release = _release(_next);
    final update = controller();
    await update.start();
    await update.checkNow();
    expect(update.waitReason, AppUpdateWaitReason.metered);
    expect(backend.stagedTags, isEmpty);
    await update.checkNow(download: true);
    expect(update.ready!.tag, _next);
  });

  test('a copy that cannot replace itself only announces the release',
      () async {
    backend.installable = false;
    channel.release = _release(_next);
    final update = controller();
    await update.start();
    await update.checkNow();
    expect(update.waitReason, AppUpdateWaitReason.manualInstall);
    await update.downloadNow();
    expect(backend.stagedTags, isEmpty);
    expect(update.ready, isNull);
  });

  test('a release that failed to install before is not offered again',
      () async {
    backend.blocked = {_next};
    channel.release = _release(_next);
    final update = controller();
    await update.start();
    await update.checkNow();
    expect(update.found, isNull);
    expect(update.ready, isNull);
    expect(backend.stagedTags, isEmpty);
  });

  test('another window downloading leaves this one waiting, then ready',
      () async {
    channel.release = _release(_next);
    backend.stageElsewhere = true;
    final update = AppUpdateController(
      currentTag: _current,
      target: AppUpdateTarget.linuxX64,
      channel: channel,
      backend: backend,
      settings: settings,
      startDelay: const Duration(days: 1),
      stagedPollInterval: const Duration(milliseconds: 20),
    );
    addTearDown(update.dispose);
    await update.start();
    await update.checkNow();
    expect(update.ready, isNull);
    expect(update.downloadFailed, isFalse);
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(update.ready!.tag, _next);
  });

  test('restart switches to the ready release', () async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    final update = controller();
    await update.start();
    expect(await update.restart(), isNull);
    expect(backend.applied, [_next]);
    expect(update.applying, isTrue);
    // Android: if the process survives, the offer comes back.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(update.applying, isFalse);
    expect(update.ready!.tag, _next);
  });

  test('other open windows keep the update ready and explain why', () async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    backend.applyProblem = AppUpdateApplyProblem.otherWindowsOpen;
    final update = controller();
    await update.start();
    expect(await update.restart(), AppUpdateApplyProblem.otherWindowsOpen);
    expect(update.applying, isFalse);
    expect(update.problem, AppUpdateApplyProblem.otherWindowsOpen);
    expect(update.ready!.tag, _next);
  });

  test('a cancelled system prompt is reported after the fact', () async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    final update = controller();
    await update.start();
    await update.restart();
    backend.problemEvents.add(AppUpdateApplyProblem.cancelled);
    await pumpEventQueue();
    expect(update.applying, isFalse);
    expect(update.problem, AppUpdateApplyProblem.cancelled);
    expect(update.ready!.tag, _next);
  });

  test('a staged copy that is gone is forgotten', () async {
    backend.stagedNow = AppUpdateStaged(release: _release(_next), path: '/x');
    backend.applyProblem = AppUpdateApplyProblem.stagedMissing;
    final update = controller();
    await update.start();
    backend.stagedNow = null;
    await update.restart();
    await pumpEventQueue();
    expect(update.ready, isNull);
  });

  test('the outcome of the switch that started this run is shown once',
      () async {
    backend.result = const AppUpdateResult(tag: _current, succeeded: true);
    final update = controller();
    await update.start();
    expect(update.result!.succeeded, isTrue);
    update.dismissResult();
    expect(update.result, isNull);
  });

  test('checks are scheduled after start and repeat', () async {
    final update = AppUpdateController(
      currentTag: _current,
      target: AppUpdateTarget.linuxX64,
      channel: channel,
      backend: backend,
      settings: settings,
      startDelay: const Duration(milliseconds: 20),
      checkInterval: const Duration(milliseconds: 30),
    );
    addTearDown(update.dispose);
    await update.start();
    expect(channel.calls, 0);
    await Future<void>.delayed(const Duration(milliseconds: 140));
    expect(channel.calls, greaterThanOrEqualTo(2));
  });
}
