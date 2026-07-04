import AVFoundation
import CoreMedia
import Darwin

/// Orchestrates the slice-1 run: synthesize a two-track `.mov` on one shared host
/// timeline with three marked clap/flash events, then read it back and compute the
/// offsets the slice asserts on.
///
/// Three events (all flash+impulse pairs), placed along the timeline:
///   • event 0  — coincident, early  → offset must be ~0 (sub-frame)
///   • event 1  — known Δ apart       → measured Δ must reproduce the input Δ
///   • event 2  — coincident, late    → its offset must equal event 0's (drift == 0)
///
/// Independence discipline (why this can actually fail, not just pass): the two tracks
/// share only the **session origin** (legitimate — one `startSession`). Every event's
/// per-side time is derived independently — video through `CMTime` arithmetic
/// (`origin + frame/fps`, the camera representation), audio through raw mach units
/// (`originHostUnits + hostUnits(sample/sampleRate)`, the `timedFrames.hostTime`
/// representation). A timebase/scale bug on either side shows up as a nonzero Δ error or
/// drift. The `negativeControl` flag deliberately reintroduces the shared-anchor bug on
/// event 1 (stamp the impulse at the flash's time, ignoring Δ) so the Δ leg is shown to
/// have teeth.
enum SliceRunner {

    /// Set true (e.g. from the CLI debug harness) to trace progress to stderr. The
    /// plugin leaves it false.
    static var debug = false
    private static func log(_ s: @autoclosure () -> String) {
        if debug { FileHandle.standardError.write(("[slice] " + s() + "\n").data(using: .utf8)!) }
    }

    struct Config {
        var outputPath: String
        var fps: Int = 30
        var durationSeconds: Double = 6.0
        var sampleRate: Int = 48_000
        var channels: Int = 2
        var width: Int = 320
        var height: Int = 240
        var knownDeltaMillis: Double = 500.0
        var audioCodec: AVWriterCore.AudioCodec = .lpcm
        var negativeControl: Bool = false

        static func from(_ args: [String: Any]) -> Config {
            var c = Config(outputPath: (args["outputPath"] as? String) ?? NSTemporaryDirectory() + "slice1.mov")
            if let v = args["fps"] as? Int { c.fps = v }
            if let v = args["durationSeconds"] as? Double { c.durationSeconds = v }
            if let v = args["sampleRate"] as? Int { c.sampleRate = v }
            if let v = args["channels"] as? Int { c.channels = v }
            if let v = args["width"] as? Int { c.width = v }
            if let v = args["height"] as? Int { c.height = v }
            if let v = args["knownDeltaMillis"] as? Double { c.knownDeltaMillis = v }
            if let v = args["audioCodec"] as? String, v.lowercased() == "aac" { c.audioCodec = .aac }
            if let v = args["negativeControl"] as? Bool { c.negativeControl = v }
            return c
        }
    }

    enum RunError: Error {
        case sampleCreationFailed
        case appendFailed(String)
        case wrongEventCount(flashes: Int, impulses: Int)
    }

    static func run(_ config: Config, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            let url = URL(fileURLWithPath: config.outputPath)
            try? FileManager.default.removeItem(at: url)

            let core = try AVWriterCore(outputURL: url,
                                        width: config.width, height: config.height, fps: config.fps,
                                        sampleRate: config.sampleRate, channels: config.channels,
                                        audioCodec: config.audioCodec,
                                        realTime: true)

            // One shared origin, captured once, in both representations (same domain,
            // same epoch). This is the *only* value both tracks share.
            let originHostUnits = mach_absolute_time()
            let originCMTime = CMClockMakeHostTimeFromSystemUnits(originHostUnits)
            try core.start(atSourceTime: originCMTime)
            log("started; origin=\(CMTimeGetSeconds(originCMTime))")

            // ----- schedule -----
            let fps = config.fps
            let sr = config.sampleRate
            let totalFrames = Int((config.durationSeconds * Double(fps)).rounded())
            let totalAudioFrames = Int((config.durationSeconds * Double(sr)).rounded())
            let deltaSec = config.knownDeltaMillis / 1000.0

            // Flash frames on exact frame boundaries at 15% / 50% / 85% of the timeline.
            let flashFrames = [
                Int((0.15 * Double(totalFrames)).rounded()),
                Int((0.50 * Double(totalFrames)).rounded()),
                Int((0.85 * Double(totalFrames)).rounded()),
            ]
            let flashSeconds = flashFrames.map { Double($0) / Double(fps) }

            // Impulse sample indices. Events 0 and 2 coincide with their flash; event 1
            // sits Δ later — except under negativeControl, where it reuses the flash's
            // time (the bug the Δ leg must catch).
            let impulseSeconds = [
                flashSeconds[0],
                config.negativeControl ? flashSeconds[1] : flashSeconds[1] + deltaSec,
                flashSeconds[2],
            ]
            let impulseSamples = impulseSeconds.map { Int(($0 * Double(sr)).rounded()) }

            // ----- drive both tracks in timeline order -----
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            let framesPerBatch = 1024
            var i = 0            // next video frame index
            var n = 0            // next audio frame index (batch start)

            while i < totalFrames || n < totalAudioFrames {
                let vSec = Double(i) / Double(fps)
                let aSec = Double(n) / Double(sr)
                let doVideo = (n >= totalAudioFrames) || (i < totalFrames && vSec <= aSec)

                if doVideo {
                    let pts = CMTimeAdd(originCMTime, CMTime(value: Int64(i), timescale: CMTimeScale(fps)))
                    guard let sb = SyntheticProducers.makeVideoSample(
                            width: config.width, height: config.height,
                            bright: flashFrames.contains(i),
                            pts: pts, frameDuration: frameDuration) else {
                        throw RunError.sampleCreationFailed
                    }
                    guard core.appendVideo(sb) else { throw RunError.appendFailed("video") }
                    i += 1
                    if i % 60 == 0 { log("video \(i)/\(totalFrames)") }
                } else {
                    let batch = min(framesPerBatch, totalAudioFrames - n)
                    var impulseFrameInBatch: Int? = nil
                    for idx in impulseSamples where idx >= n && idx < n + batch {
                        impulseFrameInBatch = idx - n
                    }
                    let hostUnits = originHostUnits + SyntheticProducers.hostUnits(forSeconds: Double(n) / Double(sr))
                    let pts = CMClockMakeHostTimeFromSystemUnits(hostUnits)
                    guard let sb = SyntheticProducers.makeAudioSample(
                            frameCount: batch, channels: config.channels, sampleRate: sr,
                            impulseFrameInBatch: impulseFrameInBatch, pts: pts) else {
                        throw RunError.sampleCreationFailed
                    }
                    guard core.appendAudio(sb) else { throw RunError.appendFailed("audio") }
                    n += batch
                }
            }
            log("drive loop done: video=\(i) audioFrames=\(n); finishing")

            // ----- finish, then measure the written file -----
            core.finish { finishError in
                if let e = finishError { self.log("finish error: \(e)"); completion(.failure(e)); return }
                self.log("finished writing; measuring")
                do {
                    let m = try SliceMeasurement.measure(url: url,
                                                         channels: config.channels,
                                                         sampleRate: sr)
                    let result = try buildResult(config: config, measurement: m)
                    completion(.success(result))
                } catch {
                    completion(.failure(error))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    private static func buildResult(config: Config,
                                    measurement m: SliceMeasurement.Result) throws -> [String: Any] {
        let flashes = m.flashTimes.sorted()
        let impulses = m.impulseTimes.sorted()
        guard flashes.count == 3, impulses.count == 3 else {
            // Surface the counts so the caller can see what actually landed.
            return [
                "ok": false,
                "reason": "expected 3 flashes and 3 impulses, got \(flashes.count)/\(impulses.count)",
                "flashTimesMillis": flashes.map { $0 * 1000.0 },
                "impulseTimesMillis": impulses.map { $0 * 1000.0 },
                "videoFrameCount": m.videoFrameCount,
                "audioFrameCount": m.audioFrameCount,
            ]
        }

        let ms = 1000.0
        let coincidentEarlyMillis = (flashes[0] - impulses[0]) * ms
        let coincidentLateMillis = (flashes[2] - impulses[2]) * ms
        let knownDeltaMeasuredMillis = (impulses[1] - flashes[1]) * ms
        let driftMillis = coincidentLateMillis - coincidentEarlyMillis
        let videoQuantMillis = m.videoTimescale > 0 ? ms / Double(m.videoTimescale) : 0

        return [
            "ok": true,
            "outputPath": config.outputPath,
            "audioCodec": config.audioCodec == .aac ? "aac" : "lpcm",
            "negativeControl": config.negativeControl,

            "coincidentEarlyMillis": coincidentEarlyMillis,
            "coincidentLateMillis": coincidentLateMillis,
            "knownDeltaMeasuredMillis": knownDeltaMeasuredMillis,
            "knownDeltaExpectedMillis": config.negativeControl ? 0.0 : config.knownDeltaMillis,
            "driftMillis": driftMillis,

            // The measurement's resolution floor: the video track quantizes PTS to
            // 1/timescale, and a coincident event can sit up to half a frame off. Report
            // both so a nonzero coincident offset can be read against the floor.
            "videoQuantMillis": videoQuantMillis,
            "halfFrameMillis": ms / Double(config.fps) / 2.0,
            "videoTimescale": Int(m.videoTimescale),
            "audioTimescale": Int(m.audioTimescale),

            "flashTimesMillis": flashes.map { $0 * ms },
            "impulseTimesMillis": impulses.map { $0 * ms },
            "videoFrameCount": m.videoFrameCount,
            "audioFrameCount": m.audioFrameCount,
        ]
    }
}
