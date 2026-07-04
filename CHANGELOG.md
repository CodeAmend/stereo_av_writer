# Changelog

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
