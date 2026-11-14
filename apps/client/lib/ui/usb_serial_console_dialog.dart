import 'dart:async';

import 'package:flutter/material.dart';

import '../console/usb_serial_console.dart';
import '../domain/quick_connect.dart';
import '../l10n/l10n.dart';
import 'app_theme.dart';

/// Android serial Console picker: the attached USB-to-serial adapters (with
/// refresh, empty and no-USB-host states), the baud rate field of the
/// desktop dialog, and Android's USB access prompt on Open. Returns the
/// quick-connect request for the picked port (`console usb:… -b baud`), so
/// it follows the same route and limits as typing that command in search.
///
/// Nothing is opened here. Access is asked only for the adapter the user
/// picked and only when they press Open; the Console tab opens the port.
/// The pick itself goes to that tab in memory ([UsbSerialAccess.rememberPick]):
/// identical adapters without a serial number share one id, and only the
/// pick tells them apart.
Future<QuickConnectRequest?> showUsbSerialConsoleDialog(
  BuildContext context, {
  required UsbSerialAccess access,
}) => showDialog<QuickConnectRequest>(
  context: context,
  builder: (_) => UsbSerialConsoleDialog(access: access),
);

class UsbSerialConsoleDialog extends StatefulWidget {
  const UsbSerialConsoleDialog({required this.access, super.key});

  final UsbSerialAccess access;

  @override
  State<UsbSerialConsoleDialog> createState() => _UsbSerialConsoleDialogState();
}

typedef _Choice = ({String device, int port});

class _UsbSerialConsoleDialogState extends State<UsbSerialConsoleDialog> {
  final _baud = TextEditingController(text: '115200');
  UsbSerialAdapterList? _list;
  _Choice? _choice;
  bool _loading = false, _opening = false;
  String? _error, _baudError;

  /// Drops results of a listing that a newer refresh replaced.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _baud.dispose();
    super.dispose();
  }

  Iterable<_Choice> _choices(UsbSerialAdapterList list) sync* {
    for (final adapter in list.adapters) {
      for (var port = 0; port < adapter.ports; port++) {
        yield (device: adapter.device, port: port);
      }
    }
  }

  void _show(UsbSerialAdapterList list) {
    final choices = _choices(list).toList();
    _list = list;
    // Keep the pick across refreshes while that adapter is still attached;
    // a single port is picked for the user.
    if (!choices.contains(_choice)) {
      _choice = choices.length == 1 ? choices.single : null;
    }
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.access.list();
      if (!mounted || generation != _generation) return;
      setState(() => _show(list));
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = context.l10n.usbSerialListFailed);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open() async {
    final l10n = context.l10n;
    final choice = _choice;
    final baudText = _baud.text.trim();
    final baud = RegExp(r'^[0-9]{1,7}$').hasMatch(baudText)
        ? int.parse(baudText)
        : 0;
    if (baud < 50 || baud > 4000000) {
      setState(() => _baudError = l10n.baudRateMustBe504000000);
      return;
    }
    if (choice == null) {
      setState(() => _error = l10n.usbSerialChooseAdapter);
      return;
    }
    final generation = ++_generation;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      if (!await widget.access.requestPermission(device: choice.device)) {
        if (mounted) setState(() => _error = l10n.usbSerialPermissionDenied);
        return;
      }
      // Android 10+ reveals the serial number only after access was
      // granted; with it the id tells identical adapters apart and still
      // matches after a replug.
      final list = await widget.access.list();
      if (!mounted) return;
      final adapter = list.adapters
          .where((a) => a.device == choice.device)
          .firstOrNull;
      if (adapter == null || choice.port >= adapter.ports) {
        setState(() {
          _show(list);
          _error = l10n.usbSerialDetached;
        });
        return;
      }
      final id = adapter.portId(choice.port);
      final request = QuickConnectRequest.parse('console $id -b $baud');
      if (request == null || request.kind != QuickConnectKind.serial) {
        throw FormatException(l10n.invalidSerialPortOrBaudRate);
      }
      widget.access.rememberPick(id, adapter.device);
      Navigator.of(context).pop(request);
    } on UsbSerialException catch (error) {
      if (!mounted) return;
      final adapter = _list?.adapters
          .where((a) => a.device == choice.device)
          .firstOrNull;
      setState(
        () => _error = usbSerialIssueMessage(
          l10n,
          error.issue,
          port: adapter == null ? '' : '${adapter.portId(choice.port)}',
        ),
      );
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.theSerialConsoleFailedToStart);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _opening = false);
      }
    }
  }

  static String _hex(int value) => value.toRadixString(16).padLeft(4, '0');

  Widget _adapterTile(UsbSerialAdapter adapter, int port) {
    final l10n = context.l10n;
    final choice = (device: adapter.device, port: port);
    final selected = _choice == choice;
    final name =
        adapter.product ??
        adapter.manufacturer ??
        l10n.usbSerialAdapterFallbackName;
    final detail = [
      '${_hex(adapter.vendorId)}:${_hex(adapter.productId)}',
      adapter.driver,
      if (adapter.product != null && adapter.manufacturer != null)
        adapter.manufacturer!,
      if (adapter.serial != null) adapter.serial!,
    ].join(' · ');
    return ListTile(
      key: ValueKey('usb_serial_adapter_${adapter.device}#$port'),
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      selected: selected,
      enabled: !_opening,
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      title: Text(
        adapter.ports > 1
            ? '$name · ${l10n.usbSerialPortNumber(port + 1)}'
            : name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => setState(() {
        _choice = choice;
        _error = null;
      }),
    );
  }

  Widget _adapters() {
    final l10n = context.l10n;
    final muted = TextStyle(color: context.palette.muted, height: 1.4);
    final list = _list;
    if (list == null) {
      return _loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          : const SizedBox.shrink();
    }
    if (list.adapters.isEmpty) {
      return Padding(
        key: ValueKey(
          list.usbHost ? 'usb_serial_empty' : 'usb_serial_no_usb_host',
        ),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              list.usbHost ? Icons.usb : Icons.usb_off,
              color: context.palette.muted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: list.usbHost
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.usbSerialNoAdapters,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(l10n.usbSerialNoAdaptersDetail, style: muted),
                      ],
                    )
                  : Text(l10n.usbSerialNoUsbHost, style: muted),
            ),
          ],
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: ListView(
        key: const ValueKey('usb_serial_adapter_list'),
        shrinkWrap: true,
        children: [
          for (final adapter in list.adapters)
            for (var port = 0; port < adapter.ports; port++)
              _adapterTile(adapter, port),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final error = _error;
    return AlertDialog(
      key: const ValueKey('usb_serial_console_dialog'),
      title: Text(l10n.homeAddSerialConsoleTitle),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.usbSerialDialogDetail,
                style: TextStyle(color: context.palette.muted, height: 1.4),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.usbSerialAdaptersHeading,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (_loading && _list != null)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  IconButton(
                    key: const ValueKey('usb_serial_refresh'),
                    tooltip: l10n.refresh,
                    icon: const Icon(Icons.refresh),
                    onPressed: _loading || _opening ? null : _refresh,
                  ),
                ],
              ),
              _adapters(),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('usb_serial_console_baud'),
                controller: _baud,
                enabled: !_opening,
                keyboardType: TextInputType.number,
                maxLength: 7,
                decoration: InputDecoration(
                  labelText: l10n.homeAddSerialConsoleBaud,
                  errorText: _baudError,
                  counterText: '',
                ),
                onChanged: (_) {
                  if (_baudError != null) setState(() => _baudError = null);
                },
                onSubmitted: (_) => _open(),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(
                  error,
                  key: const ValueKey('usb_serial_error'),
                  style: TextStyle(color: context.palette.red, height: 1.4),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const ValueKey('usb_serial_console_open'),
          onPressed: _opening || _loading || _choice == null ? null : _open,
          child: _opening
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.homeAddSerialConsoleOpen),
        ),
      ],
    );
  }
}
