import Cocoa
import FlutterMacOS

public class StereoAvWriterPlugin: NSObject, FlutterPlugin {
  private let workQueue = DispatchQueue(label: "stereo_av_writer.slice", qos: .userInitiated)
  private var recorder: CameraRecorder?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "stereo_av_writer", binaryMessenger: registrar.messenger)
    let instance = StereoAvWriterPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)

    case "runSliceOne":
      let args = (call.arguments as? [String: Any]) ?? [:]
      let config = SliceRunner.Config.from(args)
      workQueue.async {
        SliceRunner.run(config) { outcome in
          DispatchQueue.main.async {
            switch outcome {
            case .success(let map):
              result(map)
            case .failure(let error):
              result(FlutterError(code: "slice_one_failed",
                                  message: error.localizedDescription,
                                  details: "\(error)"))
            }
          }
        }
      }

    case "startCameraRecording":
      let args = (call.arguments as? [String: Any]) ?? [:]
      var cfg = CameraRecorder.Config(outputPath: (args["outputPath"] as? String)
                                        ?? NSTemporaryDirectory() + "camera_slice.mov")
      if let v = args["fps"] as? Int { cfg.fps = v }
      if let v = args["channels"] as? Int { cfg.channels = v }
      if let v = args["sampleRate"] as? Int { cfg.sampleRate = v }
      if let v = args["preview"] as? Bool { cfg.preview = v }
      let rec = CameraRecorder(config: cfg)
      recorder = rec
      rec.start { error in
        DispatchQueue.main.async {
          if let e = error {
            result(FlutterError(code: "camera_start_failed", message: e.localizedDescription, details: "\(e)"))
          } else {
            result(nil)
          }
        }
      }

    case "pushAudioBatch":
      guard let args = call.arguments as? [String: Any],
            let typed = args["samples"] as? FlutterStandardTypedData,
            let hostTimeNum = args["hostTime"] as? NSNumber else {
        result(FlutterError(code: "bad_args", message: "pushAudioBatch needs samples + hostTime", details: nil))
        return
      }
      let floats: [Float] = typed.data.withUnsafeBytes { raw in
        Array(raw.bindMemory(to: Float.self))
      }
      recorder?.appendAudioBatch(samples: floats, hostTime: hostTimeNum.uint64Value)
      result(nil)

    case "stopCameraRecording":
      guard let rec = recorder else { result(nil); return }
      rec.stop { path, error in
        DispatchQueue.main.async {
          self.recorder = nil
          if let e = error {
            result(FlutterError(code: "camera_stop_failed", message: e.localizedDescription, details: path))
          } else {
            result(path)
          }
        }
      }

    case "analyzeClaps":
      let args = (call.arguments as? [String: Any]) ?? [:]
      let path = (args["outputPath"] as? String) ?? ""
      let channels = (args["channels"] as? Int) ?? 2
      let sampleRate = (args["sampleRate"] as? Int) ?? 48_000
      workQueue.async {
        do {
          let r = try ClapDetection.detect(url: URL(fileURLWithPath: path),
                                           channels: channels, sampleRate: sampleRate)
          DispatchQueue.main.async {
            result(["audioOnsetsMillis": r.audioOnsetsMillis,
                    "videoMotionPeaksMillis": r.videoMotionPeaksMillis])
          }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "analyze_failed", message: error.localizedDescription, details: "\(error)"))
          }
        }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
