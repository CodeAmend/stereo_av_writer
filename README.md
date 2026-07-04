# stereo_av_writer

Mux **true-stereo audio** and **video** into one file with near-perfect A/V sync, on a
single `AVAssetWriter` timeline. macOS-first Flutter plugin.

> **Status: work in progress.** The hard problem — does audio and video actually mux in
> sync on one clock — is solved and empirically confirmed. What remains is product
> surface (preview, device selection) and long-recording robustness. See
> [Status & roadmap](#status--roadmap).

## What it is

A local, in-app recorder for a music-teaching app: pick a camera, hit record, get **one
muxed `.mov`** the app can upload. One less step than "record outside the app, then
upload."

Its one hard job: **stitch true-stereo audio together with video frames into a single
file with near-perfect A/V sync, held for recordings up to 1–2 hours, with zero drift**
— because the file is watched later and nothing re-syncs it at playback, so any baked-in
error is permanent.

## What it is not

- **Not a camera package.** The video source is a native `AVCaptureVideoDataOutput`; this
  package owns everything *audio-and-after* (stereo capture, encode, sync, mux, file).
- **Not an encoder/muxer from scratch.** `AVAssetWriter` is the encoder and muxer; this
  feeds it timestamped inputs.
- **Not a screen recorder / compositor.** Single video source in.

## How it works

The whole design rests on one fact: **an `AVCaptureSession`'s video PTS and
`multichannel_capture`'s audio `hostTime` both live in the mach host-time domain**
(`CMClockGetHostTimeClock`), so they are directly comparable with no conversion.

```text
 AVCaptureVideoDataOutput ──► CMSampleBuffer (host-clock PTS) ──┐  native → native
   (video, PTS on synchronizationClock)                        │  (PTS preserved)
                                                               ├─► AVWriterCore ─► out.mov
 multichannel_capture.timedFrames ──► (samples + hostTime) ────┘  Dart → native
   (true-stereo audio, host-clock stamped)                         (timestamp travels
                                                                     with the samples)
```

- **`AVWriterCore`** — two `AVAssetWriterInput`s on one `AVAssetWriter`, both timed against
  an injectable host clock (defaults to the capture session's `synchronizationClock`).
- **Video** stays native end-to-end: raw `CMSampleBuffer` straight off the capture output,
  never round-tripped through Dart (that would lose the PTS and choke on hours of frames).
- **Audio** is captured by [`multichannel_capture`](#dependencies) (true-stereo, no
  `AVCaptureSession` mono-downmix trap) and pushed to the native writer from Dart. The
  `hostTime` is stamped at the capture instant and travels *with* the samples, so the Dart
  hop adds latency, not timestamp error.

The design was built and proven in thin slices; the specs are the best deep dive:

- [`docs/slice-1-spec.md`](docs/slice-1-spec.md) — synthetic-frame mux + a sync proof with
  a negative control (deliberately break sync, confirm the test catches it).
- [`docs/camera-slice-spec.md`](docs/camera-slice-spec.md) — real capture + the empirical
  clock-coherence proof.

## Usage

```dart
import 'package:stereo_av_writer/stereo_av_writer.dart';

final recorder = StereoAvCameraRecorder();

// Starts the stereo audio capture, the video-only capture session, and the writer.
await recorder.start(outputPath: '/path/to/take.mov');

// ... teacher records ...

final path = await recorder.stop(); // finalized, muxed .mov ready to upload
```

The [`example/`](example/) app is a **clap sync harness**: record, clap, and it reports the
measured audio/video offset read back from the written file — the tool used to confirm the
clocks cohere.

There is also a synthetic verification harness, `StereoAvWriter().runSliceOne(...)`, which
proves the writer core with no camera at all (see the example's `integration_test/`).

## Dependencies

This package depends on **[`multichannel_capture`](../multichannel_capture)** for
true-stereo audio capture, currently referenced by relative path:

```yaml
dependencies:
  multichannel_capture:
    path: ../multichannel_capture
```

> ⚠️ **Cloning this repo alone will not build** until that sibling package is available
> next to it (or the dependency is repointed to a published/git source). The two packages
> are developed together.

## Requirements

- macOS 12.3+ (uses `AVCaptureSession.synchronizationClock`; falls back to the host clock
  below that).
- The host app must declare camera + microphone usage and the
  `com.apple.security.device.camera` / `.audio-input` entitlements (see
  [`example/macos/Runner`](example/macos/Runner)).

## Status & roadmap

**Done and verified:** the writer core, the synthetic sync proof (with negative control),
real camera + stereo capture into one muxed file, and empirical confirmation that the real
camera PTS and real audio `hostTime` share the clock (no gross offset, no drift).

Remaining, in tiers, to reach a shippable record button:

| Tier | Work |
|------|------|
| **1 — try it in-app** | AAC audio (currently LPCM for measurement); a clean `start`/`stop`/state API |
| **2 — real feature** | camera preview (Flutter texture bridge); camera + mic device selection; device-loss handling |
| **3 — production** | real-time backpressure hardening for 1–2 h recordings; HEVC; long-duration soak |

None of these are open *questions* — the sync risk is retired; they are known,
incremental builds.

## Naming

The package name is a placeholder. `stereo_av_writer` describes the mechanism; a final
name will be chosen once the API stabilizes.

## License

[MIT](LICENSE) © 2026 Michael Bruce Allen
