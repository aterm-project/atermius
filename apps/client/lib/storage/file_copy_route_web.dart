import 'package:web/web.dart' as web;

const _key = 'atermius.file-copy-route.v1';
Future<String?> readFileCopyRoute() async =>
    web.window.localStorage.getItem(_key);
Future<void> writeFileCopyRoute(String route) async =>
    web.window.localStorage.setItem(_key, route);
