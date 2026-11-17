// Ласточка для App Store. Копируется поверх ios/Runner/AppDelegate.swift скриптом tool/appstore_prepare.py.
// Добавляет к шаблону Flutter ключ устройства Apple (APNs) для уведомлений, когда Ласточка закрыта:
// Dart спрашивает его через канал lastochka/system (метод pushToken) и регистрирует на сервере Matrix.
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushToken: String?
  private var waiting: [FlutterResult] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // уведомления (свои и flutter_local_notifications) идут через Flutter — так требует и сам плагин
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LastochkaPush") else { return }
    let channel = FlutterMethodChannel(name: "lastochka/system", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, call.method == "pushToken" else {
        result(FlutterMethodNotImplemented)
        return
      }
      if let t = self.pushToken {
        result(t)
        return
      }
      self.waiting.append(result)
      if self.waiting.count == 1 {
        UIApplication.shared.registerForRemoteNotifications()
        // нет сети или нет разрешения у сборки — не ждём вечно
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.finish(nil) }
      }
    }
  }

  private func finish(_ token: String?) {
    if let token = token { pushToken = token }
    let w = waiting
    waiting = []
    w.forEach { $0(pushToken) }
  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    finish(deviceToken.map { String(format: "%02x", $0) }.joined())
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    NSLog("[Ласточка] APNs: %@", error.localizedDescription)
    finish(nil)
  }

  // Ласточка открыта — уведомление Apple «Новое сообщение» не показываем: о сообщении она сообщит
  // сама, с именем отправителя и (если разрешено) текстом
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if notification.request.trigger is UNPushNotificationTrigger {
      completionHandler([])
    } else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }
  }
}
