import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'text_masking_scanner_method_channel.dart';

abstract class TextMaskingScannerPlatform extends PlatformInterface {
  /// Constructs a TextMaskingScannerPlatform.
  TextMaskingScannerPlatform() : super(token: _token);

  static final Object _token = Object();

  static TextMaskingScannerPlatform _instance = MethodChannelTextMaskingScanner();

  /// The default instance of [TextMaskingScannerPlatform] to use.
  ///
  /// Defaults to [MethodChannelTextMaskingScanner].
  static TextMaskingScannerPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [TextMaskingScannerPlatform] when
  /// they register themselves.
  static set instance(TextMaskingScannerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
