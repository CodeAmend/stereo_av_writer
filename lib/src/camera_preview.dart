import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// v0.79.3 — live camera preview surface (macOS). Renders the native
/// `AVCaptureVideoPreviewLayer` bound to the active
/// [StereoAvCameraRecorder] preview session via an `AppKitView`.
///
/// Mount this AFTER calling `startPreview()` — the native view binds to whatever
/// session is current and rebinds if it changes. On non-macOS it's a black box.
class StereoAvPreview extends StatelessWidget {
  const StereoAvPreview({super.key});

  static const String _viewType = 'stereo_av_writer/preview';

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    return const AppKitView(viewType: _viewType);
  }
}
