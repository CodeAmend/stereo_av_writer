# Slice 1 spec — synthetic-frame mux + clap/flash sync proof

**Status:** proposed, for review. **No build until signed off.** Package name is a
placeholder (`stereo_av_writer`) — see [Naming](#naming).

This is a spec, not a fresh audit. The sync question is already answered upstream:
audio `hostTime` (from `multichannel_capture.timedFrames`) and video PTS (from
`AVCaptureVideoDataOutput`) are both in the **mach host-time domain**
(`CMClockGetHostTimeClock`), so they are directly comparable with no conversion.
Slice 1 turns that answer into a working mux and *measures* that the mux preserves
the shared timeline — without touching a camera.

---

## 1. What slice 1 proves — and what it deliberately does not

**Proves (conceptual risk):**
- Two `AVAssetWriterInput`s on one `AVAssetWriter`, both fed **host-clock PTS**,
  interleave into one `.mov` with the A/V offset **you handed in, preserved**.
- The `mach host units → CMTime` mapping (`CMClockMakeHostTimeFromSystemUnits`) is
  wired correctly on both the audio and video sides.
- The offset is **constant over time** — zero drift, because there is one clock.

**Does NOT prove (plumbing risk — deferred to the camera slice):**
- `AVCaptureVideoDataOutput` device selection, preview, permissions.
- The *empirical* confirmation that a **real** camera's PTS and a **real** audio
  HAL `hostTime` agree on a common physical instant. Slice 1 has no camera, so it
  cannot observe a physical clap/flash on both subsystems. See §6 (Ceiling).
- Session ownership (open decision #2) — slice 1 has no `AVCaptureSession` at all.

The split is intentional, mirroring `multichannel_capture`'s synthetic-tone slice:
isolate "does one host timeline mux in sync" from "does a real capture graph feed
it." If both rode one slice and it failed red, you wouldn't know which half broke.

---

## 2. Architecture, in slice-1 form

```
 synthetic video producer ──► CMSampleBuffer (host-clock PTS) ──┐
   (solid color, flips to FLASH on a marked frame)              │
                                                                ├─► AVAssetWriter ─► out.mov
 synthetic audio producer ──► CMSampleBuffer (host-clock PTS) ──┘   (.mov, one
   (silence, IMPULSE on a marked frame)                             writer, two
                                                                    AVAssetWriterInputs)
```

Camera-slice version swaps the video producer for a real
`AVCaptureVideoDataOutput` delegate and the audio producer for
`multichannel_capture.timedFrames`; **the writer core is unchanged.** Building the
writer against synthetic producers first is what lets that swap be a swap.

---

## 3. Native writer core (the reusable part)

All of this lives natively (macOS). Dart never sees a sample buffer.

- `AVAssetWriter(outputURL:, fileType: .mov)`.
- **Video input:** `AVAssetWriterInput(mediaType: .video, outputSettings:)` with an
  H.264 (baseline slice-1 choice) codec config, `expectsMediaDataInRealTime = true`.
  Append synthetic `CMSampleBuffer`s directly via `append(_:)` — we construct the
  sample buffers ourselves precisely so we control the PTS (an
  `AVAssetWriterInputPixelBufferAdaptor` would let AVFoundation time frames for us,
  which is the opposite of what we're testing).
- **Audio input:** `AVAssetWriterInput(mediaType: .audio, outputSettings:)` with AAC
  settings; append LPCM `CMSampleBuffer`s (stereo f32, 48 kHz), writer encodes.
- **Session start:** `startWriting()`, then `startSession(atSourceTime: origin)`
  where `origin = CMClockMakeHostTimeFromSystemUnits(t0)` and `t0` is a host-time
  read taken **before** either producer emits, so every sample PTS ≥ origin.
- **Finish:** drain both inputs, `markAsFinished()` on each, `finishWriting`.

**PTS rule (the one that matters):** every sample buffer's
`presentationTimeStamp = CMClockMakeHostTimeFromSystemUnits(hostUnits)`, where
`hostUnits` is a **raw `mach_absolute_time()`-domain value read independently in
that producer's own emit path**. Never compute one host value and feed it to both
inputs (see §5).

---

## 4. Synthetic producers

**Video producer.** Emits at a fixed fps (30 baseline). Each frame: a `CVPixelBuffer`
of a solid color, wrapped in a `CMSampleBuffer` with a `CMVideoFormatDescription` and
`CMSampleTimingInfo { duration = 1/fps, presentationTimeStamp = hostPTS,
decodeTimeStamp = .invalid }`. On a **marked frame** the color flips to the FLASH
color for exactly one frame. `hostPTS` is read from `mach_absolute_time()` inside
the emit call.

**Audio producer.** Emits fixed-size LPCM batches (mirror `multichannel_capture`:
interleaved f32, stereo, 48 kHz; batch ≈ the capture read size). Samples are silence
except on a **marked instant**, where a single-sample (or short-burst) IMPULSE is
written. Each batch → one `CMSampleBuffer` with PTS = the batch's own independent
host-time read and duration = `framesInBatch / sampleRate`. This is exactly the shape
a real `TimedAudioBatch` takes (`{ samples, hostTime, firstFrameIndex }`), so the
producer is a drop-in stand-in for `timedFrames`.

**Tier-2 (optional, cheap add-on):** replace the synthetic audio producer with a live
`multichannel_capture.timedFrames` capture. This runs **real** audio `hostTime`
values through `CMClockMakeHostTimeFromSystemUnits` and the writer, and doubles as
the pending end-to-end validation of `timedFrames` in a real mux context. It still
does **not** close cross-subsystem coherence (video is still synthetic) — §6.

---

## 5. The measurement (this is the point of the slice)

The failure mode we are defending against: a test that **passes green synthetically
and drifts the instant a real camera clock enters.** That happens when both
timestamps derive from one shared anchor — then any timebase/scale bug applies
equally to both and **cancels in the offset**, so the file reads 0 and lies.

Defenses, all asserted against the **written file** (read back with `AVAssetReader`,
not trusted from in-memory PTS — the container quantizes, and we want to measure what
was actually muxed):

1. **Coincident event (offset ≈ 0).** Video FLASH and audio IMPULSE marked at the
   "same instant" via a single trigger, **but each producer reads the host clock
   itself** in its own emit path. Expected file offset ≈ the few µs between two
   adjacent clock reads — sub-sample, nowhere near a video frame. Doubles as the
   human clap/flash visual QA.

2. **Known-nonzero event (offset ≈ Δ).** A second FLASH/IMPULSE pair emitted a
   **deliberate, independently-recorded** Δ apart (e.g. ~500 ms). Assert the file
   reproduces Δ within tolerance. **This is the anchor/scale-bug catcher** — a
   shared-anchor or mis-scaled-PTS bug that a coincident-only test hides fails here,
   because the wrong scale won't reproduce a known 500 ms. Target the origin offset
   on purpose, exactly as the brief demands.

3. **Drift = 0.** Place event (1) near t=0 and event (2) minutes later; assert the
   *coincident-baseline* offset measured early equals the one measured late. One
   clock ⇒ the expected drift slope is **exactly zero**, not "small." A nonzero slope
   is a bug (someone is doing their own clock conversion), not a tolerance to widen.

**Tolerance & resolution floor.** Assert coincident |offset| well under one video
frame (33 ms @30fps) and ideally sub-millisecond. But the honest resolution floor is
set by the **container track timescales** (`.mov` quantizes video PTS to the video
track timescale, audio to ~`sampleRate`): the reader reports quantized PTS, so a
perfect mux can still show up to ~½-frame video quantization. **Report the achieved
floor; do not claim precision below it.** If sub-ms video-side resolution is needed,
raise the video track timescale and document it. Every assertion prints the measured
number — pass/fail alone is not the deliverable, the number is.

**Cross-check (nice-to-have):** dump the same file with `ffprobe -show_frames` and
confirm the offsets independently of our own `AVAssetReader` path.

---

## 6. Ceiling — what a camera-less slice fundamentally can't do

Cross-subsystem clock **coherence** (real audio HAL `hostTime` vs real camera capture
PTS keyed to one physical event) requires both real subsystems observing a common
stimulus. Slice 1 has no camera, so it cannot. The upstream audit already gives us
**high confidence** these share the host domain (audio audit + `synchronizationClock`
default = `CMClockGetHostTimeClock()`); the empirical clap/flash confirmation with
both subsystems live is the **camera slice's** job. Slice 1 makes that later test
trivial by proving the writer core it will plug into.

---

## 7. Control plane vs data plane

- **Data plane (native only):** sample buffers → writer. Never round-trips through
  Dart — 1–2 h of raw video through Dart is a perf catastrophe and would drop the PTS.
- **Control plane (Dart ↔ native):** the existing method channel (`StereoAvWriterPlugin`)
  carries start/stop, the output path, and a state/error stream. In slice 1 it also
  carries the synthetic-run parameters (fps, duration, marked-event schedule) and
  returns the measured offsets for the test to assert on.

---

## 8. Deliverables of this slice

- Native writer core (§3) + synthetic producers (§4), macOS.
- A method-channel control surface sufficient to run a synthetic mux and retrieve the
  measured offsets.
- The measurement harness (§5): `AVAssetReader` readback, the three assertions with
  printed numbers, optional `ffprobe` cross-check.
- An `example/` integration test that runs a short synthetic mux and asserts (1)–(3).
- **Not** in this slice: any `AVCaptureSession`, device/preview/permission code, or a
  finalized public API.

**Definition of done:** a synthetic `.mov` in which the coincident offset is
sub-frame (ideally sub-ms, at the documented floor), the known-Δ event reproduces Δ,
and the offset does not drift across a multi-minute run — each with its measured
number reported, and green under a shared-anchor *negative control* (deliberately
break independence and confirm the known-Δ assertion catches it).

---

## 9. Open decisions — raised, NOT locked here

- **#2 Session ownership** (stitcher vs caller owns `AVCaptureSession`/video output).
  Lean: stitcher owns it (session and writer are two ends of one sync-critical
  pipeline). Slice 1 has no session, so this does not gate it. **Defer to the camera
  slice.** *Cheap insurance to take now:* shape the writer core's timeline so it can
  **accept an injected host clock** as well as read `CMClockGetHostTimeClock()`
  itself — if the consuming app already ran its own `AVCaptureSession`,
  caller-owns would become a hard constraint rather than a lean.
  **Confirmed: the consuming app owns NO `AVCaptureSession` of its own** — all camera
  lifecycle (device, preview, on/off, switch) is delegated to a third-party
  real-time-calling SDK, and the only capture session in that world is internal to that
  SDK's live-call path (the `AVCaptureSession + AVAudioEngine` mono-downmix trap that
  `multichannel_capture` exists to avoid). So for the stitcher, the consuming app is
  **greenfield on camera**: the injectable clock is **harmless insurance, not
  load-bearing**. Slice 1 builds the **self-owned** `CMClockGetHostTimeClock()` path as
  the default (what the app will use), keeping the injection seam present but not
  architecting around it. The stitcher also cannot piggyback that SDK's camera feed
  (decoded/preview frames = dead PTS, the ruled-out trap), so it must stand up its own
  `AVCaptureVideoDataOutput` regardless — which reinforces the stitcher-owns-session
  lean. *Camera-slice/product scope, noted not decided: record-during-a-live-call is a
  camera-**device** contention question (two sessions, one physical camera), not a
  session-ownership-API question.*
- **#3 Public API shape** (file path + start/stop controller + state stream; native
  video input). Downstream of #2. Leave the caller-facing session/output boundary
  open.
- **#3a Audio-sample transport to the writer** *(new — surfaced by the code).*
  `timedFrames` delivers PCM into **Dart** as `Float32List` + int `hostTime`. The
  writer is native. So the real-product audio path is either (a) Dart passes each
  batch (samples + hostTime) down to the native writer via the control channel —
  small data (~384 KB/s stereo f32), PTS is just an int to carry intact; or (b)
  native-to-native, the writer reads `multichannel_capture`'s C ABI
  (`mc_read_frames_timed`) directly, bypassing Dart but coupling to its ABI. Not a
  slice-1 blocker (slice-1 audio is synthetic/native), but decide it before the audio
  path goes real. Lean: (a) — the data is small and (b) hard-couples two packages'
  native layers.

---

## 10. Naming

Package name stays **UNCONFIRMED — needs sign-off**; per the brief it should wait
until the built thing *feels* a certain way to use. Seeding candidates only:

- `av_stitcher` — descriptive, matches the working nickname "the stitcher"; house
  style of `multichannel_capture`. **UNCONFIRMED.**
- `synced_av_writer` / `stereo_av_writer` (current) — descriptive, plainest.
  **UNCONFIRMED.**
- `slate` or `clapper` — a film **slate/clapperboard** is literally the tool that
  syncs sound to picture via a clap; thematically exact given the clap/flash proof.
  Evocative but an overloaded word. **UNCONFIRMED.**

Recommendation: **do not choose yet.** Ship slice 1 under the placeholder; name at
the camera slice when the API feel exists.
