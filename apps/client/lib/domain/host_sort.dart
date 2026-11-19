import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../storage/host_sort_store.dart';
import 'models.dart';

enum HostSortOrder {
  recentRequested,
  nameAscending,
  nameDescending,
  address,
  protocol,
  favoritesFirst,
}

String localHostSortScope(String profileId) => jsonEncode(['local', profileId]);
String cloudHostSortScope(String server, String account, String vault) =>
    jsonEncode(['cloud', server, account, vault]);

/// One device-wide order, with recent requests isolated by profile/account/Vault.
/// Request metadata stays outside synchronized Host records. Recording never
/// waits for disk I/O or the connection result.
class HostSortController extends ChangeNotifier {
  static HostSortController? _instance;
  static HostSortController get instance => _instance ??= HostSortController();
  @visibleForTesting
  static set debugInstance(HostSortController? value) => _instance = value;

  static const maxRequests = 1000;
  HostSortStore? _store;
  HostSortOrder order = HostSortOrder.recentRequested;
  final _requests = <String, Map<String, int>>{};
  Future<void>? _writes;
  int _revision = 0, _sequence = 0;
  bool _disposed = false;

  static bool _validHostId(Object? id) =>
      id is String &&
      id.isNotEmpty &&
      utf8.encode(id).length <= 128 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(id);

  String _key(String scope) => sha256.convert(utf8.encode(scope)).toString();
  int? lastRequested(String? scope, String hostId) =>
      scope == null ? null : _requests[_key(scope)]?[hostId];

  Future<void> load(HostSortStore store) async {
    _store = store;
    final revision = _revision;
    try {
      final raw = await store.read().timeout(const Duration(seconds: 2));
      if (_disposed ||
          revision != _revision ||
          raw == null ||
          raw.length > 524288)
        return;
      final data = jsonDecode(raw);
      if (data is! Map || data['version'] != 1) return;
      final savedOrder = HostSortOrder.values
          .where((v) => v.name == data['order'])
          .firstOrNull;
      final requests = <String, Map<String, int>>{};
      final scopes = data['requests'];
      if (scopes is Map) {
        for (final entry in scopes.entries) {
          if (entry.key is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key as String) ||
              entry.value is! Map)
            continue;
          final values = <String, int>{};
          for (final host in (entry.value as Map).entries) {
            if (_validHostId(host.key) &&
                host.value is int &&
                (host.value as int) > 0 &&
                (host.value as int) <= 8640000000000000) {
              values[host.key as String] = host.value as int;
              _sequence = math.max(_sequence, host.value as int);
            }
          }
          if (values.isNotEmpty) requests[entry.key as String] = values;
        }
      }
      order = savedOrder ?? HostSortOrder.recentRequested;
      _requests
        ..clear()
        ..addAll(requests);
      _trim();
      notifyListeners();
    } on Object {
      // Storage unavailable or malformed: use the default in this run.
    }
  }

  Future<void> select(HostSortOrder value) {
    if (_disposed) return Future.value();
    _revision++;
    order = value;
    notifyListeners();
    return _save();
  }

  void requested(String? scope, Iterable<String> hostIds) {
    if (_disposed || scope == null || scope.isEmpty) return;
    final ids = hostIds.where(_validHostId).toSet();
    if (ids.isEmpty) return;
    _revision++;
    _sequence = math.max(_sequence + 1, clock.now().microsecondsSinceEpoch);
    final recent = _requests.putIfAbsent(_key(scope), () => {});
    for (final id in ids) {
      recent[id] = _sequence;
    }
    _trim();
    notifyListeners();
    unawaited(_save());
  }

  List<HostRecord> sorted(Iterable<HostRecord> hosts, {String? scope}) {
    final recent = scope == null ? null : _requests[_key(scope)];
    int name(HostRecord a, HostRecord b) {
      final comparison = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return comparison != 0 ? comparison : a.id.compareTo(b.id);
    }

    int compare(HostRecord a, HostRecord b) {
      final result = switch (order) {
        HostSortOrder.recentRequested => (recent?[b.id] ?? 0).compareTo(
          recent?[a.id] ?? 0,
        ),
        HostSortOrder.nameAscending => name(a, b),
        HostSortOrder.nameDescending => name(b, a),
        HostSortOrder.address => _address(a, b),
        HostSortOrder.protocol => a.protocol.name.compareTo(b.protocol.name),
        HostSortOrder.favoritesFirst => (b.isFavorite ? 1 : 0).compareTo(
          a.isFavorite ? 1 : 0,
        ),
      };
      return result == 0 ? name(a, b) : result;
    }

    return hosts.toList()..sort(compare);
  }

  static int _address(HostRecord a, HostRecord b) {
    // Natural numeric chunks keep IPv4 addresses and numbered hostnames useful.
    final chunks = RegExp(r'\d+|\D+');
    final left = chunks
        .allMatches(a.address.toLowerCase())
        .map((m) => m.group(0)!)
        .toList();
    final right = chunks
        .allMatches(b.address.toLowerCase())
        .map((m) => m.group(0)!)
        .toList();
    for (var i = 0; i < math.min(left.length, right.length); i++) {
      final x = int.tryParse(left[i]), y = int.tryParse(right[i]);
      final result = x != null && y != null
          ? x.compareTo(y)
          : left[i].compareTo(right[i]);
      if (result != 0) return result;
    }
    final result = left.length.compareTo(right.length);
    return result == 0 ? a.port.compareTo(b.port) : result;
  }

  void _trim() {
    final entries = [
      for (final scope in _requests.entries)
        for (final host in scope.value.entries)
          (scope: scope.key, id: host.key, time: host.value),
    ];
    if (entries.length <= maxRequests) return;
    entries.sort((a, b) => b.time.compareTo(a.time));
    for (final old in entries.skip(maxRequests)) {
      _requests[old.scope]?.remove(old.id);
    }
    _requests.removeWhere((_, values) => values.isEmpty);
  }

  Future<void> _save() {
    final store = _store;
    if (store == null) return Future.value();
    final value = jsonEncode({
      'version': 1,
      'order': order.name,
      'requests': _requests,
    });
    return _writes = (_writes ?? Future<void>.value()).then((_) async {
      try {
        await store.write(value);
      } on Object {
        /* Sorting remains usable. */
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
