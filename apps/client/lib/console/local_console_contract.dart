abstract interface class LocalConsole {
  Stream<String> get output;
  Future<int> get exitCode;
  void input(String text);
  void resize(int columns, int rows);
  Future<void> close();
}

/// Optional capability of a PTY-backed local shell: the shell process's
/// current working directory, used when duplicating/splitting a shell. Returns
/// null when the platform cannot report it (callers fall back to the launch
/// directory).
abstract interface class LocalConsoleWorkingDirectory {
  Future<String?> currentWorkingDirectory();
}

/// Optional capability of a console whose device opens asynchronously: an
/// Android USB serial adapter first waits for Android's USB access prompt.
/// [ready] completes once the port is open, or fails with a
/// [LocalConsoleStartException]. Callers attach the console to a tab only
/// after it completed; consoles without this capability are usable as soon
/// as they are returned.
abstract interface class LocalConsoleStartup {
  Future<void> get ready;
}

/// Why a [LocalConsoleStartup] console could not start. [message] is
/// localized and contains nothing secret, so it can be shown as is.
class LocalConsoleStartException implements Exception {
  const LocalConsoleStartException(this.message);
  final String message;

  @override
  String toString() => message;
}
