import AVFoundation
import CoreMedia
import Cocoa

/// The camera slice's live recorder: a video-only `AVCaptureSession` feeding the proven
/// `AVWriterCore`, with audio pushed in from Dart (`multichannel_capture.timedFrames`,
/// decision #3a). Owns the origin problem for two live free-running sources (spec §5.1)
/// and funnels both tracks through one serial writer queue (spec §6).
final class CameraRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    struct Config {
        var outputPath: String
        var fps: Int = 30
        var channels: Int = 2
        var sampleRate: Int = 48_000
        var preview: Bool = false
    }

    enum RecorderError: Error {
        case cameraPermissionDenied
        case noCameraDevice
        case cannotAddCameraInput
        case cannotAddVideoOutput
    }

    // Fixed small, widely-supported capture size; resolution is irrelevant to the sync
    // proof and 640×480 keeps motion detection cheap.
    private static let width = 640
    private static let height = 480

    private let config: Config
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let delegateQueue = DispatchQueue(label: "stereo_av_writer.capture.video")
    // One serial queue owns ALL writer state — appends and the origin decision — so no
    // track can race another and the origin buffering needs no extra locks (spec §6).
    private let writerQueue = DispatchQueue(label: "stereo_av_writer.writer")

    private var core: AVWriterCore!
    private var previewWindow: NSWindow?

    // Origin state — touched only on writerQueue.
    private var originSet = false
    private var firstVideoPTS: CMTime?
    private var firstAudioPTS: CMTime?
    private var pending: [(isVideo: Bool, buf: CMSampleBuffer)] = []

    init(config: Config) { self.config = config }

    // MARK: - Lifecycle

    func start(completion: @escaping (Error?) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { completion(RecorderError.cameraPermissionDenied); return }
            do { try self.configureAndStart(); completion(nil) }
            catch { completion(error) }
        }
    }

    private func configureAndStart() throws {
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }

        guard let device = AVCaptureDevice.default(for: .video) else { throw RecorderError.noCameraDevice }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecorderError.cannotAddCameraInput }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: delegateQueue)
        guard session.canAddOutput(videoOutput) else { throw RecorderError.cannotAddVideoOutput }
        session.addOutput(videoOutput)
        session.commitConfiguration()

        // Inject the clock the camera stamps PTS against — the whole architecture's
        // meeting point. `synchronizationClock` is macOS 12.3+ and defaults to the host
        // clock; below that (and as fallback) use the host clock directly — same domain.
        let clock: CMClock
        if #available(macOS 12.3, *) {
            clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        } else {
            clock = CMClockGetHostTimeClock()
        }
        core = try AVWriterCore(outputURL: URL(fileURLWithPath: config.outputPath),
                                width: Self.width, height: Self.height, fps: config.fps,
                                sampleRate: config.sampleRate, channels: config.channels,
                                audioCodec: .lpcm, realTime: true, clock: clock)
        try core.beginWriting()

        if config.preview { showPreview() }
        session.startRunning()
    }

    func stop(completion: @escaping (String?, Error?) -> Void) {
        session.stopRunning()
        hidePreview()
        writerQueue.async {
            self.core.finish { err in completion(self.config.outputPath, err) }
        }
    }

    // MARK: - Video in (capture delegate queue → writer queue)

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        writerQueue.async { self.handle(sampleBuffer, isVideo: true) }
    }

    // MARK: - Audio in (Dart-pushed #3a → writer queue)

    /// Called by the plugin with a batch pulled off `timedFrames` in Dart. `hostTime` is
    /// raw mach units (the capture instant), so the PTS is correct regardless of how late
    /// the Dart hop delivered it (spec §5).
    func appendAudioBatch(samples: [Float], hostTime: UInt64) {
        let pts = CMClockMakeHostTimeFromSystemUnits(hostTime)
        guard let sb = SyntheticProducers.audioSampleBuffer(
                from: samples, channels: config.channels,
                sampleRate: config.sampleRate, pts: pts) else { return }
        writerQueue.async { self.handle(sb, isVideo: false) }
    }

    // MARK: - Origin buffering (spec §5.1) — all on writerQueue

    private func handle(_ buf: CMSampleBuffer, isVideo: Bool) {
        if originSet {
            _ = isVideo ? core.appendVideo(buf) : core.appendAudio(buf)
            return
        }
        // Not yet started: remember each track's first PTS, buffer the sample, and set
        // the origin to min(firstVideo, firstAudio) once both tracks have delivered one.
        let pts = CMSampleBufferGetPresentationTimeStamp(buf)
        if isVideo { if firstVideoPTS == nil { firstVideoPTS = pts } }
        else { if firstAudioPTS == nil { firstAudioPTS = pts } }
        pending.append((isVideo, buf))

        guard let v = firstVideoPTS, let a = firstAudioPTS else { return }
        let origin = CMTimeMinimum(v, a)
        core.setOrigin(origin)
        originSet = true
        // Drain in PTS order; all buffered samples are ≥ origin by construction.
        for item in pending.sorted(by: {
            CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0.buf),
                          CMSampleBufferGetPresentationTimeStamp($1.buf)) < 0
        }) {
            _ = item.isVideo ? core.appendVideo(item.buf) : core.appendAudio(item.buf)
        }
        pending.removeAll()
    }

    // MARK: - Throwaway aim preview (spec §9) — debug rig, never a Dart surface

    private func showPreview() {
        DispatchQueue.main.async {
            let layer = AVCaptureVideoPreviewLayer(session: self.session)
            layer.videoGravity = .resizeAspect
            let frame = NSRect(x: 80, y: 80, width: 480, height: 360)
            let win = NSWindow(contentRect: frame,
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
            // ARC owns this reference; NSWindow defaults isReleasedWhenClosed = true, which
            // would release it a second time on close() → double-free crash. Turn it off.
            win.isReleasedWhenClosed = false
            win.title = "stereo_av_writer — aim (debug)"
            let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer = layer          // layer-hosting: set layer before wantsLayer
            view.wantsLayer = true
            win.contentView = view
            win.makeKeyAndOrderFront(nil)
            self.previewWindow = win
        }
    }

    private func hidePreview() {
        DispatchQueue.main.async { self.previewWindow?.close(); self.previewWindow = nil }
    }
}
