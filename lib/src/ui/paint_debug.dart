import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// 渲染管线的可选诊断日志。
///
/// 用于排查"内容已写入 buffer 但画面没及时更新"类问题。默认关闭，零开销。
///
/// **开启方式（三选一）**：
/// 1. 运行时环境变量（推荐，无需重编译）：
///    `XTERM_PAINT_DEBUG=true flutter run`（macOS/Linux）
///    `$env:XTERM_PAINT_DEBUG="true"; flutter run`（Windows PowerShell）
/// 2. 代码内开启：`TerminalPaintDebug.enabled = true;`
/// 3. 仅 debug 构建自动开启：见下方 `kDebugMode` 注释。
///
/// 注意：`enabled` 在首次访问时从环境变量读取一次（lazyInit），之后运行时改
/// 环境变量无效——需重启 app。也可直接给 `enabled` 赋值覆盖。
///
/// 日志覆盖链路：
///   terminal.write → _onTerminalChange → markNeedsLayout/Paint →
///   performLayout (stick-to-bottom) → paint (全画/scroll/增量)
///
/// 输出示例（开启后）：
///   [xterm-paint] onTerminalChange geo=true lines=24
///   [xterm-paint]   performLayout scrollOff 0→18 stick=true
///   [xterm-paint]   paint mode=1 painted={20,19} effFirst=4 effLast=20
class TerminalPaintDebug {
  /// 是否启用 paint 链路日志。
  /// 默认在首次访问时从环境变量 `XTERM_PAINT_DEBUG` 读取（不区分大小写，
  /// 接受 "1"/"true"/"yes"）。运行时可直接赋值覆盖。
  static bool enabled = _initFromEnv();

  static bool _initFromEnv() {
    if (kReleaseMode) return false;
    final v = Platform.environment['XTERM_PAINT_DEBUG'];
    if (v == null) return false;
    final lower = v.toLowerCase();
    return lower == '1' || lower == 'true' || lower == 'yes';
  }

  static void log(String message) {
    if (!enabled) return;
    // ignore: avoid_print
    print('[xterm-paint] $message');
  }
}
