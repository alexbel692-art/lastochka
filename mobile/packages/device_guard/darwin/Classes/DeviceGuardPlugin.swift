// Системные защиты iPhone (часть — и Mac) для Ласточки:
// • excludeFromBackup — база переписки и настройки не попадают в резервные копии iCloud/компьютера;
// • copySecret — секрет в буфер обмена только на этом устройстве (без «Универсального буфера»
//   на Mac и iPad) и с автоматическим удалением через заданное время;
// • isCaptured / событие captured — идёт запись экрана, трансляция AirPlay или повтор экрана;
// • bioState — «отпечаток» набора лиц/пальцев Face ID / Touch ID: меняется, если кто-то добавил своё лицо;
// • switcherCover — заставка поверх окна системными средствами в момент сворачивания: снимок для
//   переключателя приложений iPhone делает сразу, и заставка Flutter могла не успеть нарисоваться.
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
import AppKit
#endif
import LocalAuthentication

public class DeviceGuardPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel?
  private var observer: NSObjectProtocol?
  #if os(iOS)
  private var coverEnabled = false
  private var cover: UIView?
  private var lifecycle: [NSObjectProtocol] = []
  #endif

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "lastochka/device_guard", binaryMessenger: messenger)
    let instance = DeviceGuardPlugin()
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)
    #if os(iOS)
    instance.observer = NotificationCenter.default.addObserver(
      forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
    ) { [weak instance] _ in
      instance?.channel?.invokeMethod("captured", arguments: UIScreen.main.isCaptured)
    }
    instance.installLifecycle()
    #endif
  }

  deinit {
    if let o = observer { NotificationCenter.default.removeObserver(o) }
    #if os(iOS)
    for o in lifecycle { NotificationCenter.default.removeObserver(o) }
    #endif
  }

  #if os(iOS)
  private func installLifecycle() {
    let nc = NotificationCenter.default
    lifecycle.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.showCover()
    })
    lifecycle.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      self?.showCover()
    })
    lifecycle.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.hideCover()
    })
  }

  private func keyWindow() -> UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    return windows.first { $0.isKeyWindow } ?? windows.first
  }

  private func showCover() {
    guard coverEnabled, cover == nil, let w = keyWindow() else { return }
    // сплошной цвет, а не размытие: сквозь размытие угадываются строки переписки
    let v = UIView(frame: w.bounds)
    v.backgroundColor = UIColor.systemBackground
    v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    w.addSubview(v)
    cover = v
  }

  private func hideCover() {
    cover?.removeFromSuperview()
    cover = nil
  }
  #endif

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "bioState":
      let ctx = LAContext()
      var err: NSError?
      guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err),
            let state = ctx.evaluatedPolicyDomainState else {
        result(nil)
        return
      }
      result(state.base64EncodedString())

    case "excludeFromBackup":
      let paths = (call.arguments as? [String]) ?? []
      var done = 0
      for path in paths where FileManager.default.fileExists(atPath: path) {
        var url = URL(fileURLWithPath: path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        // проверяем, что отметка действительно стоит
        if (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true {
          done += 1
        }
      }
      result(done)

    #if os(iOS)
    case "copySecret":
      guard let args = call.arguments as? [String: Any], let text = args["text"] as? String else {
        result(false)
        return
      }
      let seconds = max(5.0, min(600.0, (args["seconds"] as? Double) ?? 60.0))
      UIPasteboard.general.setItems(
        [["public.utf8-plain-text": text]],
        options: [.localOnly: true, .expirationDate: Date(timeIntervalSinceNow: seconds)]
      )
      result(true)

    case "isCaptured":
      result(UIScreen.main.isCaptured)

    case "switcherCover":
      coverEnabled = (call.arguments as? Bool) ?? false
      if !coverEnabled { hideCover() }
      result(true)
    #endif

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
