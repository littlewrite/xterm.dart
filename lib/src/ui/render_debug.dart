import 'package:flutter/foundation.dart';

/// Opt-in diagnostics for Windows text-mix / scroll / flush issues.
/// Host apps can still override:
/// ```dart
/// TerminalRenderDebug.enabled = true;
/// TerminalRenderDebug.sink = (line) => logger.i(line);
/// ```
class TerminalRenderDebug {
  TerminalRenderDebug._();

  /// When true, emits [debugPrint] and optional [sink] messages.
  static bool enabled = false;

  /// Optional sink (e.g. FaTerm file logger). Prefer this on Windows so logs
  /// can be copied from the log file even if console is noisy.
  static ValueChanged<String>? sink;

  /// Skip repetitive paint lines unless something looks wrong, or every N ms.
  static Duration minPaintLogInterval = const Duration(milliseconds: 80);

  static DateTime? _lastPaintLogAt;
  static int get paintSeq => _paintSeq;
  static int _paintSeq = 0;
  static int _changeSeq = 0;
  static int _flushSeq = 0;

  static void resetCounters() {
    _paintSeq = 0;
    _changeSeq = 0;
    _flushSeq = 0;
    _lastPaintLogAt = null;
  }

  static void log(String message) {
    if (!enabled && sink == null) {
      return;
    }
    final line = '[xterm.render] $message';
    sink?.call(line);
    if (enabled) {
      debugPrint(line);
    }
  }

  static void logChange({
    required bool geometryChanged,
    required bool stickToBottom,
    required int lineCount,
    required int cursorAbsY,
    required double scrollOffset,
    required double maxScrollExtent,
  }) {
    if (!enabled && sink == null) {
      return;
    }
    _changeSeq++;
    final lag = maxScrollExtent - scrollOffset;
    log(
      'change#$_changeSeq geo=$geometryChanged stick=$stickToBottom '
      'lines=$lineCount cursorAbsY=$cursorAbsY '
      'scroll=${scrollOffset.toStringAsFixed(1)} '
      'max=${maxScrollExtent.toStringAsFixed(1)} '
      'lag=${lag.toStringAsFixed(1)}',
    );
  }

  static void logPaint({
    required bool stickToBottom,
    required int firstLine,
    required int lastLine,
    required int cursorAbsY,
    required double scrollOffset,
    required double maxScrollExtent,
    required bool force,
  }) {
    if (!enabled && sink == null) {
      return;
    }
    final now = DateTime.now();
    final lag = maxScrollExtent - scrollOffset;
    final suspicious = !stickToBottom ||
        lag > 1.0 ||
        cursorAbsY < firstLine ||
        cursorAbsY > lastLine;
    if (!force && !suspicious) {
      final last = _lastPaintLogAt;
      if (last != null && now.difference(last) < minPaintLogInterval) {
        return;
      }
    }
    _lastPaintLogAt = now;
    _paintSeq++;
    log(
      'paint#$_paintSeq stick=$stickToBottom '
      'view=[$firstLine,$lastLine] cursorAbsY=$cursorAbsY '
      'scroll=${scrollOffset.toStringAsFixed(1)} '
      'max=${maxScrollExtent.toStringAsFixed(1)} '
      'lag=${lag.toStringAsFixed(1)}'
      '${suspicious ? ' SUSPECT' : ''}',
    );
  }

  static void logFlush({
    required int lineCount,
    required int viewWidth,
    required int viewHeight,
    required int cursorX,
    required int cursorY,
    required int cursorAbsY,
    required int scrollBack,
    required bool currentLineWrapped,
    required bool previousLineWrapped,
  }) {
    if (!enabled && sink == null) {
      return;
    }
    _flushSeq++;
    log(
      'flush#$_flushSeq lines=$lineCount '
      'view=[$viewWidth,$viewHeight] '
      'cursor=[$cursorX,$cursorY] cursorAbsY=$cursorAbsY '
      'scrollBack=$scrollBack wrapCurrent=$currentLineWrapped '
      'wrapPrevious=$previousLineWrapped',
    );
  }
}
