import 'package:xterm/src/core/mouse/mode.dart';

abstract class EscapeHandler {
  void writeChar(int char);

  /* SBC */

  void bell();

  void backspaceReturn();

  void tab();

  void lineFeed();

  void carriageReturn();

  void shiftOut();

  void shiftIn();

  void unknownSBC(int char);

  /* ANSI sequence */

  void saveCursor();

  void restoreCursor();

  void index();

  void nextLine();

  void setTapStop();

  void reverseIndex();

  void designateCharset(int charset, int name);

  void unkownEscape(int char);

  /* CSI */

  void repeatPreviousCharacter(int n);

  void setCursor(int x, int y);

  void setCursorX(int x);

  void setCursorY(int y);

  void sendPrimaryDeviceAttributes();

  void clearTabStopUnderCursor();

  void clearAllTabStops();

  void moveCursorX(int offset);

  void moveCursorY(int n);

  void sendSecondaryDeviceAttributes();

  void sendTertiaryDeviceAttributes();

  void sendOperatingStatus();

  void sendCursorPosition();

  /// `CSI ? Ps $ p` —— 报告某个 DEC 私有模式的当前状态。
  void reportDecMode(int mode);

  /// `CSI > Ps q` —— 报告终端名与版本（XTVERSION）。
  void sendXtermVersion();

  /// `CSI 14 t` —— 报告窗口的像素尺寸。
  void sendWindowPixelSize();

  /// `CSI 16 t` —— 报告单个单元格的像素尺寸。
  void sendCellPixelSize();

  void setMargins(int i, [int? bottom]);

  void cursorNextLine(int amount);

  void cursorPrecedingLine(int amount);

  void eraseDisplayBelow();

  void eraseDisplayAbove();

  void eraseDisplay();

  void eraseScrollbackOnly();

  void eraseLineRight();

  void eraseLineLeft();

  void eraseLine();

  void endLine();

  void insertLines(int amount);

  void deleteLines(int amount);

  void deleteChars(int amount);

  void scrollUp(int amount);

  void scrollDown(int amount);

  void eraseChars(int amount);

  void insertBlankChars(int amount);

  void unknownCSI(int finalByte);

  /* Modes */

  void setInsertMode(bool enabled);

  void setLineFeedMode(bool enabled);

  void setUnknownMode(int mode, bool enabled);

  /* DEC Private modes */

  void setCursorKeysMode(bool enabled);

  void setReverseDisplayMode(bool enabled);

  void setOriginMode(bool enabled);

  void setColumnMode(bool enabled);

  void setAutoWrapMode(bool enabled);

  void setAnsiMode(bool enabled);

  void setMouseMode(MouseMode mode);

  void setCursorBlinkMode(bool enabled);

  void setCursorVisibleMode(bool enabled);

  void useAltBuffer();

  void useMainBuffer();

  void clearAltBuffer();

  void setAppKeypadMode(bool enabled);

  void setReportFocusMode(bool enabled);

  void setMouseReportMode(MouseReportMode mode);

  void setAltBufferMouseScrollMode(bool enabled);

  void setBracketedPasteMode(bool enabled);

  void setModifyOtherKeys(int value);

  void setFormatOtherKeys(int value);

  void setUnknownDecMode(int mode, bool enabled);

  void resize(int cols, int rows);

  void sendSize();

  /* Select Graphic Rendition (SGR) */

  void resetCursorStyle();

  void setCursorBold();

  void setCursorFaint();

  void setCursorItalic();

  void setCursorUnderline();

  void setCursorBlink();

  void setCursorInverse();

  void setCursorInvisible();

  void setCursorStrikethrough();

  void unsetCursorBold();

  void unsetCursorFaint();

  void unsetCursorItalic();

  void unsetCursorUnderline();

  void unsetCursorBlink();

  void unsetCursorInverse();

  void unsetCursorInvisible();

  void unsetCursorStrikethrough();

  void setForegroundColor16(int color);

  void setForegroundColor256(int index);

  void setForegroundColorRgb(int r, int g, int b);

  void resetForeground();

  void setBackgroundColor16(int color);

  void setBackgroundColor256(int index);

  void setBackgroundColorRgb(int r, int g, int b);

  void resetBackground();

  void unsupportedStyle(int param);

  /* OSC */

  /// OSC 8 hyperlink. [params] is the raw parameter list (only `id=` is
  /// defined by the spec); an empty [uri] closes the current hyperlink.
  void setHyperlink(String params, String uri);

  void setTitle(String name);

  void setIconName(String name);

  void setClipboard(String selection, String data);

  void unknownOSC(String code, List<String> args);

  void showSearch();

  void closeSearch();
}
