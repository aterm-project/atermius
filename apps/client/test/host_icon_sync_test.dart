import 'package:aterm_client/domain/host_operating_system.dart';
import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/telnet/telnet_ui.dart';
import 'package:aterm_client/ui/atermius_icons.dart';
import 'package:aterm_client/ui/host_system_icon.dart';
import 'package:aterm_client/ui/workspace_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

HostRecord _host(String id, HostProtocol protocol) => HostRecord(
  id: id,
  name: id,
  address: '$id.example',
  username: 'demo',
  protocol: protocol,
  port: protocol.defaultPort,
);

HostRecord _observed(HostRecord host, HostOperatingSystemFamily family) =>
    host.copyWithDetectedOperatingSystem(
      HostOperatingSystem(
        family: family,
        displayName: 'Observed ${family.name}',
        detectedAt: DateTime.utc(2026, 11, 15),
      ),
    );

Widget _app(Widget body) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: body),
);

/// The operating system mark inside [of]: the icon's own CustomPaint.
Finder _mark(Finder of) => find.descendant(
  of: of,
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is CustomPaint &&
        widget.painter.runtimeType.toString() == '_SystemMark',
  ),
);

void main() {
  group('home page icon of a Host without an identified system', () {
    testWidgets('RDP shows the RDP mark, VNC the monitor, others the server', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              for (final protocol in HostProtocol.values)
                HostSystemIcon(
                  key: ValueKey(protocol.name),
                  host: _host(protocol.name, protocol),
                ),
            ],
          ),
        ),
      );
      IconData shown(String key) => tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(Icon),
            ),
          )
          .icon!;
      expect(shown('rdp'), AtermiusIcons.remoteDesktop);
      expect(shown('vnc'), Icons.desktop_windows_outlined);
      expect(shown('ssh'), Icons.dns_outlined);
      expect(shown('telnet'), Icons.dns_outlined);
      // Still described as not identified: the protocol is not a guess at
      // the system.
      expect(
        find.byTooltip('Operating system not identified yet'),
        findsNWidgets(HostProtocol.values.length),
      );
    });

    testWidgets('an identified system wins over the protocol icon', (
      tester,
    ) async {
      final host = _observed(
        _host('rdp', HostProtocol.rdp),
        HostOperatingSystemFamily.windows,
      );
      await tester.pumpWidget(_app(HostSystemIcon(host: host)));
      expect(_mark(find.byType(HostSystemIcon)), findsOneWidget);
      expect(find.byIcon(AtermiusIcons.remoteDesktop), findsNothing);
    });

    testWidgets('plain leaves out the tooltip and the semantics label', (
      tester,
    ) async {
      final host = _observed(
        _host('ssh', HostProtocol.ssh),
        HostOperatingSystemFamily.linux,
      );
      await tester.pumpWidget(
        _app(HostSystemIcon(host: host, plain: true, size: 16)),
      );
      expect(_mark(find.byType(HostSystemIcon)), findsOneWidget);
      expect(find.byType(Tooltip), findsNothing);
      expect(
        tester.getSize(_mark(find.byType(HostSystemIcon))),
        const Size.square(16),
      );
    });
  });

  group('workspace tabs show the home page icon of their Host', () {
    Future<void> pumpTabs(WidgetTester tester, List<WorkspaceTab> tabs) =>
        tester.pumpWidget(
          _app(
            WorkspaceTabBar(
              tabs: tabs,
              selectedId: tabs.first.id,
              onSelect: (_) {},
              onClose: (_) {},
            ),
          ),
        );

    WorkspaceTab tab(HostRecord host, {bool connected = true}) => WorkspaceTab(
      id: host.id,
      title: host.name,
      icon: hostSessionIcon(host.protocol),
      host: host,
      isConnected: connected,
    );

    testWidgets('the same system mark as the card, in its own colours', (
      tester,
    ) async {
      final linux = _observed(
        _host('linux', HostProtocol.ssh),
        HostOperatingSystemFamily.linux,
      );
      final windows = _observed(
        _host('windows', HostProtocol.ssh),
        HostOperatingSystemFamily.windows,
      );
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              WorkspaceTabBar(
                tabs: [tab(linux), tab(windows)],
                selectedId: 'linux',
                onSelect: (_) {},
                onClose: (_) {},
              ),
              HostSystemIcon(key: const ValueKey('card-linux'), host: linux),
              HostSystemIcon(
                key: const ValueKey('card-windows'),
                host: windows,
              ),
            ],
          ),
        ),
      );
      final bar = find.byType(WorkspaceTabBar);
      expect(_mark(bar), findsNWidgets(2));
      expect(
        find.descendant(of: bar, matching: find.byIcon(Icons.terminal)),
        findsNothing,
      );
      // The tab paints with the painter the card uses: equal painters (same
      // family and colour) do not repaint.
      final tabMarks = tester.widgetList<CustomPaint>(_mark(bar)).toList();
      for (final (index, key) in ['card-linux', 'card-windows'].indexed) {
        final card = tester.widget<CustomPaint>(
          _mark(find.byKey(ValueKey(key))),
        );
        expect(
          card.painter!.shouldRepaint(tabMarks[index].painter!),
          isFalse,
          reason: key,
        );
      }
      // No second tooltip or label inside the tab.
      expect(
        find.descendant(of: bar, matching: find.byTooltip('Observed linux')),
        findsNothing,
      );
    });

    testWidgets('without an identified system the session icon stays', (
      tester,
    ) async {
      await pumpTabs(tester, [
        for (final protocol in HostProtocol.values)
          tab(_host(protocol.name, protocol)),
      ]);
      final bar = find.byType(WorkspaceTabBar);
      expect(_mark(bar), findsNothing);
      expect(
        find.descendant(of: bar, matching: find.byIcon(Icons.terminal)),
        findsNWidgets(2),
        reason: 'SSH and Telnet',
      );
      expect(
        find.descendant(
          of: bar,
          matching: find.byIcon(AtermiusIcons.remoteDesktop),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: bar,
          matching: find.byIcon(Icons.desktop_windows_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.byIcon(Icons.dns_outlined)),
        findsNothing,
      );
    });

    testWidgets('the mark is dimmed while the session is not connected', (
      tester,
    ) async {
      final host = _observed(
        _host('linux', HostProtocol.ssh),
        HostOperatingSystemFamily.linux,
      );
      Finder dimmed() => find.ancestor(
        of: _mark(find.byType(WorkspaceTabBar)),
        matching: find.byWidgetPredicate(
          (widget) => widget is Opacity && widget.opacity == .55,
        ),
      );
      await pumpTabs(tester, [tab(host, connected: false)]);
      expect(dimmed(), findsOneWidget);
      await pumpTabs(tester, [tab(host)]);
      expect(dimmed(), findsNothing);
    });

    testWidgets('tabs without a Host keep their plain icons', (tester) async {
      await pumpTabs(tester, const [
        WorkspaceTab(id: 'hosts', title: 'Home', isHome: true),
        WorkspaceTab(id: 'console', title: 'Local Console'),
        WorkspaceTab(id: 'files', title: 'Files', isFile: true),
      ]);
      final bar = find.byType(WorkspaceTabBar);
      for (final icon in [
        Icons.home_outlined,
        Icons.terminal,
        Icons.folder_outlined,
      ]) {
        expect(
          find.descendant(of: bar, matching: find.byIcon(icon)),
          findsOneWidget,
        );
      }
      expect(find.byType(HostSystemIcon), findsNothing);
    });
  });
}
