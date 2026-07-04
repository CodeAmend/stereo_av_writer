import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'stereo_av_writer_method_channel.dart';

abstract class StereoAvWriterPlatform extends PlatformInterface {
  /// Constructs a StereoAvWriterPlatform.
  StereoAvWriterPlatform() : super(token: _token);

  static final Object _token = Object();

  static StereoAvWriterPlatform _instance = MethodChannelStereoAvWriter();

  /// The default instance of [StereoAvWriterPlatform] to use.
  ///
  /// Defaults to [MethodChannelStereoAvWriter].
  static StereoAvWriterPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [StereoAvWriterPlatform] when
  /// they register themselves.
  static set instance(StereoAvWriterPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
