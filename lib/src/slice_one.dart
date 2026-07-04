/// Slice-1 configuration and result models.
///
/// Slice 1 proves the writer core: a synthetic two-track `.mov` muxed on one shared
/// host timeline, with three marked clap/flash events read back from the *file* to
/// measure A/V sync. No camera, no `AVCaptureSession` — see `docs/slice-1-spec.md`.
library;

/// Inputs to a synthetic slice-1 mux run.
class SliceOneConfig {
  const SliceOneConfig({
    required this.outputPath,
    this.fps = 30,
    this.durationSeconds = 6.0,
    this.sampleRate = 48000,
    this.channels = 2,
    this.width = 320,
    this.height = 240,
    this.knownDeltaMillis = 500.0,
    this.audioCodec = SliceAudioCodec.lpcm,
    this.negativeControl = false,
  });

  /// Where the muxed `.mov` is written.
  final String outputPath;
  final int fps;
  final double durationSeconds;
  final int sampleRate;
  final int channels;
  final int width;
  final int height;

  /// The deliberate offset (ms) between flash and impulse on event 1 — the leg that
  /// catches a shared-anchor / mis-scaled-PTS bug.
  final double knownDeltaMillis;

  /// `lpcm` (default) gives a sample-exact measurement; `aac` is the product codec and
  /// adds a priming offset not gated by the sync assertions.
  final SliceAudioCodec audioCodec;

  /// When true, reintroduces the shared-anchor bug on event 1 (impulse stamped at the
  /// flash's time, ignoring [knownDeltaMillis]) — used to prove the Δ leg can fail.
  final bool negativeControl;

  Map<String, dynamic> toMap() => {
        'outputPath': outputPath,
        'fps': fps,
        'durationSeconds': durationSeconds,
        'sampleRate': sampleRate,
        'channels': channels,
        'width': width,
        'height': height,
        'knownDeltaMillis': knownDeltaMillis,
        'audioCodec': audioCodec == SliceAudioCodec.aac ? 'aac' : 'lpcm',
        'negativeControl': negativeControl,
      };
}

enum SliceAudioCodec { lpcm, aac }

/// Measured outcome of a slice-1 run, recovered from the written file.
class SliceOneResult {
  const SliceOneResult({
    required this.ok,
    required this.reason,
    required this.outputPath,
    required this.audioCodec,
    required this.negativeControl,
    required this.coincidentEarlyMillis,
    required this.coincidentLateMillis,
    required this.knownDeltaMeasuredMillis,
    required this.knownDeltaExpectedMillis,
    required this.driftMillis,
    required this.videoQuantMillis,
    required this.halfFrameMillis,
    required this.videoTimescale,
    required this.audioTimescale,
    required this.flashTimesMillis,
    required this.impulseTimesMillis,
    required this.videoFrameCount,
    required this.audioFrameCount,
  });

  /// False if the readback did not recover exactly three flashes and three impulses;
  /// [reason] then explains what landed instead.
  final bool ok;
  final String reason;
  final String outputPath;
  final String audioCodec;
  final bool negativeControl;

  /// A/V offset (ms, video − audio) at the early coincident event. ~0 expected.
  final double coincidentEarlyMillis;

  /// A/V offset (ms) at the late coincident event.
  final double coincidentLateMillis;

  /// Measured gap (ms, impulse − flash) at the known-Δ event.
  final double knownDeltaMeasuredMillis;

  /// The Δ that was requested (0 under negative control).
  final double knownDeltaExpectedMillis;

  /// Late coincident offset − early coincident offset. Expected exactly 0 (one clock).
  final double driftMillis;

  /// Video PTS quantization floor (ms = 1000 / videoTimescale).
  final double videoQuantMillis;

  /// Half a video frame (ms) — the coincident event's structural floor.
  final double halfFrameMillis;

  final int videoTimescale;
  final int audioTimescale;
  final List<double> flashTimesMillis;
  final List<double> impulseTimesMillis;
  final int videoFrameCount;
  final int audioFrameCount;

  factory SliceOneResult.fromMap(Map<dynamic, dynamic> m) {
    double d(String k) => (m[k] as num?)?.toDouble() ?? double.nan;
    int i(String k) => (m[k] as num?)?.toInt() ?? -1;
    List<double> dl(String k) =>
        ((m[k] as List?) ?? const []).map((e) => (e as num).toDouble()).toList();

    return SliceOneResult(
      ok: (m['ok'] as bool?) ?? false,
      reason: (m['reason'] as String?) ?? '',
      outputPath: (m['outputPath'] as String?) ?? '',
      audioCodec: (m['audioCodec'] as String?) ?? '',
      negativeControl: (m['negativeControl'] as bool?) ?? false,
      coincidentEarlyMillis: d('coincidentEarlyMillis'),
      coincidentLateMillis: d('coincidentLateMillis'),
      knownDeltaMeasuredMillis: d('knownDeltaMeasuredMillis'),
      knownDeltaExpectedMillis: d('knownDeltaExpectedMillis'),
      driftMillis: d('driftMillis'),
      videoQuantMillis: d('videoQuantMillis'),
      halfFrameMillis: d('halfFrameMillis'),
      videoTimescale: i('videoTimescale'),
      audioTimescale: i('audioTimescale'),
      flashTimesMillis: dl('flashTimesMillis'),
      impulseTimesMillis: dl('impulseTimesMillis'),
      videoFrameCount: i('videoFrameCount'),
      audioFrameCount: i('audioFrameCount'),
    );
  }

  @override
  String toString() => 'SliceOneResult(ok: $ok, '
      'coincidentEarly: ${coincidentEarlyMillis.toStringAsFixed(3)}ms, '
      'coincidentLate: ${coincidentLateMillis.toStringAsFixed(3)}ms, '
      'knownΔ: ${knownDeltaMeasuredMillis.toStringAsFixed(3)}ms '
      '(expected ${knownDeltaExpectedMillis.toStringAsFixed(1)}ms), '
      'drift: ${driftMillis.toStringAsFixed(3)}ms, '
      'floor: videoQuant ${videoQuantMillis.toStringAsFixed(3)}ms / '
      'halfFrame ${halfFrameMillis.toStringAsFixed(3)}ms, '
      'timescales v=$videoTimescale a=$audioTimescale, '
      'frames v=$videoFrameCount a=$audioFrameCount'
      '${ok ? '' : ', reason: $reason'})';
}
