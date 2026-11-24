import 'package:aterm_client/app_update/app_update_windows_elevation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('arguments survive the Windows command line', () {
    expect(quoteWindowsArgument('--atermius-update-apply'), '--atermius-update-apply');
    expect(
      quoteWindowsArgument(r'--atermius-update-install=C:\Program Files\Atermius\releases\x'),
      r'"--atermius-update-install=C:\Program Files\Atermius\releases\x"',
    );
    // A trailing backslash must not escape the closing quote.
    expect(quoteWindowsArgument(r'C:\Program Files\'), r'"C:\Program Files\\"');
    expect(quoteWindowsArgument('say "hi"'), r'"say \"hi\""');
    expect(quoteWindowsArgument(r'a\"b c'), r'"a\\\"b c"');
    expect(quoteWindowsArgument(''), '""');
  });
}
