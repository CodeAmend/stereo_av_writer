import 'src/slice_one.dart';
import 'stereo_av_writer_platform_interface.dart';

export 'src/slice_one.dart';
export 'src/camera_recorder.dart';

class StereoAvWriter {
  Future<String?> getPlatformVersion() {
    return StereoAvWriterPlatform.instance.getPlatformVersion();
  }

  /// Run a synthetic slice-1 mux + clap/flash sync measurement and return the offsets
  /// recovered from the written file. See `docs/slice-1-spec.md`.
  Future<SliceOneResult> runSliceOne(SliceOneConfig config) {
    return StereoAvWriterPlatform.instance.runSliceOne(config);
  }
}
