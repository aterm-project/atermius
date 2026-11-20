import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../ssh/peer_file_copy.dart';
import '../storage/file_copy_route_native.dart'
    if (dart.library.js_interop) '../storage/file_copy_route_web.dart';

class FileCopyRouteDialog extends StatefulWidget {
  const FileCopyRouteDialog({
    required this.source,
    required this.destination,
    super.key,
  });

  final String source;
  final String destination;

  @override
  State<FileCopyRouteDialog> createState() => _FileCopyRouteDialogState();
}

class _FileCopyRouteDialogState extends State<FileCopyRouteDialog> {
  static FileCopyRoute? _lastChoice;
  static Future<void> _pendingSave = Future.value();
  FileCopyRoute? _route;
  int _seconds = 5;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var initial = _lastChoice;
    if (initial == null) {
      try {
        final stored = await readFileCopyRoute();
        initial = FileCopyRoute.values
            .where((r) => r.name == stored)
            .firstOrNull;
      } catch (_) {
        // Local settings may be unavailable on this device.
      }
    }
    if (!mounted || _route != null) return;
    setState(() => _route = initial ?? FileCopyRoute.local);
    _restartTimer();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (ModalRoute.of(context)?.isCurrent != true) return;
      if (_seconds == 1) {
        _confirm();
      } else {
        setState(() => _seconds--);
      }
    });
  }

  void _confirm() {
    final route = _route;
    if (route == null || ModalRoute.of(context)?.isCurrent != true) return;
    _timer?.cancel();
    _lastChoice = route;
    _pendingSave = _pendingSave
        .then((_) => writeFileCopyRoute(route.name))
        .catchError((Object _) {});
    Navigator.pop(context, route);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.fileCopyBetweenHosts),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.fileCopyFromTo(widget.source, widget.destination)),
            RadioGroup<FileCopyRoute>(
              groupValue: _route,
              onChanged: (route) {
                if (route != null) {
                  setState(() {
                    _route = route;
                    _seconds = 5;
                  });
                  _restartTimer();
                }
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RadioListTile<FileCopyRoute>(
                    value: FileCopyRoute.local,
                    title: Text(l10n.fileCopyViaLocal),
                  ),
                  RadioListTile<FileCopyRoute>(
                    value: FileCopyRoute.direct,
                    title: Text(l10n.fileCopyDirect),
                    subtitle: Text(l10n.fileCopyDirectFallback),
                  ),
                ],
              ),
            ),
            if (_route != null) Text(l10n.fileCopyCountdown(_seconds)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _route == null ? null : _confirm,
          child: Text(l10n.fileManagerCopy),
        ),
      ],
    );
  }
}
