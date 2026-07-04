# Camera-slice spec — real capture + empirical clock-coherence proof

**Status:** proposed, for review. **No build until signed off.** Package name still a
placeholder (`stereo_av_writer`) — see [Naming](#naming). Builds directly on
`docs/slice-1-spec.md` (slice 1 is **done and verified**).

Slice 1 proved the writer core against synthetic producers: mux-preservation, the
known-Δ scale/anchor catcher, and zero-drift-in-principle — all with exact numbers,
all automated. This slice swaps the synthetic producers for the **real** sources and
proves the one thing a camera-less slice structurally could not: that a real camera
PTS and a real audio `hostTime` land on the **same physical instant**.

---

## 1. What this slice proves — and what it reuses / defers

**Proves (the one open leg): cross-subsystem clock coherence.** A real
`AVCaptureVideoDataOutput` PTS and a real `multichannel_capture.timedFrames` `hostTime`,
keyed to one physical event (a clap), land together in the muxed file within tolerance —
empirically confirming the high-confidence audit claim that both live on the host clock.

**Reuses unchanged:** the entire writer core — [AVWriterCore.swift](../macos/Classes/AVWriterCore.swift),
the audio `CMSampleBuffer` builder in [SyntheticProducers.swift](../macos/Classes/SyntheticProducers.swift)
(minus the impulse), and the file-readback machinery in [SliceMeasurement.swift](../macos/Classes/SliceMeasurement.swift).
The synthetic-first approach was *buying* this swap; this slice is where it pays out.

**Does NOT re-prove:** mux-preservation, the known-Δ scale leg, drift-in-principle —
slice 1 closed those. In particular there is **no physical known-Δ leg**: you can't
hand-produce a precise Δ, and you don't need to, because that bug class already died
synthetically.

**Defers (unchanged):** productized preview / the Flutter texture bridge, the final
public API shape (#3), audio+video **device enumeration** (default devices this slice),
record-during-a-live-call device contention, and real-time backpressure hardening
(the 1–2 h soak — §8).

---

## 2. What's settled going in

- **Session ownership → stitcher owns it.** The consuming app is greenfield on camera
  (its calling SDK owns the camera; no app-owned `AVCaptureSession`), so stitcher-owns
  is unopposed.
- **Clock → inject `session.synchronizationClock` into the writer core.** This is where
  the injectable clock earns its keep *internally*: the writer references the exact clock
  the camera stamps PTS against. Defaults to the host clock — the domain audio `hostTime`
  already lives in.
- **Audio transport → Dart-mediated (#3a).** `timedFrames` surfaces PCM in Dart; the
  stitcher's Dart layer pushes each batch down to the native writer. Native-to-native
  coupling to `multichannel_capture`'s C ABI is rejected (don't shackle two packages'
  native layers for a 384 KB/s hop).
- **Stimulus → hand clap** (or clapperboard). The LED+piezo sync box is reactive-only —
  reach for it only if a clap comes back weird. Rationale: the bug being ruled out is
  categorical (wrong domain / gross offset), which shows as tens of ms → seconds; a clap
  catches that. Building hardware for a sub-frame number aims precision below the yes/no.

---

## 3. Architecture, camera-slice form

```
 AVCaptureSession (VIDEO-ONLY)                          multichannel_capture (Dart)
   AVCaptureVideoDataOutput ──► CMSampleBuffer            timedFrames: TimedAudioBatch
     (PTS on synchronizationClock)   │                      { samples: Float32List,
                                      │  native→native        hostTime: Int, ... }
                                      │  (PTS preserved)          │  Dart→native (#3a)
                                      ▼                           ▼  channel push
                              ┌──────────────────────────────────────────┐
                              │  AVWriterCore (clock = synchronizationClock)│
                              │  video AVAssetWriterInput │ audio input     │──► out.mov
                              └──────────────────────────────────────────┘
```

Audio does **not** pass through `AVCaptureSession` — that's the mono-downmix trap
`multichannel_capture` exists to avoid. The capture session here is video-only.

---

## 4. Native: video capture → core

- **Video-only `AVCaptureSession`**; default camera device; `AVCaptureVideoDataOutput`
  with a delegate on a dedicated queue.
- **Inject the clock:** construct `AVWriterCore(clock: session.synchronizationClock)`.
- **Video path:** the delegate's `CMSampleBuffer` goes straight to `appendVideo` —
  native-to-native, PTS intact, never round-tripped through Dart (2 h of raw video
  through Dart is a perf catastrophe and drops the PTS).
- **Permissions:** camera (`NSCameraUsageDescription` + `AVCaptureDevice.requestAccess(.video)`)
  and microphone (`NSMicrophoneUsageDescription`), plus the sandbox entitlements
  `com.apple.security.device.camera` and `.audio-input` on the example app.

**Audio-capture ownership:** the stitcher owns the `multichannel_capture` session (on its
Dart side) — consistent with "owns everything audio-and-after." The caller hands over no
audio; it calls start/stop and the stitcher captures, stamps, and muxes.

---

## 5. Audio path (#3a) — and why the Dart hop is sync-safe

Dart subscribes to `timedFrames` and pushes each `TimedAudioBatch` down a binary-typed
channel (`Float32List` samples + int `hostTime` + channels/rate); native rebuilds the
`CMSampleBuffer` (the slice-1 audio builder, real PCM instead of an impulse) and appends.

**The property that makes this correct:** the `hostTime` is stamped in
`multichannel_capture`'s **audio callback**, at the capture instant, and travels *with*
the samples as an integer. The Dart hop adds delivery **latency** but not timestamp
**error** — the PTS is the capture instant, not the arrival instant. So a slow hop can
threaten *liveness* (audio must reach the writer before finalize; backpressure), never
*sync*. That decoupling of timestamp-from-delivery is the whole reason Dart-mediated
transport is safe.

---

## 5.1 Session origin — derived from the first samples, not read up front

Slice 1 could read the host clock *before* either producer emitted and use it as the
session origin, guaranteeing every PTS ≥ origin. Real capture can't: by the time
`startWriting` runs, both sources are free-running, and a frame already in the pipeline
can carry a PTS from *before* any "now" you could read. So origin is derived from the
samples, not chosen from the top:

1. `startWriting()` — but **defer** `startSession`.
2. Buffer incoming samples from both tracks without appending, until the **first sample
   from each** track has arrived.
3. `startSession(atSourceTime: min(firstVideoPTS, firstAudioPTS))`.
4. Drain the buffered samples (all ≥ origin by construction) and go live.

**Why `min`, and why it matters more here than for a stock recorder:** video is delivered
≈ immediately (PTS ≈ delivery), but audio is **delivered late, timestamped early** — a
batch arriving now can carry a `hostTime` from tens of ms ago (its capture instant, §5).
Starting the session on the first video frame would drop that later-arriving-but-earlier-
stamped audio (PTS < origin), silently clipping the head of the audio track. Taking the
min over both tracks' first samples guarantees nothing falls below origin. The buffering
window is bounded by audio startup latency (first batch + hop, sub-100 ms); cap it
defensively.

**Origin is not sync-critical.** It is common to both tracks, so it cancels in the
measurement (offset = `videoClapPTS − audioClapPTS`, both on the same file timeline).
Getting origin wrong clips a head or opens a leading gap; it *cannot* skew the clap
number. (Rejected alternative: origin = a host time minus a safety margin, no buffering —
bakes in a leading gap and a guessed margin.)

**Core change this forces:** [`AVWriterCore`](../macos/Classes/AVWriterCore.swift) today
does `startWriting` + `startSession` together with an origin computed up front. Split
them — begin writing early, set the origin later from the first samples. A small, clean
edit that only surfaces once a second, differently-latenced source exists.

---

## 6. Concurrency (new — slice 1 never exercised it)

Slice 1 drove both tracks from one thread in timeline order. Here there are two **live
async** sources: video on the capture delegate queue, audio arriving via the channel.
Discipline:

- **Per-input single-threading:** the video input is touched only from the delegate
  queue; the audio input only from a dedicated serial audio queue. `AVAssetWriter`
  permits concurrent appends to *different* inputs from different threads; it does not
  permit racing the *same* input.
- **Known limitation, honestly flagged:** the core's `append` spin-waits on
  `isReadyForMoreMediaData`. Blocking the capture delegate queue makes the capture system
  drop frames. For this slice's short recordings that's harmless (a few dropped frames
  don't hurt clap detection). The non-blocking / drop-or-queue design for sustained
  real-time is **backpressure hardening, deferred to the soak slice** (§8).

---

## 7. The empirical measurement (the point of the slice)

One physical event the camera **sees** and the mic **hears** at the same instant; then
the same file-readback discipline as slice 1 (measure the written file, not in-memory
PTS).

**Detection (objective, no human scrubbing):**
- **Audio clap:** peak of a short-time onset function — a clap is a razor-sharp
  transient, detectable to ~1 ms.
- **Video clap:** the frame of maximum inter-frame motion energy in a window around the
  audio clap; report that frame's PTS. (A clapperboard's stick-close sharpens this if a
  hand clap reads mushy.)
- **Offset = videoClapPTS − audioClapPTS.**

**Resolution floor — stated, not hidden:** ±1 video frame (~33 ms @30 fps), set by the
frame *period* on the video side (you only sample the visual every frame); the audio
side is sample-sharp. This is **sufficient because the leg is a yes/no** — a real domain
bug is tens of ms → seconds, far outside the floor. If a tighter number is ever wanted,
the lever is **higher-fps capture** (±8 ms @120 fps), not a sync box.

**Legs:**
1. **Coherence:** coincident-clap offset within ~1 frame of zero → real camera and real
   audio share the instant.
2. **Real-clock drift:** a second clap a couple of minutes later; its offset must equal
   the first within the ±1-frame noise. (Structurally near-impossible to fail — one
   clock, and every audio batch re-anchors to `hostTime` every ~21 ms, so error can't
   integrate — but confirmed, not assumed.)

**Detectors are validated independently of any clap:** run them against slice 1's
synthetic file, whose flash frames and impulse samples are known ground truth. That
splits "does the detector work" (automatable, known truth) from "do the real clocks
cohere" (needs the clap) — so the only human-supplied ingredient is the physical
coincidence itself.

---

## 8. Who verifies what (this slice is not headless)

Slice 1 I drove end to end — no camera, no mic, no human. This slice has a human-in-loop
seam, so the "definition of done" splits:

**I can build and verify (no clap):**
- The full capture → core → mux plumbing: a real two-track `.mov` records with sane
  durations, frame counts, and monotonic PTS on both tracks.
- The `#3a` audio path end to end (real `timedFrames` reaching the writer).
- The clap detectors, against slice 1's synthetic ground-truth file.
- (First run needs a one-time camera/mic permission grant — a single human click, or
  pre-granted.)

**You verify (the one clap):**
- Run the harness, aim, **clap**, stop — read the coherence offset. Clap again a couple
  minutes later for the drift leg. Two ~2-second actions; nothing to watch in between;
  the machine computes the verdict, your eyes are not the instrument.
- The debug harness makes it one button: start → clap → stop → prints the offset.

**Explicitly NOT this slice:** the 1–2 h run. That is **throughput robustness** (does the
writer keep up; memory; thermal) — a *different* question from sync, run **once,
unattended**, in a later slice. Sync over long duration is already settled by §7's
re-anchoring property.

---

## 9. Preview — deferred, with the leak sealed

Productized preview (the Flutter texture bridge) is product-UX and belongs with the real
record-button slice; bundling it dilutes the sync headline. **But** the interactive clap
harness needs someone to aim the camera, so the example needs a preview.

**Guardrail:** a **debug-gated, throwaway native `AVCaptureVideoPreviewLayer`** in a
borderless window **inside the plugin**, attached to the same video-only session —
**never a Dart-exposed surface**. With no API handle, the real preview must be a
*deliberate* future surface, not an accidental promotion of the aim-rig. Native, gated,
disposable.

---

## 10. Deliverables & definition of done

- Native: video-only `AVCaptureSession` + delegate → core (clock injected); debug preview
  window; camera/mic permission + entitlements.
- Dart: stitcher owns the `multichannel_capture` session; `timedFrames` → channel → writer
  (#3a); a provisional `startRecording` / `stopRecording` control surface (the *product*
  API is #3, still deferred — this is the slice's working surface, marked provisional).
- Measurement: audio-onset + video-motion clap detectors; offset + drift computation;
  detector self-test against the slice-1 synthetic file.
- An interactive example harness: aim → record → clap → stop → printed offset.

**Definition of done:** (a) *I* confirm a real two-track file muxes with sane
tracks and the detectors pass on the synthetic ground-truth file; (b) *you* run the clap
harness and the coherence offset lands within ~1 frame with no gross offset, and the
two-clap drift is within the floor — each with its measured number reported.

---

## 11. Open decisions — still deferred

- **#3 public API shape** — `startRecording`/`stopRecording` here is provisional; the
  productized surface (preview, device selection, state/error stream) is still open.
- **Device enumeration** (audio + video) — default devices this slice.
- **Productized preview / texture bridge** — deliberate future surface (§9).
- **Record-during-a-live-call** — camera-**device** contention (two sessions, one
  camera), product scope.
- **Real-time backpressure over 1–2 h** — the soak slice (§8); the append spin-wait is
  not the sustained-real-time design.

---

## 12. Naming

Still **UNCONFIRMED — needs sign-off.** Candidates unchanged (`av_stitcher`,
`synced_av_writer`, or the film-slate-themed `slate`/`clapper`). Recommendation: keep the
placeholder until the API feel exists — which, with a real record path landing this
slice, is getting close.
