import 'package:flutter_test/flutter_test.dart';
import 'package:stereo_av_writer/stereo_av_writer.dart';
import 'package:stereo_av_writer/stereo_av_writer_platform_interface.dart';
import 'package:stereo_av_writer/stereo_av_writer_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockStereoAvWriterPlatform
    with MockPlatformInterfaceMixin
    implements StereoAvWriterPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final StereoAvWriterPlatform initialPlatform = StereoAvWriterPlatform.instance;

  test('$MethodChannelStereoAvWriter is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelStereoAvWriter>());
  });

  test('getPlatformVersion', () async {
    StereoAvWriter stereoAvWriterPlugin = StereoAvWriter();
    MockStereoAvWriterPlatform fakePlatform = MockStereoAvWriterPlatform();
    StereoAvWriterPlatform.instance = fakePlatform;

    expect(await stereoAvWriterPlugin.getPlatformVersion(), '42');
  });
}
