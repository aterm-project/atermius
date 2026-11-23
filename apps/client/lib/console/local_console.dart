import 'local_console_stub.dart'
    if (dart.library.io) 'local_console_io.dart'
    as platform;
import 'local_shell.dart';
export 'local_console_contract.dart';
export 'local_shell.dart';
import 'local_console_contract.dart';

/// Whether the embedded local shell exists here (Linux, Windows and macOS
/// desktops). Never true on Android: the app has no shell of its own there.
bool get localConsoleSupported => platform.localConsoleSupported;

/// Whether the serial Console exists here: COM ports on Windows, /dev/cu.*
/// on macOS and USB-to-serial adapters (USB host / OTG) on Android. Separate
/// from [localConsoleSupported] so Android gets serial without a shell.
bool get serialConsoleSupported => platform.serialConsoleSupported;

/// Whether serial ports are USB adapters picked from a list (Android) rather
/// than typed device names.
bool get serialConsoleUsesUsbAdapters => platform.serialConsoleUsesUsbAdapters;

/// Starts the embedded local shell described by [launch] in an owned PTY.
/// Throws [LocalShellException] / [UnsupportedError] when it cannot start.
LocalConsole openLocalConsole({
  LocalShellLaunch launch = LocalShellLaunch.systemDefault,
}) => platform.openLocalConsole(launch: launch);

/// Shell kinds installed on this desktop (empty on web/mobile).
List<LocalShellKind> availableLocalShellKinds() =>
    platform.availableLocalShellKinds();

/// Opens a serial Console on [port] at 8N1 without flow control: `COMn` on
/// Windows, `/dev/cu.*` on macOS, a `usb:` id (UsbSerialPortId) on Android.
/// An Android console implements [LocalConsoleStartup]: it asks for USB
/// access and opens the adapter after it is returned.
LocalConsole openSerialConsole(String port, {int baudRate = 115200}) =>
    platform.openSerialConsole(port, baudRate: baudRate);
