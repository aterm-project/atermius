// Team Vault UI on the real controller and server: the organization page
// section, "New team Vault", and a Host's "Put in Vault…" dialog, wide and
// phone-narrow, in two languages.
import 'dart:io';

import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/cloud_access/organizations_page.dart';
import 'package:aterm_client/ui/cloud_access/share_host_dialog.dart';
import 'package:aterm_client/ui/cloud_access/team_vaults.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/cloud_real_server.dart';

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 400 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue);
}

/// Progress bars animate forever, so settle by time instead.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<T> _drive<T>(WidgetTester tester, Future<T> Function() work) async {
  T? value;
  Object? failure;
  var finished = false;
  work().then(
    (v) {
      value = v;
      finished = true;
    },
    onError: (Object e) {
      failure = e;
      finished = true;
    },
  );
  await _until(tester, () => finished);
  if (failure != null) throw failure!;
  return value as T;
}

void main() {
  if (realServerBinary == null || !File(realServerBinary!).existsSync()) {
    testWidgets('team Vault UI requires real server', (_) async {}, skip: true);
    return;
  }
  late SodiumSumo sodium;
  setUpAll(() async {
    HttpOverrides.global = null;
    FlutterSecureStorage.setMockInitialValues({});
    sodium = await SodiumSumoInit.init();
  });

  for (final (locale, width) in [
    (const Locale('en'), 1280.0),
    (const Locale('zh'), 390.0),
  ]) {
    testWidgets('create a team Vault and put a Host in it at $width '
        '${locale.languageCode}', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final l10n = await AppLocalizations.delegate.load(locale);
      final host = testHost('Host-${locale.languageCode}');
      // A controller of its own per test: the UI flow starts controller
      // timers in the test zone, and disposing the controller at the end is
      // what cancels them.
      late TestServer server;
      late Party owner;
      late String orgId, teamId, personalId;
      await tester.runAsync(() async {
        server = await TestServer.start();
        owner = await party(
          sodium,
          server.baseUrl,
          username: 'tv-owner@example.test',
          storagePrefix: 'tv${locale.languageCode}.',
          bootstrap: server.bootstrapToken(),
        );
        personalId = owner.app.activeVault!.id;
        orgId =
            (await owner.service.api.createOrg('Ops org'))['org_id'] as String;
        teamId =
            (await owner.service.api.createTeam(orgId, 'SRE'))['team_id']
                as String;
        await owner.app.saveHost(host);
        await owner.app.synchronize();
        await idle(owner.app);
      });
      final before = owner.app.vaults.map((v) => v.id).toSet();

      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizationSetup.delegates,
          supportedLocales: AppLocalizationSetup.locales,
          theme: buildAppTheme(locale: locale),
          home: OrganizationDetailPage(service: owner.service, orgId: orgId),
        ),
      );
      await _until(
        tester,
        () => find
            .byKey(const ValueKey('org-team-vault-new'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.text(l10n.teamVaultsHeading), findsOneWidget);
      expect(tester.takeException(), isNull);

      // New team Vault: name, team as Editor, create.
      await tester.ensureVisible(
        find.byKey(const ValueKey('org-team-vault-new')),
      );
      await tester.tap(find.byKey(const ValueKey('org-team-vault-new')));
      await _until(
        tester,
        () => find
            .byKey(ValueKey('team-vault-grant-team:$teamId'))
            .evaluate()
            .isNotEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.enterText(
        find.byKey(const ValueKey('team-vault-name')),
        'SRE ${locale.languageCode}',
      );
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey('team-vault-grant-team:$teamId')),
          matching: find.byType(DropdownButton<String>),
        ),
      );
      await _settle(tester);
      await tester.tap(find.text(l10n.cloudAccessRoleEditor).last);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('team-vault-create')));
      await _until(
        tester,
        () => find.byType(VaultGrantsPanel).evaluate().isNotEmpty,
      );
      await _until(
        tester,
        () =>
            find.text(l10n.cloudAccessTeamLabel('SRE')).evaluate().isNotEmpty ||
            find.text('SRE').evaluate().isNotEmpty,
      );
      expect(tester.takeException(), isNull);
      final created = owner.app.vaults
          .map((v) => v.id)
          .where((id) => !before.contains(id))
          .single;
      expect(owner.app.vaultOrganization(created)?.id, orgId);
      expect(owner.app.activeVault?.id, personalId);
      await tester.tap(find.byKey(const ValueKey('team-vault-created-done')));
      await _settle(tester);
      // The organization page lists it.
      expect(find.byKey(ValueKey('org-team-vault-$created')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Put the Host in it (move is the default for a writable source).
      final context = tester.element(find.byType(OrganizationDetailPage));
      final result = showPutHostsInVaultDialog(
        context,
        app: owner.app,
        hosts: [owner.app.hosts.firstWhere((h) => h.id == host.id)],
      );
      await _settle(tester);
      expect(find.text(l10n.teamVaultPutTitle(host.name)), findsOneWidget);
      expect(
        find.byKey(ValueKey('team-vault-target-$created')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(ValueKey('team-vault-target-$created')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('team-vault-put-confirm')));
      final done = await _drive(tester, () => result);
      expect(done, isTrue);
      expect(tester.takeException(), isNull);
      await _settle(tester);
      expect(owner.app.activeVault?.id, personalId);
      expect(owner.app.hosts.map((h) => h.id), isNot(contains(host.id)));
      // Work started from the widget tree may wait on timers of the test
      // zone, so keep pumping while the controller verifies the result.
      final names = await _drive(tester, () async {
        await owner.app.selectVault(created);
        await owner.app.synchronize();
        await idle(owner.app);
        final found = owner.app.hosts.map((h) => h.name).toList();
        await owner.app.selectVault(personalId);
        await idle(owner.app);
        return found;
      });
      expect(names, [host.name]);
      await tester.pumpWidget(const SizedBox.shrink());
      owner.app.dispose();
      owner.client.close();
      await tester.runAsync(server.stop);
      await tester.pump(const Duration(seconds: 31));
    });
  }
}
