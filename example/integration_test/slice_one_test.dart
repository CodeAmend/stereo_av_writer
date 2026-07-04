// Slice-1 sync proof, exercised end-to-end against the real native writer.
//
// Runs a synthetic two-track mux and asserts the three sync legs against the file that
// was actually written, then runs a negative control to prove the tightest leg (the
// known-Δ leg) can fail — a sync test that only ever passes proves nothing.
//
// See docs/slice-1-spec.md.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:stereo_av_writer/stereo_av_writer.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final plugin = StereoAvWriter();

  String tmpPath(String name) =>
      '${Directory.systemTemp.path}/stereo_av_writer_$name.mov';

  testWidgets('synthetic mux: three sync legs hold', (tester) async {
    final result = await plugin.runSliceOne(
      SliceOneConfig(outputPath: tmpPath('sync'), knownDeltaMillis: 500.0),
    );
    // ignore: avoid_print
    print('SLICE1 $result');

    expect(result.ok, isTrue, reason: result.reason);
    expect(File(result.outputPath).existsSync(), isTrue);
    expect(result.flashTimesMillis.length, 3);
    expect(result.impulseTimesMillis.length, 3);

    // The coincident floor is set by the video container quantization / half a frame.
    // Allow one full frame of slack over that — a domain/scale bug is tens of ms+.
    final coincidentTol = result.halfFrameMillis + 1000.0 / 30.0;

    // Leg 1 — coincident events land together (both early and late).
    expect(result.coincidentEarlyMillis.abs(), lessThan(coincidentTol),
        reason: 'early coincident offset ${result.coincidentEarlyMillis}ms '
            'exceeds floor ${coincidentTol}ms');
    expect(result.coincidentLateMillis.abs(), lessThan(coincidentTol),
        reason: 'late coincident offset ${result.coincidentLateMillis}ms');

    // Leg 2 — the known Δ is reproduced (the scale/anchor-bug catcher). Tight.
    expect((result.knownDeltaMeasuredMillis - 500.0).abs(), lessThan(3.0),
        reason: 'measured Δ ${result.knownDeltaMeasuredMillis}ms != 500ms');

    // Leg 3 — no drift across the run. One clock ⇒ ~exactly zero.
    expect(result.driftMillis.abs(), lessThan(2.0),
        reason: 'drift ${result.driftMillis}ms across the run');
  });

  testWidgets('negative control: the Δ leg has teeth', (tester) async {
    // Reintroduce the shared-anchor bug: the impulse is stamped at the flash's time,
    // so the measured Δ collapses toward 0 and the leg-2 assertion MUST fail.
    final control = await plugin.runSliceOne(
      SliceOneConfig(
        outputPath: tmpPath('negctl'),
        knownDeltaMillis: 500.0,
        negativeControl: true,
      ),
    );
    // ignore: avoid_print
    print('SLICE1-NEGCTL $control');

    expect(control.ok, isTrue, reason: control.reason);

    // Under the injected bug, measured Δ ≈ 0 — nowhere near 500ms. This confirms the
    // real test's leg-2 assertion would have caught it.
    final wouldPassLeg2 = (control.knownDeltaMeasuredMillis - 500.0).abs() < 3.0;
    expect(wouldPassLeg2, isFalse,
        reason: 'negative control should NOT satisfy leg 2, but measured Δ was '
            '${control.knownDeltaMeasuredMillis}ms');
    expect(control.knownDeltaMeasuredMillis.abs(), lessThan(3.0),
        reason: 'shared-anchor bug should collapse Δ to ~0, got '
            '${control.knownDeltaMeasuredMillis}ms');
  });
}
