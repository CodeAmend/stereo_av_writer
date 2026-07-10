import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:multichannel_capture/multichannel_capture.dart' as mc;

/// Result of running the clap detectors over a recorded file. Offsets are
/// `video − audio` per event, paired by sorted time.
class ClapAnalysis {
  ClapAnalysis(this.audioOnsetsMillis, this.videoMotionPeaksMillis);

  final List<double> audioOnsetsMillis;
  final List<double> videoMotionPeaksMillis;

  int get audioCount => audioOnsetsMillis.length;
  int get videoCount => videoMotionPeaksMillis.length;

  /// `videoClap − audioClap` per event (paired by sorted order). ~0 = coherent.
  List<double> get offsetsMillis {
    final a = [...audioOnsetsMillis]..sort();
    final v = [...videoMotionPeaksMillis]..sort();
    final n = a.length < v.length ? a.length : v.length;
    return [for (var i = 0; i < n; i++) v[i] - a[i]];
  }

  /// Difference between the last and first coincident offsets — the real-clock drift
  /// leg. Needs ≥2 events.
  double? get driftMillis {
    final o = offsetsMillis;
    return o.length >= 2 ? o.last - o.first : null;
  }

  @override
  String toString() =>
      'ClapAnalysis(events a=$audioCount v=$videoCount, offsets=${offsetsMillis.map((o) => o.toStringAsFixed(1)).toList()}ms'
      '${driftMillis != null ? ', drift=${driftMillis!.toStringAsFixed(1)}ms' : ''})';
}

/// A selectable capture device (camera). From [StereoAvCameraRecorder.listCameras].
class CameraDevice {
  final String id;
  final String name;

  /// v0.82 .3b — true for an external camera (vs the built-in FaceTime cam). Lets
  /// the record modal default the mirror per camera (built-in → on, external → off).
  final bool isExternal;
  const CameraDevice(this.id, this.name, {this.isExternal = false});
}

/// Live per-channel audio level (peak, 0..1) from [StereoAvCameraRecorder.levels].
/// In mono mode [left] == [right] (both fed the downmix).
class StereoLevels {
  final double left;
  final double right;
  const StereoLevels(this.left, this.right);
}

/// Camera-slice recorder: the stitcher's Dart layer owns the `multichannel_capture`
/// session, starts the native video-only capture + writer, and pipes `timedFrames`
/// down to the native writer (decision #3a). See `docs/camera-slice-spec.md`.
class StereoAvCameraRecorder {
  static const MethodChannel _ch = MethodChannel('stereo_av_writer');

  mc.AudioCapture? _capture;
  StreamSubscription<mc.TimedAudioBatch>? _sub;
  String? _outputPath;
  int _channels = 2;
  int _sampleRate = 48000;
  double? _captureWidth;
  double? _captureHeight;

  /// v0.79.4 — downmix to mono: average all channels → write the same value to
  /// each. Affects BOTH the written audio and [levels] (both channels go
  /// identical). Toggle any time (preview or recording) — the writer's format is
  /// unchanged, only the sample values. Default false (true stereo).
  bool mono = false;
  final StreamController<StereoLevels> _levelsCtrl =
      StreamController<StereoLevels>.broadcast();

  bool get isRecording => _capture != null;

  /// v0.82 .3b — the negotiated capture aspect ratio (width / height), from the
  /// native session's REAL dimensions; null before [startPreview] reports them.
  /// The record modal derives its layout from this (arch-82 D8: honest AR).
  double? get previewAspectRatio {
    final w = _captureWidth, h = _captureHeight;
    if (w == null || h == null || h == 0) return null;
    return w / h;
  }

  /// v0.79.4 — live L/R audio level (peak, 0..1) computed off the capture batches.
  /// Emits during preview AND recording (audio is open in both). Broadcast.
  Stream<StereoLevels> get levels => _levelsCtrl.stream;

  /// Release the levels stream. Call when the recorder is discarded.
  void dispose() {
    _levelsCtrl.close();
  }

  /// Start a recording. Prompts for microphone (via `multichannel_capture`) then camera
  /// (native) the first time. `preview` shows a throwaway native aim window.
  Future<void> start({
    required String outputPath,
    int fps = 30,
    bool preview = true,
  }) async {
    if (isRecording) throw StateError('already recording');
    _outputPath = outputPath;

    // 1. Audio first — read the ACTUAL negotiated format, so the native writer builds
    //    audio sample buffers in the format the device really delivers.
    final cap = mc.startCapture(sampleRate: 48000, channels: 2);
    _capture = cap;
    _channels = cap.channels;
    _sampleRate = cap.sampleRate;

    // 2. Native video-only capture + writer, told the real audio format. If it fails,
    //    tear the audio capture back down so state is clean and a retry works.
    try {
      await _ch.invokeMethod('startCameraRecording', {
        'outputPath': outputPath,
        'fps': fps,
        'channels': _channels,
        'sampleRate': _sampleRate,
        'preview': preview,
      });
    } catch (_) {
      cap.stop();
      _capture = null;
      rethrow;
    }

    // 3. Pipe timedFrames → native writer (#3a). hostTime travels with the samples, so
    //    the Dart hop adds latency, not timestamp error.
    _sub = cap.timedFrames.listen(_handleBatch);
  }

  /// v0.79.3 — enumerate cameras (built-in + external, e.g. an OBS virtual cam).
  Future<List<CameraDevice>> listCameras() async {
    final list = await _ch.invokeMethod<List<dynamic>>('listCameras');
    return (list ?? [])
        .map((e) => CameraDevice(
              (e as Map)['id'] as String,
              e['name'] as String,
              isExternal: (e['isExternal'] as bool?) ?? false,
            ))
        .toList();
  }

  /// v0.79.3 — start LIVE PREVIEW: bring up audio (to learn the real negotiated
  /// format) + the video-only capture session, but NOT the writer. Mount a
  /// [StereoAvPreview] after this to see the camera. Audio is piped down already
  /// but the native side drops it until [beginRecording]. Pass [cameraId] from
  /// [listCameras] (or null for the system default).
  Future<void> startPreview({
    required String outputPath,
    String? cameraId,
    int? audioDeviceIndex,
    int fps = 30,
  }) async {
    if (isRecording) throw StateError('already active');
    _outputPath = outputPath;

    final cap = mc.startCapture(
      deviceIndex: audioDeviceIndex,
      sampleRate: 48000,
      channels: 2,
    );
    _capture = cap;
    _channels = cap.channels;
    _sampleRate = cap.sampleRate;

    try {
      // v0.82 .3b — the native side returns the negotiated capture dimensions.
      final dims = await _ch.invokeMethod<Map<dynamic, dynamic>>(
        'startCameraPreview',
        {
          'outputPath': outputPath,
          'fps': fps,
          'channels': _channels,
          'sampleRate': _sampleRate,
          'cameraId': ?cameraId,
        },
      );
      final w = (dims?['width'] as num?)?.toDouble();
      final h = (dims?['height'] as num?)?.toDouble();
      if (w != null && h != null && w > 0 && h > 0) {
        _captureWidth = w;
        _captureHeight = h;
      }
    } catch (_) {
      cap.stop();
      _capture = null;
      rethrow;
    }

    _sub = cap.timedFrames.listen(_handleBatch);
  }

  /// v0.79.3 — attach the writer and start recording (call after [startPreview]).
  /// v0.82 .3b — send the CURRENT negotiated audio format so a mic swapped during
  /// preview (via [reconfigureAudio]) is reflected in the writer.
  Future<void> beginRecording() async {
    await _ch.invokeMethod('beginCameraRecording', {
      'channels': _channels,
      'sampleRate': _sampleRate,
    });
  }

  /// v0.82 .3b — swap ONLY the audio capture (mic change) without touching the
  /// native camera session, so the live preview does NOT reload (decouple the
  /// capture legs). Preview-phase only; the new format is taken at [beginRecording].
  Future<void> reconfigureAudio({int? audioDeviceIndex}) async {
    await _sub?.cancel();
    _sub = null;
    _capture?.stop();
    final cap = mc.startCapture(
      deviceIndex: audioDeviceIndex,
      sampleRate: 48000,
      channels: 2,
    );
    _capture = cap;
    _channels = cap.channels;
    _sampleRate = cap.sampleRate;
    _sub = cap.timedFrames.listen(_handleBatch);
  }

  /// v0.82 .3b — mirror BOTH the preview and the RECORDED frames in lockstep =
  /// true WYSIWYG (arch-82 D2). Default on (an instrument reads naturally); flip
  /// off for a behind/overhead camera whose framing is already correct.
  Future<void> setMirror(bool mirrored) async {
    await _ch.invokeMethod('setMirror', {'mirrored': mirrored});
  }

  /// Stop, finalize the file, and return its path.
  Future<String?> stop() async {
    await _sub?.cancel();
    _sub = null;
    _capture?.stop();
    _capture = null;
    final path = await _ch.invokeMethod<String>('stopCameraRecording');
    return path ?? _outputPath;
  }

  // One place both capture paths funnel through: apply the mono downmix if set,
  // push the (possibly processed) samples to the native writer, and emit the L/R
  // level for the meter — all from the SAME samples, so mono → identical bars.
  void _handleBatch(mc.TimedAudioBatch batch) {
    var samples = batch.samples;
    if (mono && _channels >= 2) {
      samples = _monoize(samples, _channels);
    }
    _ch.invokeMethod('pushAudioBatch', {
      'samples': samples,
      'hostTime': batch.hostTime,
    });
    if (_channels >= 1 && _levelsCtrl.hasListener) {
      _levelsCtrl.add(_computeLevels(samples, _channels));
    }
  }

  /// Average all channels per frame and write the mean back to every channel.
  static Float32List _monoize(Float32List interleaved, int channels) {
    final frames = interleaved.length ~/ channels;
    final out = Float32List(interleaved.length);
    for (var f = 0; f < frames; f++) {
      final base = f * channels;
      var sum = 0.0;
      for (var c = 0; c < channels; c++) {
        sum += interleaved[base + c];
      }
      final avg = sum / channels;
      for (var c = 0; c < channels; c++) {
        out[base + c] = avg;
      }
    }
    return out;
  }

  /// Peak magnitude per channel (L = ch0, R = ch1, or ch0 again if mono device).
  static StereoLevels _computeLevels(Float32List interleaved, int channels) {
    final frames = interleaved.length ~/ channels;
    if (frames == 0) return const StereoLevels(0, 0);
    final rightCh = channels >= 2 ? 1 : 0;
    var lPeak = 0.0, rPeak = 0.0;
    for (var f = 0; f < frames; f++) {
      final base = f * channels;
      final l = interleaved[base].abs();
      final r = interleaved[base + rightCh].abs();
      if (l > lPeak) lPeak = l;
      if (r > rPeak) rPeak = r;
    }
    return StereoLevels(lPeak > 1 ? 1 : lPeak, rPeak > 1 ? 1 : rPeak);
  }

  /// Run the clap detectors over a recorded file.
  Future<ClapAnalysis> analyze(String outputPath) async {
    final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('analyzeClaps', {
      'outputPath': outputPath,
      'channels': _channels,
      'sampleRate': _sampleRate,
    });
    List<double> dl(String k) =>
        ((m?[k] as List?) ?? const []).map((e) => (e as num).toDouble()).toList();
    return ClapAnalysis(dl('audioOnsetsMillis'), dl('videoMotionPeaksMillis'));
  }
}
