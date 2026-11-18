import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// Font files served next to the fallback fonts (see web/fonts/README.txt).
const webMonospaceFontFiles = [
  'fonts/dejavusansmono/DejaVuSansMono.ttf',
  'fonts/dejavusansmono/DejaVuSansMono-Bold.ttf',
];

Future<void>? _loading;

/// Registers a real fixed-width font as the `monospace` family.
///
/// The CanvasKit renderer cannot see the browser's fonts, so the generic
/// `monospace` family resolves to the proportional UI font there. A terminal
/// then measures its cell from that font's wide "m" and paints every narrower
/// glyph with gaps around it. Registering the bundled font notifies the
/// framework (system fonts changed), so a terminal that is already on screen
/// measures its cell again.
Future<void> loadWebMonospaceFont() => _loading ??= _load();

Future<void> _load() async {
  try {
    final base = Uri.parse(web.document.baseURI);
    final loader = FontLoader('monospace');
    for (final file in webMonospaceFontFiles) {
      loader.addFont(_fetch(base.resolve(file)));
    }
    await loader.load();
  } catch (_) {
    // Keep the proportional fallback and allow a later retry.
    _loading = null;
  }
}

Future<ByteData> _fetch(Uri uri) async {
  final response = await http.get(uri);
  if (response.statusCode != 200) {
    throw StateError('font request failed: ${response.statusCode}');
  }
  return ByteData.sublistView(response.bodyBytes);
}
