import 'dart:convert';

import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/admin_sync_policy_card.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sync policy GET is authenticated and parses the response', () async {
    late http.Request captured;
    final api = ApiClient(
      baseUrl: 'https://admin.example.test/prefix',
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(_policy(limit: 20, revision: 3)),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..accessToken = 'session-access-token';
    try {
      final policy = await api.instanceAdminSyncPolicy();
      expect(captured.method, 'GET');
      expect(captured.url.path, '/prefix/api/v1/admin/sync-policy');
      expect(captured.headers['authorization'], 'Bearer session-access-token');
      expect(policy.recordHistoryLimit, 20);
      expect(policy.defaultRecordHistoryLimit, 20);
      expect(policy.minRecordHistoryLimit, 2);
      expect(policy.maxRecordHistoryLimit, 1000);
      expect(policy.revision, 3);
      expect(policy.updatedAt, DateTime.utc(2026, 11, 21, 9));
    } finally {
      api.close();
    }
  });

  test(
    'sync policy PUT echoes the revision in the form it was received',
    () async {
      final bodies = <Object?>[];
      final api = ApiClient(
        baseUrl: 'https://admin.example.test',
        client: MockClient((request) async {
          bodies.add(jsonDecode(request.body));
          expect(request.method, 'PUT');
          expect(request.url.path, '/api/v1/admin/sync-policy');
          return http.Response(
            jsonEncode(_policy(limit: 50, revision: 4)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      try {
        final updated = await api.updateInstanceAdminSyncPolicy(
          expectedRevision: 3,
          recordHistoryLimit: 50,
        );
        expect(updated.recordHistoryLimit, 50);
        await api.updateInstanceAdminSyncPolicy(
          expectedRevision: '18446744073709551',
          recordHistoryLimit: 50,
        );
        expect(bodies, [
          {'expected_revision': 3, 'record_history_limit': 50},
          {
            'expected_revision': '18446744073709551',
            'record_history_limit': 50,
          },
        ]);
        await expectLater(
          api.updateInstanceAdminSyncPolicy(
            expectedRevision: -1,
            recordHistoryLimit: 50,
          ),
          throwsArgumentError,
        );
        await expectLater(
          api.updateInstanceAdminSyncPolicy(
            expectedRevision: '3.5',
            recordHistoryLimit: 50,
          ),
          throwsArgumentError,
        );
        expect(bodies, hasLength(2));
      } finally {
        api.close();
      }
    },
  );

  test(
    'sync policy parser accepts both revision forms and rejects bad values',
    () {
      expect(
        InstanceAdminSyncPolicy.fromJson(_policy(limit: 20, revision: 0))
            .revision,
        0,
      );
      expect(
        InstanceAdminSyncPolicy.fromJson(_policy(limit: 20, revision: '7'))
            .revision,
        '7',
      );
      expect(
        InstanceAdminSyncPolicy.fromJson({
          ..._policy(limit: 20, revision: 1),
          'updated_at': null,
        }).updatedAt,
        isNull,
      );
      for (final revision in [-1, '07', 'abc', 1.5, null, true]) {
        expect(
          () => InstanceAdminSyncPolicy.fromJson(
            _policy(limit: 20, revision: revision),
          ),
          throwsFormatException,
        );
      }
      for (final limit in [1, 1001, '20', null]) {
        expect(
          () => InstanceAdminSyncPolicy.fromJson(
            _policy(limit: limit, revision: 1),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => InstanceAdminSyncPolicy.fromJson({
          ..._policy(limit: 20, revision: 1),
          'updated_at': 'yesterday',
        }),
        throwsFormatException,
      );
    },
  );

  testWidgets('admin loads, validates and saves the history limit', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      await _pumpCard(tester, harness.app);
      expect(find.text('Record version history'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('admin-sync-policy-history-limit')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('admin-sync-policy-load')));
      await tester.pumpAndSettle();
      expect(harness.api.loads, 1);
      expect(find.text('Versions kept per record'), findsOneWidget);
      expect(find.text('20'), findsOneWidget);
      expect(find.text('Server default: 20'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('admin-sync-policy-history-limit')),
        '1',
      );
      await tester.tap(find.byKey(const ValueKey('admin-sync-policy-save')));
      await tester.pump();
      expect(find.text('Enter a whole number from 2 to 1000.'), findsOneWidget);
      expect(harness.api.saves, isEmpty);

      await tester.enterText(
        find.byKey(const ValueKey('admin-sync-policy-history-limit')),
        '50',
      );
      await tester.tap(find.byKey(const ValueKey('admin-sync-policy-save')));
      await tester.pumpAndSettle();
      expect(harness.api.saves, [
        {'expected_revision': 3, 'record_history_limit': 50},
      ]);
      expect(find.text('History limit saved.'), findsOneWidget);
      expect(harness.app.instanceAdminSyncPolicy?.recordHistoryLimit, 50);
      expect(harness.app.instanceAdminSyncPolicy?.revision, 4);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('a stale revision reloads the policy and tells the admin', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      await _pumpCard(tester, harness.app);
      await tester.tap(find.byKey(const ValueKey('admin-sync-policy-load')));
      await tester.pumpAndSettle();

      // Another admin saves 80 first; this admin's revision 3 is now stale.
      harness.api
        ..policy = _policy(limit: 80, revision: 4)
        ..saveError = const ApiException(
          statusCode: 409,
          code: 'SYNC_POLICY_CONFLICT',
          message: 'The sync policy changed.',
        );
      await tester.enterText(
        find.byKey(const ValueKey('admin-sync-policy-history-limit')),
        '50',
      );
      await tester.tap(find.byKey(const ValueKey('admin-sync-policy-save')));
      await tester.pumpAndSettle();

      expect(harness.api.saves, [
        {'expected_revision': 3, 'record_history_limit': 50},
      ]);
      expect(harness.api.loads, 2);
      expect(
        find.text(
          'The history limit was changed elsewhere. The latest value is shown; check it and save again.',
        ),
        findsOneWidget,
      );
      // The field shows the other admin's value, not the rejected draft.
      expect(find.text('80'), findsOneWidget);
      expect(find.text('50'), findsNothing);
      expect(find.text('History limit saved.'), findsNothing);

      // Saving again uses the reloaded revision.
      harness.api.saveError = null;
      await tester.enterText(
        find.byKey(const ValueKey('admin-sync-policy-history-limit')),
        '60',
      );
      await tester.tap(find.byKey(const ValueKey('admin-sync-policy-save')));
      await tester.pumpAndSettle();
      expect(harness.api.saves.last, {
        'expected_revision': 4,
        'record_history_limit': 60,
      });
      expect(find.text('History limit saved.'), findsOneWidget);
    } finally {
      await _dispose(tester, harness);
    }
  });

  testWidgets('an older server and a non-admin account get a plain message', (
    tester,
  ) async {
    final harness = await _Harness.create(isAdmin: true);
    try {
      harness.api.loadError = const ApiException(
        statusCode: 404,
        code: 'NOT_FOUND',
        message: 'No such route.',
      );
      await _pumpCard(tester, harness.app);
      await tester.tap(find.byKey(const ValueKey('admin-sync-policy-load')));
      await tester.pumpAndSettle();
      expect(
        find.text('This server does not support the history limit setting.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('admin-sync-policy-save')),
        findsNothing,
      );
    } finally {
      await _dispose(tester, harness);
    }

    final member = await _Harness.create(isAdmin: false);
    try {
      await _pumpCard(tester, member.app);
      await tester.tap(find.byKey(const ValueKey('admin-sync-policy-load')));
      await tester.pumpAndSettle();
      expect(member.api.loads, 0);
      expect(
        find.byKey(const ValueKey('admin-sync-policy-save')),
        findsNothing,
      );
    } finally {
      await _dispose(tester, member);
    }
  });
}

Map<String, dynamic> _policy({
  required Object? limit,
  required Object? revision,
}) => {
  'record_history_limit': limit,
  'default_record_history_limit': 20,
  'min_record_history_limit': 2,
  'max_record_history_limit': 1000,
  'revision': revision,
  'updated_at': '2026-11-21T09:00:00Z',
};

Future<void> _pumpCard(WidgetTester tester, AppController app) async {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ListenableBuilder(
            listenable: app,
            builder: (_, _) => InstanceAdminSyncPolicyCard(app: app),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _dispose(WidgetTester tester, _Harness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  harness.app.dispose();
  harness.api.close();
  await harness.database.close();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

class _Harness {
  _Harness(this.database, this.api, this.app);

  final ClientDatabase database;
  final _SyncPolicyApi api;
  final AppController app;

  static Future<_Harness> create({required bool isAdmin}) async {
    final sodium = await SodiumSumoInit.init();
    final database = ClientDatabase.forTesting(NativeDatabase.memory());
    final api = _SyncPolicyApi();
    final app =
        AppController(
            sodium: sodium,
            database: database,
            secureStore: ClientSecureStore(),
          )
          ..api = api
          ..account = AccountProfile(
            accountId: 'account-123',
            deviceId: 'device-456',
            accountKeyEnvelopeVersion: 1,
            accountKeyEnvelope: const {},
            policy: {'instance_admin': isAdmin},
          );
    return _Harness(database, api, app);
  }
}

class _SyncPolicyApi extends ApiClient {
  _SyncPolicyApi()
    : super(
        baseUrl: 'https://admin-widget.example.test',
        client: MockClient((_) async => throw StateError('Unexpected request')),
      );

  Map<String, dynamic> policy = _policy(limit: 20, revision: 3);
  int loads = 0;
  final List<Map<String, Object?>> saves = [];
  ApiException? loadError;
  ApiException? saveError;

  @override
  Future<InstanceAdminSyncPolicy> instanceAdminSyncPolicy() async {
    loads++;
    if (loadError case final error?) throw error;
    return InstanceAdminSyncPolicy.fromJson(policy);
  }

  @override
  Future<InstanceAdminSyncPolicy> updateInstanceAdminSyncPolicy({
    required Object expectedRevision,
    required int recordHistoryLimit,
  }) async {
    saves.add({
      'expected_revision': expectedRevision,
      'record_history_limit': recordHistoryLimit,
    });
    if (saveError case final error?) throw error;
    policy = _policy(
      limit: recordHistoryLimit,
      revision: (expectedRevision as int) + 1,
    );
    return InstanceAdminSyncPolicy.fromJson(policy);
  }
}
