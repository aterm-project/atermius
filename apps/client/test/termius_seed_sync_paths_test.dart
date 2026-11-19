import 'package:aterm_client/import/termius_seed_sync_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('termiusSeedCandidatePaths cross-platform parity', () {
    test('resolves Windows APPDATA, LOCALAPPDATA, USERPROFILE, exe and env override', () {
      final paths = termiusSeedCandidatePaths(
        isWindows: true,
        isMacOS: false,
        env: const {
          'ATERMIUS_SEED_FILE': r'D:\Seeds\custom-seed.json',
          'APPDATA': r'C:\Users\Alice\AppData\Roaming',
          'LOCALAPPDATA': r'C:\Users\Alice\AppData\Local',
          'USERPROFILE': r'C:\Users\Alice',
        },
        executableDir: r'C:\Program Files\Atermius',
        currentDir: r'C:\Work',
      );

      expect(paths, [
        r'D:\Seeds\custom-seed.json',
        r'C:\Users\Alice\AppData\Roaming\Atermius\atermius-local-seed.json',
        r'C:\Users\Alice\AppData\Roaming\com.atermius.atermClient\atermius-auto-import.json',
        r'C:\Users\Alice\AppData\Local\Atermius\atermius-local-seed.json',
        r'C:\Users\Alice\Documents\atermius-auto-import.json',
        r'C:\Users\Alice\Downloads\aterm-project\atermius-local-seed.json',
        r'C:\Program Files\Atermius\atermius-local-seed.json',
        r'C:\Program Files\Atermius\data\flutter_assets\atermius-local-seed.json',
        r'C:\Work\atermius-local-seed.json',
      ]);
    });

    test('resolves macOS Application Support and app bundle Resources paths', () {
      final paths = termiusSeedCandidatePaths(
        isWindows: false,
        isMacOS: true,
        env: const {'HOME': '/Users/alice'},
        executableDir: '/Applications/Atermius.app/Contents/MacOS',
      );

      expect(paths, [
        '/Users/alice/Documents/atermius-auto-import.json',
        '/Users/alice/Library/Application Support/com.atermius.atermClient/atermius-auto-import.json',
        '/Applications/Atermius.app/Contents/MacOS/atermius-local-seed.json',
        '/Applications/Atermius.app/Contents/Resources/atermius-local-seed.json',
      ]);
    });
  });

  group('termiusSeedMarkerPath cross-platform parity', () {
    test('stores Windows marker under APPDATA with LOCALAPPDATA and USERPROFILE fallbacks', () {
      final appDataMarker = termiusSeedMarkerPath(
        isWindows: true,
        isMacOS: false,
        isIOS: false,
        env: const {
          'APPDATA': r'C:\Users\Alice\AppData\Roaming',
          'LOCALAPPDATA': r'C:\Users\Alice\AppData\Local',
          'USERPROFILE': r'C:\Users\Alice',
        },
        profileId: 'local/default:01',
      );
      expect(
        appDataMarker,
        r'C:\Users\Alice\AppData\Roaming\Atermius\.seed-applied-local_default_01.sha256',
      );

      final localMarker = termiusSeedMarkerPath(
        isWindows: true,
        isMacOS: false,
        isIOS: false,
        env: const {
          'LOCALAPPDATA': r'C:\Users\Alice\AppData\Local',
          'USERPROFILE': r'C:\Users\Alice',
        },
        profileId: 'p1',
      );
      expect(
        localMarker,
        r'C:\Users\Alice\AppData\Local\Atermius\.seed-applied-p1.sha256',
      );

      final homeFallbackMarker = termiusSeedMarkerPath(
        isWindows: true,
        isMacOS: false,
        isIOS: false,
        env: const {'USERPROFILE': r'C:\Users\Alice'},
        profileId: 'p1',
      );
      expect(
        homeFallbackMarker,
        r'C:\Users\Alice\.atermius\.seed-applied-p1.sha256',
      );
    });

    test('preserves macOS and iOS marker locations and uses XDG on Linux', () {
      expect(
        termiusSeedMarkerPath(
          isWindows: false,
          isMacOS: true,
          isIOS: false,
          env: const {'HOME': '/Users/alice'},
          profileId: 'p1',
        ),
        '/Users/alice/Library/Application Support/com.atermius.atermClient/.seed-applied-p1.sha256',
      );
      expect(
        termiusSeedMarkerPath(
          isWindows: false,
          isMacOS: false,
          isIOS: true,
          env: const {'HOME': '/var/mobile/Containers/Data/Application/UUID'},
          profileId: 'p1',
        ),
        '/var/mobile/Containers/Data/Application/UUID/Library/Application Support/.seed-applied-p1.sha256',
      );
      expect(
        termiusSeedMarkerPath(
          isWindows: false,
          isMacOS: false,
          isIOS: false,
          env: const {
            'HOME': '/home/alice',
            'XDG_CONFIG_HOME': '/home/alice/.xdg',
          },
          profileId: 'p1',
        ),
        '/home/alice/.xdg/atermius/.seed-applied-p1.sha256',
      );
    });
  });
}
