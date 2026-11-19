// 真实 OpenSSH sshd + 公钥认证 + 可切换 TCP 黑洞代理的长连接集成测试。
//
// 与基于 fakeAsync 的 72h 浸泡压测互补：这里全部使用真实墙钟、真实 sshd、真实
// RFC 4253 密钥交换与 `keepalive@openssh.com` 全局请求，验证已认证会话在半开
// 黑洞（不发 RST/FIN、静默丢包）下能被看门狗识破并断开，且网络恢复后可重新建连。
//
// 非 root 启动的 sshd 只允许当前用户登录；缺少 /usr/sbin/sshd 或 ssh-keygen 时跳过。
// 可通过环境变量 ATERM_REAL_SOAK_SECONDS 调整真实墙钟浸泡时长（默认 60 秒）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aterm_client/domain/models.dart';
import 'package:aterm_client/ssh/ssh_connection_health.dart';
import 'package:aterm_client/ssh/ssh_keepalive_policy.dart';
import 'package:aterm_client/ssh/ssh_service.dart';
import 'package:flutter_test/flutter_test.dart';

final bool _toolsAvailable =
    !Platform.isWindows &&
    File('/usr/sbin/sshd').existsSync() &&
    Process.runSync('which', ['ssh-keygen']).exitCode == 0;

void main() {
  group('真实 sshd 长连接与半开黑洞', () {
    late _TemporarySshd sshd;
    late _BlackholeProxy proxy;

    setUp(() async {
      sshd = await _TemporarySshd.start();
      proxy = await _BlackholeProxy.start(sshd.port);
    });

    tearDown(() async {
      await proxy.close();
      await sshd.stop();
    });

    Future<SshConnection> connect(SshKeepalivePolicy policy) async {
      final controller = SshKeepaliveController();
      addTearDown(controller.dispose);
      await controller.select(policy);
      return SshService(
        api: null,
        deviceId: 'real-sshd-long-connection-test',
        useRelay: false,
        keepaliveController: controller,
      ).connect(
        host: HostRecord(
          id: 'real-sshd',
          name: 'real sshd',
          address: '127.0.0.1',
          port: proxy.port,
          username: sshd.user,
        ),
        credential: CredentialRecord(
          id: 'key',
          name: 'key',
          username: sshd.user,
          kind: AuthKind.privateKey,
          privateKey: sshd.userPrivateKey,
        ),
        verifyHostKey: (_, _) async => true,
      );
    }

    test(
      '周期保活：已认证会话进入真实 TCP 黑洞后被看门狗识破断开，恢复后可重新建连',
      () async {
        final connection = await connect(
          const SshKeepalivePolicy(
            intervalSeconds: 10,
            maxMissed: 2,
            rekeyMinutes: 0,
          ),
        );
        final shell = _ShellProbe(connection);
        expect(await shell.roundTrip('before-blackhole'), isTrue);
        expect(await connection.probeLiveness(), isTrue);
        expect(connection.health.lastRtt, isNotNull);
        expect(connection.health.state, SshHealthState.healthy);

        final watch = Stopwatch()..start();
        proxy.blackhole = true;
        await connection.client.done
            .then<void>((_) {}, onError: (Object _) {})
            .timeout(const Duration(seconds: 60));
        watch.stop();

        expect(connection.client.isClosed, isTrue);
        expect(connection.health.keepaliveTimedOut, isTrue);
        // 10s 间隔 + 8s 单次超时 + 连续 2 次：理论上约 18~28s 内判定。
        expect(watch.elapsed, lessThan(const Duration(seconds: 45)));
        await connection.close();

        // 网络恢复：经同一代理重新建立已认证会话并正常收发。
        proxy.blackhole = false;
        final again = await connect(
          const SshKeepalivePolicy(
            intervalSeconds: 10,
            maxMissed: 2,
            rekeyMinutes: 0,
          ),
        );
        addTearDown(again.close);
        expect(await _ShellProbe(again).roundTrip('after-recovery'), isTrue);
        // ignore: avoid_print
        print(
          jsonEncode({
            'realSshd': 'blackhole_detect',
            'detectSeconds': watch.elapsed.inMilliseconds / 1000,
          }),
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: _toolsAvailable ? null : 'OpenSSH unavailable',
    );

    test(
      '关闭周期保活：前台切回探活在真实黑洞中连续超时后关闭僵死传输',
      () async {
        final connection = await connect(
          const SshKeepalivePolicy(
            intervalSeconds: 0,
            maxMissed: 2,
            rekeyMinutes: 0,
          ),
        );
        expect(await _ShellProbe(connection).roundTrip('ready'), isTrue);
        expect(
          await connection.probeLiveness(timeout: const Duration(seconds: 2)),
          isTrue,
        );

        proxy.blackhole = true;
        expect(
          await connection.probeLiveness(timeout: const Duration(seconds: 2)),
          isFalse,
        );
        expect(connection.client.isClosed, isFalse);
        expect(connection.health.state, SshHealthState.degraded);
        expect(
          await connection.probeLiveness(timeout: const Duration(seconds: 2)),
          isFalse,
        );
        await connection.client.done
            .then<void>((_) {}, onError: (Object _) {})
            .timeout(const Duration(seconds: 10));
        expect(connection.client.isClosed, isTrue);
        expect(connection.health.keepaliveTimedOut, isTrue);
        await connection.close();
      },
      timeout: const Timeout(Duration(minutes: 1)),
      skip: _toolsAvailable ? null : 'OpenSSH unavailable',
    );

    test(
      '真实墙钟浸泡：周期保活 + 主动 rekey + 持续回显在长连接中保持健康',
      () async {
        final soakSeconds =
            int.tryParse(
              Platform.environment['ATERM_REAL_SOAK_SECONDS'] ?? '',
            ) ??
            60;
        final connection = await connect(
          const SshKeepalivePolicy(
            intervalSeconds: 10,
            maxMissed: 2,
            rekeyMinutes: 0,
          ),
        );
        addTearDown(connection.close);
        final shell = _ShellProbe(connection);
        final watch = Stopwatch()..start();
        var echoes = 0, rekeys = 0, round = 0;
        while (watch.elapsed < Duration(seconds: soakSeconds)) {
          round++;
          expect(await shell.roundTrip('soak-$round'), isTrue);
          echoes++;
          if (round % 4 == 0) {
            await connection.client.rekey().timeout(
              const Duration(seconds: 30),
            );
            rekeys++;
            expect(await shell.roundTrip('after-rekey-$round'), isTrue);
            echoes++;
          }
          await Future<void>.delayed(const Duration(seconds: 5));
        }
        watch.stop();

        expect(connection.client.isClosed, isFalse);
        expect(connection.health.keepaliveTimedOut, isFalse);
        expect(connection.health.missedProbes, 0);
        expect(
          connection.health.probesSucceeded,
          greaterThanOrEqualTo(soakSeconds ~/ 10 - 1),
        );
        expect(rekeys, greaterThanOrEqualTo(1));
        // ignore: avoid_print
        print(
          jsonEncode({
            'realSshd': 'wall_clock_soak',
            'seconds': watch.elapsed.inSeconds,
            'echoes': echoes,
            'rekeys': rekeys,
            'keepaliveProbesSucceeded': connection.health.probesSucceeded,
            'smoothedRttMs': connection.health.smoothedRtt?.inMilliseconds,
          }),
        );
      },
      timeout: const Timeout(Duration(minutes: 30)),
      skip: _toolsAvailable ? null : 'OpenSSH unavailable',
    );
  });
}

/// 在交互 shell 上发送带唯一标记的 echo 并等待回显，验证端到端可用。
class _ShellProbe {
  _ShellProbe(this.connection) {
    connection.output.listen(_buffer.write);
  }

  final SshConnection connection;
  final _buffer = StringBuffer();

  Future<bool> roundTrip(String tag) async {
    // 使用算术展开，确保匹配的是 shell 的输出而非终端对输入的回显。
    final expected = 'mark-$tag-42';
    connection.input('echo mark-$tag-\$((40+2))\n');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (_buffer.toString().contains(expected)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return false;
  }
}

/// 可切换的 TCP 转发代理：`blackhole = true` 时双向静默丢弃数据但不关闭连接，
/// 模拟 NAT 超时 / 防火墙静默丢包 / 切网后的半开链路。
class _BlackholeProxy {
  _BlackholeProxy._(this._server, this._upstreamPort) {
    _server.listen(_accept);
  }

  static Future<_BlackholeProxy> start(int upstreamPort) async =>
      _BlackholeProxy._(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        upstreamPort,
      );

  final ServerSocket _server;
  final int _upstreamPort;
  final _sockets = <Socket>[];
  bool blackhole = false;

  int get port => _server.port;

  Future<void> _accept(Socket client) async {
    _sockets.add(client);
    final Socket upstream;
    try {
      upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _upstreamPort,
      );
    } on Object {
      client.destroy();
      return;
    }
    _sockets.add(upstream);
    void pipe(Socket from, Socket to) {
      from.listen(
        (data) {
          if (!blackhole) to.add(data);
        },
        onDone: () => to.destroy(),
        onError: (Object _) => to.destroy(),
        cancelOnError: true,
      );
    }

    pipe(client, upstream);
    pipe(upstream, client);
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }
}

/// 以当前用户身份在回环地址上临时启动的真实 OpenSSH sshd。
class _TemporarySshd {
  _TemporarySshd._(
    this._root,
    this._process,
    this.port,
    this.user,
    this.userPrivateKey,
  );

  final Directory _root;
  final Process _process;
  final int port;
  final String user;
  final String userPrivateKey;

  static Future<_TemporarySshd> start() async {
    final root = await Directory.systemTemp.createTemp('atermius-real-sshd-');
    Future<void> keygen(String name) async {
      final result = await Process.run('ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        '-N',
        '',
        '-f',
        '${root.path}/$name',
      ]);
      if (result.exitCode != 0) throw StateError('ssh-keygen failed');
    }

    await keygen('user');
    await keygen('host');
    await File(
      '${root.path}/authorized_keys',
    ).writeAsString(await File('${root.path}/user.pub').readAsString());
    final user = await _currentUser();
    final lease = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = lease.port;
    await lease.close();
    await File('${root.path}/sshd_config').writeAsString('''
ListenAddress 127.0.0.1
Port $port
HostKey ${root.path}/host
PidFile ${root.path}/sshd.pid
AuthorizedKeysFile ${root.path}/authorized_keys
AuthenticationMethods publickey
AllowUsers $user
StrictModes no
UsePAM no
UseDNS no
PermitTTY yes
PrintMotd no
ClientAliveInterval 0
LogLevel ERROR
''');
    final process = await Process.start('/usr/sbin/sshd', [
      '-D',
      '-e',
      '-f',
      '${root.path}/sshd_config',
    ]);
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    // 不用探测连接判断就绪（会计入 OpenSSH PerSourcePenalties），改为轮询端口占用。
    for (var i = 0; ; i++) {
      try {
        final probe = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        await probe.close();
      } on SocketException {
        break; // 端口已被 sshd 占用。
      }
      if (i > 200) throw StateError('sshd did not start');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return _TemporarySshd._(
      root,
      process,
      port,
      user,
      await File('${root.path}/user').readAsString(),
    );
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode;
    await _root.delete(recursive: true);
  }

  static Future<String> _currentUser() async {
    final fromEnvironment = Platform.environment['USER'];
    if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
      return fromEnvironment;
    }
    final result = await Process.run('id', ['-un']);
    if (result.exitCode != 0) throw StateError('Could not determine user.');
    return (result.stdout as String).trim();
  }
}
