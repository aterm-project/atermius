import 'package:aterm_client/app_controller.dart';
import 'package:aterm_client/l10n/app_localizations_en.dart';
import 'package:aterm_client/l10n/app_localizations_zh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('missing password vault key reads as guidance, not a format error', () {
    const error = PasswordVaultKeyUnavailableException();
    final text = error.toString();
    expect(text, AppLocalizationsEn().passwordVaultKeyNotSyncedYet);
    expect(text, isNot(contains('FormatException')));
    expect(error, isNot(isA<FormatException>()));
    expect(AppLocalizationsZh().passwordVaultKeyNotSyncedYet, contains('密码登录'));
  });
}
