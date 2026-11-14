import 'dart:async';

import 'package:aterm_client/console/usb_serial_console.dart';
import 'package:aterm_client/console/usb_serial_port_id.dart';
import 'package:aterm_client/domain/quick_connect.dart';
import 'package:aterm_client/l10n/app_localizations.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/usb_serial_console_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _ftdi = UsbSerialAdapter(
  device: '/dev/bus/usb/001/004',
  vendorId: 0x0403,
  productId: 0x6001,
  driver: 'FTDI',
  manufacturer: 'FTDI',
  product: 'FT232R USB UART',
);

/// Programmable adapter list: [lists] answers successive list() calls (the
/// last one repeats); a null entry fails the listing.
class _FakeAccess implements UsbSerialAccess {
  _FakeAccess(this.lists);

  final List<UsbSerialAdapterList?> lists;
  int listCalls = 0;
  final requested = <String?>[];
  FutureOr<bool> Function(String? device) answer = (_) => true;

  @override
  Future<UsbSerialAdapterList> list() async {
    final list = lists[listCalls < lists.length ? listCalls : lists.length - 1];
    listCalls++;
    if (list == null) throw const UsbSerialException(UsbSerialIssue.failed);
    return list;
  }

  @override
  Future<bool> requestPermission({
    String? device,
    UsbSerialPortId? port,
  }) async {
    requested.add(device);
    return answer(device);
  }

  final picks = <(String, String)>[];

  @override
  void rememberPick(UsbSerialPortId port, String device) =>
      picks.add(('$port', device));
}

UsbSerialAdapterList _adapters(List<UsbSerialAdapter> adapters) =>
    UsbSerialAdapterList(usbHost: true, adapters: adapters);

void main() {
  late List<QuickConnectRequest?> results;

  Future<void> openDialog(WidgetTester tester, UsbSerialAccess access) async {
    results = [];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => results.add(
                await showUsbSerialConsoleDialog(context, access: access),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Finder key(String value) => find.byKey(ValueKey(value));

  FilledButton openButton(WidgetTester tester) =>
      tester.widget<FilledButton>(key('usb_serial_console_open'));

  testWidgets('empty state, refresh, then access is asked for the picked '
      'adapter and the id carries the serial number revealed after it', (
    tester,
  ) async {
    final access = _FakeAccess([
      _adapters(const []),
      _adapters(const [_ftdi]),
      _adapters(const [
        UsbSerialAdapter(
          device: '/dev/bus/usb/001/004',
          vendorId: 0x0403,
          productId: 0x6001,
          driver: 'FTDI',
          product: 'FT232R USB UART',
          serial: 'A50285BI',
          permission: true,
        ),
      ]),
    ]);
    await openDialog(tester, access);
    expect(key('usb_serial_empty'), findsOne);
    expect(find.text('Connect a USB serial adapter (OTG)'), findsOne);
    expect(openButton(tester).onPressed, isNull);

    await tester.tap(key('usb_serial_refresh'));
    await tester.pumpAndSettle();
    expect(find.text('FT232R USB UART'), findsOne);
    expect(find.text('0403:6001 · FTDI · FTDI'), findsOne);
    expect(access.requested, isEmpty, reason: 'nothing asked before Open');

    await tester.enterText(key('usb_serial_console_baud'), '9600');
    await tester.tap(key('usb_serial_console_open'));
    await tester.pumpAndSettle();
    expect(access.requested, ['/dev/bus/usb/001/004']);
    expect(key('usb_serial_console_dialog'), findsNothing);
    final request = results.single!;
    expect(request.kind, QuickConnectKind.serial);
    expect(request.address, 'usb:0403:6001:A50285BI');
    expect(request.baudRate, 9600);
    expect(access.picks, [('usb:0403:6001:A50285BI', '/dev/bus/usb/001/004')]);
  });

  testWidgets('identical adapters without serial numbers: the pick goes to '
      'the Console tab with the bus path, the id stays the same', (
    tester,
  ) async {
    const first = UsbSerialAdapter(
      device: '/dev/bus/usb/001/005',
      vendorId: 0x1a86,
      productId: 0x7523,
      driver: 'CH34x',
      product: 'USB Serial',
    );
    const second = UsbSerialAdapter(
      device: '/dev/bus/usb/001/006',
      vendorId: 0x1a86,
      productId: 0x7523,
      driver: 'CH34x',
      product: 'USB Serial',
    );
    final access = _FakeAccess([
      _adapters(const [first, second]),
    ]);
    await openDialog(tester, access);
    await tester.tap(
      find.byKey(const ValueKey('usb_serial_adapter_/dev/bus/usb/001/006#0')),
    );
    await tester.pump();
    await tester.tap(key('usb_serial_console_open'));
    await tester.pumpAndSettle();
    expect(access.requested, ['/dev/bus/usb/001/006']);
    expect(results.single!.address, 'usb:1a86:7523');
    expect(access.picks, [('usb:1a86:7523', '/dev/bus/usb/001/006')]);
  });

  testWidgets('a device without USB host says so', (tester) async {
    await openDialog(
      tester,
      _FakeAccess([const UsbSerialAdapterList(usbHost: false, adapters: [])]),
    );
    expect(key('usb_serial_no_usb_host'), findsOne);
    expect(find.textContaining("doesn't support USB host"), findsOne);
  });

  testWidgets('declined access keeps the dialog open with the reason', (
    tester,
  ) async {
    final access = _FakeAccess([
      _adapters(const [_ftdi]),
    ])..answer = (_) => false;
    await openDialog(tester, access);
    await tester.tap(key('usb_serial_console_open'));
    await tester.pumpAndSettle();
    expect(key('usb_serial_console_dialog'), findsOne);
    expect(
      find.textContaining('USB access to the adapter was denied.'),
      findsOne,
    );
    expect(results, isEmpty);
  });

  testWidgets('access errors and an adapter unplugged meanwhile are shown', (
    tester,
  ) async {
    // The background error happens before any re-listing; the next listing
    // (after access was granted) no longer has the adapter.
    final access =
        _FakeAccess([
            _adapters(const [_ftdi]),
            _adapters(const []),
          ])
          ..answer = (_) =>
              throw const UsbSerialException(UsbSerialIssue.background);
    await openDialog(tester, access);
    await tester.tap(key('usb_serial_console_open'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Android only asks for USB access while'),
      findsOne,
    );

    access.answer = (_) => true;
    await tester.tap(key('usb_serial_console_open'));
    await tester.pumpAndSettle();
    expect(find.text('The USB serial adapter was disconnected.'), findsOne);
    expect(key('usb_serial_empty'), findsOne);
    expect(results, isEmpty);
    expect(access.picks, isEmpty);
  });

  testWidgets('multi-port adapters list each port; nothing is preselected', (
    tester,
  ) async {
    final access = _FakeAccess([
      _adapters(const [
        UsbSerialAdapter(
          device: '/dev/bus/usb/002/003',
          vendorId: 0x0403,
          productId: 0x6010,
          driver: 'FTDI',
          product: 'Dual RS232',
          ports: 2,
        ),
      ]),
    ]);
    await openDialog(tester, access);
    expect(find.text('Dual RS232 · Port 1'), findsOne);
    expect(find.text('Dual RS232 · Port 2'), findsOne);
    expect(openButton(tester).onPressed, isNull);
    await tester.tap(find.text('Dual RS232 · Port 2'));
    await tester.pump();
    await tester.tap(key('usb_serial_console_open'));
    await tester.pumpAndSettle();
    expect(results.single!.address, 'usb:0403:6010#1');
    expect(results.single!.baudRate, 115200);
  });

  testWidgets('an invalid baud rate is rejected before asking for access', (
    tester,
  ) async {
    final access = _FakeAccess([
      _adapters(const [_ftdi]),
    ]);
    await openDialog(tester, access);
    await tester.enterText(key('usb_serial_console_baud'), '12');
    await tester.tap(key('usb_serial_console_open'));
    await tester.pumpAndSettle();
    expect(find.text('Baud rate must be 50–4000000'), findsOne);
    expect(access.requested, isEmpty);
  });

  testWidgets('a failed listing is reported', (tester) async {
    await openDialog(tester, _FakeAccess([null]));
    expect(find.text("Couldn't list USB serial adapters."), findsOne);
  });
}
