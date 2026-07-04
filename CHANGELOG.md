# Changelog

## 0.2.0

Product surface for in-app recording (stretto v0.79 integration).

- **AAC audio** for camera recording (was LPCM, the sync-measurement codec).
- **Embedded live preview**: `StereoAvPreview` (`AppKitView`) over a native
  `AVCaptureVideoPreviewLayer`, backed by a recorder **lifecycle split** —
  `startPreview()` runs the session for preview → `beginRecording()` attaches the
  writer → `stop()`.
- **Device enumeration + selection**: `listCameras()` / `CameraDevice`, plus
  `cameraId` + `audioDeviceIndex` on `startPreview` (built-in + external cameras,
  e.g. an OBS virtual cam; audio via `multichannel_capture` device index).
- **Live L/R levels + mono**: a broadcast `levels` stream (`StereoLevels`, per-channel
  peak) and a `mono` flag that averages channels to both — for an in-app meter and a
  mono-signal option.
- Dependency on `multichannel_capture` switched from a local `path:` to a `git:` ref.

## 0.1.0 (unreleased)

Initial development. The A/V sync core is built and empirically verified; product surface
and long-recording robustness are still to come (see the roadmap in the README).

- **Writer core** (`AVWriterCore`): two `AVAssetWriterInput`s on one `AVAssetWriter`,
  timed against an injectable host clock; begin-writing and set-origin split so the origin
  can be derived from the first live samples.
- **Synthetic sync proof** (slice 1): host-stamped synthetic frames + audio muxed and
  measured back from the file, with a negative control that proves the test can fail.
- **Real capture** (camera slice): video-only `AVCaptureSession` +
  `multichannel_capture.timedFrames` audio (Dart-mediated) muxed into one `.mov`;
  `min(firstVideoPTS, firstAudioPTS)` origin handling for two live sources.
- **Empirical coherence confirmed**: real camera PTS and real audio `hostTime` track
  together across a recording — same clock, no gross offset, no drift.
- `example/` clap sync harness + a synthetic integration test.

See [`docs/`](docs/) for the slice specs.
