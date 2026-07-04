
import 'stereo_av_writer_platform_interface.dart';

class StereoAvWriter {
  Future<String?> getPlatformVersion() {
    return StereoAvWriterPlatform.instance.getPlatformVersion();
  }
}
