import AVFoundation
import CoreMedia

/// Detects clap events in a muxed file, from the file itself (same discipline as
/// `SliceMeasurement`). The audio side is razor-sharp (a clap is a hard transient,
/// localizable to ~1 ms); the video side is frame-quantized (peak inter-frame motion,
/// ±1 frame). Pairing the two per event gives the A/V coherence offset.
///
/// Thresholds are **relative to each track's own peak**, so the same detector works on a
/// synthetic full-scale impulse/flash (ground-truth self-test) and on a real, un-
/// normalized clap in a room.
enum ClapDetection {

    struct Result {
        var audioOnsetsMillis: [Double]
        var videoMotionPeaksMillis: [Double]
    }

    enum DetectError: Error {
        case noVideoTrack
        case noAudioTrack
        case readerFailed(String)
    }

    /// Events closer than this are treated as one (collapses the two motion spikes that
    /// bracket a flash, and rejects ringing after a clap). Claps in these tests are
    /// seconds/minutes apart, so this is safe.
    private static let refractorySeconds = 0.15

    /// Window (seconds) around each audio clap in which to find the matching video
    /// event. Wide enough for any real latency, tight enough to reject warmup and the
    /// follow-through motion that peaks ~1s after a hand clap's contact.
    private static let anchorWindowSeconds = 0.30

    static func detect(url: URL, channels: Int, sampleRate: Int) throws -> Result {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw DetectError.noVideoTrack
        }
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw DetectError.noAudioTrack
        }
        // Audio is the reliable, sharp side — detect the claps there, then ANCHOR the
        // video search to each clap's time. This guarantees N-for-N correspondence and
        // sidesteps the two things that break independent video peak-picking on a real
        // hand clap: the camera-startup brightness spike, and follow-through motion that
        // peaks ~1s after contact. The video event is the biggest brightness change
        // (hands darkening the frame at contact) within the window around each clap.
        let audio = try audioOnsets(asset: asset, track: audioTrack,
                                    channels: channels, sampleRate: sampleRate)
        let bright = try videoBrightnessChangeSeries(asset: asset, track: videoTrack)

        var videoEvents: [Double] = []
        for onset in audio {
            let win = bright.filter { abs($0.t - onset) <= anchorWindowSeconds }
            if let peak = win.max(by: { $0.v < $1.v }) { videoEvents.append(peak.t) }
        }
        return Result(audioOnsetsMillis: audio.map { $0 * 1000.0 },
                      videoMotionPeaksMillis: videoEvents.map { $0 * 1000.0 })
    }

    /// Per-frame mean brightness LEVEL (not change) — for diagnostics.
    static func videoBrightnessLevelSeries(asset: AVAsset, track: AVAssetTrack) throws -> [(t: Double, v: Float)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw DetectError.readerFailed(reader.error?.localizedDescription ?? "video reader")
        }
        var series: [(t: Double, v: Float)] = []
        while let sample = output.copyNextSampleBuffer() {
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let grid = sampleGrid(pb)
            let mean = grid.isEmpty ? 0 : Float(grid.reduce(0) { $0 + Int($1) }) / Float(grid.count)
            series.append((t, mean))
        }
        return series
    }

    /// Per-frame absolute change in mean brightness — the metric for a "clap over the
    /// lens" (hands briefly darken the frame at contact). Robust to the follow-through
    /// motion that fools the motion metric.
    static func videoBrightnessChangeSeries(asset: AVAsset, track: AVAssetTrack) throws -> [(t: Double, v: Float)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw DetectError.readerFailed(reader.error?.localizedDescription ?? "video reader")
        }
        var series: [(t: Double, v: Float)] = []
        var prevMean: Float?
        while let sample = output.copyNextSampleBuffer() {
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let grid = sampleGrid(pb)
            let mean = grid.isEmpty ? 0 : Float(grid.reduce(0) { $0 + Int($1) }) / Float(grid.count)
            series.append((t, prevMean == nil ? 0 : abs(mean - prevMean!)))
            prevMean = mean
        }
        if reader.status == .failed {
            throw DetectError.readerFailed(reader.error?.localizedDescription ?? "video read")
        }
        return series
    }

    // MARK: - Audio onsets

    private static func audioOnsets(asset: AVAsset, track: AVAssetTrack,
                                    channels: Int, sampleRate: Int) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw DetectError.readerFailed(reader.error?.localizedDescription ?? "audio reader")
        }

        // First pass: per-frame peak amplitude + its absolute time.
        var amps: [(t: Double, a: Float)] = []
        while let sample = output.copyNextSampleBuffer() {
            let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var len = 0, total = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &len,
                    totalLengthOut: &total, dataPointerOut: &ptr) == noErr, let raw = ptr else { continue }
            let floatCount = total / 4
            let frames = floatCount / channels
            raw.withMemoryRebound(to: Float.self, capacity: floatCount) { f in
                for frame in 0..<frames {
                    var peak: Float = 0
                    for c in 0..<channels { peak = max(peak, abs(f[frame * channels + c])) }
                    amps.append((start + Double(frame) / Double(sampleRate), peak))
                }
            }
        }
        if reader.status == .failed {
            throw DetectError.readerFailed(reader.error?.localizedDescription ?? "audio read")
        }
        return peaksAboveRelativeThreshold(amps.map { ($0.t, $0.a) }, fraction: 0.4)
    }

    // MARK: - Video motion

    private static func videoMotionPeaks(asset: AVAsset, track: AVAssetTrack) throws -> [Double] {
        return peaksAboveRelativeThreshold(try videoMotionSeries(asset: asset, track: track),
                                           fraction: 0.4)
    }

    /// Full per-frame motion series (time seconds, motion), for detection + diagnostics.
    static func videoMotionSeries(asset: AVAsset, track: AVAssetTrack) throws -> [(t: Double, v: Float)] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw DetectError.readerFailed(reader.error?.localizedDescription ?? "video reader")
        }

        // Per-frame motion = mean abs difference vs previous frame, over a sparse pixel
        // grid (every 16th pixel) for speed. Motion is attributed to the *current* frame.
        var motion: [(t: Double, m: Float)] = []
        var prev: [UInt8]? = nil
        while let sample = output.copyNextSampleBuffer() {
            let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let grid = sampleGrid(pb)
            if let p = prev, p.count == grid.count {
                var acc = 0
                for i in 0..<grid.count { acc += abs(Int(grid[i]) - Int(p[i])) }
                motion.append((t, Float(acc) / Float(grid.count)))
            } else {
                motion.append((t, 0))
            }
            prev = grid
        }
        if reader.status == .failed {
            throw DetectError.readerFailed(reader.error?.localizedDescription ?? "video read")
        }
        return motion.map { (t: $0.t, v: $0.m) }
    }

    /// Diagnostics: audio onsets + the full video motion series (for tuning the video
    /// detector against real footage).
    static func diagnose(url: URL, channels: Int, sampleRate: Int)
        throws -> (audio: [Double], video: [(t: Double, v: Float)]) {
        let asset = AVURLAsset(url: url)
        guard let vt = asset.tracks(withMediaType: .video).first else { throw DetectError.noVideoTrack }
        guard let at = asset.tracks(withMediaType: .audio).first else { throw DetectError.noAudioTrack }
        let a = try audioOnsets(asset: asset, track: at, channels: channels, sampleRate: sampleRate)
        let v = try videoMotionSeries(asset: asset, track: vt)
        return (a.map { $0 * 1000.0 }, v)
    }

    private static func sampleGrid(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let step = 16
        var out: [UInt8] = []
        out.reserveCapacity((w / step) * (h / step))
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                // green byte of BGRA at (x,y) as a cheap luma proxy
                out.append(base.load(fromByteOffset: y * bpr + x * 4 + 1, as: UInt8.self))
                x += step
            }
            y += step
        }
        return out
    }

    // MARK: - Peak picking

    /// Cluster samples above `fraction * globalPeak` into events (refractory gap), and
    /// report the time of the max-valued sample in each cluster.
    private static func peaksAboveRelativeThreshold(_ series: [(t: Double, v: Float)],
                                                    fraction: Float) -> [Double] {
        guard let globalPeak = series.map({ $0.v }).max(), globalPeak > 0 else { return [] }
        let threshold = fraction * globalPeak

        var events: [Double] = []
        var bestT: Double? = nil
        var bestV: Float = 0
        var lastAboveT: Double? = nil

        func flush() {
            if let t = bestT { events.append(t) }
            bestT = nil; bestV = 0
        }
        for (t, v) in series {
            if v >= threshold {
                if let last = lastAboveT, t - last > refractorySeconds { flush() }
                if v > bestV { bestV = v; bestT = t }
                lastAboveT = t
            }
        }
        flush()
        return events
    }
}
