import AVFoundation
import CoreMedia

/// Reads the muxed `.mov` back with `AVAssetReader` and recovers, from the **file**
/// (not from the in-memory PTS we fed in — the container quantizes, and we want to
/// measure what was actually written), the presentation time of every FLASH frame and
/// every audio IMPULSE. Pairing those by event index gives the A/V offsets the slice
/// asserts on.
enum SliceMeasurement {

    struct Result {
        var flashTimes: [Double]        // seconds, file timeline
        var impulseTimes: [Double]      // seconds, file timeline
        var videoTimescale: Int32
        var audioTimescale: Int32
        var videoFrameCount: Int
        var audioFrameCount: Int
    }

    enum MeasureError: Error {
        case noVideoTrack
        case noAudioTrack
        case readerFailed(String)
    }

    /// Brightness threshold on the base color's near-black (0x10) vs the flash's
    /// near-white (0xF0) — anything past the midpoint is a flash.
    private static let flashLumaThreshold: UInt8 = 0x80
    /// A written impulse is full-scale (1.0); silence is 0. Half-scale cleanly separates
    /// them even after any container/codec rounding.
    private static let impulseAmplitudeThreshold: Float = 0.5

    static func measure(url: URL,
                        channels: Int,
                        sampleRate: Int) throws -> Result {
        let asset = AVURLAsset(url: url)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw MeasureError.noVideoTrack
        }
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            throw MeasureError.noAudioTrack
        }

        let (flashTimes, videoCount) = try readFlashes(asset: asset, track: videoTrack)
        let (impulseTimes, audioCount) = try readImpulses(asset: asset,
                                                          track: audioTrack,
                                                          channels: channels,
                                                          sampleRate: sampleRate)

        return Result(flashTimes: flashTimes,
                      impulseTimes: impulseTimes,
                      videoTimescale: videoTrack.naturalTimeScale,
                      audioTimescale: audioTrack.naturalTimeScale,
                      videoFrameCount: videoCount,
                      audioFrameCount: audioCount)
    }

    // MARK: - Video

    private static func readFlashes(asset: AVAsset,
                                    track: AVAssetTrack) throws -> ([Double], Int) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw MeasureError.readerFailed(reader.error?.localizedDescription ?? "video reader")
        }

        var flashTimes: [Double] = []
        var frameCount = 0
        var wasBright = false   // rising-edge only: one time per flash event

        while let sample = output.copyNextSampleBuffer() {
            frameCount += 1
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let bright = frameIsBright(sample)
            if bright && !wasBright {
                flashTimes.append(CMTimeGetSeconds(pts))
            }
            wasBright = bright
        }
        if reader.status == .failed {
            throw MeasureError.readerFailed(reader.error?.localizedDescription ?? "video read")
        }
        return (flashTimes, frameCount)
    }

    private static func frameIsBright(_ sample: CMSampleBuffer) -> Bool {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return false }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return false }
        // Sample the center pixel's blue byte (BGRA); solid fill makes any pixel equal.
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let offset = (h / 2) * bytesPerRow + (w / 2) * 4
        let byte = base.load(fromByteOffset: offset, as: UInt8.self)
        return byte >= flashLumaThreshold
    }

    // MARK: - Audio

    private static func readImpulses(asset: AVAsset,
                                     track: AVAssetTrack,
                                     channels: Int,
                                     sampleRate: Int) throws -> ([Double], Int) {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw MeasureError.readerFailed(reader.error?.localizedDescription ?? "audio reader")
        }

        var impulseTimes: [Double] = []
        var frameCount = 0
        var wasHot = false   // rising-edge cluster: one time per impulse event

        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let bufferStart = CMTimeGetSeconds(pts)
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }

            var lengthAtOffset = 0
            var totalLength = 0
            var dataPtr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                                              lengthAtOffsetOut: &lengthAtOffset,
                                              totalLengthOut: &totalLength,
                                              dataPointerOut: &dataPtr) == noErr,
                  let raw = dataPtr else { continue }

            let floatCount = totalLength / 4
            let frames = floatCount / channels
            raw.withMemoryRebound(to: Float.self, capacity: floatCount) { fptr in
                for frame in 0..<frames {
                    var hot = false
                    for c in 0..<channels {
                        if abs(fptr[frame * channels + c]) >= impulseAmplitudeThreshold {
                            hot = true
                            break
                        }
                    }
                    if hot && !wasHot {
                        let t = bufferStart + Double(frame) / Double(sampleRate)
                        impulseTimes.append(t)
                    }
                    wasHot = hot
                }
            }
            frameCount += frames
        }
        if reader.status == .failed {
            throw MeasureError.readerFailed(reader.error?.localizedDescription ?? "audio read")
        }
        return (impulseTimes, frameCount)
    }
}
