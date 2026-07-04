import AVFoundation
import CoreMedia

/// The reusable writer core: two `AVAssetWriterInput`s on one `AVAssetWriter`, both
/// timed against a single **host clock**. This is the part slice 1 exists to prove and
/// that the camera slice will reuse unchanged — the only thing that changes there is
/// where the sample buffers come from (a real `AVCaptureVideoDataOutput` /
/// `multichannel_capture.timedFrames` instead of the synthetic producers).
///
/// The clock is **injectable** (decision-#2 insurance). It defaults to
/// `CMClockGetHostTimeClock()` — the domain that `multichannel_capture`'s raw-mach
/// `hostTime` and an `AVCaptureSession`'s default `synchronizationClock` both live in.
/// The consuming app owns no `AVCaptureSession` of its own (its calling SDK owns the
/// camera), so the self-owned default is what ships; injection is present but not
/// load-bearing.
final class AVWriterCore {
    enum AudioCodec {
        case lpcm   // uncompressed — sample-exact, used for the sync measurement
        case aac    // product codec — adds a characterized priming offset, not gated
    }

    enum WriterError: Error {
        case cannotAddVideoInput
        case cannotAddAudioInput
        case startWritingFailed(String)
        case writerFailed(String)
    }

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput

    /// The shared timeline reference. Both tracks' PTS are interpreted in this domain.
    let clock: CMClock

    init(outputURL: URL,
         width: Int,
         height: Int,
         fps: Int,
         sampleRate: Int,
         channels: Int,
         audioCodec: AudioCodec,
         realTime: Bool,
         clock: CMClock = CMClockGetHostTimeClock()) throws {
        self.clock = clock
        // AVAssetWriter refuses to overwrite; clear any prior file (e.g. a partial from a
        // previous run) so startWriting doesn't fail with "Cannot Save".
        try? FileManager.default.removeItem(at: outputURL)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = realTime

        var audioSettings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        switch audioCodec {
        case .lpcm:
            audioSettings[AVFormatIDKey] = kAudioFormatLinearPCM
            audioSettings[AVLinearPCMBitDepthKey] = 32
            audioSettings[AVLinearPCMIsFloatKey] = true
            audioSettings[AVLinearPCMIsBigEndianKey] = false
            audioSettings[AVLinearPCMIsNonInterleaved] = false
        case .aac:
            audioSettings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            audioSettings[AVEncoderBitRateKey] = 128_000
        }
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = realTime

        guard writer.canAdd(videoInput) else { throw WriterError.cannotAddVideoInput }
        writer.add(videoInput)
        guard writer.canAdd(audioInput) else { throw WriterError.cannotAddAudioInput }
        writer.add(audioInput)
    }

    /// "Now" on the shared timeline, as the camera side would read it — a direct clock
    /// read yielding a `CMTime`. (The audio side instead arrives as raw mach units and
    /// is mapped via `CMClockMakeHostTimeFromSystemUnits`; the two representations
    /// meeting in the same domain is exactly what the measurement checks.)
    func now() -> CMTime { CMClockGetTime(clock) }

    /// Begin writing without committing an origin. Live capture needs this split from
    /// `setOrigin`: the origin can only be known once the first samples arrive (their PTS
    /// are free-running by the time we start), so we begin writing, buffer, then set the
    /// origin from `min(firstVideoPTS, firstAudioPTS)`. See camera-slice spec §5.1.
    func beginWriting() throws {
        guard writer.startWriting() else {
            throw WriterError.startWritingFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    /// Commit the session origin. Every sample appended after this must have PTS ≥ origin.
    func setOrigin(_ origin: CMTime) {
        writer.startSession(atSourceTime: origin)
    }

    /// Convenience for the synthetic path (slice 1), where origin is known up front.
    func start(atSourceTime origin: CMTime) throws {
        try beginWriting()
        setOrigin(origin)
    }

    /// Append a video sample buffer, spin-waiting for the input to drain. Returns false
    /// (and stops) if the writer has entered a failed state.
    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        return append(sampleBuffer, to: videoInput)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        return append(sampleBuffer, to: audioInput)
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput) -> Bool {
        // The inputs use expectsMediaDataInRealTime = true (push source), so this spins
        // at most briefly. The bound is a safety net so a stalled writer fails loudly
        // instead of hanging the platform channel forever.
        var spins = 0
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { return false }
            if spins > 20_000 { return false }   // ~10s at 500µs
            usleep(500)
            spins += 1
        }
        if writer.status == .failed { return false }
        return input.append(sampleBuffer)
    }

    /// Mark both inputs finished and flush. `completion` receives an error if the
    /// writer failed (a partial file may still exist — the finalize-partial policy).
    /// Debug tracing to stderr (CLI harness sets this; plugin leaves it off).
    static var debug = false
    private func dlog(_ s: @autoclosure () -> String) {
        if AVWriterCore.debug { FileHandle.standardError.write(("[core] " + s() + "\n").data(using: .utf8)!) }
    }

    func finish(completion: @escaping (Error?) -> Void) {
        dlog("finish: status before=\(writer.status.rawValue) vReady=\(videoInput.isReadyForMoreMediaData) aReady=\(audioInput.isReadyForMoreMediaData)")
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        dlog("finish: marked finished, calling finishWriting")
        // Strong self on purpose: finishWriting finalizes asynchronously, so the handler
        // must keep the writer (and this core) alive until it fires. A weak capture lets
        // the writer deallocate mid-finalize and the completion never runs.
        writer.finishWriting {
            self.dlog("finishWriting completion fired: status=\(self.writer.status.rawValue)")
            if self.writer.status == .failed {
                completion(WriterError.writerFailed(self.writer.error?.localizedDescription ?? "unknown"))
            } else {
                completion(nil)
            }
        }
    }
}
