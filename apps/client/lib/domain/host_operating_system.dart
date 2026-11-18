/// Untrusted, informational observations from an authenticated SSH endpoint.
/// These values never participate in host-key trust or authentication.
enum HostOperatingSystemFamily {
  linux,
  windows,
  macos,
  freebsd,
  openbsd,
  netbsd,
  dragonfly,
  solaris,
  aix,
  unix,
}

const hostOperatingSystemManifestKey = 'host_os_v1';

class HostOperatingSystem {
  HostOperatingSystem({
    required this.family,
    required this.displayName,
    required this.detectedAt,
    this.distributionId,
    this.distributionLike = const [],
    this.version,
  }) {
    if (!_safeText(displayName, 128) ||
        (version != null && !_safeText(version!, 128)) ||
        (distributionId != null &&
            !_distributionIdPattern.hasMatch(distributionId!)) ||
        distributionLike.length > maxDistributionLike ||
        !distributionLike.every(_distributionIdPattern.hasMatch) ||
        detectedAt.millisecondsSinceEpoch <= 0) {
      throw const FormatException('Invalid operating system observation');
    }
  }

  final HostOperatingSystemFamily family;
  final String displayName;

  /// The system's own identifier: `ID` of os-release on Linux, or the name of
  /// a recognized product built on the system (see [hostSystemProducts]).
  final String? distributionId;

  /// Systems this one is derived from, nearest first: `ID_LIKE` of
  /// os-release, and for a product the distribution underneath it.
  final List<String> distributionLike;
  final String? version;

  static const maxDistributionLike = 8;

  /// Name of the outline that stands for this system (a key of
  /// `hostSystemMarks`), or null when only the family is known. A derivative
  /// without a mark of its own shows the nearest system it is based on.
  String? get markId {
    for (final id in [?distributionId, ...distributionLike]) {
      final mark = hostSystemMarkAliases[id];
      if (mark != null) return mark;
    }
    return switch (family) {
      HostOperatingSystemFamily.freebsd => 'freebsd',
      HostOperatingSystemFamily.openbsd => 'openbsd',
      HostOperatingSystemFamily.netbsd => 'netbsd',
      _ => null,
    };
  }

  final DateTime detectedAt;

  bool sameSystem(HostOperatingSystem other) =>
      family == other.family &&
      displayName == other.displayName &&
      distributionId == other.distributionId &&
      distributionLike.join(' ') == other.distributionLike.join(' ') &&
      version == other.version;

  Map<String, Object?> toJson() => {
    'version': 1,
    'family': family.name,
    'display_name': displayName,
    if (distributionId != null) 'distribution_id': distributionId,
    if (distributionLike.isNotEmpty) 'distribution_like': distributionLike,
    if (version != null) 'system_version': version,
    'detected_at_ms': detectedAt.toUtc().millisecondsSinceEpoch,
  };

  static HostOperatingSystem? read(Map<String, Object?>? manifest) {
    try {
      final raw = manifest?[hostOperatingSystemManifestKey];
      if (raw is! Map || raw['version'] != 1) return null;
      return HostOperatingSystem(
        family: HostOperatingSystemFamily.values.firstWhere(
          (v) => v.name == raw['family'],
        ),
        displayName: raw['display_name'] as String,
        distributionId: raw['distribution_id'] as String?,
        distributionLike: [
          ...?(raw['distribution_like'] as List?)?.cast<String>(),
        ],
        version: raw['system_version'] as String?,
        detectedAt: DateTime.fromMillisecondsSinceEpoch(
          raw['detected_at_ms'] as int,
          isUtc: true,
        ),
      );
    } on Object {
      return null;
    }
  }
}

final _distributionIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

/// Products that run on top of a general system and are told apart by a file
/// they install: identifier -> name shown to the user.
const hostSystemProducts = <String, String>{
  'proxmox': 'Proxmox VE',
  'proxmox-backup': 'Proxmox Backup Server',
  'synology': 'Synology DSM',
  'truenas': 'TrueNAS',
  'unraid': 'Unraid',
  'openmediavault': 'openmediavault',
  'qnap': 'QNAP QTS',
  'pfsense': 'pfSense',
  'opnsense': 'OPNsense',
  'android': 'Android',
};

/// os-release `ID` values and product identifiers -> mark name.
const hostSystemMarkAliases = <String, String>{
  'ubuntu': 'ubuntu',
  'ubuntu-core': 'ubuntu',
  'debian': 'debian',
  'alpine': 'alpine',
  'arch': 'arch',
  'archlinux': 'arch',
  'archarm': 'arch',
  'fedora': 'fedora',
  'rhel': 'redhat',
  'redhat': 'redhat',
  'rhcos': 'redhat',
  'centos': 'centos',
  'rocky': 'rocky',
  'almalinux': 'almalinux',
  'opensuse': 'opensuse',
  'opensuse-leap': 'opensuse',
  'opensuse-tumbleweed': 'opensuse',
  'opensuse-slowroll': 'opensuse',
  'opensuse-microos': 'opensuse',
  'suse': 'suse',
  'sles': 'suse',
  'sled': 'suse',
  'sles_sap': 'suse',
  'sle-micro': 'suse',
  'sle_hpc': 'suse',
  'linuxmint': 'mint',
  'kali': 'kali',
  'gentoo': 'gentoo',
  'nixos': 'nixos',
  'manjaro': 'manjaro',
  'manjaro-arm': 'manjaro',
  'pop': 'pop',
  'raspbian': 'raspberrypi',
  'openwrt': 'openwrt',
  'immortalwrt': 'openwrt',
  'lede': 'openwrt',
  'void': 'void',
  'slackware': 'slackware',
  'elementary': 'elementary',
  'zorin': 'zorin',
  'deepin': 'deepin',
  'uos': 'deepin',
  'endeavouros': 'endeavouros',
  'artix': 'artix',
  'mx': 'mx',
  'solus': 'solus',
  'fedora-asahi-remix': 'asahi',
  'qubes': 'qubes',
  'tails': 'tails',
  'parrot': 'parrot',
  'talos': 'talos',
  'alinux': 'alibaba',
  'ol': 'oracle',
  'amzn': 'amazon',
  'steamos': 'steamos',
  'sailfishos': 'sailfish',
  'android': 'android',
  'proxmox': 'proxmox',
  'proxmox-backup': 'proxmox',
  'synology': 'synology',
  'truenas': 'truenas',
  'unraid': 'unraid',
  'openmediavault': 'openmediavault',
  'qnap': 'qnap',
  'pfsense': 'pfsense',
  'opnsense': 'opnsense',
  'esxi': 'vmware',
};

bool _safeText(String text, int limit) =>
    text.isNotEmpty &&
    text.length <= limit &&
    text == text.trim() &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(text);
