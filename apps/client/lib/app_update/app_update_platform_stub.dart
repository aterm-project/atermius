import 'app_update_controller.dart';

/// Web: the page is updated by the server that hosts it.
Future<List<String>> appUpdateStartup(List<String> arguments) async =>
    arguments;

void appUpdateHoldInstance() {}

AppUpdateController? createAppUpdateController({
  required ({String title, String body}) Function() doneNotice,
}) => null;
