import 'ssh_keepalive_store_native.dart'
    if (dart.library.js_interop) 'ssh_keepalive_store_web.dart'
    as platform;

/// 本机设备级的 SSH 链路保活与长连接维护策略存储接口。
///
/// 不包含任何密钥或主机信息，不参与加密保险库同步，仅描述当前设备网络环境下的
/// 保活心跳、僵死判定、前台切回探活与周期密钥轮换策略。
abstract interface class SshKeepaliveStore {
  Future<String?> read();

  Future<void> write(String value);
}

SshKeepaliveStore createSshKeepaliveStore() =>
    platform.createSshKeepaliveStore();

/// 供单元测试与压测使用的内存存储实现。
class MemorySshKeepaliveStore implements SshKeepaliveStore {
  MemorySshKeepaliveStore([this.value]);

  String? value;
  int writes = 0;
  Object? failWith;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    writes++;
    if (failWith case final error?) throw error;
    this.value = value;
  }
}
