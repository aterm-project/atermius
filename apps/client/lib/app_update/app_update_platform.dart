import 'app_update_controller.dart';
import 'app_update_platform_stub.dart'
    if (dart.library.io) 'app_update_platform_io.dart'
    as platform;

/// First thing in `main`: on desktop this may finish a pending update and
/// never return. Returns the arguments the rest of the app should see.
Future<List<String>> appUpdateStartup(List<String> arguments) =>
    platform.appUpdateStartup(arguments);

/// Counts this process as a running main window for the updater.
void appUpdateHoldInstance() => platform.appUpdateHoldInstance();

/// The updater for this build, or null where the app is updated another
/// way (web, stores) or was not built as a release.
AppUpdateController? createAppUpdateController({
  required ({String title, String body}) Function() doneNotice,
}) => platform.createAppUpdateController(doneNotice: doneNotice);
