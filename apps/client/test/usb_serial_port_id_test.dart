import 'package:aterm_client/console/usb_serial_port_id.dart';
import 'package:aterm_client/domain/quick_connect.dart';
import 'package:aterm_client/domain/window_combination.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UsbSerialPortId', () {
    test('parses and formats the canonical id', () {
      for (final text in [
        'usb:0403:6001',
        'usb:0403:6001:A50285BI',
        'usb:0403:6010#1',
        'usb:0403:6011:FT4232H-1.2_x#15',
        'usb:0000:ffff',
      ]) {
        expect(UsbSerialPortId.tryParse(text).toString(), text);
      }
      final id = UsbSerialPortId.tryParse('usb:0403:6010:FT9Z#1')!;
      expect(
        (id.vendorId, id.productId, id.serial, id.port),
        (0x0403, 0x6010, 'FT9Z', 1),
      );
    });

    test('normalizes case of prefix and hex and an explicit #0, keeps the '
        'serial number as is', () {
      expect(
        UsbSerialPortId.tryParse('USB:1A86:7523:AbC#0').toString(),
        'usb:1a86:7523:AbC',
      );
      expect(
        UsbSerialPortId.tryParse('usb:10C4:EA60'),
        UsbSerialPortId(vendorId: 0x10c4, productId: 0xea60),
      );
      expect(
        UsbSerialPortId.tryParse('usb:10c4:ea60:a'),
        isNot(UsbSerialPortId.tryParse('usb:10c4:ea60:A')),
      );
    });

    test('rejects malformed ids', () {
      for (final text in [
        '',
        'usb:',
        'usb:0403',
        'usb:403:6001',
        'usb:0403:60011',
        'usb:0403:6001:',
        'usb:0403:6001#',
        'usb:0403:6001#16',
        'usb:0403:6001#01',
        'usb:0403:6001#-1',
        'usb:0403:6001:a b',
        'usb:0403:6001:a/b',
        'usb:0403:6001:a\\b',
        'usb:0403:6001:a:b',
        'usb:0403:6001:\u202eA',
        'usb:0403:6001:a\nb',
        'usb:0403:6001:${'x' * 65}',
        ' usb:0403:6001',
        'usb:0403:6001 ',
        'usb:g403:6001',
        'usbx:0403:6001',
        'COM3',
        '/dev/cu.usbserial',
      ]) {
        expect(UsbSerialPortId.tryParse(text), isNull, reason: text);
      }
      expect(
        UsbSerialPortId.tryParse('usb:0403:6001:${'x' * 64}')?.serial,
        hasLength(64),
      );
    });

    test('constructor validates every field', () {
      for (final build in <UsbSerialPortId Function()>[
        () => UsbSerialPortId(vendorId: -1, productId: 0),
        () => UsbSerialPortId(vendorId: 0x10000, productId: 0),
        () => UsbSerialPortId(vendorId: 0, productId: 0x10000),
        () => UsbSerialPortId(vendorId: 0, productId: 0, port: 16),
        () => UsbSerialPortId(vendorId: 0, productId: 0, port: -1),
        () => UsbSerialPortId(vendorId: 0, productId: 0, serial: ''),
        () => UsbSerialPortId(vendorId: 0, productId: 0, serial: 'a#1'),
      ]) {
        expect(build, throwsFormatException);
      }
      expect(UsbSerialPortId.isValidSerial('A50285BI'), isTrue);
      expect(UsbSerialPortId.isValidSerial('A5 0285'), isFalse);
    });

    test('claims only the usb: prefix', () {
      expect(UsbSerialPortId.claims('usb:zz'), isTrue);
      expect(UsbSerialPortId.claims('USB:0403:6001'), isTrue);
      expect(UsbSerialPortId.claims('COM3'), isFalse);
      expect(UsbSerialPortId.claims('usb'), isFalse);
    });
  });

  group('quick connect', () {
    test('accepts usb: ports and stores the canonical id', () {
      final request = QuickConnectRequest.parse(
        'console tty @USB:0403:6001:A50285bi#0 -b 9600',
      )!;
      expect(
        (request.kind, request.address, request.baudRate),
        (QuickConnectKind.serial, 'usb:0403:6001:A50285bi', 9600),
      );
      expect(
        QuickConnectRequest.parse('tty @usb:1a86:7523')!.address,
        'usb:1a86:7523',
      );
      expect(
        QuickConnectRequest.parse('console usb:0403:6010#1')!.address,
        'usb:0403:6010#1',
      );
    });

    test('rejects malformed usb: ports and keeps COM parsing', () {
      for (final text in [
        'console tty @usb:0403',
        'console tty @usb:0403:6001#16',
        'console tty @usb:0403:6001:a/b -b 9600',
      ]) {
        expect(
          () => QuickConnectRequest.parse(text),
          throwsFormatException,
          reason: text,
        );
      }
      expect(QuickConnectRequest.parse('tty @com5')!.address, 'COM5');
    });
  });

  test('window combination panes keep a usb: serial Console port', () {
    final pane = CombinationPane(
      kind: 'console',
      serialPort: 'usb:0403:6001:A50285BI',
      baudRate: 9600,
    );
    final decoded = CombinationPane.fromJson(pane.toJson());
    expect(decoded.serialPort, 'usb:0403:6001:A50285BI');
    expect(decoded.baudRate, 9600);
  });
}
