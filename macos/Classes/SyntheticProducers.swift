import AVFoundation
import CoreMedia
import Darwin

/// Builds the synthetic `CMSampleBuffer`s slice 1 muxes. These stand in for a real
/// camera (`AVCaptureVideoDataOutput`) and real audio (`multichannel_capture.timedFrames`)
/// so the writer core can be proven with zero capture plumbing. Their shape mirrors the
/// real sources exactly, so the camera slice swaps them out without touching the core.
enum SyntheticProducers {

    // MARK: - Host-time conversion (the audio side's raw-mach → CMTime path)

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Convert a duration in seconds to raw `mach_absolute_time()` units. This is how we
    /// synthesize the `hostTime` integers that a real `TimedAudioBatch` carries.
    static func hostUnits(forSeconds seconds: Double) -> UInt64 {
        let nanos = seconds * 1_000_000_000.0
        return UInt64(nanos * Double(timebase.denom) / Double(timebase.numer))
    }

    // MARK: - Video

    /// A solid-fill BGRA frame. `bright == true` is the FLASH frame; false is the base
    /// color. Detection on readback just thresholds one pixel's brightness, so a solid
    /// fill is all we need.
    static func makeVideoSample(width: Int,
                                height: Int,
                                bright: Bool,
                                pts: CMTime,
                                frameDuration: CMTime) -> CMSampleBuffer? {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            let value: Int32 = bright ? 0xF0 : 0x10   // near-white flash vs near-black base
            memset(base, value, bytesPerRow * height)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])

        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pb,
                formatDescriptionOut: &formatDesc) == noErr,
              let fmt = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(duration: frameDuration,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pb,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: fmt,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: - Audio

    /// One batch of interleaved f32 PCM (silence unless an impulse index falls inside
    /// it), stamped at `pts`. Mirrors `TimedAudioBatch { samples, hostTime, ... }`.
    ///
    /// `impulseFrameInBatch`, when non-nil, is the frame offset within this batch whose
    /// samples are set to full-scale — the audio half of a clap/flash event.
    static func makeAudioSample(frameCount: Int,
                                channels: Int,
                                sampleRate: Int,
                                impulseFrameInBatch: Int?,
                                pts: CMTime) -> CMSampleBuffer? {
        var samples = [Float](repeating: 0, count: frameCount * channels)
        if let f = impulseFrameInBatch, f >= 0, f < frameCount {
            for c in 0..<channels { samples[f * channels + c] = 1.0 }
        }
        return audioSampleBuffer(from: samples, channels: channels, sampleRate: sampleRate, pts: pts)
    }

    /// Build an interleaved-f32-PCM `CMSampleBuffer` from real samples — the camera
    /// slice's audio path (`multichannel_capture.timedFrames` → writer). Same plumbing
    /// as the synthetic builder; the only difference is the samples are real.
    static func audioSampleBuffer(from samples: [Float],
                                  channels: Int,
                                  sampleRate: Int,
                                  pts: CMTime) -> CMSampleBuffer? {
        let frameCount = samples.count / channels
        guard frameCount > 0 else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)

        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDesc) == noErr,
              let fmt = formatDesc else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var sampleSize = 4 * channels

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: nil,
                dataReady: false,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: fmt,
                sampleCount: frameCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 1,
                sampleSizeArray: &sampleSize,
                sampleBufferOut: &sampleBuffer) == noErr,
              let sb = sampleBuffer else { return nil }

        let byteCount = samples.count * 4
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: byteCount,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount,
                flags: 0,
                blockBufferOut: &blockBuffer) == noErr,
              let bb = blockBuffer else { return nil }

        guard CMBlockBufferAssureBlockMemory(bb) == noErr else { return nil }
        let ok: OSStatus = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!,
                                          blockBuffer: bb,
                                          offsetIntoDestination: 0,
                                          dataLength: byteCount)
        }
        guard ok == noErr,
              CMSampleBufferSetDataBuffer(sb, newValue: bb) == noErr else { return nil }
        // The buffer was created dataReady:false (no data yet); now that the block buffer
        // is attached, mark it ready — otherwise the writer waits forever for the data
        // and finishWriting never completes.
        guard CMSampleBufferSetDataReady(sb) == noErr else { return nil }
        return sb
    }
}
