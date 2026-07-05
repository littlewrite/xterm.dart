import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// Terminal 帧调度链路的可选诊断日志。
///
/// 用于排查高频 write 场景下是否存在重复请求 engine frame 的浪费。
class TerminalFrameDebug {
  static bool enabled = _initFromEnv();

  static bool _initFromEnv() {
    if (kReleaseMode) return false;
    final v = Platform.environment['XTERM_FRAME_DEBUG'];
    if (v == null) return false;
    final lower = v.toLowerCase();
    return lower == '1' || lower == 'true' || lower == 'yes';
  }

  static void log(String message) {
    if (!enabled) return;
    // ignore: avoid_print
    print('[xterm-frame] $message');
  }
}
