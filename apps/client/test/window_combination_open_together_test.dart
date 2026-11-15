import 'dart:async';

import 'package:aterm_client/domain/window_combination.dart';
import 'package:aterm_client/domain/window_placement.dart';
import 'package:aterm_client/platform/window_geometry.dart';
import 'package:aterm_client/ui/session_workspace.dart';
import 'package:aterm_client/ui/window_combinations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A window set is shown as soon as its terminal panes exist; file panes join
// later, once their SSH owner is connected.

/// Pane 0 (SSH) left of a column with its files (pane 2) above pane 1 (SSH).
WindowCombination _recipe({
  SavedWindowPlacement? main,
  List<CombinationWindow> windows = const [],
}) => WindowCombination(
  id: 'set',
  name: 'Set',
  panes: [
    CombinationPane(kind: 'ssh', hostId: 'a'),
    CombinationPane(kind: 'ssh', hostId: 'b'),
    CombinationPane(kind: 'sftp', hostId: 'a', remotePath: '/', ownerPane: 0),
  ],
  tree: const {
    'axis': 'horizontal',
    'ratio': .4,
    'first': {'pane': 0},
    'second': {
      'axis': 'vertical',
      'ratio': .6,
      'first': {'pane': 2},
      'second': {'pane': 1},
    },
  },
  activePane: 1,
  mainPlacement: main,
  windows: windows,
);

SavedWindowPlacement _placement() =>
    SavedWindowPlacement(x: 10, y: 20, width: 1000, height: 600);

class _Geometry extends WindowGeometry {
  int restores = 0;

  @override
  Future<bool> restorePlacement(
    SavedWindowPlacement placement, {
    bool Function()? isCurrent,
  }) async {
    restores++;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the panes are reported once every terminal pane exists, before any '
      'file pane, and again when a file pane joined', () async {
    final events = <String>[];
    final owner = Completer<void>();
    final restoring = CombinationRestoreCoordinator().restore(
      recipe: _recipe(),
      isCurrent: () => true,
      canResolve: (_) => true,
      open: (pane) async {
        events.add('open ${pane.hostId}');
        return 'ssh-${pane.hostId}';
      },
      openAttachedFile: (pane, ownerId) async {
        events.add('file waits for $ownerId');
        await owner.future;
        return 'file';
      },
      onSessions: (sessions) => events.add('panes $sessions'),
    );
    await pumpEventQueue();
    // Both terminals exist and were reported while the file still waits for
    // its owner to connect.
    expect(events, [
      'open a',
      'open b',
      'panes {0: ssh-a, 1: ssh-b}',
      'file waits for ssh-a',
    ]);
    owner.complete();
    final result = await restoring;
    expect(events.last, 'panes {0: ssh-a, 1: ssh-b, 2: file}');
    expect(events, hasLength(5));
    expect(result!.sessions, {0: 'ssh-a', 1: 'ssh-b', 2: 'file'});
    expect(result.failures, 0);
  });

  test('a set without file panes reports its panes once; a stale restore '
      'reports nothing', () async {
    final recipe = WindowCombination(
      id: 'plain',
      name: 'Plain',
      panes: [CombinationPane(kind: 'ssh', hostId: 'a')],
      tree: const {'pane': 0},
      activePane: 0,
    );
    final reports = <Map<int, String>>[];
    await CombinationRestoreCoordinator().restore(
      recipe: recipe,
      isCurrent: () => true,
      canResolve: (_) => true,
      open: (_) async => 'ssh',
      onSessions: reports.add,
    );
    expect(reports, [
      {0: 'ssh'},
    ]);

    var current = true;
    reports.clear();
    final stale = await CombinationRestoreCoordinator().restore(
      recipe: recipe,
      isCurrent: () => current,
      canResolve: (_) => true,
      open: (_) async {
        current = false;
        return 'ssh';
      },
      onSessions: reports.add,
    );
    expect(stale!.stale, isTrue);
    expect(reports, isEmpty);
  });

  test('a file pane that joins later takes its saved place', () {
    final workspace = SessionWorkspaceController();
    addTearDown(workspace.dispose);
    final recipe = _recipe();
    applyWindowCombination(recipe, workspace, {0: 'ssh-a', 1: 'ssh-b'});
    expect(workspace.sessionIds, ['ssh-a', 'ssh-b']);
    expect(workspace.selectedId, 'ssh-b');

    expect(
      extendWindowCombination(
        recipe,
        workspace,
        placed: {0: 'ssh-a', 1: 'ssh-b'},
        sessions: {0: 'ssh-a', 1: 'ssh-b', 2: 'file'},
      ),
      isTrue,
    );
    expect(workspace.sessionIds, ['ssh-a', 'file', 'ssh-b']);
    expect(workspace.selectedId, 'ssh-b');
    final root = workspace.root as SessionWorkspaceSplit;
    expect(root.axis, Axis.horizontal);
    expect(root.ratio, .4);
    final column = root.second as SessionWorkspaceSplit;
    expect(column.axis, Axis.vertical);
    expect(column.ratio, .6);
  });

  test('a pane closed meanwhile is left out; the file still takes its '
      'place', () {
    final workspace = SessionWorkspaceController();
    addTearDown(workspace.dispose);
    final recipe = _recipe();
    applyWindowCombination(recipe, workspace, {0: 'ssh-a', 1: 'ssh-b'});
    workspace.remove('ssh-b');

    expect(
      extendWindowCombination(
        recipe,
        workspace,
        placed: {0: 'ssh-a'},
        sessions: {0: 'ssh-a', 2: 'file'},
      ),
      isTrue,
    );
    expect(workspace.sessionIds, ['ssh-a', 'file']);
  });

  test('panes the user rearranged meanwhile are not moved back', () {
    final recipe = _recipe();
    const placed = {0: 'ssh-a', 1: 'ssh-b'};
    const joined = {0: 'ssh-a', 1: 'ssh-b', 2: 'file'};

    // Unsplit: each pane is a tab of its own again.
    final unsplit = SessionWorkspaceController();
    addTearDown(unsplit.dispose);
    applyWindowCombination(recipe, unsplit, placed);
    unsplit.unsplit('ssh-b');
    expect(
      extendWindowCombination(recipe, unsplit, placed: placed, sessions: joined),
      isFalse,
    );
    expect(unsplit.sessionIds, ['ssh-a']);
    expect(unsplit.groupedSessionIds, isEmpty);

    // Another tab was dropped into the split.
    final joinedByOther = SessionWorkspaceController();
    addTearDown(joinedByOther.dispose);
    applyWindowCombination(recipe, joinedByOther, placed);
    joinedByOther.split('other', 'ssh-a', SessionSplitEdge.top);
    expect(
      extendWindowCombination(
        recipe,
        joinedByOther,
        placed: placed,
        sessions: joined,
      ),
      isFalse,
    );
    expect(joinedByOther.sessionIds, ['other', 'ssh-a', 'ssh-b']);

    // Rearranged the other way round.
    final swapped = SessionWorkspaceController();
    addTearDown(swapped.dispose);
    applyWindowCombination(recipe, swapped, placed);
    swapped.split('ssh-a', 'ssh-b', SessionSplitEdge.right);
    expect(swapped.sessionIds, ['ssh-b', 'ssh-a']);
    expect(
      extendWindowCombination(recipe, swapped, placed: placed, sessions: joined),
      isFalse,
    );
    expect(swapped.sessionIds, ['ssh-b', 'ssh-a']);

    // Looking at another tab does not count: the split is still intact.
    final elsewhere = SessionWorkspaceController();
    addTearDown(elsewhere.dispose);
    applyWindowCombination(recipe, elsewhere, placed);
    elsewhere.activate('other');
    expect(elsewhere.sessionIds, ['other']);
    expect(
      extendWindowCombination(
        recipe,
        elsewhere,
        placed: placed,
        sessions: joined,
      ),
      isTrue,
    );
    expect(elsewhere.sessionIds, ['ssh-a', 'file', 'ssh-b']);
  });

  test('the main window can be placed before the separate windows', () async {
    final geometry = _Geometry();
    final recipe = _recipe(
      main: _placement(),
      windows: [CombinationWindow(pane: 1, placement: _placement())],
    );
    final detached = <String>[];
    Future<int> restore({required bool separate, required bool main}) =>
        restoreWindowCombinationPlacements(
          recipe: recipe,
          sessions: const {0: 'ssh-a', 1: 'ssh-b'},
          isCurrent: () => true,
          detach: (_, _, id) async {
            detached.add(id);
            return id;
          },
          applyDetached: (_, _) async => true,
          closeDetached: (_) async {},
          geometry: geometry,
          separateWindows: separate,
          mainWindow: main,
        );

    expect(await restore(separate: false, main: true), 0);
    expect(geometry.restores, 1);
    expect(detached, isEmpty);

    expect(await restore(separate: true, main: false), 0);
    expect(geometry.restores, 1);
    expect(detached, ['ssh-b']);
  });
}
