import 'package:flutter/material.dart';

import '../domain/host_operating_system.dart';
import '../domain/models.dart';
import '../telnet/telnet_ui.dart' show hostProtocolIcon;
import 'app_theme.dart';
import '../l10n/l10n.dart';

/// The icon that stands for a Host: on the home page cards and on the
/// workspace tabs of its sessions, so both always show the same picture.
///
/// A Host whose operating system was observed over an authenticated
/// connection shows that system's local vector mark. Without an observation
/// the address or name never predicts a system: a remote desktop Host shows
/// its protocol's icon (only SSH connections observe the system, so this is
/// what RDP and VNC Hosts show), any other Host the ordinary server icon.
class HostSystemIcon extends StatelessWidget {
  const HostSystemIcon({
    required this.host,
    this.size = 24,
    this.plain = false,
    this.fallbackIcon,
    this.fallbackColor,
    super.key,
  }) : assert(size > 0);
  final HostRecord host;
  final double size;

  /// Only the picture, without the tooltip and semantics label naming the
  /// operating system. For places that describe themselves, such as a tab.
  final bool plain;

  /// Icon and colour used instead of the defaults when no operating system
  /// has been observed.
  final IconData? fallbackIcon;
  final Color? fallbackColor;

  /// The icon of [host] when its operating system is not known.
  static IconData unidentifiedIcon(HostRecord host) => host.protocol.isTerminal
      ? Icons.dns_outlined
      : hostProtocolIcon(host.protocol);

  @override
  Widget build(BuildContext context) {
    final system = host.detectedOperatingSystem;
    final color = _systemColor(system, context.palette.accentText);
    final picture = system == null
        ? Icon(
            fallbackIcon ?? unidentifiedIcon(host),
            size: size,
            color: fallbackColor ?? color,
          )
        : {
            HostOperatingSystemFamily.solaris,
            HostOperatingSystemFamily.aix,
            HostOperatingSystemFamily.unix,
          }.contains(system.family)
        ? Icon(Icons.computer_outlined, size: size, color: color)
        : CustomPaint(
            size: Size.square(size),
            painter: _SystemMark(system.family, color),
          );
    if (plain) return picture;
    final label = system == null
        ? context.l10n.operatingSystemNotIdentifiedYet
        : system.version != null &&
              !system.displayName.contains(system.version!)
        ? '${system.displayName} · ${system.version}'
        : system.displayName;
    return Semantics(
      label: context.l10n.operatingSystemLabel(label),
      child: Tooltip(message: label, child: picture),
    );
  }
}

Color _systemColor(HostOperatingSystem? system, Color fallback) {
  if (system == null) return fallback;
  if (system.family == HostOperatingSystemFamily.windows) {
    return const Color(0xff42a5f5);
  }
  if (system.family == HostOperatingSystemFamily.macos) {
    return const Color(0xffb0bec5);
  }
  if (system.family != HostOperatingSystemFamily.linux) {
    return const Color(0xffef7064);
  }
  return switch (system.distributionId) {
    'ubuntu' => const Color(0xffe97943),
    'debian' => const Color(0xffdf5275),
    'alpine' || 'fedora' || 'rhel' || 'centos' => const Color(0xff669fe1),
    'arch' || 'archlinux' => const Color(0xff42b4de),
    'rocky' ||
    'almalinux' ||
    'opensuse' ||
    'opensuse-leap' ||
    'opensuse-tumbleweed' ||
    'sles' => const Color(0xff64b985),
    _ => const Color(0xffe9bb58),
  };
}

class _SystemMark extends CustomPainter {
  const _SystemMark(this.family, this.color);
  final HostOperatingSystemFamily family;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final ink = Paint()..color = color;
    if (family == HostOperatingSystemFamily.windows) {
      for (final x in [2.0, 13.0]) {
        for (final y in [2.0, 13.0]) {
          canvas.drawRect(Rect.fromLTWH(x, y, 9, 9), ink);
        }
      }
    } else if (family == HostOperatingSystemFamily.macos) {
      final apple = Path()
        ..moveTo(12, 7)
        ..cubicTo(7, 3, 2, 8, 4, 14)
        ..cubicTo(6, 21, 8, 23, 12, 20)
        ..cubicTo(16, 23, 18, 21, 21, 15)
        ..cubicTo(16, 13, 17, 9, 21, 8)
        ..cubicTo(18, 4, 15, 5, 12, 7)
        ..close();
      canvas.drawPath(apple, ink);
      canvas.drawPath(
        Path()
          ..moveTo(12, 5)
          ..quadraticBezierTo(12, 1, 17, 1)
          ..quadraticBezierTo(17, 5, 12, 5)
          ..close(),
        ink,
      );
    } else if (family == HostOperatingSystemFamily.linux) {
      final dark = Paint()..color = const Color(0xff38434d);
      canvas.drawOval(const Rect.fromLTWH(3, 6, 18, 16), dark);
      canvas.drawOval(const Rect.fromLTWH(7, 1, 10, 16), dark);
      canvas.drawOval(
        const Rect.fromLTWH(7, 10, 10, 11),
        Paint()..color = const Color(0xffedf2f6),
      );
      final white = Paint()..color = Colors.white;
      canvas.drawOval(const Rect.fromLTWH(8, 5, 3, 4), white);
      canvas.drawOval(const Rect.fromLTWH(13, 5, 3, 4), white);
      canvas.drawCircle(const Offset(10, 7), .7, dark);
      canvas.drawCircle(const Offset(14, 7), .7, dark);
      canvas.drawPath(
        Path()
          ..moveTo(9, 9)
          ..lineTo(15, 9)
          ..lineTo(12, 12)
          ..close(),
        ink,
      );
      canvas.drawOval(const Rect.fromLTWH(3, 20, 8, 3), ink);
      canvas.drawOval(const Rect.fromLTWH(13, 20, 8, 3), ink);
    } else {
      // A shared BSD/Unix mark; exact system text remains in the tooltip.
      canvas.drawPath(
        Path()
          ..moveTo(5, 8)
          ..lineTo(3, 2)
          ..lineTo(10, 6)
          ..lineTo(14, 6)
          ..lineTo(21, 2)
          ..lineTo(19, 8)
          ..close(),
        ink,
      );
      canvas.drawOval(const Rect.fromLTWH(4, 6, 16, 16), ink);
      final eye = Paint()..color = const Color(0xff263238);
      canvas.drawCircle(const Offset(9, 13), 1.4, eye);
      canvas.drawCircle(const Offset(15, 13), 1.4, eye);
      canvas.drawLine(
        const Offset(9, 18),
        const Offset(15, 18),
        eye..strokeWidth = 1.2,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SystemMark oldDelegate) =>
      family != oldDelegate.family || color != oldDelegate.color;
}
