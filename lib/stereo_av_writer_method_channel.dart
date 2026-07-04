import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'stereo_av_writer_platform_interface.dart';

/// An implementation of [StereoAvWriterPlatform] that uses method channels.
class MethodChannelStereoAvWriter extends StereoAvWriterPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('stereo_av_writer');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
