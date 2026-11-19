import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func sceneWillEnterForeground(_ scene: UIScene) {
    super.sceneWillEnterForeground(scene)
    (UIApplication.shared.delegate as? AppDelegate)?.handleSceneWillEnterForeground(scene)
  }

  override func sceneDidEnterBackground(_ scene: UIScene) {
    super.sceneDidEnterBackground(scene)
    (UIApplication.shared.delegate as? AppDelegate)?.handleSceneDidEnterBackground(scene)
  }
}
