import 'dart:io';

import 'package:flutter/material.dart';
import 'package:stereo_av_writer/stereo_av_writer.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(home: ClapHarness());
}

class ClapHarness extends StatefulWidget {
  const ClapHarness({super.key});
  @override
  State<ClapHarness> createState() => _ClapHarnessState();
}

class _ClapHarnessState extends State<ClapHarness> {
  final _recorder = StereoAvCameraRecorder();
  bool _recording = false;
  bool _busy = false;
  String _status = 'Ready. Press Record, aim at yourself, and CLAP.';
  ClapAnalysis? _analysis;
  String? _error;

  String get _outputPath => '${Directory.systemTemp.path}/camera_slice.mov';

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
      _analysis = null;
    });
    try {
      await _recorder.start(outputPath: _outputPath, preview: true);
      setState(() {
        _recording = true;
        _status = 'RECORDING — clap once now (and again in ~1–2 min for the drift leg), '
            'then Stop & Analyze.';
      });
    } catch (e) {
      setState(() => _error = 'start failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _stopAndAnalyze() async {
    setState(() {
      _busy = true;
      _status = 'Finalizing + analyzing…';
    });
    try {
      final path = await _recorder.stop();
      final analysis = await _recorder.analyze(path ?? _outputPath);
      debugPrint('CLAP-RESULT $analysis');
      setState(() {
        _recording = false;
        _analysis = analysis;
        _status = 'Done. See the offset below.';
      });
    } catch (e) {
      setState(() => _error = 'stop/analyze failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Widget _verdict(ClapAnalysis a) {
    final offsets = a.offsetsMillis;
    if (a.audioCount == 0 || a.videoCount == 0) {
      return const Text('No clap detected — clap sharply, in frame, and retry.',
          style: TextStyle(color: Colors.orange));
    }
    const floorMs = 1000.0 / 30.0; // ~1 video frame
    final coherent = offsets.every((o) => o.abs() < floorMs + 5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('audio onsets (ms): ${a.audioOnsetsMillis.map((x) => x.toStringAsFixed(1)).toList()}'),
        Text('video peaks  (ms): ${a.videoMotionPeaksMillis.map((x) => x.toStringAsFixed(1)).toList()}'),
        const SizedBox(height: 8),
        Text('A/V offset (video − audio): ${offsets.map((o) => o.toStringAsFixed(1)).toList()} ms',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        if (a.driftMillis != null) Text('drift across claps: ${a.driftMillis!.toStringAsFixed(1)} ms'),
        const SizedBox(height: 8),
        Text(
          coherent
              ? '✅ COHERENT — offset within ~1 frame. Camera PTS and audio hostTime share the clock.'
              : '⚠️ Offset exceeds ~1 frame. Either a mushy clap (retry / use a clapperboard) '
                  'or a real coherence issue worth investigating.',
          style: TextStyle(color: coherent ? Colors.green : Colors.orange),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('stereo_av_writer — clap sync harness')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status),
            const SizedBox(height: 16),
            Row(
              children: [
                FilledButton(
                  onPressed: (_busy || _recording) ? null : _start,
                  child: const Text('Record'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: (_busy || !_recording) ? null : _stopAndAnalyze,
                  child: const Text('Stop & Analyze'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            if (_analysis != null) _verdict(_analysis!),
          ],
        ),
      ),
    );
  }
}
