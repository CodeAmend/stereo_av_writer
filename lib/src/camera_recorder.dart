import 'dart:async';

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

  bool get isRecording => _capture != null;

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
    _sub = cap.timedFrames.listen((batch) {
      _ch.invokeMethod('pushAudioBatch', {
        'samples': batch.samples,
        'hostTime': batch.hostTime,
      });
    });
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
