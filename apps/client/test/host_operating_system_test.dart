import 'dart:async';

import 'package:aterm_client/domain/host_operating_system.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/host_operating_system_probe.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';

String linuxRelease(String body) =>
    'Linux\n__ATERMIUS_RELEASE__\n$body\n__ATERMIUS_KERNEL__\n6.8.0\n__ATERMIUS_MACOS__\n';
SshExecResult result(String output, {bool truncated = false}) => SshExecResult(
  stdout: output,
  stderr: '',
  exitCode: 0,
  exitSignal: null,
  outputTruncated: truncated,
);

void main() {
  test('reads Linux release data without evaluating shell syntax', () {
    for (final distro in [
      'ubuntu',
      'debian',
      'alpine',
      'rhel',
      'fedora',
      'arch',
      'rocky',
      'opensuse-leap',
    ]) {
      final system = parseHostOperatingSystem(
        linuxRelease(
          'ID=$distro\nPRETTY_NAME="Example Linux"\nVERSION_ID="24.04"',
        ),
      )!;
      expect(system.family, HostOperatingSystemFamily.linux);
      expect(system.distributionId, distro);
      expect(system.displayName, 'Example Linux');
      expect(system.version, '24.04');
    }
    final injected = parseHostOperatingSystem(
      linuxRelease(r'ID=$(touch /tmp/not-run)'),
    )!;
    expect(injected.distributionId, isNull);
    expect(injected.displayName, 'Linux');
    expect(
      hostOperatingSystemUnixCommand,
      isNot(contains('. /etc/os-release')),
    );
    expect(hostOperatingSystemUnixCommand, isNot(contains('source ')));
  });

  test('keeps the systems a distribution is derived from', () {
    final mint = parseHostOperatingSystem(
      linuxRelease(
        'NAME="Linux Mint"\nID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_ID="22"',
      ),
    )!;
    expect(mint.distributionId, 'linuxmint');
    expect(mint.distributionLike, ['ubuntu', 'debian']);
    expect(mint.markId, 'mint');
    final unknown = parseHostOperatingSystem(
      linuxRelease('ID=kylin\nID_LIKE=debian\nPRETTY_NAME="Kylin V10"'),
    )!;
    expect(unknown.distributionLike, ['debian']);
    expect(unknown.markId, 'debian');
    final hostile = parseHostOperatingSystem(
      linuxRelease(
        r'ID=alpine'
        '\n'
        r'ID_LIKE="$(reboot) Debian ../x alpine arch"',
      ),
    )!;
    expect(hostile.distributionLike, ['arch']);
    expect(hostile.markId, 'alpine');
    final read = HostOperatingSystem.read({
      hostOperatingSystemManifestKey: mint.toJson(),
    })!;
    expect(read.sameSystem(mint), isTrue);
    expect(read.distributionLike, ['ubuntu', 'debian']);
    // Observations stored before ID_LIKE was kept still resolve by ID.
    final old = Map<String, Object?>.of(mint.toJson())
      ..remove('distribution_like');
    final stored = HostOperatingSystem.read({
      hostOperatingSystemManifestKey: old,
    })!;
    expect(stored.distributionLike, isEmpty);
    expect(stored.markId, 'mint');
    expect(stored.sameSystem(mint), isFalse);
  });

  test('recognizes products built on a general system', () {
    String probe(String kernel, String release, String products) =>
        '$kernel\n__ATERMIUS_RELEASE__\n$release\n__ATERMIUS_KERNEL__\n6.8.0\n'
        '__ATERMIUS_MACOS__\n\n__ATERMIUS_PRODUCT__\n$products\n';
    final pve = parseHostOperatingSystem(
      probe(
        'Linux',
        'ID=debian\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\nVERSION_ID="12"',
        'proxmox',
      ),
    )!;
    expect(pve.family, HostOperatingSystemFamily.linux);
    expect(pve.distributionId, 'proxmox');
    expect(pve.distributionLike, ['debian']);
    expect(pve.displayName, 'Proxmox VE (Debian GNU/Linux 12 (bookworm))');
    expect(pve.version, isNull);
    expect(pve.markId, 'proxmox');
    final dsm = parseHostOperatingSystem(probe('Linux', '', 'synology'))!;
    expect(dsm.displayName, 'Synology DSM');
    expect(dsm.markId, 'synology');
    final android = parseHostOperatingSystem(probe('Linux', '', 'android'))!;
    expect(android.displayName, 'Android');
    expect(android.markId, 'android');
    final pfsense = parseHostOperatingSystem(probe('FreeBSD', '', 'pfsense'))!;
    expect(pfsense.family, HostOperatingSystemFamily.freebsd);
    expect(pfsense.displayName, 'pfSense');
    expect(pfsense.markId, 'pfsense');
    final plain = parseHostOperatingSystem(
      probe('Linux', 'ID=debian\nNAME=Debian', 'not-a-product\n'),
    )!;
    expect(plain.distributionId, 'debian');
    expect(plain.displayName, 'Debian');
    // A marker inside os-release cannot name a product.
    final spoofed = parseHostOperatingSystem(
      'Linux\n__ATERMIUS_RELEASE__\nID=debian\n__ATERMIUS_PRODUCT__\nproxmox\n'
      '__ATERMIUS_KERNEL__\n6.8.0\n__ATERMIUS_MACOS__\n',
    )!;
    expect(spoofed.distributionId, 'debian');
    final esxi = parseHostOperatingSystem(
      'VMkernel\n__ATERMIUS_RELEASE__\n__ATERMIUS_KERNEL__\n8.0.2\n'
      '__ATERMIUS_MACOS__\n\n__ATERMIUS_PRODUCT__\n',
    )!;
    expect(esxi.family, HostOperatingSystemFamily.unix);
    expect(esxi.displayName, 'VMware ESXi');
    expect(esxi.version, '8.0.2');
    expect(esxi.markId, 'vmware');
    for (final product in hostSystemProducts.keys) {
      expect(hostOperatingSystemUnixCommand, contains('&& echo $product'));
    }
  });

  test('recognizes macOS, BSD, Solaris, AIX and localized Windows versions', () {
    for (final entry in {
      'Darwin': HostOperatingSystemFamily.macos,
      'FreeBSD': HostOperatingSystemFamily.freebsd,
      'OpenBSD': HostOperatingSystemFamily.openbsd,
      'NetBSD': HostOperatingSystemFamily.netbsd,
      'DragonFly': HostOperatingSystemFamily.dragonfly,
      'SunOS': HostOperatingSystemFamily.solaris,
      'AIX': HostOperatingSystemFamily.aix,
    }.entries) {
      final os = parseHostOperatingSystem(
        '${entry.key}\n__ATERMIUS_RELEASE__\n__ATERMIUS_KERNEL__\n14.0\n__ATERMIUS_MACOS__\n15.1\n',
      )!;
      expect(os.family, entry.value);
      expect(os.version, entry.key == 'Darwin' ? '15.1' : '14.0');
    }
    for (final label in ['Version', '版本', 'Версия']) {
      final os = parseHostOperatingSystem(
        'Microsoft Windows [$label 10.0.20348.1]\r\n',
      )!;
      expect(os.family, HostOperatingSystemFamily.windows);
      expect(os.version, '10.0.20348.1');
    }
  });

  test(
    'unknown, controls, terminal escapes and byte-overlimit output are ignored',
    () {
      for (final invalid in [
        '',
        'unknown appliance',
        '\u001b[31mLinux',
        'Linux\u0000',
        'Linux\n${'é' * 5000}',
      ]) {
        expect(parseHostOperatingSystem(invalid), isNull);
      }
      expect(
        parseHostOperatingSystem(
          linuxRelease('ID=ubuntu\nPRETTY_NAME="${'x' * 200}"'),
        )!.displayName,
        'Linux',
      );
    },
  );

  test('manifest schema preserves old, unrelated and future metadata', () {
    const legacy = HostRecord(
      id: 'id',
      name: 'Host',
      address: 'host',
      username: 'user',
      manifest: {
        'future_import': {
          'nested': ['retained'],
        },
      },
    );
    expect(
      HostRecord.fromJson(Map<String, dynamic>.from(legacy.toJson()))
          .detectedOperatingSystem,
      isNull,
    );
    final system = parseHostOperatingSystem(
      linuxRelease('ID=debian\nNAME=Debian'),
    )!;
    final updated = legacy.copyWithDetectedOperatingSystem(system);
    final roundtrip = HostRecord.fromJson(
      Map<String, dynamic>.from(updated.toJson()),
    );
    expect(roundtrip.detectedOperatingSystem?.sameSystem(system), isTrue);
    expect(
      roundtrip.manifest?['future_import'],
      legacy.manifest?['future_import'],
    );
    expect(
      updated.copyWith(address: 'new-endpoint').detectedOperatingSystem,
      isNull,
    );
    expect(
      updated
          .copyWith(name: 'new display name')
          .detectedOperatingSystem
          ?.sameSystem(system),
      isTrue,
    );
    final future = legacy.copyWith(
      manifest: {
        ...?legacy.manifest,
        hostOperatingSystemManifestKey: {'version': 999, 'future': 'retained'},
      },
    );
    expect(future.detectedOperatingSystem, isNull);
    expect(
      HostRecord.fromJson(Map<String, dynamic>.from(future.toJson())).manifest,
      future.manifest,
    );
  });

  test('probe uses bounded fixed commands and falls back without consulting host text', () async {
    final commands = <String>[];
    final os = await HostOperatingSystemProbe().detectWithExecutor((
      command, {
      required cancellation,
      required timeout,
      required maxOutputBytes,
    }) async {
      commands.add(command);
      expect(timeout, const Duration(seconds: 3));
      expect(maxOutputBytes, 8192);
      return commands.length == 1
          ? result('command not found')
          : result('Microsoft Windows [Version 10.0.1]');
    });
    expect(commands, [
      hostOperatingSystemUnixCommand,
      hostOperatingSystemWindowsCommand,
    ]);
    expect(os?.family, HostOperatingSystemFamily.windows);
  });

  test('probe discards truncated output and suppresses errors', () async {
    var calls = 0;
    final os = await HostOperatingSystemProbe().detectWithExecutor((
      command, {
      required cancellation,
      required timeout,
      required maxOutputBytes,
    }) async {
      calls++;
      if (calls == 1) return result(linuxRelease('ID=ubuntu'), truncated: true);
      throw StateError('remote exec unavailable');
    });
    expect(os, isNull);
    expect(calls, 2);
  });

  test(
    'deadline cancels a hung exec and late completion remains harmless',
    () async {
      final pending = Completer<SshExecResult>();
      SshExecCancellation? observedCancellation;
      final os =
          await HostOperatingSystemProbe(
            timeout: const Duration(milliseconds: 20),
          ).detectWithExecutor((
            command, {
            required cancellation,
            required timeout,
            required maxOutputBytes,
          }) {
            observedCancellation = cancellation;
            return pending.future;
          });
      expect(os, isNull);
      expect(observedCancellation?.isCancelled, isTrue);
      pending.complete(result(linuxRelease('ID=ubuntu')));
      await Future<void>.delayed(Duration.zero);
    },
  );
}
