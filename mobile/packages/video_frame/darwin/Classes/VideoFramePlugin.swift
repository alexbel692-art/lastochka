// Первый кадр видео в JPEG (без сведений из исходного файла) — для превью в ленте и при отправке.
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
import AppKit
#endif
import AVFoundation

public class VideoFramePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "lastochka/video_frame", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(VideoFramePlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "frame", let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
      result(FlutterMethodNotImplemented)
      return
    }
    let maxSide = (args["max"] as? Int) ?? 480
    DispatchQueue.global(qos: .userInitiated).async {
      let r = VideoFramePlugin.grab(path: path, maxSide: maxSide)
      DispatchQueue.main.async { result(r) }
    }
  }

  static func grab(path: String, maxSide: Int) -> [String: Any]? {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true // кадр сразу в правильной ориентации
    gen.maximumSize = CGSize(width: maxSide, height: maxSide)
    guard let cg = try? gen.copyCGImage(at: CMTime.zero, actualTime: nil) else { return nil }
    var vw = 0, vh = 0
    if let track = asset.tracks(withMediaType: .video).first {
      let s = track.naturalSize.applying(track.preferredTransform)
      vw = Int(abs(s.width))
      vh = Int(abs(s.height))
    }
    let d = asset.duration
    let ms = d.isNumeric ? Int(CMTimeGetSeconds(d) * 1000) : 0
    #if os(iOS)
    guard let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.82) else { return nil }
    #else
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
    #endif
    return ["jpeg": FlutterStandardTypedData(bytes: data), "w": cg.width, "h": cg.height, "vw": vw, "vh": vh, "duration": ms]
  }
}
