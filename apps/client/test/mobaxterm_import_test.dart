import 'dart:convert';
import 'dart:typed_data';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/import/legacy_text_decoder.dart';
import 'package:aterm_client/import/mobaxterm_sessions.dart';
import 'package:aterm_client/import/termius_transfer.dart';
import 'package:aterm_client/import/termius_transfer_target.dart';
import 'package:aterm_client/l10n/l10n.dart';
import 'package:aterm_client/ui/app_theme.dart';
import 'package:aterm_client/ui/termius_transfer_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Synthetic sessions only. Field positions follow MobaXterm 23+ exports.
const _terminal =
    'MobaFont%10%0%0%-1%15%236,236,236%30,30,30%180,180,192%0%-1%0%%xterm%-1%'
    '-1%_Std_Colors_0_%80%24%0%1%-1%<none>%%0%0%-1';

String _session(int icon, List<String> connection, {String comment = ' '}) =>
    '#$icon#${connection.join('%')}#$_terminal#0#$comment#-1';

String _ssh(
  String host, {
  String port = '22',
  String user = '',
  String command = '',
  String gatewayHosts = '',
  String gatewayPorts = '',
  String gatewayUsers = '',
  String key = '',
  String gatewayKeys = '',
  String proxyType = '0',
}) {
  final fields = List.filled(39, '');
  fields[0] = '0';
  fields[1] = host;
  fields[2] = port;
  fields[3] = user;
  fields[5] = '-1';
  fields[6] = '-1';
  fields[7] = command;
  fields[8] = gatewayHosts;
  fields[9] = gatewayPorts;
  fields[10] = gatewayUsers;
  fields[11] = '0';
  fields[12] = user.isEmpty ? '-1' : '0';
  fields[13] = '0';
  fields[14] = key;
  fields[15] = gatewayKeys;
  fields[16] = '-1';
  fields[19] = proxyType;
  fields[21] = '1080';
  return _session(109, fields);
}

String _rdp(String host, {String user = '', String gateway = ''}) {
  final fields = List.filled(32, '0');
  fields[0] = '4';
  fields[1] = host;
  fields[2] = '3389';
  fields[3] = user;
  fields[12] = '';
  fields[13] = gateway;
  fields[14] = gateway.isEmpty ? '' : '22';
  fields[15] = gateway.isEmpty ? '' : 'jump';
  fields[18] = '';
  return _session(91, fields);
}

String _vnc(String host, String port) {
  final fields = List.filled(18, '');
  fields[0] = '5';
  fields[1] = host;
  fields[2] = port;
  fields[3] = '-1';
  fields[4] = '0';
  return _session(128, fields);
}

String _telnet(String host) => _session(98, ['1', host, '23', '', '', '2']);

String _sftp(String host, String user, String key) {
  final fields = List.filled(16, '');
  fields[0] = '7';
  fields[1] = host;
  fields[2] = '2222';
  fields[3] = user;
  fields[9] = key;
  return _session(140, fields);
}

String _serial() =>
    _session(131, ['8', '-1', '100', '3', '0', '0', '1', '2', 'COM3']);

String _file(List<String> lines) => '${lines.join('\r\n')}\r\n';

TermiusImportRow _row(TermiusImportDocument document, String label) =>
    document.rows.singleWhere((row) => row.label == label);

Set<TermiusIssueCode> _codes(TermiusImportRow row) => {
  for (final issue in row.issues) issue.code,
};

class _FakeTarget implements TermiusTransferTarget {
  @override
  bool get canWrite => true;
  final applied = <TermiusImportPlan>[];

  @override
  String? get contextKey => 'fake';

  @override
  Future<TermiusCatalog> loadCatalog() async =>
      TermiusCatalog(hosts: const [], groups: const []);

  @override
  Future<TermiusApplyReport> apply(TermiusImportPlan plan) async {
    applied.add(plan);
    return TermiusApplyReport(
      createdHosts: plan.createCount,
      createdGroups: plan.newGroups.length,
    );
  }
}

void main() {
  final export = _file([
    '[Bookmarks]',
    'SubRep=',
    'ImgNum=42',
    'web01=${_ssh('10.0.0.11', user: 'deploy', command: 'htop')}',
    'bastion=${_ssh('bastion.example', user: 'jump')}',
    'Windows box=${_rdp('win.example', user: 'Administrator', gateway: 'bastion.example')}',
    'Switch=${_telnet('switch.example')}',
    'Console=${_serial()}',
    '',
    '[Bookmarks_1]',
    r'SubRep=Prod\DB',
    'ImgNum=41',
    'db1=${_ssh('db1.internal', user: 'postgres', gatewayHosts: 'gw.example', gatewayPorts: '2222', gatewayUsers: 'ops', key: r'_ProfileDir_\.ssh\id_ed25519')}',
    'db2=${_ssh('db2.internal', user: 'postgres', gatewayHosts: 'gw.example__PIPE__inner.example', gatewayPorts: '2222__PIPE__22', gatewayUsers: 'ops__PIPE__ops')}',
    'files=${_sftp('files.example', 'ftp', r'_CurrentDrive_:\keys\files.ppk')}',
    'desk=${_vnc('vnc.example', '5901')}',
    'nobody=${_ssh('anon.example', user: '[Work]')}',
  ]);

  group('MobaXtermImporter', () {
    test('maps sessions, folders, gateways and unsupported types', () {
      expect(looksLikeMobaXtermSessions(utf8.encode(export)), isTrue);
      final document = MobaXtermImporter.parseBytes(
        utf8.encode(export),
        languageCode: 'en',
      );
      expect(document.format, TermiusSourceFormat.mobaXterm);
      expect(document.blocksWholeFile, isFalse);

      final web = _row(document, 'web01');
      expect(web.protocol, HostProtocol.ssh);
      expect(web.address, '10.0.0.11');
      expect(web.port, 22);
      expect(web.username, 'deploy');
      expect(web.groupPath, isEmpty);
      expect(web.blocked, isFalse);
      expect(
        web.issues.single.code,
        TermiusIssueCode.sshOptionIgnored,
        reason: 'the remote command is reported',
      );

      // The RDP gateway matches the "bastion" session, so no extra host.
      final windows = _row(document, 'Windows box');
      expect(windows.protocol, HostProtocol.rdp);
      expect(windows.username, 'Administrator');
      expect(windows.jumpAlias, 'bastion');

      final telnet = _row(document, 'Switch');
      expect(telnet.protocol, HostProtocol.telnet);
      expect(telnet.port, 23);
      expect(telnet.blocked, isFalse);

      final serial = _row(document, 'Console');
      expect(serial.blocked, isTrue);
      expect(serial.issues.single.code, TermiusIssueCode.mobaUnsupportedSession);
      expect(serial.issues.single.detail, 'Serial');

      // db1 goes through a new gateway host "ops@gw.example:2222".
      final db1 = _row(document, 'db1');
      expect(db1.groupPath, ['Prod', 'DB']);
      expect(db1.jumpAlias, 'ops@gw.example:2222');
      final keyIssue = db1.issues.singleWhere(
        (issue) => issue.code == TermiusIssueCode.mobaKeyFileNotRead,
      );
      expect(keyIssue.detail, 'id_ed25519');
      final gateway = _row(document, 'ops@gw.example:2222');
      expect(gateway.address, 'gw.example');
      expect(gateway.port, 2222);
      expect(gateway.username, 'ops');
      expect(gateway.groupPath, ['Prod', 'DB']);
      expect(gateway.jumpAlias, isNull);
      expect(_codes(gateway), {TermiusIssueCode.mobaGatewayAdded});
      // Gateway rows come right before the first session that needs them.
      expect(document.rows.indexOf(gateway), document.rows.indexOf(db1) - 1);

      // db2 reuses the first hop and adds the second one behind it.
      final db2 = _row(document, 'db2');
      expect(db2.jumpAlias, 'ops@inner.example');
      expect(_row(document, 'ops@inner.example').jumpAlias, 'ops@gw.example:2222');
      expect(
        document.rows.where((row) => row.label.startsWith('ops@gw.example')),
        hasLength(1),
      );

      final sftp = _row(document, 'files');
      expect(sftp.protocol, HostProtocol.ssh);
      expect(sftp.port, 2222);
      expect(_codes(sftp), {
        TermiusIssueCode.mobaSftpAsSsh,
        TermiusIssueCode.mobaKeyFileNotRead,
      });

      final vnc = _row(document, 'desk');
      expect(vnc.protocol, HostProtocol.vnc);
      expect(vnc.port, 5901);

      final credential = _row(document, 'nobody');
      expect(credential.username, isEmpty);
      expect(_codes(credential), {
        TermiusIssueCode.mobaCredentialUsername,
        TermiusIssueCode.missingUsername,
      });

      // Rows are numbered in display order.
      expect(
        [for (final row in document.rows) row.row],
        [for (var index = 1; index <= document.rows.length; index++) index],
      );
    });

    test('plans groups, jump hosts and the fallback username', () {
      final document = MobaXtermImporter.parse(export);
      expect(TermiusImportPlanner.hasRowsMissingUsername(document), isTrue);
      final plan = TermiusImportPlanner.plan(
        document,
        TermiusCatalog(hosts: const [], groups: const []),
        fallbackUsername: 'admin',
      );
      final hosts = {for (final host in plan.hostsToCreate) host.name: host};
      expect(hosts.keys, containsAll(<String>[
        'web01',
        'bastion',
        'Windows box',
        'Switch',
        'ops@gw.example:2222',
        'ops@inner.example',
        'db1',
        'db2',
        'files',
        'desk',
        'nobody',
      ]));
      expect(hosts, isNot(contains('Console')));
      expect(hosts['nobody']!.username, 'admin');
      expect(hosts['Windows box']!.jumpHostId, hosts['bastion']!.id);
      expect(hosts['db1']!.jumpHostId, hosts['ops@gw.example:2222']!.id);
      expect(hosts['db2']!.jumpHostId, hosts['ops@inner.example']!.id);
      expect(
        hosts['ops@inner.example']!.jumpHostId,
        hosts['ops@gw.example:2222']!.id,
      );
      expect(hosts['Switch']!.protocol, HostProtocol.telnet);
      expect(hosts['Switch']!.validate(), isNull);
      expect(plan.newGroups.map((group) => group.name), ['Prod', 'DB']);
      final prod = plan.newGroups.first;
      expect(plan.newGroups.last.parentId, prod.id);
      expect(hosts['db1']!.groupId, plan.newGroups.last.id);
      // Creation order puts every jump host before the hosts using it.
      final ordered = orderHostsForCreation(plan.hostsToCreate, const {});
      final seen = <String>{};
      for (final host in ordered) {
        if (host.jumpHostId != null) expect(seen, contains(host.jumpHostId));
        seen.add(host.id);
      }
    });

    test('MobaXterm.ini: other sections ignored, saved passwords reported', () {
      final document = MobaXtermImporter.parse(
        _file([
          '[Misc]',
          'SessionP=123',
          '[Bookmarks]',
          'SubRep=',
          'ImgNum=42',
          'one=${_ssh('one.example', user: 'me', proxyType: '2')}',
          '[Passwords]',
          r'ssh22:me@one.example=_obfuscated_',
          '[Credentials]',
          'Work=me:_obfuscated_',
        ]),
      );
      expect(document.rows, hasLength(1));
      expect(
        document.fileIssues.single.code,
        TermiusIssueCode.mobaPasswordsNotImported,
      );
      final row = document.rows.single;
      expect(row.password, isNull);
      expect(row.issues.single.detail, 'Proxy');
    });

    test('files without sessions are refused', () {
      final empty = MobaXtermImporter.parse('[Misc]\r\nfoo=bar\r\n');
      expect(empty.blocksWholeFile, isTrue);
      expect(empty.fileIssues.single.code, TermiusIssueCode.mobaNoSessions);
      expect(
        MobaXtermImporter.parse('').fileIssues.single.code,
        TermiusIssueCode.emptyFile,
      );
      expect(looksLikeMobaXtermSessions(utf8.encode('a,b\r\n1,2')), isFalse);
      final broken = MobaXtermImporter.parse('[Bookmarks]\r\nx=garbage\r\n');
      expect(
        broken.rows.single.issues.single.code,
        TermiusIssueCode.mobaInvalidSession,
      );
    });

    // Shapes seen in real exports and in MobaXterm's ServersListToMxtSessions.
    test('real-world quirks', () {
      final document = MobaXtermImporter.parse(
        _file([
          '[Bookmarks]',
          'SubRep=Imported',
          'ImgNum=41',
          'h1 (SSH)= #109#0%h1.example%22%%%-1%-1%%%22%%0%-1',
          'h1 (Telnet)= #98#1%h1.example%23%%%0%%22%%%0',
          'h1 (RDP)= #91#4%h1.example%3389%%0%-1%-1%-1%-1%0%0%-1%%%22%%-1%0%%-1%%-1%-1%0',
          'GNS3 R1 = #98#1%172.16.253.1%5004%%%2%%%%%0%0%%1080%%#$_terminal#0# #-1',
          'Switch=#98#1%192.168.1.1%23%admin%%2%%%%%0%0%%1080%%#$_terminal#0# #-1',
          'Default user= #109#0%d.example%22%<default>%%0%-1%%%%%0%0%0%%%-1%0%0%0%%1080%%0%0%1#$_terminal#0# #-1',
          'WSL-Ubuntu=#105#14%Ubuntu%',
          'Shell=#97#10%0__PIPE__Bash%%',
        ]),
      );
      expect(document.rows, hasLength(8));
      final ssh = _row(document, 'h1 (SSH)');
      expect(ssh.groupPath, ['Imported']);
      expect(_codes(ssh), {TermiusIssueCode.missingUsername});
      expect(_row(document, 'h1 (Telnet)').protocol, HostProtocol.telnet);
      expect(_row(document, 'h1 (RDP)').blocked, isFalse);
      final gns3 = _row(document, 'GNS3 R1');
      expect(gns3.port, 5004);
      expect(gns3.blocked, isFalse);
      // Atermius Telnet hosts never store a username.
      expect(_row(document, 'Switch').username, isEmpty);
      expect(_row(document, 'Default user').username, isEmpty);
      final wsl = _row(document, 'WSL-Ubuntu');
      expect(wsl.issues.single.detail, 'WSL');
      expect(wsl.address, isEmpty);
      expect(_row(document, 'Shell').address, isEmpty);
    });

    test('bad hosts, ports and usernames block only their row', () {
      final document = MobaXtermImporter.parse(
        _file([
          '[Bookmarks]',
          'bad host=${_ssh('a b', user: 'x')}',
          'bad port=${_ssh('p.example', port: '70000', user: 'x')}',
          'bad user=${_ssh('u.example', user: 'two words')}',
          'ok=${_ssh('ok.example', user: 'x')}',
        ]),
      );
      expect(_codes(_row(document, 'bad host')), {
        TermiusIssueCode.invalidAddress,
      });
      expect(_codes(_row(document, 'bad port')), {TermiusIssueCode.invalidPort});
      expect(_codes(_row(document, 'bad user')), {
        TermiusIssueCode.invalidUsername,
      });
      expect(_row(document, 'ok').blocked, isFalse);
    });
  });

  group('decodeWindowsText', () {
    List<int> ini(List<int> folder, List<int> name) => [
      ...ascii.encode('[Bookmarks_1]\r\nSubRep='),
      ...folder,
      ...ascii.encode('\r\nImgNum=41\r\n'),
      ...name,
      ...ascii.encode('=${_ssh('h.example', user: 'u')}\r\n'),
    ];
    // "生产\数据库" and "主服务器" in GBK (code page 936).
    const gbkFolder = [
      0xC9, 0xFA, 0xB2, 0xFA, 0x5C, 0xCA, 0xFD, 0xBE, 0xDD, 0xBF, 0xE2, //
    ];
    const gbkName = [0xD6, 0xF7, 0xB7, 0xFE, 0xCE, 0xF1, 0xC6, 0xF7];
    // "本番" and "サーバー" in Shift_JIS (code page 932).
    const sjisFolder = [0x96, 0x7B, 0x94, 0xD4];
    const sjisName = [0x83, 0x54, 0x81, 0x5B, 0x83, 0x6F, 0x81, 0x5B];

    test('GBK files from Chinese Windows', () {
      for (final language in ['zh', 'en']) {
        final document = MobaXtermImporter.parseBytes(
          ini(gbkFolder, gbkName),
          languageCode: language,
        );
        final row = document.rows.single;
        expect(row.label, '主服务器', reason: language);
        expect(row.groupPath, ['生产', '数据库'], reason: language);
      }
    });

    test('Shift_JIS files from Japanese Windows', () {
      for (final language in ['ja', 'en']) {
        final document = MobaXtermImporter.parseBytes(
          ini(sjisFolder, sjisName),
          languageCode: language,
        );
        expect(document.rows.single.label, 'サーバー', reason: language);
        expect(document.rows.single.groupPath, ['本番'], reason: language);
      }
    });

    test('Western and Cyrillic single-byte files', () {
      final cafe = [0x43, 0x61, 0x66, 0xE9, 0x73];
      expect(decodeWindowsText(cafe, languageCode: 'en').text, 'Cafés');
      final server = [0xD1, 0xE5, 0xF0, 0xE2, 0xE5, 0xF0];
      final russian = decodeWindowsText(server, languageCode: 'ru');
      expect(russian.text, 'Сервер');
      expect(russian.codePage, LegacyCodePage.windows1251);
    });

    test('UTF-8 with or without BOM wins over code pages', () {
      const text = '[Bookmarks]\r\n主机=x\r\n';
      final withBom = [0xEF, 0xBB, 0xBF, ...utf8.encode(text)];
      expect(decodeWindowsText(withBom, languageCode: 'zh').text, text);
      expect(
        decodeWindowsText(utf8.encode(text), languageCode: 'ja').codePage,
        LegacyCodePage.utf8,
      );
    });
  });

  testWidgets('dialog imports a MobaXterm file from both buttons', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1600);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final target = _FakeTarget();
    final l10n = appLocalizationsFor(const Locale('en'));
    final file = Uint8List.fromList(
      utf8.encode(
        _file([
          '[Bookmarks]',
          'SubRep=',
          'web01=${_ssh('10.0.0.11', user: 'deploy')}',
          'Console=${_serial()}',
        ]),
      ),
    );
    final picked = <TermiusImportSource>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizationSetup.delegates,
        supportedLocales: AppLocalizationSetup.locales,
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () => showDialog<TermiusTransferOutcome>(
                context: context,
                builder: (_) => TermiusTransferDialog(
                  target: target,
                  pickBytesForTesting: (source) async {
                    picked.add(source);
                    return (
                      bytes: Uint8List.fromList(file),
                      name: 'all.mxtsessions',
                    );
                  },
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.mobaXtermImportChoose), findsOneWidget);
    expect(find.text(l10n.mobaXtermImportHelp), findsOneWidget);

    // A MobaXterm file picked with the CSV button is recognized too.
    await tester.tap(find.byKey(const ValueKey('termius_import_pick_csv')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(l10n.mobaXtermIssueUnsupportedSession('Serial')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('termius_import_pick_mobaxterm')),
    );
    await tester.pumpAndSettle();
    expect(picked, [TermiusImportSource.csv, TermiusImportSource.mobaXterm]);
    expect(find.text('all.mxtsessions'), findsOneWidget);
    expect(find.text(l10n.r7ImportApply(1)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('termius_import_apply')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.r7ImportConfirmTitle), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('termius_import_confirm_accept')),
    );
    await tester.pumpAndSettle();
    final host = target.applied.single.hostsToCreate.single;
    expect(host.name, 'web01');
    expect(host.address, '10.0.0.11');
    expect(host.username, 'deploy');
  });
}
