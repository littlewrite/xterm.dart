import 'dart:async';
import 'dart:convert';
import 'dart:math' show max;

import 'package:flutter/scheduler.dart';
import 'package:xterm/src/base/observable.dart';
import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/cursor.dart';
import 'package:xterm/src/core/escape/emitter.dart';
import 'package:xterm/src/core/escape/handler.dart';
import 'package:xterm/src/core/escape/parser.dart';
import 'package:xterm/src/core/hyperlink.dart';
import 'package:xterm/src/core/hyperlink_text.dart';
import 'package:xterm/src/core/input/handler.dart';
import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/core/mouse/handler.dart';
import 'package:xterm/src/core/mouse/mode.dart';
import 'package:xterm/src/core/platform.dart';
import 'package:xterm/src/core/state.dart';
import 'package:xterm/src/core/tabs.dart';
import 'package:xterm/src/utils/ascii.dart';
import 'package:xterm/src/utils/circular_buffer.dart';
import 'package:xterm/src/ui/search_box.dart';

/// [Terminal] is an interface to interact with command line applications. It
/// translates escape sequences from the application into updates to the
/// [buffer] and events such as [onTitleChange] or [onBell], as well as
/// translating user input into escape sequences that the application can
/// understand.
class Terminal with Observable implements TerminalState, EscapeHandler {
  /// The number of lines that the scrollback buffer can hold. If the buffer
  /// exceeds this size, the lines at the top of the buffer will be removed.
  final int maxLines;

  /// Function that is called when the program requests the terminal to ring
  /// the bell. If not set, the terminal will do nothing.
  void Function()? onBell;

  /// Function that is called when the program requests the terminal to change
  /// the title of the window to [title].
  void Function(String title)? onTitleChange;

  /// Function that is called when the program requests the terminal to change
  /// the icon of the window. [icon] is the name of the icon.
  void Function(String icon)? onIconChange;

  /// Function that is called when the terminal emits data to the underlying
  /// program. This is typically caused by user inputs from [textInput],
  /// [keyInput], [mouseInput], or [paste].
  void Function(String data)? onOutput;

  /// Function that is called when the terminal answers a query made by the
  /// underlying program: device attributes, cursor position, reported size.
  ///
  /// Deliberately separate from [onOutput]: a reply is not user input, so a
  /// caller that routes [onOutput] through input handling (command boundaries,
  /// input method, suggestion triggers) must not see replies there. When unset
  /// the reply falls back to [onOutput], so existing callers keep working.
  void Function(String data)? onTerminalReply;

  void _reply(String data) {
    (onTerminalReply ?? onOutput)?.call(data);
  }

  /// Whether this terminal answers capability probes: DECRPM (`CSI ? Ps $ p`),
  /// XTVERSION (`CSI > Ps q`) and the pixel-size reports (`CSI 14 t` / `16 t`).
  ///
  /// The always-on replies — DA1, CPR, character size — are deliberately not
  /// behind this flag: a terminal that stops answering those reads as broken.
  /// Defaults to on.
  bool answerCapabilityQueries = true;

  /// Name and version reported for XTVERSION, so a program can tell which
  /// terminal it is talking to. Defaults name the emulation core.
  String terminalName = 'xterm.dart';

  String terminalVersion = '0';

  /// Last cell size in pixels reported by layout. Zero means "not measured
  /// yet", and the pixel-size queries go unanswered rather than guessing:
  /// a program sizing images off a wrong number is worse off than one that
  /// knows the terminal did not answer.
  int _cellPixelWidth = 0;

  int _cellPixelHeight = 0;

  bool get _hasCellPixelSize => _cellPixelWidth > 0 && _cellPixelHeight > 0;

  /// Function that is called when the dimensions of the terminal change.
  void Function(int width, int height, int pixelWidth, int pixelHeight)?
      onResize;

  /// The [TerminalInputHandler] used by this terminal. [defaultInputHandler] is
  /// used when not specified. User of this class can provide their own
  /// implementation of [TerminalInputHandler] or extend [defaultInputHandler]
  /// with [CascadeInputHandler].
  TerminalInputHandler? inputHandler;

  TerminalMouseHandler? mouseHandler;

  /// The callback that is called when the terminal receives a unrecognized
  /// escape sequence.
  void Function(String code, List<String> args)? onPrivateOSC;

  /// The callback that is called when the terminal receives an OSC clipboard
  /// request, such as OSC 52.
  void Function(String selection, String data)? onClipboard;

  /// Flag to toggle os specific behaviors.
  final TerminalTargetPlatform platform;

  /// Characters that break selection when double clicking. If not set, the
  /// [Buffer.defaultWordSeparators] will be used.
  final Set<int>? wordSeparators;

  /// Whether `CSI 8 ; height ; width t` may resize this terminal.
  ///
  /// The sequence asks for a window resize, and only a host that owns its
  /// window can satisfy it. Defaults to `false`, which is correct for a
  /// terminal embedded in a layout it does not own (a Flutter widget, for
  /// example): resizing the grid while the viewport stays the same draws
  /// everything at the wrong scale until the next layout pass. Only a host
  /// that really owns its window should opt in.
  final bool allowCsiWindowResize;

  Terminal({
    this.maxLines = 1000,
    this.onBell,
    this.onTitleChange,
    this.onIconChange,
    this.onOutput,
    this.onTerminalReply,
    this.onResize,
    this.platform = TerminalTargetPlatform.unknown,
    this.inputHandler = defaultInputHandler,
    this.mouseHandler = defaultMouseHandler,
    this.onPrivateOSC,
    this.onClipboard,
    this.reflowEnabled = true,
    this.allowCsiWindowResize = false,
    this.wordSeparators,
  });

  late final _parser = EscapeParser(
    this,
    allowCsiWindowResize: allowCsiWindowResize,
  );

  final _emitter = const EscapeEmitter();

  late var _buffer = _mainBuffer;

  late final _mainBuffer = Buffer(
    this,
    maxLines: maxLines,
    isAltBuffer: false,
    wordSeparators: wordSeparators,
  );

  late final _altBuffer = Buffer(
    this,
    maxLines: maxLines,
    isAltBuffer: true,
    wordSeparators: wordSeparators,
  );

  final _tabStops = TabStops();

  /// The last character written to the buffer. Used to implement some escape
  /// sequences that repeat the last character.
  var _precedingCodepoint = 0;

  /* TerminalState */

  int _viewWidth = 80;

  int _viewHeight = 24;

  final _cursorStyle = CursorStyle();

  bool _insertMode = false;

  bool _lineFeedMode = false;

  bool _cursorKeysMode = false;

  bool _reverseDisplayMode = false;

  bool _originMode = false;

  bool _autoWrapMode = true;

  bool _ansiMode = true;

  MouseMode _mouseMode = MouseMode.none;

  MouseReportMode _mouseReportMode = MouseReportMode.normal;

  bool _cursorBlinkMode = false;

  bool _cursorVisibleMode = true;

  bool _appKeypadMode = false;

  bool _reportFocusMode = false;

  bool _altBufferMouseScrollMode = false;

  bool _bracketedPasteMode = false;

  int _modifyOtherKeys = 0;

  int _formatOtherKeys = 0;

  // 标记当前批次是否已经产生了需要通知 UI 的变更。
  bool _hasPendingFlush = false;
  // 避免同一帧内重复注册刷新回调，确保一帧最多触发一次通知。
  bool _frameFlushScheduled = false;
  // 支持嵌套批量更新，只有最外层 write 结束后才安排刷新。
  int _updateBatchDepth = 0;
  /* State getters */

  /// Number of cells in a terminal row.
  @override
  int get viewWidth => _viewWidth;

  /// Number of rows in this terminal.
  @override
  int get viewHeight => _viewHeight;

  @override
  CursorStyle get cursor => _cursorStyle;

  @override
  bool get insertMode => _insertMode;

  @override
  bool get lineFeedMode => _lineFeedMode;

  @override
  bool get cursorKeysMode => _cursorKeysMode;

  @override
  bool get reverseDisplayMode => _reverseDisplayMode;

  @override
  bool get originMode => _originMode;

  @override
  bool get autoWrapMode => _autoWrapMode;

  @override
  bool get ansiMode => _ansiMode;

  @override
  MouseMode get mouseMode => _mouseMode;

  @override
  MouseReportMode get mouseReportMode => _mouseReportMode;

  @override
  bool get cursorBlinkMode => _cursorBlinkMode;

  @override
  bool get cursorVisibleMode => _cursorVisibleMode;

  @override
  bool get appKeypadMode => _appKeypadMode;

  @override
  bool get reportFocusMode => _reportFocusMode;

  @override
  bool get altBufferMouseScrollMode => _altBufferMouseScrollMode;

  @override
  bool get bracketedPasteMode => _bracketedPasteMode;

  @override
  int get modifyOtherKeys => _modifyOtherKeys;

  @override
  int get formatOtherKeys => _formatOtherKeys;

  /// Current active buffer of the terminal. This is initially [mainBuffer] and
  /// can be switched back and forth from [altBuffer] to [mainBuffer] when
  /// the underlying program requests it.
  Buffer get buffer => _buffer;

  Buffer get mainBuffer => _mainBuffer;

  Buffer get altBuffer => _altBuffer;

  bool get isUsingAltBuffer => _buffer == _altBuffer;

  /// Lines of the active buffer.
  IndexAwareCircularBuffer<BufferLine> get lines => _buffer.lines;

  /// Whether the terminal performs reflow when the viewport size changes or
  /// simply truncates lines. true by default.
  @override
  bool reflowEnabled;

  /// Writes the data from the underlying program to the terminal. Calling this
  /// updates the states of the terminal and emits events such as [onBell] or
  /// [onTitleChange] when the escape sequences in [data] request it.
  void write(String data) {
    // 一次 write 过程中可能连续改动 buffer、cursor 和模式状态，
    // 这里先合并这些变更，避免解析过程中频繁 notifyListeners。
    _beginUpdateBatch();
    try {
      _parser.write(data);
    } finally {
      _endUpdateBatch();
    }
  }

  /// Sends a key event to the underlying program.
  ///
  /// See also:
  /// - [charInput]
  /// - [textInput]
  /// - [paste]
  bool keyInput(
    TerminalKey key, {
    String? character,
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    final output = inputHandler?.call(
      TerminalKeyboardEvent(
        key: key,
        character: character,
        shift: shift,
        alt: alt,
        ctrl: ctrl,
        state: this,
        altBuffer: isUsingAltBuffer,
        platform: platform,
      ),
    );

    if (output != null) {
      onOutput?.call(output);
      return true;
    }

    return false;
  }

  /// Similary to [keyInput], but takes a character as input instead of a
  /// [TerminalKey].
  ///
  /// See also:
  /// - [keyInput]
  /// - [textInput]
  /// - [paste]
  bool charInput(int charCode, {bool alt = false, bool ctrl = false}) {
    if (ctrl) {
      // a(97) ~ z(122)
      if (charCode >= Ascii.a && charCode <= Ascii.z) {
        final output = charCode - Ascii.a + 1;
        onOutput?.call(String.fromCharCode(output));
        return true;
      }

      // [(91) ~ _(95)
      if (charCode >= Ascii.openBracket && charCode <= Ascii.underscore) {
        final output = charCode - Ascii.openBracket + 27;
        onOutput?.call(String.fromCharCode(output));
        return true;
      }
    }

    if (alt && platform != TerminalTargetPlatform.macos) {
      if (charCode >= Ascii.a && charCode <= Ascii.z) {
        final code = charCode - Ascii.a + 65;
        final input = [0x1b, code];
        onOutput?.call(String.fromCharCodes(input));
        return true;
      }
    }

    return false;
  }

  /// Sends regular text input to the underlying program.
  ///
  /// See also:
  /// - [keyInput]
  /// - [charInput]
  /// - [paste]
  void textInput(String text) {
    onOutput?.call(text);
  }

  /// Similar to [textInput], except that when the program tells the terminal
  /// that it supports [bracketedPasteMode], the text is wrapped in escape
  /// sequences to indicate that it is a paste operation. Prefer this method
  /// over [textInput] when pasting text.
  ///
  /// See also:
  /// - [textInput]
  void paste(String text) {
    if (_bracketedPasteMode) {
      onOutput?.call(_emitter.bracketedPaste(text));
    } else {
      textInput(text);
    }
  }

  // Handle a mouse event and return true if it was handled.
  bool mouseInput(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    CellOffset position, {
    bool motion = false,
  }) {
    final output = mouseHandler?.call(
      TerminalMouseEvent(
        button: button,
        buttonState: buttonState,
        position: position,
        state: this,
        platform: platform,
        motion: motion,
      ),
    );
    if (output != null) {
      onOutput?.call(output);
      return true;
    }
    return false;
  }

  /// Resize the terminal screen. [newWidth] and [newHeight] should be greater
  /// than 0. Text reflow is currently not implemented and will be avaliable in
  /// the future.
  ///
  /// [cellPixelWidth] / [cellPixelHeight] are the size of a single **cell** in
  /// device pixels — the view's logical cell size times `devicePixelRatio`, so
  /// Retina and Windows 125% / 150% scaling report real pixels. They are also
  /// what the pixel-size queries (`CSI 14 t` / `CSI 16 t`) answer, and what
  /// `onResize` receives as its last two arguments.
  @override
  void resize(
    int newWidth,
    int newHeight, [
    int? cellPixelWidth,
    int? cellPixelHeight,
  ]) {
    newWidth = max(newWidth, 1);
    newHeight = max(newHeight, 1);

    if (cellPixelWidth != null &&
        cellPixelHeight != null &&
        cellPixelWidth > 0 &&
        cellPixelHeight > 0) {
      _cellPixelWidth = cellPixelWidth;
      _cellPixelHeight = cellPixelHeight;
    }

    final sizeChanged = newWidth != _viewWidth || newHeight != _viewHeight;

    onResize?.call(
      newWidth,
      newHeight,
      cellPixelWidth ?? 0,
      cellPixelHeight ?? 0,
    );

    //we need to resize both buffers so that they are ready when we switch between them
    _altBuffer.resize(_viewWidth, _viewHeight, newWidth, newHeight);
    _mainBuffer.resize(_viewWidth, _viewHeight, newWidth, newHeight);

    _viewWidth = newWidth;
    _viewHeight = newHeight;

    if (buffer == _altBuffer) {
      buffer.clearScrollback();
    }

    _altBuffer.resetVerticalMargins();
    _mainBuffer.resetVerticalMargins();

    // 重排会把文本在物理行之间搬来搬去，任何持有行列坐标的监听者（比如 find 的
    // 匹配表）都必须重算。走和 `write` 同一套批量刷新：resize 常常发生在
    // RenderTerminal.performLayout 里，直接 notifyListeners 会让监听者在 layout
    // 中途跑，这里统一推迟到下一帧开始。
    if (sizeChanged) {
      _markPendingFlush();
    }
  }

  @override
  String toString() {
    return 'Terminal(#$hashCode, $_viewWidth x $_viewHeight, ${_buffer.height} lines)';
  }

  /* Handlers */

  @override
  void writeChar(int char) {
    _precedingCodepoint = char;
    _buffer.writeChar(char);
  }

  /* SBC */

  @override
  void bell() {
    onBell?.call();
  }

  @override
  void backspaceReturn() {
    _buffer.moveCursorX(-1);
  }

  @override
  void tab() {
    final nextStop = _tabStops.find(_buffer.cursorX + 1, _viewWidth);

    if (nextStop != null) {
      _buffer.setCursorX(nextStop);
    } else {
      _buffer.setCursorX(_viewWidth);
      _buffer.cursorGoForward(); // Enter pending-wrap state
    }
  }

  @override
  void lineFeed() {
    _buffer.lineFeed();
  }

  @override
  void carriageReturn() {
    _buffer.setCursorX(0);
  }

  @override
  void shiftOut() {
    _buffer.charset.use(1);
  }

  @override
  void shiftIn() {
    _buffer.charset.use(0);
  }

  @override
  void unknownSBC(int char) {
    // no-op
  }

  /* ANSI sequence */

  @override
  void saveCursor() {
    _buffer.saveCursor();
  }

  @override
  void restoreCursor() {
    _buffer.restoreCursor();
  }

  @override
  void index() {
    // Explicit IND breaks soft-wrap chain (aligns with Windows Terminal's
    // _DoLineFeed which calls SetWrapForced(false) for non-auto-wrap feeds).
    _buffer.currentLine.isWrapped = false;
    _buffer.index();
  }

  @override
  void nextLine() {
    // Explicit CNL/NEL breaks soft-wrap chain (aligns with Windows Terminal's
    // _DoLineFeed which calls SetWrapForced(false) for non-auto-wrap feeds).
    _buffer.currentLine.isWrapped = false;
    _buffer.index();
    _buffer.setCursorX(0);
  }

  @override
  void setTapStop() {
    _tabStops.isSetAt(_buffer.cursorX);
  }

  @override
  void reverseIndex() {
    _buffer.reverseIndex();
  }

  @override
  void designateCharset(int charset, int name) {
    _buffer.charset.designate(charset, name);
  }

  @override
  void unkownEscape(int char) {
    // no-op
  }

  /* CSI */

  @override
  void repeatPreviousCharacter(int count) {
    if (_precedingCodepoint == 0) {
      return;
    }

    for (var i = 0; i < count; i++) {
      writeChar(_precedingCodepoint);
    }
  }

  @override
  void setCursor(int x, int y) {
    _buffer.setCursor(x, y);
  }

  @override
  void setCursorX(int x) {
    _buffer.setCursorX(x);
  }

  @override
  void setCursorY(int y) {
    _buffer.setCursorY(y);
  }

  @override
  void moveCursorX(int offset) {
    _buffer.moveCursorX(offset);
  }

  @override
  void moveCursorY(int n) {
    _buffer.moveCursorY(n);
  }

  @override
  void clearTabStopUnderCursor() {
    _tabStops.clearAt(_buffer.cursorX);
  }

  @override
  void clearAllTabStops() {
    _tabStops.clearAll();
  }

  @override
  void sendPrimaryDeviceAttributes() {
    _reply(_emitter.primaryDeviceAttributes());
  }

  @override
  void sendSecondaryDeviceAttributes() {
    _reply(_emitter.secondaryDeviceAttributes());
  }

  @override
  void sendTertiaryDeviceAttributes() {
    _reply(_emitter.tertiaryDeviceAttributes());
  }

  @override
  void sendOperatingStatus() {
    _reply(_emitter.operatingStatus());
  }

  @override
  void sendCursorPosition() {
    _reply(_emitter.cursorPosition(_buffer.cursorX, _buffer.cursorY));
  }

  @override
  void reportDecMode(int mode) {
    if (!answerCapabilityQueries) {
      return;
    }
    _reply(_emitter.modeReport(mode, _decModeReportValue(mode)));
  }

  /// DECRPM 的状态码：0 未识别 / 1 已置位 / 2 已复位。
  ///
  /// 只回**能唯一判断**的模式：没实现的回 0，实现了但同一份状态被多个模式共用
  /// 的也回 0（1000 与 1001 都落到 `MouseMode.upDownScroll`，事后分不出是哪一个
  /// 被置位 —— 乱回 1 会让程序以为另一个模式也开着）。报成"已复位"更糟：程序
  /// 会以为发条 `CSI ? Ps h` 就能打开，而本终端根本不认这个模式。
  int _decModeReportValue(int mode) {
    switch (mode) {
      case 7:
        return autoWrapMode ? 1 : 2;
      case 9:
        return _mouseMode == MouseMode.clickOnly ? 1 : 2;
      case 1002:
        return _mouseMode == MouseMode.upDownScrollDrag ? 1 : 2;
      case 1003:
        return _mouseMode == MouseMode.upDownScrollMove ? 1 : 2;
      case 1004:
        return _reportFocusMode ? 1 : 2;
      case 1005:
        return _mouseReportMode == MouseReportMode.utf ? 1 : 2;
      case 1006:
        return _mouseReportMode == MouseReportMode.sgr ? 1 : 2;
      case 1015:
        return _mouseReportMode == MouseReportMode.urxvt ? 1 : 2;
      case 2004:
        return _bracketedPasteMode ? 1 : 2;
      default:
        return 0;
    }
  }

  @override
  void sendXtermVersion() {
    if (!answerCapabilityQueries) {
      return;
    }
    _reply(_emitter.xtermVersion(terminalName, terminalVersion));
  }

  @override
  void sendWindowPixelSize() {
    if (!answerCapabilityQueries || !_hasCellPixelSize) {
      return;
    }
    _reply(
      _emitter.windowPixelSize(
        viewHeight * _cellPixelHeight,
        viewWidth * _cellPixelWidth,
      ),
    );
  }

  @override
  void sendCellPixelSize() {
    if (!answerCapabilityQueries || !_hasCellPixelSize) {
      return;
    }
    _reply(_emitter.cellPixelSize(_cellPixelHeight, _cellPixelWidth));
  }

  @override
  void setMargins(int top, [int? bottom]) {
    _buffer.setVerticalMargins(top, bottom ?? viewHeight - 1);
  }

  @override
  void cursorNextLine(int amount) {
    _buffer.moveCursorY(amount);
    _buffer.setCursorX(0);
  }

  @override
  void cursorPrecedingLine(int amount) {
    _buffer.moveCursorY(-amount);
    _buffer.setCursorX(0);
  }

  @override
  void eraseDisplayBelow() {
    _buffer.eraseDisplayFromCursor();
  }

  @override
  void eraseDisplayAbove() {
    _buffer.eraseDisplayToCursor();
  }

  @override
  void eraseDisplay() {
    _buffer.eraseDisplay();
  }

  @override
  void eraseScrollbackOnly() {
    _buffer.clearScrollback();
  }

  @override
  void eraseLineRight() {
    _buffer.eraseLineFromCursor();
  }

  @override
  void eraseLineLeft() {
    _buffer.eraseLineToCursor();
  }

  @override
  void eraseLine() {
    _buffer.eraseLine();
  }

  @override
  void endLine() {
    _buffer.endLine();
  }

  @override
  void insertLines(int amount) {
    _buffer.insertLines(amount);
  }

  @override
  void deleteLines(int amount) {
    _buffer.deleteLines(amount);
  }

  @override
  void deleteChars(int amount) {
    _buffer.deleteChars(amount);
  }

  @override
  void scrollUp(int amount) {
    _buffer.scrollUp(amount);
  }

  @override
  void scrollDown(int amount) {
    _buffer.scrollDown(amount);
  }

  @override
  void eraseChars(int amount) {
    _buffer.eraseChars(amount);
  }

  @override
  void insertBlankChars(int amount) {
    _buffer.insertBlankChars(amount);
  }

  @override
  void sendSize() {
    _reply(_emitter.size(viewHeight, viewWidth));
  }

  @override
  void unknownCSI(int finalByte) {
    // no-op
  }

  /* Modes */

  @override
  void setInsertMode(bool enabled) {
    _insertMode = enabled;
  }

  @override
  void setLineFeedMode(bool enabled) {
    _lineFeedMode = enabled;
  }

  @override
  void setUnknownMode(int mode, bool enabled) {
    // no-op
  }

  /* DEC Private modes */

  @override
  void setCursorKeysMode(bool enabled) {
    _cursorKeysMode = enabled;
  }

  @override
  void setReverseDisplayMode(bool enabled) {
    _reverseDisplayMode = enabled;
  }

  @override
  void setOriginMode(bool enabled) {
    _originMode = enabled;
  }

  @override
  void setColumnMode(bool enabled) {
    // no-op
  }

  @override
  void setAutoWrapMode(bool enabled) {
    _autoWrapMode = enabled;
  }

  @override
  void setAnsiMode(bool enabled) {
    _ansiMode = enabled;
  }

  @override
  void setMouseMode(MouseMode mode) {
    _mouseMode = mode;
  }

  @override
  void setCursorBlinkMode(bool enabled) {
    _cursorBlinkMode = enabled;
  }

  @override
  void setCursorVisibleMode(bool enabled) {
    _cursorVisibleMode = enabled;
  }

  @override
  void useAltBuffer() {
    _buffer = _altBuffer;
  }

  @override
  void useMainBuffer() {
    _buffer = _mainBuffer;
  }

  @override
  void clearAltBuffer() {
    _altBuffer.clear();
  }

  @override
  void setAppKeypadMode(bool enabled) {
    _appKeypadMode = enabled;
  }

  @override
  void setReportFocusMode(bool enabled) {
    _reportFocusMode = enabled;
  }

  @override
  void setMouseReportMode(MouseReportMode mode) {
    _mouseReportMode = mode;
  }

  @override
  void setAltBufferMouseScrollMode(bool enabled) {
    _altBufferMouseScrollMode = enabled;
  }

  @override
  void setBracketedPasteMode(bool enabled) {
    _bracketedPasteMode = enabled;
  }

  @override
  void setModifyOtherKeys(int value) {
    _modifyOtherKeys = value.clamp(0, 3);
  }

  @override
  void setFormatOtherKeys(int value) {
    _formatOtherKeys = value.clamp(0, 1);
  }

  @override
  void setUnknownDecMode(int mode, bool enabled) {
    // no-op
  }

  /* Select Graphic Rendition (SGR) */

  @override
  void resetCursorStyle() {
    _cursorStyle.reset();
  }

  @override
  void setCursorBold() {
    _cursorStyle.setBold();
  }

  @override
  void setCursorFaint() {
    _cursorStyle.setFaint();
  }

  @override
  void setCursorItalic() {
    _cursorStyle.setItalic();
  }

  @override
  void setCursorUnderline() {
    _cursorStyle.setUnderline();
  }

  @override
  void setCursorBlink() {
    _cursorStyle.setBlink();
  }

  @override
  void setCursorInverse() {
    _cursorStyle.setInverse();
  }

  @override
  void setCursorInvisible() {
    _cursorStyle.setInvisible();
  }

  @override
  void setCursorStrikethrough() {
    _cursorStyle.setStrikethrough();
  }

  @override
  void unsetCursorBold() {
    _cursorStyle.unsetBold();
  }

  @override
  void unsetCursorFaint() {
    _cursorStyle.unsetFaint();
  }

  @override
  void unsetCursorItalic() {
    _cursorStyle.unsetItalic();
  }

  @override
  void unsetCursorUnderline() {
    _cursorStyle.unsetUnderline();
  }

  @override
  void unsetCursorBlink() {
    _cursorStyle.unsetBlink();
  }

  @override
  void unsetCursorInverse() {
    _cursorStyle.unsetInverse();
  }

  @override
  void unsetCursorInvisible() {
    _cursorStyle.unsetInvisible();
  }

  @override
  void unsetCursorStrikethrough() {
    _cursorStyle.unsetStrikethrough();
  }

  @override
  void setForegroundColor16(int color) {
    _cursorStyle.setForegroundColor16(color);
  }

  @override
  void setForegroundColor256(int index) {
    _cursorStyle.setForegroundColor256(index);
  }

  @override
  void setForegroundColorRgb(int r, int g, int b) {
    _cursorStyle.setForegroundColorRgb(r, g, b);
  }

  @override
  void resetForeground() {
    _cursorStyle.resetForegroundColor();
  }

  @override
  void setBackgroundColor16(int color) {
    _cursorStyle.setBackgroundColor16(color);
  }

  @override
  void setBackgroundColor256(int index) {
    _cursorStyle.setBackgroundColor256(index);
  }

  @override
  void setBackgroundColorRgb(int r, int g, int b) {
    _cursorStyle.setBackgroundColorRgb(r, g, b);
  }

  @override
  void resetBackground() {
    _cursorStyle.resetBackgroundColor();
  }

  @override
  void unsupportedStyle(int param) {
    // no-op
  }

  /* OSC */

  /// Hyperlinks opened with `id=`, kept so later rows can reuse the same
  /// instance and stay one logical link.
  ///
  /// Bounded and evicted oldest-first: entries are just a dedupe aid, so losing
  /// one only costs a fresh object, never correctness.
  final _hyperlinks = <String, TerminalHyperlink>{};

  static const _maxCachedHyperlinks = 128;

  /// Upper bound for an accepted OSC 8 URI. Longer payloads are dropped
  /// instead of being attached to cells or kept in the id cache.
  static const _maxHyperlinkUriLength = 8192;

  @override
  void setHyperlink(String params, String uri) {
    if (uri.isEmpty || uri.length > _maxHyperlinkUriLength) {
      _cursorStyle.hyperlink = null;
      return;
    }
    final id = _parseHyperlinkId(params);
    // Links without an id are never reused by the terminal, so they skip the
    // cache entirely — matching xterm's "registered a single time" rule.
    if (id == null) {
      final link = TerminalHyperlink(uri: uri);
      _cursorStyle.hyperlink = link;
      return;
    }
    final key = '$id\u0000$uri';
    var link = _hyperlinks.remove(key);
    if (link == null) {
      link = TerminalHyperlink(uri: uri, id: id);
      if (_hyperlinks.length >= _maxCachedHyperlinks) {
        _hyperlinks.remove(_hyperlinks.keys.first);
      }
    }
    _hyperlinks[key] = link;
    _cursorStyle.hyperlink = link;
  }

  static String? _parseHyperlinkId(String params) {
    if (params.isEmpty) {
      return null;
    }
    for (final part in params.split(':')) {
      if (part.startsWith('id=')) {
        final id = part.substring(3);
        return id.isEmpty ? null : id;
      }
    }
    return null;
  }

  /// Hyperlink attached to [offset] in the active buffer, or null.
  TerminalHyperlink? hyperlinkAt(CellOffset offset) {
    final lines = _buffer.lines;
    if (offset.y < 0 || offset.y >= lines.length) {
      return null;
    }
    final line = lines[offset.y];
    final explicit = line.getLink(offset.x);
    if (explicit != null) {
      return explicit;
    }
    // Plain-text URLs (dev servers, test runners) are detected on demand: no
    // per-cell storage, so nothing can go stale on scroll/reflow/overwrite.
    final match = terminalUrlMatchAtColumn(
      line,
      offset.x,
      matches: _plainUrlsIn(line),
    );
    return match == null ? null : TerminalHyperlink(uri: match.uri);
  }

  BufferLine? _plainUrlCacheLine;
  int _plainUrlCacheRevision = -1;
  List<TerminalUrlMatch> _plainUrlCache = const [];

  /// One-line cache so moving the pointer inside the same URL does not rescan
  /// the row for every hover event.
  List<TerminalUrlMatch> _plainUrlsIn(BufferLine line) {
    if (identical(line, _plainUrlCacheLine) &&
        line.revision == _plainUrlCacheRevision) {
      return _plainUrlCache;
    }
    final matches = findTerminalUrlsInLine(line);
    _plainUrlCacheLine = line;
    _plainUrlCacheRevision = line.revision;
    _plainUrlCache = matches;
    return matches;
  }

  @override
  void setTitle(String name) {
    onTitleChange?.call(name);
  }

  @override
  void setIconName(String name) {
    onIconChange?.call(name);
  }

  @override
  void setClipboard(String selection, String data) {
    onClipboard?.call(selection, data);
  }

  @override
  void unknownOSC(String ps, List<String> pt) {
    onPrivateOSC?.call(ps, pt);
  }

  static String? decodeOsc52Payload(String data) {
    if (data.isEmpty || data == '?') {
      return null;
    }

    try {
      final normalized = base64.normalize(data);
      return utf8.decode(base64.decode(normalized));
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _hasPendingFlush = false;
    _frameFlushScheduled = false;
  }

  /// search widget show callback
  void Function()? onSearch;

  /// search widget close callback
  void Function()? onCloseSearch;

  /// custom search widget
  TerminalSearchDelegate? customSearchDelegate;

  /// trigger search widget show
  @override
  void showSearch() {
    // 单槽回调：View 重建竞态下可能短暂为 null。调用方应能容忍 no-op，
    // 但活跃 TerminalView 会在 build/didUpdateWidget 里重新声明所有权。
    onSearch?.call();
  }

  /// trigger search widget close
  @override
  void closeSearch() {
    onCloseSearch?.call();
  }

  void _beginUpdateBatch() {
    _updateBatchDepth++;
  }

  void _endUpdateBatch() {
    if (_updateBatchDepth == 0) {
      return;
    }

    _updateBatchDepth--;

    if (_updateBatchDepth == 0) {
      // 只有最外层批次结束时才真正安排一次刷新。
      _markPendingFlush();
    }
  }

  void _markPendingFlush() {
    _hasPendingFlush = true;

    if (_frameFlushScheduled) {
      // 当前帧已经安排过刷新，后续变更直接并入本次 flush。
      return;
    }

    _frameFlushScheduled = true;

    if (_scheduleFrameFlush()) {
      return;
    }

    // 某些非 Flutter 帧环境下可能拿不到 frame callback，退化到微任务中刷新。
    scheduleMicrotask(_flushPendingListeners);
  }

  bool _scheduleFrameFlush() {
    try {
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        _flushPendingListeners();
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  void _flushPendingListeners() {
    if (!_frameFlushScheduled) {
      return;
    }

    _frameFlushScheduled = false;

    if (!_hasPendingFlush) {
      return;
    }

    _hasPendingFlush = false;
    // 真正的 UI 通知只在这里发出，保证批量更新最终只触发一次监听回调。
    notifyListeners();
  }
}
