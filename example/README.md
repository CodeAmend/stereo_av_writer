# stereo_av_writer_example

A macOS **clap sync harness** for the [`stereo_av_writer`](../) plugin.

It records real video (camera) + true-stereo audio (`multichannel_capture`) into one muxed
`.mov`, then reads the file back and reports the measured audio/video offset — the tool
used to confirm that the camera PTS and the audio `hostTime` share the clock.

## Running

```sh
flutter run -d macos
```

Then:

1. **Record** — grant camera + microphone permission on first run.
2. Produce a sharp, coincident audio+visual event in view of the camera (a metronome that
   *flashes and clicks* is ideal; a hand clap works only coarsely — its visual is mushy).
3. **Stop & Analyze** — the app reports the per-event A/V offset read from the written file.

A tiny debug preview window appears while recording so you can aim the camera. It is
throwaway test scaffolding, not part of the plugin's API.

## Integration test

`integration_test/slice_one_test.dart` drives the **synthetic** path (no camera): it muxes
host-stamped synthetic frames + audio and asserts the A/V sync legs, including a negative
control that deliberately breaks sync and confirms the assertion catches it.

```sh
flutter test integration_test/slice_one_test.dart -d macos
```
