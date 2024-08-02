import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'text_masking_scanner_platform_interface.dart';

/// An implementation of [TextMaskingScannerPlatform] that uses method channels.
class MethodChannelTextMaskingScanner extends TextMaskingScannerPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('text_masking_scanner');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
