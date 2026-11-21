// Layout of the Groups and Keychain pages: phone widths, large text and the
// longest languages must not overflow, and the cards keep what each Group
// and Keychain item is about readable at a glance.
import 'package:aterm_client/api/api_client.dart';
import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/storage/client_database.dart';
import 'package:aterm_client/storage/secure_store.dart';
import 'package:aterm_client/ui/app_shell.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

const _vaultId = '11111111-1111-4111-8111-111111111111';

/// ssh-keygen user certificates of a throwaway test CA: one valid until
/// 2099, one that expired in 2021.
const _validCertificate =
    'ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjA'
    'xQG9wZW5zc2guY29tAAAAIKWuSJTmHqhLt1oXgWf8AEF93idL0Wiad7/D1RLIHog'
    'kAAAAIJzCoRmdEduLYIQM+xp0h2kf4YidrDBmUrTzTqwcg4FcAAAAAAAAAAAAAAA'
    'BAAAACG9wcy0yMDI2AAAAEgAAAAZkZXBsb3kAAAAEcm9vdAAAAABpVbkAAAAAAPK'
    'lI4AAAAAAAAAAggAAABVwZXJtaXQtWDExLWZvcndhcmRpbmcAAAAAAAAAF3Blcm1'
    'pdC1hZ2VudC1mb3J3YXJkaW5nAAAAAAAAABZwZXJtaXQtcG9ydC1mb3J3YXJkaW5'
    'nAAAAAAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAA'
    'AAAAAMwAAAAtzc2gtZWQyNTUxOQAAACBbeWFoPh5M1I7zp+PeiUvghOvOoRy+dRK'
    '3+i9fL0tCNQAAAFMAAAALc3NoLWVkMjU1MTkAAABAivTojhRPNXReYedPBHXP0LN'
    '0nCn3uWrrV/DzYtZh1c6pJJ/5ESK6sSUEhstUBZIpZaxYl4SoKK5IJCHgyjV/DA='
    '=';
const _expiredCertificate =
    'ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjA'
    'xQG9wZW5zc2guY29tAAAAIM3BapyK7odKV2nr9XRrEkdjJPHTP/tGXhGKQoll8e4'
    '0AAAAIDQTMFpMeV1afqQ94z8rvi7M5naUj3+6Mq9IX5HrOFdfAAAAAAAAAAAAAAA'
    'BAAAAE2xlZ2FjeS1iYXN0aW9uLTIwMjAAAAAHAAAAA29wcwAAAABeC+EAAAAAAF/'
    'uZgAAAAAAAAAAggAAABVwZXJtaXQtWDExLWZvcndhcmRpbmcAAAAAAAAAF3Blcm1'
    'pdC1hZ2VudC1mb3J3YXJkaW5nAAAAAAAAABZwZXJtaXQtcG9ydC1mb3J3YXJkaW5'
    'nAAAAAAAAAApwZXJtaXQtcHR5AAAAAAAAAA5wZXJtaXQtdXNlci1yYwAAAAAAAAA'
    'AAAAAMwAAAAtzc2gtZWQyNTUxOQAAACBbeWFoPh5M1I7zp+PeiUvghOvOoRy+dRK'
    '3+i9fL0tCNQAAAFMAAAALc3NoLWVkMjU1MTkAAABAVILhAXmaQC5nFO7fxdTBXsU'
    'rGvRSxw93Rp72Kc77s+uGcq7AnEHO8Q2h4BVBrHzsbXcS2eFFUxEZ89BEhvIVAg='
    '=';

void _seed(AppController app) {
  app.groups.addAll(const [
    GroupRecord(
      id: 'g-prod',
      name: 'Production',
      color: 0x4FC3F7,
      defaultCredentialId: 'c-key',
    ),
    GroupRecord(
      id: 'g-eu',
      name: 'European customer databases and their read replicas',
      color: 0x81C784,
      parentId: 'g-prod',
    ),
    GroupRecord(
      id: 'g-lab',
      name: 'Lab',
      color: 0xBA68C8,
      defaultCredentialId: 'c-missing',
    ),
    GroupRecord(id: 'g-loop-a', name: 'Cycle Alpha', parentId: 'g-loop-b'),
    GroupRecord(
      id: 'g-loop-b',
      name: 'Cycle Beta',
      parentId: 'g-loop-a',
      color: 3,
    ),
    GroupRecord(id: 'g-empty', name: 'Empty'),
  ]);
  app.credentials.addAll(const [
    CredentialRecord(
      id: 'c-key',
      name: 'Operations deploy key for the production fleet',
      username: 'deploy',
      kind: AuthKind.privateKey,
      fingerprint: 'SHA256:3f9a1c0e8b7d6a5f4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c9b',
    ),
    CredentialRecord(
      id: 'c-password',
      name: 'Windows administrator',
      username: 'Administrator',
    ),
    CredentialRecord(
      id: 'c-cert',
      name: 'CA-signed operations identity',
      username: 'deploy',
      kind: AuthKind.privateKey,
      fingerprint: 'SHA256:W3lhaD4eTNSO86fj3olL4ITrzqEcvnUSt/ovXy9LQjU',
      certificate: _validCertificate,
    ),
    CredentialRecord(
      id: 'c-expired',
      name: 'Legacy bastion',
      username: 'ops',
      kind: AuthKind.privateKey,
      certificate: _expiredCertificate,
    ),
    CredentialRecord(id: 'c-unused', name: 'Router console', username: 'admin'),
  ]);
  app.hosts.addAll(const [
    HostRecord(
      id: 'h1',
      name: 'db-primary',
      address: '10.0.1.21',
      groupId: 'g-prod',
      credentialId: 'c-key',
    ),
    HostRecord(
      id: 'h2',
      name: 'build-windows-runner',
      address: '10.0.3.40',
      protocol: HostProtocol.rdp,
      groupId: 'g-eu',
      credentialId: 'c-password',
    ),
    HostRecord(
      id: 'h3',
      name: 'core-switch',
      address: '192.168.10.1',
      protocol: HostProtocol.telnet,
      groupId: 'g-lab',
    ),
    HostRecord(
      id: 'h4',
      name: 'lab-desktop',
      address: '10.9.0.5',
      protocol: HostProtocol.vnc,
      groupId: 'g-lab',
    ),
    HostRecord(
      id: 'h5',
      name: 'db-eu-1',
      address: '10.2.0.1',
      groupId: 'g-eu',
      credentialId: 'c-cert',
    ),
    HostRecord(
      id: 'h6',
      name: 'db-eu-2',
      address: '10.2.0.2',
      groupId: 'g-eu',
      credentialId: 'c-cert',
    ),
    HostRecord(
      id: 'h7',
      name: 'bastion',
      address: '10.2.0.9',
      credentialId: 'c-expired',
    ),
  ]);
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required WorkspacePage page,
  required Size size,
  required Locale locale,
  double textScale = 1,
  bool canWrite = true,
  Future<void> Function(AppController app)? expectations,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  final previousL10n = currentL10n;
  debugCurrentL10n = lookupAppLocalizations(locale);
  final sodium = await SodiumSumoInit.init();
  final database = ClientDatabase.forTesting(NativeDatabase.memory());
  final app =
      AppController(
          sodium: sodium,
          database: database,
          secureStore: ClientSecureStore(),
        )
        ..stage = ClientStage.workspace
        ..page = page
        ..activeVault = VaultDescriptor(
          id: _vaultId,
          role: canWrite ? 'owner' : 'viewer',
          activeKeyEpoch: '1',
          membershipVersion: '1',
          canWrite: canWrite,
        );
  _seed(app);
  try {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizationSetup.delegates,
        supportedLocales: AppLocalizationSetup.locales,
        theme: buildAppTheme(locale: locale),
        home: AppShell(controller: app),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await expectations?.call(app);
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
    await database.close();
    debugCurrentL10n = previousL10n;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  }
}

Finder _inCard(String groupId, Finder matching) => find.descendant(
  of: find.byKey(ValueKey('server_group_$groupId')),
  matching: matching,
);

Finder _inRow(String credentialId, Finder matching) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) =>
        widget is Semantics &&
        widget.properties.identifier == 'ssh-credential-$credentialId',
  ),
  matching: matching,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pages = {
    'groups': WorkspacePage.groups,
    'keychain': WorkspacePage.credentials,
  };

  for (final MapEntry(key: name, value: page) in pages.entries) {
    for (final lang in ['en', 'zh', 'ru']) {
      for (final width in [320.0, 390.0]) {
        testWidgets('$name fits a ${width.toInt()} px phone in $lang', (
          tester,
        ) async {
          await _pumpPage(
            tester,
            page: page,
            size: Size(width, 2600),
            locale: Locale(lang),
          );
        });
      }
    }

    for (final width in [320.0, 390.0]) {
      testWidgets('$name fits a ${width.toInt()} px phone at 1.5x text in '
          'Russian', (tester) async {
        await _pumpPage(
          tester,
          page: page,
          size: Size(width, 4000),
          locale: const Locale('ru'),
          textScale: 1.5,
        );
      });
    }

    // Two and three card columns, where every card of a row is stretched
    // to the tallest one.
    for (final width in [900.0, 1440.0]) {
      testWidgets('$name fits a ${width.toInt()} px window at 1.5x text in '
          'Russian', (tester) async {
        await _pumpPage(
          tester,
          page: page,
          size: Size(width, 2400),
          locale: const Locale('ru'),
          textScale: 1.5,
        );
      });
    }
  }

  testWidgets('Group cards show colour, contents and default credential', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.groups,
      size: const Size(1440, 1400),
      locale: const Locale('en'),
      expectations: (app) async {
        expect(find.text('6 groups'), findsOneWidget);
        expect(find.text('6 hosts in groups'), findsOneWidget);
        expect(find.text('1 host without a group'), findsOneWidget);

        // Sorted by name, three to a row, one height per row.
        final alpha = tester.getRect(
          find.byKey(const ValueKey('server_group_g-loop-a')),
        );
        final beta = tester.getRect(
          find.byKey(const ValueKey('server_group_g-loop-b')),
        );
        final empty = tester.getRect(
          find.byKey(const ValueKey('server_group_g-empty')),
        );
        final europe = tester.getRect(
          find.byKey(const ValueKey('server_group_g-eu')),
        );
        expect(beta.top, alpha.top);
        expect(empty.top, alpha.top);
        expect(beta.height, alpha.height);
        expect(empty.height, alpha.height);
        expect(beta.left, greaterThan(alpha.right));
        expect(europe.top, greaterThan(alpha.bottom));
        expect(europe.left, alpha.left);

        Color badge(String id) => tester
            .widget<Icon>(_inCard(id, find.byIcon(Icons.folder_copy_outlined)))
            .color!;
        expect(badge('g-lab'), const Color(0xFFBA68C8));
        // A palette index is not drawn as a near-black RGB value.
        expect(badge('g-loop-b'), isNot(const Color(0xFF000003)));

        expect(_inCard('g-eu', find.text('Inside Production')), findsOneWidget);
        expect(_inCard('g-eu', find.text('3 hosts')), findsOneWidget);
        expect(_inCard('g-eu', find.text('SSH')), findsOneWidget);
        expect(_inCard('g-eu', find.text('2')), findsOneWidget);
        expect(_inCard('g-eu', find.text('RDP')), findsOneWidget);
        expect(_inCard('g-lab', find.text('Telnet')), findsOneWidget);
        expect(_inCard('g-lab', find.text('VNC')), findsOneWidget);
        expect(_inCard('g-prod', find.text('1 subgroup')), findsOneWidget);
        expect(
          _inCard(
            'g-prod',
            find.text(
              'Default credential: '
              'Operations deploy key for the production fleet',
            ),
          ),
          findsOneWidget,
        );
        expect(
          _inCard('g-lab', find.text('Default credential unavailable')),
          findsOneWidget,
        );
        expect(_inCard('g-empty', find.text('No hosts yet')), findsOneWidget);
        expect(
          _inCard('g-empty', find.text('No default credential')),
          findsOneWidget,
        );
        expect(
          _inCard('g-loop-a', find.text('Parent relationship needs repair')),
          findsOneWidget,
        );
      },
    );
  });

  testWidgets('deleting an unused Group asks in the page language', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.groups,
      size: const Size(1440, 1400),
      locale: const Locale('zh'),
      expectations: (app) async {
        final zh = lookupAppLocalizations(const Locale('zh'));
        await tester.tap(
          find.byKey(const ValueKey('server_group_actions_g-empty')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(zh.deleteGroup3).last);
        await tester.pumpAndSettle();
        expect(find.text(zh.groupsDeleteConfirmBody('Empty')), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('server_group_delete_cancel')),
        );
        await tester.pumpAndSettle();
      },
    );
  });

  testWidgets('Keychain rows show type, usage and certificate state', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.credentials,
      size: const Size(1440, 1400),
      locale: const Locale('en'),
      expectations: (app) async {
        expect(_inRow('c-key', find.text('SSH key')), findsOneWidget);
        expect(_inRow('c-password', find.text('Password')), findsOneWidget);
        expect(_inRow('c-cert', find.text('Certificate')), findsOneWidget);
        expect(_inRow('c-expired', find.text('Certificate')), findsOneWidget);

        expect(_inRow('c-key', find.text('1 host · 1 group')), findsOneWidget);
        expect(
          _inRow('c-key', find.text('Host “db-primary”, Group "Production"')),
          findsOneWidget,
        );
        expect(_inRow('c-cert', find.text('2 hosts')), findsOneWidget);
        expect(
          _inRow('c-unused', find.text('Not used by any host or group')),
          findsOneWidget,
        );
        expect(
          _inRow(
            'c-key',
            find.text(
              'SHA256:3f9a1c0e8b7d6a5f4e3d2c1b0a9f8e7d6c5b4a3f2e1d0c9b',
            ),
          ),
          findsOneWidget,
        );
        expect(
          _inRow('c-cert', find.textContaining('principals: deploy, root')),
          findsOneWidget,
        );
        final expired = tester.widget<Text>(
          _inRow('c-expired', find.textContaining('expired')),
        );
        expect(
          expired.style?.color,
          isNot(
            tester
                .widget<Text>(
                  _inRow('c-cert', find.textContaining('valid until')),
                )
                .style
                ?.color,
          ),
        );
      },
    );
  });

  testWidgets('Keychain type filters count and narrow the list', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.credentials,
      size: const Size(1440, 1400),
      locale: const Locale('en'),
      expectations: (app) async {
        Finder chip(String filter) =>
            find.byKey(ValueKey('cloud_keychain_filter_$filter'));
        expect(
          find.descendant(of: chip('all'), matching: find.text('5')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: chip('passwords'), matching: find.text('2')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: chip('keys'), matching: find.text('3')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: chip('certificates'), matching: find.text('2')),
          findsOneWidget,
        );

        await tester.tap(chip('certificates'));
        await tester.pump();
        expect(find.text('CA-signed operations identity'), findsOneWidget);
        expect(find.text('Legacy bastion'), findsOneWidget);
        expect(find.text('Router console'), findsNothing);

        await tester.tap(chip('passwords'));
        await tester.pump();
        expect(find.text('Router console'), findsOneWidget);
        expect(find.text('Legacy bastion'), findsNothing);

        await tester.tap(chip('all'));
        await tester.pump();
        // The search hint promises host names too.
        await tester.enterText(
          find.byKey(const ValueKey('keychain_search')),
          'build-windows',
        );
        await tester.pump();
        expect(find.text('Windows administrator'), findsOneWidget);
        expect(find.text('Router console'), findsNothing);
        // Not the "Host" word of the usage labels.
        await tester.enterText(
          find.byKey(const ValueKey('keychain_search')),
          'host',
        );
        await tester.pump();
        expect(find.text('Windows administrator'), findsNothing);

        await tester.enterText(
          find.byKey(const ValueKey('keychain_search')),
          'no such credential',
        );
        await tester.pump();
        expect(
          find.text('Nothing matches the current search or filter.'),
          findsOneWidget,
        );
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pump();
        expect(find.text('Router console'), findsOneWidget);
      },
    );
  });

  testWidgets('tapping a Keychain row opens it; read-only opens the viewer', (
    tester,
  ) async {
    await _pumpPage(
      tester,
      page: WorkspacePage.credentials,
      size: const Size(1440, 1400),
      locale: const Locale('en'),
      expectations: (app) async {
        await tester.tap(find.text('Router console'));
        await tester.pumpAndSettle();
        expect(find.text('Save encrypted credential'), findsOneWidget);
      },
    );
    await _pumpPage(
      tester,
      page: WorkspacePage.credentials,
      size: const Size(1440, 1400),
      locale: const Locale('en'),
      canWrite: false,
      expectations: (app) async {
        await tester.tap(find.text('Router console'));
        await tester.pumpAndSettle();
        expect(find.text('View credential'), findsOneWidget);
        expect(find.text('Save encrypted credential'), findsNothing);
      },
    );
  });
}
