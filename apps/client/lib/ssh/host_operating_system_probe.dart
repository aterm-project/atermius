import 'dart:async';
import 'dart:convert';

import '../domain/host_operating_system.dart';
import 'ssh_service.dart';

/// Fixed, read-only commands. No host properties, user text, or remote output
/// are ever interpolated into a command, and os-release is read, never sourced.
const hostOperatingSystemUnixCommand =
    "uname -s; printf '\\n__ATERMIUS_RELEASE__\\n'; "
    "if [ -r /etc/os-release ]; then cat /etc/os-release; fi; "
    "printf '\\n__ATERMIUS_KERNEL__\\n'; uname -r; "
    "printf '\\n__ATERMIUS_MACOS__\\n'; sw_vers -productVersion 2>/dev/null; "
    // Products built on a general system, told apart by a file they install.
    "printf '\\n__ATERMIUS_PRODUCT__\\n'; "
    "test -x /usr/bin/pveversion && echo proxmox; "
    "test -x /usr/sbin/proxmox-backup-manager && echo proxmox-backup; "
    "test -e /etc/synoinfo.conf && echo synology; "
    "test -e /data/freenas-v1.db && echo truenas; "
    "test -e /etc/unraid-version && echo unraid; "
    "test -d /etc/openmediavault && echo openmediavault; "
    "test -e /etc/config/qpkg.conf && echo qnap; "
    "test -e /etc/inc/pfsense-utils.inc && echo pfsense; "
    "test -d /usr/local/opnsense && echo opnsense; "
    "test -e /system/build.prop && echo android";
const hostOperatingSystemWindowsCommand = 'cmd /c ver';

typedef HostOperatingSystemExecutor = Future<SshExecResult> Function(
  String command, {
  required SshExecCancellation cancellation,
  required Duration timeout,
  required int maxOutputBytes,
});

class HostOperatingSystemProbe {
  HostOperatingSystemProbe({this.timeout = deadline}) {
    if (timeout <= Duration.zero || timeout > deadline) {
      throw ArgumentError.value(timeout, 'timeout');
    }
  }
  final Duration timeout;
  static const maxOutputBytes = 8192;
  static const deadline = Duration(seconds: 6);

  Future<HostOperatingSystem?> detect(SshConnection connection) =>
      detectWithExecutor(
        (
          command, {
          required cancellation,
          required timeout,
          required maxOutputBytes,
        }) => connection.executeRemoteCommand(
          command,
          cancellation: cancellation,
          timeout: timeout,
          maxOutputBytes: maxOutputBytes,
        ),
      );

  /// Invoke only after SSH authentication succeeds. Failure remains local and
  /// never prevents the terminal or file workspace from opening.
  Future<HostOperatingSystem?> detectWithExecutor(
    HostOperatingSystemExecutor execute,
  ) async {
    final cancellation = SshExecCancellation();
    final elapsed = Stopwatch()..start();
    final timer = Timer(timeout, cancellation.cancel);
    try {
      for (final command in [
        hostOperatingSystemUnixCommand,
        hostOperatingSystemWindowsCommand,
      ]) {
        final remaining = timeout - elapsed.elapsed;
        if (cancellation.isCancelled || remaining <= Duration.zero) return null;
        final result =
            await execute(
              command,
              cancellation: cancellation,
              timeout: const Duration(seconds: 3),
              maxOutputBytes: maxOutputBytes,
            ).timeout(
              remaining,
              onTimeout: () {
                cancellation.cancel();
                throw TimeoutException('OS observation deadline');
              },
            );
        if (result.cancelled || result.timedOut || result.execOpenPending) {
          return null;
        }
        if (result.outputTruncated) continue;
        final parsed = parseHostOperatingSystem(result.stdout);
        if (parsed != null) return parsed;
      }
    } on Object {
      /* Informational probe failures are deliberately ignored. */
    } finally {
      timer.cancel();
      cancellation.cancel();
    }
    return null;
  }
}

HostOperatingSystem? parseHostOperatingSystem(
  String output, {
  DateTime? detectedAt,
}) {
  if (output.length > HostOperatingSystemProbe.maxOutputBytes ||
      utf8.encode(output).length > HostOperatingSystemProbe.maxOutputBytes ||
      RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]').hasMatch(output)) {
    return null;
  }
  final now = detectedAt ?? DateTime.now().toUtc();
  final normalized = output.replaceAll('\r\n', '\n');
  final lines = normalized.split('\n').map((s) => s.trim()).toList();
  if (lines.isEmpty) return null;
  final kernel = lines.first;
  HostOperatingSystemFamily? family;
  String? name;
  switch (kernel) {
    case 'Linux':
      family = HostOperatingSystemFamily.linux;
      name = 'Linux';
    case 'Darwin':
      family = HostOperatingSystemFamily.macos;
      name = 'macOS';
    case 'FreeBSD':
      family = HostOperatingSystemFamily.freebsd;
      name = 'FreeBSD';
    case 'OpenBSD':
      family = HostOperatingSystemFamily.openbsd;
      name = 'OpenBSD';
    case 'NetBSD':
      family = HostOperatingSystemFamily.netbsd;
      name = 'NetBSD';
    case 'DragonFly':
      family = HostOperatingSystemFamily.dragonfly;
      name = 'DragonFly BSD';
    case 'SunOS':
      family = HostOperatingSystemFamily.solaris;
      name = 'Solaris';
    case 'AIX':
      family = HostOperatingSystemFamily.aix;
      name = 'AIX';
    case 'VMkernel':
      family = HostOperatingSystemFamily.unix;
      name = 'VMware ESXi';
  }
  if (family == null) {
    final windows = RegExp(
      r'^Microsoft Windows \[[^0-9\]\r\n]{0,32}([0-9][0-9.]{0,63})\]$',
      caseSensitive: false,
    ).firstMatch(normalized.trim());
    if (windows == null) return null;
    return HostOperatingSystem(
      family: HostOperatingSystemFamily.windows,
      displayName: 'Windows',
      version: windows.group(1),
      detectedAt: now,
    );
  }
  String? version;
  String? distribution = kernel == 'VMkernel' ? 'esxi' : null;
  final like = <String>[];
  final idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');
  final releaseStart = lines.indexOf('__ATERMIUS_RELEASE__');
  final kernelStart = lines.indexOf('__ATERMIUS_KERNEL__');
  final macStart = lines.indexOf('__ATERMIUS_MACOS__');
  final productStart = lines.indexOf('__ATERMIUS_PRODUCT__');
  if (family == HostOperatingSystemFamily.linux &&
      releaseStart >= 0 &&
      kernelStart > releaseStart) {
    final values = <String, String>{};
    for (final line in lines.sublist(releaseStart + 1, kernelStart)) {
      final match = RegExp(r'^(ID|ID_LIKE|PRETTY_NAME|NAME|VERSION_ID)=(.*)$')
          .firstMatch(line);
      if (match == null) continue;
      var value = match.group(2)!;
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      if (value.isNotEmpty && value.length <= 128 && !value.contains('\\')) {
        values[match.group(1)!] = value;
      }
    }
    final id = values['ID'];
    if (id != null && idPattern.hasMatch(id)) {
      distribution = id;
    }
    for (final base in (values['ID_LIKE'] ?? '').split(' ')) {
      if (idPattern.hasMatch(base) &&
          base != distribution &&
          !like.contains(base) &&
          like.length < HostOperatingSystem.maxDistributionLike) {
        like.add(base);
      }
    }
    name = values['PRETTY_NAME'] ?? values['NAME'] ?? name;
    version = values['VERSION_ID'];
  } else {
    final start = family == HostOperatingSystemFamily.macos
        ? macStart
        : kernelStart;
    if (start >= 0 &&
        start + 1 < lines.length &&
        RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._+ -]{0,127}$')
            .hasMatch(lines[start + 1])) {
      version = lines[start + 1];
    }
  }
  // A product names the system; what it is built on moves to the bases.
  final product = productStart < 0
      ? null
      : lines
            .skip(productStart + 1)
            .where(hostSystemProducts.containsKey)
            .firstOrNull;
  if (product != null &&
      (productStart > macStart && productStart > kernelStart)) {
    final label = hostSystemProducts[product]!;
    final base = name!;
    if (distribution != null) like.insert(0, distribution);
    if (like.length > HostOperatingSystem.maxDistributionLike) {
      like.removeLast();
    }
    distribution = product;
    name = base == 'Linux' || base == 'FreeBSD' || base.length > 96
        ? label
        : '$label ($base)';
    version = null;
  }
  try {
    return HostOperatingSystem(
      family: family,
      displayName: name!,
      distributionId: distribution,
      distributionLike: like,
      version: version,
      detectedAt: now,
    );
  } on Object {
    return null;
  }
}
