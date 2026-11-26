// A refresh of the account's Vaults (membership hints, and the account
// refresh that a sync or an SSH host key check runs every 45 seconds) keeps
// the selected Vault selected the whole time. It used to select the account's
// first Vault while it loaded and the selected one again afterwards; the
// workspace took that for a Vault change and dropped the splits of the open
// tabs, closed file tabs, and a reconnect finishing meanwhile was discarded.
//
// Run: ATERMIUS_TEST_SERVER_BINARY=<cargo target>/debug/atermius-server \
//      flutter test test/vault_reload_keeps_selection_test.dart
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';

import 'support/cloud_real_server.dart';

void main() {
  if (realServerBinary == null || !File(realServerBinary!).existsSync()) {
    test(
      'a Vault refresh keeps the selected Vault on a real server',
      () {},
      skip: 'set ATERMIUS_TEST_SERVER_BINARY to the built atermius-server',
    );
    return;
  }
  late TestServer server;

  setUpAll(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = await TestServer.start();
  });

  tearDownAll(() async {
    await server.stop();
  });

  test('a Vault refresh never selects another Vault meanwhile', () async {
    final sodium = await SodiumSumoInit.init();
    final owner = await party(
      sodium,
      server.baseUrl,
      username: 'reload@example.test',
      bootstrap: server.bootstrapToken(),
    );
    final app = owner.app;
    try {
      final first = app.activeVault!.id;
      final created = await app.createVaultInScope('Second');
      await idle(app);
      await app.selectVault(created.vaultId);
      await idle(app);
      final selected = app.activeVault!.id;
      expect(selected, created.vaultId);
      expect(
        app.vaults.first.id,
        first,
        reason: 'the selected Vault must not be the first one listed',
      );

      final seen = <String?>{};
      void record() => seen.add(app.activeVault?.id);
      app.addListener(record);
      try {
        // Notifications from elsewhere (terminal tabs, sync status) arrive
        // while the refresh waits on the server; each one must still see the
        // selected Vault.
        var reloading = true;
        final reload = app.reloadVaultsForTesting().whenComplete(
          () => reloading = false,
        );
        while (reloading) {
          app.notifyListeners();
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        await reload;
      } finally {
        app.removeListener(record);
      }

      expect(seen, {selected});
      expect(app.activeVault?.id, selected);
    } finally {
      app.dispose();
    }
  });
}
