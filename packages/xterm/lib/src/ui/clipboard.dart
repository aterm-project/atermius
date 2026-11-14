import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Where terminal views read the text they paste: the paste shortcut and
/// the touch toolbar's Paste.
///
/// Defaults to Flutter's [Clipboard]. An app can replace [read] with a
/// reader that tells the user why there is nothing to paste (an empty
/// clipboard, an image, a read the system refused); it returns null then.
abstract final class TerminalClipboard {
  static Future<String?> Function(BuildContext context) read = _flutterRead;

  static Future<String?> _flutterRead(BuildContext context) async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;
}
