import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/host_sort.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/storage/host_sort_store.dart';
import 'package:aterm_client/terminal/session_recovery.dart';
import 'package:aterm_client/storage/host_sort_store_native.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_sort_fixture.dart';

List<String> ids(Iterable<HostRecord> hosts) => hosts.map((h) => h.id).toList();

class _SlowStore implements HostSortStore {
  final readResult = Completer<String?>();
  @override
  Future<String?> read() => readResult.future;
  @override
  Future<void> write(String value) async {}
}

class _FailedStore implements HostSortStore {
  @override
  Future<String?> read() async => throw StateError('unavailable');
  @override
  Future<void> write(String value) async => throw StateError('unavailable');
}

void main() {
  test('recent requests are the default, with stable name/id ties', () {
    final sort = HostSortController();
    expect(sort.order, HostSortOrder.recentRequested);
    expect(ids(sort.sorted(hosts)), ['a', 'b', 'z']);
    sort.requested('scope', ['z']);
    expect(ids(sort.sorted(hosts, scope: 'scope')), ['z', 'a', 'b']);
    expect(ids(hosts), ['a', 'b', 'z'], reason: 'the source is never mutated');
    expect(
      ids(
        sort.sorted([
          const HostRecord(id: '2', name: 'Same', address: 'x'),
          const HostRecord(id: '1', name: 'same', address: 'x'),
        ]),
      ),
      ['1', '2'],
    );
  });

  test(
    'automatic recovery never moves a host, while manual restore does',
    () async {
      final sort = HostSortController();
      sort.requested('s', ['a']);
      final initial = sort.lastRequested('s', 'a');
      sort.requested('s', ['b']);
      final recovery = SessionRecovery(
        automatic: true,
        isCurrent: () => true,
        reconnect: () async {},
        onUserRetry: () => sort.requested('s', ['a']),
      );
      try {
        recovery.update(connected: true);
        recovery.update(connected: false);
        await recovery.retry(manual: false);
        expect(sort.lastRequested('s', 'a'), initial);
        expect(ids(sort.sorted(hosts, scope: 's')).first, 'b');
        await recovery.retry();
        expect(ids(sort.sorted(hosts, scope: 's')).first, 'a');
      } finally {
        recovery.dispose();
      }
    },
  );

  test('requests stay ordered even within the same clock tick or after clock rollback', () {
    final sort = HostSortController();
    final time = Clock.fixed(DateTime.utc(2026, 11, 19));
    withClock(time, () {
      sort.requested('s', ['z']);
      sort.requested('s', ['a']);
    });
    expect(ids(sort.sorted(hosts, scope: 's')), ['a', 'z', 'b']);
    withClock(
      Clock.fixed(DateTime.utc(2025)),
      () => sort.requested('s', ['b']),
    );
    expect(ids(sort.sorted(hosts, scope: 's')), ['b', 'a', 'z']);
  });

  test('all six modes and natural numeric address ordering', () async {
    final sort = HostSortController();
    for (final (order, expected) in [
      (HostSortOrder.nameAscending, ['a', 'b', 'z']),
      (HostSortOrder.nameDescending, ['z', 'b', 'a']),
      (HostSortOrder.address, ['b', 'z', 'a']),
      (HostSortOrder.protocol, ['z', 'b', 'a']),
      (HostSortOrder.favoritesFirst, ['b', 'a', 'z']),
    ]) {
      await sort.select(order);
      expect(ids(sort.sorted(hosts)), expected, reason: order.name);
    }
  });

  test('requests from profiles/accounts/Vaults and servers are isolated', () {
    final sort = HostSortController();
    final scopes = [
      localHostSortScope('p1'),
      localHostSortScope('p2'),
      cloudHostSortScope('one', 'a', 'v1'),
      cloudHostSortScope('one', 'a', 'v2'),
      cloudHostSortScope('one', 'b', 'v1'),
      cloudHostSortScope('two', 'a', 'v1'),
    ];
    sort.requested(scopes.first, ['z']);
    for (final scope in scopes.skip(1)) {
      expect(ids(sort.sorted(hosts, scope: scope)), ['a', 'b', 'z']);
    }
  });

  test(
    'choice and request history survive a restart without storing endpoints',
    () async {
      final store = MemoryHostSortStore();
      final first = HostSortController();
      await first.load(store);
      final scope = cloudHostSortScope(
        'private-server.example',
        'account-id',
        'vault-id',
      );
      first.requested(scope, ['z']);
      await first.select(HostSortOrder.nameDescending);
      final saved = store.value!;
      expect(saved, isNot(contains('private-server')));
      expect(saved, isNot(contains('account-id')));
      expect(saved, isNot(contains('192.0.2.')));
      final second = HostSortController();
      await second.load(store);
      expect(second.order, HostSortOrder.nameDescending);
      await second.select(HostSortOrder.recentRequested);
      expect(ids(second.sorted(hosts, scope: scope)), ['z', 'a', 'b']);
    },
  );

  test('a late preference read never overwrites the user selection', () async {
    final store = _SlowStore();
    final sort = HostSortController();
    final loading = sort.load(store);
    await sort.select(HostSortOrder.address);
    store.readResult.complete(
      jsonEncode({'version': 1, 'order': 'nameDescending', 'requests': {}}),
    );
    await loading;
    expect(sort.order, HostSortOrder.address);
  });

  test(
    'malformed/newer stored preferences and I/O failures stay usable',
    () async {
      for (final value in [
        '{',
        '[]',
        jsonEncode({'version': 2}),
        jsonEncode({
          'version': 1,
          'order': 'not-supported',
          'requests': {'bad': 'wrong'},
        }),
      ]) {
        final sort = HostSortController();
        await sort.load(MemoryHostSortStore(value));
        expect(sort.order, HostSortOrder.recentRequested);
        expect(ids(sort.sorted(hosts)), ['a', 'b', 'z']);
      }
      final sort = HostSortController();
      await sort.load(_FailedStore());
      sort.requested('s', ['z']);
      await sort.select(HostSortOrder.recentRequested);
      expect(ids(sort.sorted(hosts, scope: 's')), ['z', 'a', 'b']);
    },
  );

  test('history stays bounded and retains the latest requests', () async {
    final sort = HostSortController();
    final store = MemoryHostSortStore();
    await sort.load(store);
    sort.requested(
      's',
      List.generate(HostSortController.maxRequests, (i) => 'h$i'),
    );
    sort.requested('s', ['new']);
    await sort.select(HostSortOrder.recentRequested);
    final data = jsonDecode(store.value!) as Map;
    final stored = ((data['requests'] as Map).values.single as Map);
    expect(stored.length, HostSortController.maxRequests);
    expect(stored.containsKey('new'), isTrue);
  });

  test('native preferences round-trip through an atomic file', () async {
    final directory = await Directory.systemTemp.createTemp('host-sort-');
    try {
      final store = FileHostSortStore(directory: () async => directory);
      final first = HostSortController();
      await first.load(store);
      first.requested('s', ['b']);
      await first.select(HostSortOrder.address);
      final second = HostSortController();
      await second.load(FileHostSortStore(directory: () async => directory));
      expect(second.order, HostSortOrder.address);
      expect(second.lastRequested('s', 'b'), isNotNull);
      expect((await directory.list().toList()).length, 1);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
