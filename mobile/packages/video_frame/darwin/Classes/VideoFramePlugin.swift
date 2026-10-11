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

  private var export: AVAssetExportSession?

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "compressProgress" {
      result(export.map { Int($0.progress * 100) } ?? -1)
      return
    }
    if call.method == "compress" {
      compress(call.arguments as? [String: Any] ?? [:], result: result)
      return
    }
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

  /// Сжатие видео перед отправкой: до 720p (кружки — до 480p), MP4, без места съёмки и прочих сведений.
  private func compress(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let src = args["src"] as? String, let dst = args["dst"] as? String else {
      result(false)
      return
    }
    let short = (args["short"] as? Int) ?? 720
    let asset = AVURLAsset(url: URL(fileURLWithPath: src))
    let preset = short <= 480 ? AVAssetExportPreset640x480 : AVAssetExportPreset1280x720
    guard let ex = AVAssetExportSession(asset: asset, presetName: preset) else {
      result(false)
      return
    }
    try? FileManager.default.removeItem(atPath: dst)
    ex.outputURL = URL(fileURLWithPath: dst)
    ex.outputFileType = .mp4
    ex.shouldOptimizeForNetworkUse = true
    ex.metadataItemFilter = AVMetadataItemFilter.forSharing()
    export = ex
    ex.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        self?.export = nil
        result(ex.status == .completed)
      }
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
