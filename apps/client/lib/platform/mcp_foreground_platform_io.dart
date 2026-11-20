import 'dart:io';

/// Mobile listeners need native lifecycle events.
bool get needsMcpForegroundService => Platform.isAndroid || Platform.isIOS;

bool get mcpForegroundOnly => Platform.isIOS;
