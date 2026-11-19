import 'paste_safety_store_native.dart'
    if (dart.library.js_interop) 'paste_safety_store_web.dart'
    as platform;

/// 本机设备级的生产粘贴安全护栏开关存储接口。
///
/// 仅存储单字节开关标记（`1` / `0`），不含任何主机、命令或凭据信息，不参与同步。
abstract interface class PasteSafetyStore {
  Future<String?> read();

  Future<void> write(String value);
}

PasteSafetyStore createPasteSafetyStore() => platform.createPasteSafetyStore();

/// 供单元测试使用的内存存储实现。
class MemoryPasteSafetyStore implements PasteSafetyStore {
  MemoryPasteSafetyStore([this.value]);

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
