import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Apple App Store launch compliance gates', () {
    test(
      'PrivacyInfo.xcprivacy exists, disables tracking, declares CA92.1/C617.1/E174.1/35F9.1, and is mounted in PBXResourcesBuildPhase',
      () {
        final targets = _discoverAppleProjectTargets();
        expect(
          targets,
          isNotEmpty,
          reason:
              'Expected at least one Apple Runner project (ios/Runner or macos/Runner).',
        );

        const requiredCategoryReasons = <String, String>{
          'NSPrivacyAccessedAPICategoryUserDefaults': 'CA92.1',
          'NSPrivacyAccessedAPICategoryFileTimestamp': 'C617.1',
          'NSPrivacyAccessedAPICategoryDiskSpace': 'E174.1',
          'NSPrivacyAccessedAPICategorySystemBootTime': '35F9.1',
        };

        for (final target in targets) {
          final privacyFile = File(
            '${target.runnerDir.path}/PrivacyInfo.xcprivacy',
          );
          expect(
            privacyFile.existsSync(),
            isTrue,
            reason: 'Missing PrivacyInfo.xcprivacy at ${privacyFile.path}',
          );

          final rawXml = privacyFile.readAsStringSync();
          expect(
            RegExp(
              r'<key>NSPrivacyTracking</key>\s*<false/>',
            ).hasMatch(rawXml),
            isTrue,
            reason:
                '${privacyFile.path} must explicitly set NSPrivacyTracking to <false/>.',
          );

          final parsed = _parseXmlPlistDict(rawXml);
          expect(
            parsed['NSPrivacyTracking'],
            isFalse,
            reason: '${privacyFile.path} NSPrivacyTracking must parse to false.',
          );

          final apiTypes = parsed['NSPrivacyAccessedAPITypes'];
          expect(
            apiTypes,
            isA<List<Object?>>(),
            reason:
                '${privacyFile.path} must declare NSPrivacyAccessedAPITypes array.',
          );

          final declaredReasonsByCategory = <String, Set<String>>{};
          for (final entry in apiTypes! as List<Object?>) {
            expect(entry, isA<Map<String, Object?>>());
            final map = entry! as Map<String, Object?>;
            final category = map['NSPrivacyAccessedAPIType'];
            final reasons = map['NSPrivacyAccessedAPITypeReasons'];
            if (category is String && reasons is List<Object?>) {
              declaredReasonsByCategory
                  .putIfAbsent(category, () => <String>{})
                  .addAll(reasons.whereType<String>());
            }
          }

          for (final expected in requiredCategoryReasons.entries) {
            final reasons = declaredReasonsByCategory[expected.key];
            expect(
              reasons,
              isNotNull,
              reason:
                  '${privacyFile.path} missing category ${expected.key} (${expected.value}).',
            );
            expect(
              reasons,
              contains(expected.value),
              reason:
                  '${privacyFile.path} category ${expected.key} missing reason ${expected.value}.',
            );
          }

          expect(
            target.pbxprojFile.existsSync(),
            isTrue,
            reason: 'Missing project.pbxproj at ${target.pbxprojFile.path}',
          );
          final pbxprojContent = target.pbxprojFile.readAsStringSync();
          expect(
            _isMountedInPbxResourcesBuildPhase(
              pbxprojContent,
              'PrivacyInfo.xcprivacy',
            ),
            isTrue,
            reason:
                'PrivacyInfo.xcprivacy must be mounted inside PBXResourcesBuildPhase in ${target.pbxprojFile.path}.',
          );
        }
      },
    );

    test(
      'ios/Runner/Info.plist declares ITSAppUsesNonExemptEncryption as <false/>',
      () {
        final iosRunnerDir = _findFirstExistingDirectory(const <String>[
          'ios/Runner',
          '../../../ios/apps/client/ios/Runner',
        ]);
        if (Directory('ios').existsSync()) {
          expect(
            iosRunnerDir,
            isNotNull,
            reason: 'ios/Runner must exist in the iOS client repository.',
          );
        }

        final plistFiles = <File>[
          if (iosRunnerDir != null) File('${iosRunnerDir.path}/Info.plist'),
          if (Directory('macos/Runner').existsSync())
            File('macos/Runner/Info.plist'),
        ];
        expect(
          plistFiles,
          isNotEmpty,
          reason: 'Expected Info.plist in ios/Runner or macos/Runner.',
        );

        for (final infoPlist in plistFiles) {
          expect(
            infoPlist.existsSync(),
            isTrue,
            reason: 'Missing Info.plist at ${infoPlist.path}',
          );
          final content = infoPlist.readAsStringSync();
          expect(
            content,
            contains('<key>ITSAppUsesNonExemptEncryption</key>'),
            reason:
                '${infoPlist.path} must declare <key>ITSAppUsesNonExemptEncryption</key>.',
          );
          expect(
            RegExp(
              r'<key>ITSAppUsesNonExemptEncryption</key>\s*<false/>',
            ).hasMatch(content),
            isTrue,
            reason:
                '${infoPlist.path} must set ITSAppUsesNonExemptEncryption to <false/>.',
          );
          final parsed = _parseXmlPlistDict(content);
          expect(parsed['ITSAppUsesNonExemptEncryption'], isFalse);
        }
      },
    );

    test(
      'ios/Runner/Info.plist and en/zh-Hans/ja/ru InfoPlist.strings provide >= 12 char purpose strings for LocalNetwork, PhotoLibrary, and Camera',
      () {
        const locales = <String>['en', 'zh-Hans', 'ja', 'ru'];
        const iosRequiredKeys = <String>[
          'NSLocalNetworkUsageDescription',
          'NSPhotoLibraryUsageDescription',
          'NSCameraUsageDescription',
        ];

        final iosRunnerDir = _findFirstExistingDirectory(const <String>[
          'ios/Runner',
          '../../../ios/apps/client/ios/Runner',
        ]);
        if (Directory('ios').existsSync()) {
          expect(
            iosRunnerDir,
            isNotNull,
            reason: 'ios/Runner must exist in the iOS client repository.',
          );
        }

        if (iosRunnerDir != null) {
          final infoPlistFile = File('${iosRunnerDir.path}/Info.plist');
          expect(infoPlistFile.existsSync(), isTrue);
          final infoMap = _parseXmlPlistDict(infoPlistFile.readAsStringSync());

          for (final key in iosRequiredKeys) {
            final value = infoMap[key];
            expect(
              value,
              isA<String>(),
              reason: '${infoPlistFile.path} missing string key $key.',
            );
            final trimmed = (value! as String).trim();
            expect(
              trimmed,
              isNotEmpty,
              reason: '${infoPlistFile.path} key $key must not be empty.',
            );
            expect(
              trimmed.length,
              greaterThanOrEqualTo(12),
              reason:
                  '${infoPlistFile.path} key $key must be >= 12 chars (got ${trimmed.length}).',
            );
          }

          for (final locale in locales) {
            final stringsFile = File(
              '${iosRunnerDir.path}/$locale.lproj/InfoPlist.strings',
            );
            expect(
              stringsFile.existsSync(),
              isTrue,
              reason: 'Missing localized InfoPlist.strings: ${stringsFile.path}',
            );
            final localized = _parseAppleStrings(
              stringsFile.readAsStringSync(),
            );
            for (final key in iosRequiredKeys) {
              final value = localized[key];
              expect(
                value,
                isNotNull,
                reason: '${stringsFile.path} missing localized key $key.',
              );
              final trimmed = value!.trim();
              expect(
                trimmed,
                isNotEmpty,
                reason: '${stringsFile.path} key $key must not be empty.',
              );
              expect(
                trimmed.length,
                greaterThanOrEqualTo(12),
                reason:
                    '${stringsFile.path} key $key must be >= 12 chars (got ${trimmed.length}).',
              );
            }
          }
          return;
        }

        // Standalone desktop checkout fallback (without sibling ios repository).
        final macosRunnerDir = Directory('macos/Runner');
        expect(macosRunnerDir.existsSync(), isTrue);
        final macosInfoMap = _parseXmlPlistDict(
          File('${macosRunnerDir.path}/Info.plist').readAsStringSync(),
        );
        final macosLocalNet =
            (macosInfoMap['NSLocalNetworkUsageDescription'] as String?)?.trim();
        expect(macosLocalNet, isNotNull);
        expect(macosLocalNet!.length, greaterThanOrEqualTo(12));
        for (final locale in locales) {
          final stringsFile = File(
            '${macosRunnerDir.path}/$locale.lproj/InfoPlist.strings',
          );
          expect(stringsFile.existsSync(), isTrue);
          final localized = _parseAppleStrings(stringsFile.readAsStringSync());
          final value = localized['NSLocalNetworkUsageDescription']?.trim();
          expect(value, isNotNull);
          expect(value!.length, greaterThanOrEqualTo(12));
        }
      },
    );

    test(
      'AppIcon.appiconset 1024x1024 marketing PNG uses IHDR colorType 2 (Truecolor RGB without alpha channel)',
      () {
        final iosAppIconDir = _findFirstExistingDirectory(const <String>[
          'ios/Runner/Assets.xcassets/AppIcon.appiconset',
          '../../../ios/apps/client/ios/Runner/Assets.xcassets/AppIcon.appiconset',
        ]);
        if (Directory('ios').existsSync()) {
          expect(
            iosAppIconDir,
            isNotNull,
            reason: 'iOS AppIcon.appiconset directory must exist.',
          );
        }

        if (iosAppIconDir == null) {
          // Allow standalone desktop checkouts without a sibling ios repo.
          final macIcon = File(
            'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
          );
          expect(macIcon.existsSync(), isTrue);
          return;
        }

        final contentsFile = File('${iosAppIconDir.path}/Contents.json');
        expect(contentsFile.existsSync(), isTrue);
        final contentsJson =
            jsonDecode(contentsFile.readAsStringSync()) as Map<String, Object?>;
        final images = (contentsJson['images'] as List<Object?>?) ?? const [];

        String? marketingFilename;
        for (final item in images) {
          if (item is Map<String, Object?> && item['size'] == '1024x1024') {
            marketingFilename = item['filename'] as String?;
            break;
          }
        }
        expect(
          marketingFilename,
          isNotNull,
          reason:
              '${contentsFile.path} must map a 1024x1024 App Store icon filename.',
        );

        final iconFile = File('${iosAppIconDir.path}/$marketingFilename');
        expect(
          iconFile.existsSync(),
          isTrue,
          reason: 'Missing 1024x1024 AppIcon PNG at ${iconFile.path}',
        );

        final bytes = iconFile.readAsBytesSync();
        expect(
          bytes.length,
          greaterThanOrEqualTo(33),
          reason: '${iconFile.path} is too short to contain a valid PNG IHDR.',
        );

        const pngSignature = <int>[
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
        ];
        expect(
          bytes.sublist(0, 8),
          equals(pngSignature),
          reason: '${iconFile.path} does not start with a valid PNG signature.',
        );

        final ihdrTag = ascii.decode(bytes.sublist(12, 16));
        expect(
          ihdrTag,
          equals('IHDR'),
          reason: 'First PNG chunk in ${iconFile.path} must be IHDR.',
        );

        final byteData = ByteData.sublistView(bytes);
        final width = byteData.getUint32(16);
        final height = byteData.getUint32(20);
        expect(width, equals(1024));
        expect(height, equals(1024));

        // PNG IHDR byte offset 25 is colorType:
        // 2 = Truecolor RGB (no alpha), 4 = Grayscale+Alpha, 6 = RGBA.
        final colorType = bytes[25];
        expect(colorType, isNot(equals(6)));
        expect(colorType, isNot(equals(4)));
        expect(
          colorType,
          equals(2),
          reason:
              '${iconFile.path} IHDR byte 25 colorType must be 2 (Truecolor RGB without alpha), got $colorType.',
        );

        expect(
          _pngContainsChunk(bytes, 'tRNS'),
          isFalse,
          reason:
              '${iconFile.path} must not embed a tRNS transparency chunk (ITMS-90717).',
        );
      },
    );

    test(
      'source tree contains zero atermius-local-seed.json private seed files',
      () {
        const forbiddenFilename = 'atermius-local-seed.json';
        final rootsToScan = <Directory>[
          Directory.current,
          if (Directory('../../../ios/apps/client').existsSync())
            Directory('../../../ios/apps/client'),
          if (Directory('../../../desktop/apps/client').existsSync())
            Directory('../../../desktop/apps/client'),
        ];

        final leakedPaths = <String>{};
        for (final root in rootsToScan) {
          _collectMatchingFiles(
            root,
            targetFileName: forbiddenFilename,
            results: leakedPaths,
          );
        }
        expect(
          leakedPaths,
          isEmpty,
          reason:
              'Private seed file $forbiddenFilename must never exist in client source trees: $leakedPaths',
        );

        final configFiles = <File>[
          File('pubspec.yaml'),
          for (final target in _discoverAppleProjectTargets())
            target.pbxprojFile,
        ];
        for (final cfg in configFiles) {
          if (cfg.existsSync()) {
            expect(
              cfg.readAsStringSync(),
              isNot(contains(forbiddenFilename)),
              reason: '${cfg.path} must not reference $forbiddenFilename.',
            );
          }
        }
      },
    );
  });
}

class _AppleProjectTarget {
  const _AppleProjectTarget({
    required this.runnerDir,
    required this.pbxprojFile,
  });

  final Directory runnerDir;
  final File pbxprojFile;
}

List<_AppleProjectTarget> _discoverAppleProjectTargets() {
  const candidateRoots = <String>[
    'ios',
    'macos',
    '../../../ios/apps/client/ios',
    '../../../desktop/apps/client/macos',
  ];
  final seenCanonicalPaths = <String>{};
  final targets = <_AppleProjectTarget>[];

  for (final root in candidateRoots) {
    final runnerDir = Directory('$root/Runner');
    final pbxprojFile = File('$root/Runner.xcodeproj/project.pbxproj');
    if (runnerDir.existsSync() && pbxprojFile.existsSync()) {
      final canonical = runnerDir.resolveSymbolicLinksSync();
      if (seenCanonicalPaths.add(canonical)) {
        targets.add(
          _AppleProjectTarget(
            runnerDir: runnerDir,
            pbxprojFile: pbxprojFile,
          ),
        );
      }
    }
  }
  return targets;
}

Directory? _findFirstExistingDirectory(List<String> candidates) {
  for (final path in candidates) {
    final dir = Directory(path);
    if (dir.existsSync()) {
      return dir;
    }
  }
  return null;
}

bool _isMountedInPbxResourcesBuildPhase(
  String pbxprojContent,
  String resourceName,
) {
  var inResourcesPhase = false;
  for (final line in const LineSplitter().convert(pbxprojContent)) {
    if (line.contains('Begin PBXResourcesBuildPhase section')) {
      inResourcesPhase = true;
    } else if (line.contains('End PBXResourcesBuildPhase section')) {
      inResourcesPhase = false;
    } else if (inResourcesPhase && line.contains(resourceName)) {
      return true;
    }
  }
  return false;
}

bool _pngContainsChunk(Uint8List bytes, String chunkType) {
  final byteData = ByteData.sublistView(bytes);
  var offset = 8;
  while (offset + 8 <= bytes.length) {
    final length = byteData.getUint32(offset);
    final type = ascii.decode(
      bytes.sublist(offset + 4, offset + 8),
      allowInvalid: true,
    );
    if (type == chunkType) {
      return true;
    }
    if (type == 'IEND') {
      return false;
    }
    offset += 12 + length;
  }
  return false;
}

void _collectMatchingFiles(
  Directory dir, {
  required String targetFileName,
  required Set<String> results,
}) {
  const skippedDirectories = <String>{
    '.git',
    '.dart_tool',
    'build',
    'Pods',
    '.symlinks',
    'ephemeral',
  };

  for (final entity in dir.listSync(followLinks: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
    if (name == null) {
      continue;
    }
    if (entity is Directory) {
      if (skippedDirectories.contains(name)) {
        continue;
      }
      _collectMatchingFiles(
        entity,
        targetFileName: targetFileName,
        results: results,
      );
    } else if (entity is File && name == targetFileName) {
      results.add(entity.path);
    }
  }
}

Map<String, Object?> _parseXmlPlistDict(String xmlSource) {
  final stripped = xmlSource
      .replaceAll(RegExp(r'<\?xml[\s\S]*?\?>'), '')
      .replaceAll(RegExp(r'<!DOCTYPE[^>]*>'), '')
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

  final tagPattern = RegExp(
    r'<(/?)(plist|dict|array|key|string|true|false|integer|real)(\s[^>]*)?(/?)>',
  );
  final matches = tagPattern.allMatches(stripped).toList(growable: false);
  var index = 0;

  Object? parseValue() {
    while (index < matches.length) {
      final match = matches[index++];
      final isClosing = match.group(1) == '/';
      final tag = match.group(2)!;
      final isSelfClosing = match.group(4) == '/';

      if (isClosing) {
        throw FormatException('Unexpected closing tag </$tag> in plist.');
      }

      switch (tag) {
        case 'plist':
          final root = parseValue();
          if (index < matches.length &&
              matches[index].group(1) == '/' &&
              matches[index].group(2) == 'plist') {
            index++;
          }
          return root;
        case 'dict':
          if (isSelfClosing) {
            return <String, Object?>{};
          }
          final map = <String, Object?>{};
          while (index < matches.length) {
            final peek = matches[index];
            if (peek.group(1) == '/' && peek.group(2) == 'dict') {
              index++;
              break;
            }
            final keyOpen = matches[index++];
            if (keyOpen.group(2) != 'key' || keyOpen.group(1) == '/') {
              throw FormatException(
                'Expected <key> inside <dict>, got ${keyOpen.group(0)}.',
              );
            }
            String keyText;
            if (keyOpen.group(4) == '/') {
              keyText = '';
            } else {
              final keyClose = matches[index++];
              if (keyClose.group(1) != '/' || keyClose.group(2) != 'key') {
                throw const FormatException('Unclosed <key> tag in plist.');
              }
              keyText = _unescapeXml(
                stripped.substring(keyOpen.end, keyClose.start),
              );
            }
            map[keyText] = parseValue();
          }
          return map;
        case 'array':
          if (isSelfClosing) {
            return <Object?>[];
          }
          final list = <Object?>[];
          while (index < matches.length) {
            final peek = matches[index];
            if (peek.group(1) == '/' && peek.group(2) == 'array') {
              index++;
              break;
            }
            list.add(parseValue());
          }
          return list;
        case 'string':
        case 'integer':
        case 'real':
          if (isSelfClosing) {
            return '';
          }
          final close = matches[index++];
          if (close.group(1) != '/' || close.group(2) != tag) {
            throw FormatException('Unclosed <$tag> tag in plist.');
          }
          return _unescapeXml(stripped.substring(match.end, close.start));
        case 'true':
          return true;
        case 'false':
          return false;
      }
    }
    throw const FormatException('Unexpected end of XML plist.');
  }

  final root = parseValue();
  if (root is! Map<String, Object?>) {
    throw const FormatException('Expected top-level plist <dict>.');
  }
  return root;
}

String _unescapeXml(String input) {
  return input
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

Map<String, String> _parseAppleStrings(String source) {
  final entries = <String, String>{};
  final length = source.length;
  var i = 0;

  void skipTrivia() {
    while (i < length) {
      final ch = source.codeUnitAt(i);
      if (ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D || ch == 0xFEFF) {
        i++;
        continue;
      }
      if (ch == 0x2F && i + 1 < length) {
        final next = source.codeUnitAt(i + 1);
        if (next == 0x2F) {
          i += 2;
          while (i < length && source.codeUnitAt(i) != 0x0A) {
            i++;
          }
          continue;
        }
        if (next == 0x2A) {
          i += 2;
          while (i + 1 < length &&
              !(source.codeUnitAt(i) == 0x2A &&
                  source.codeUnitAt(i + 1) == 0x2F)) {
            i++;
          }
          i += 2;
          continue;
        }
      }
      break;
    }
  }

  String readQuoted() {
    if (i >= length || source.codeUnitAt(i) != 0x22) {
      throw FormatException('Expected opening quote at offset $i in .strings.');
    }
    i++;
    final buffer = StringBuffer();
    while (i < length) {
      final ch = source[i++];
      if (ch == '"') {
        return buffer.toString();
      }
      if (ch == r'\' && i < length) {
        final esc = source[i++];
        switch (esc) {
          case 'n':
            buffer.write('\n');
          case 'r':
            buffer.write('\r');
          case 't':
            buffer.write('\t');
          case '"':
            buffer.write('"');
          case r'\':
            buffer.write(r'\');
          default:
            buffer.write(esc);
        }
      } else {
        buffer.write(ch);
      }
    }
    throw const FormatException('Unterminated quoted string in .strings.');
  }

  while (true) {
    skipTrivia();
    if (i >= length) {
      break;
    }
    final key = readQuoted();
    skipTrivia();
    if (i >= length || source[i] != '=') {
      throw FormatException('Expected "=" after key "$key" in .strings.');
    }
    i++;
    skipTrivia();
    final value = readQuoted();
    skipTrivia();
    if (i >= length || source[i] != ';') {
      throw FormatException('Expected ";" after value for "$key" in .strings.');
    }
    i++;
    entries[key] = value;
  }

  return entries;
}
