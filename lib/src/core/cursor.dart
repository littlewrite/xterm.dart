import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/hyperlink.dart';

class CursorStyle {
  int foreground;

  int background;

  int attrs;

  /// Hyperlink currently opened by OSC 8, or null when no link is active.
  ///
  /// Like SGR attributes this is part of the cursor state and is copied into
  /// every cell written until the program closes or replaces the link.
  TerminalHyperlink? hyperlink;

  /// Underline style selected by `SGR 4:x`; 0 means no underline.
  int underlineStyle;

  /// Underline colour selected by `SGR 58`, encoded like foreground/background.
  /// 0 means "use the foreground colour".
  int underlineColor;

  CursorStyle({
    this.foreground = 0,
    this.background = 0,
    this.attrs = 0,
    this.hyperlink,
    this.underlineStyle = 0,
    this.underlineColor = 0,
  });

  static final empty = CursorStyle();

  void setBold() {
    attrs |= CellAttr.bold;
  }

  void setFaint() {
    attrs |= CellAttr.faint;
  }

  void setItalic() {
    attrs |= CellAttr.italic;
  }

  void setUnderline() {
    attrs |= CellAttr.underline;
    // Plain `SGR 4` means a single underline. Without selecting the style here
    // a previous `SGR 4:x` (curly, double, ...) would survive it.
    underlineStyle = CellAttr.underlineStyleSingle;
  }

  /// `SGR 4:x` — selects the underline style and turns underlining on (or off
  /// for style 0).
  void setUnderlineStyle(int style) {
    underlineStyle = style;
    if (style == CellAttr.underlineStyleNone) {
      attrs &= ~CellAttr.underline;
    } else {
      attrs |= CellAttr.underline;
    }
  }

  void setUnderlineColor256(int color) {
    underlineColor = _paletteIndex(color) | CellColor.palette;
  }

  void setUnderlineColorRgb(int r, int g, int b) {
    underlineColor = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  void resetUnderlineColor() {
    underlineColor = 0;
  }

  void setBlink() {
    attrs |= CellAttr.blink;
  }

  void setInverse() {
    attrs |= CellAttr.inverse;
  }

  void setInvisible() {
    attrs |= CellAttr.invisible;
  }

  void setStrikethrough() {
    attrs |= CellAttr.strikethrough;
  }

  void unsetBold() {
    attrs &= ~CellAttr.bold;
  }

  void unsetFaint() {
    attrs &= ~CellAttr.faint;
  }

  void unsetItalic() {
    attrs &= ~CellAttr.italic;
  }

  void unsetUnderline() {
    attrs &= ~CellAttr.underline;
    underlineStyle = CellAttr.underlineStyleNone;
  }

  void unsetBlink() {
    attrs &= ~CellAttr.blink;
  }

  void unsetInverse() {
    attrs &= ~CellAttr.inverse;
  }

  void unsetInvisible() {
    attrs &= ~CellAttr.invisible;
  }

  void unsetStrikethrough() {
    attrs &= ~CellAttr.strikethrough;
  }

  bool get isBold => (attrs & CellAttr.bold) != 0;

  bool get isFaint => (attrs & CellAttr.faint) != 0;

  bool get isItalis => (attrs & CellAttr.italic) != 0;

  bool get isUnderline => (attrs & CellAttr.underline) != 0;

  bool get isBlink => (attrs & CellAttr.blink) != 0;

  bool get isInverse => (attrs & CellAttr.inverse) != 0;

  bool get isInvisible => (attrs & CellAttr.invisible) != 0;

  void setForegroundColor16(int color) {
    foreground = color | CellColor.named;
  }

  void setForegroundColor256(int color) {
    foreground = _paletteIndex(color) | CellColor.palette;
  }

  void setForegroundColorRgb(int r, int g, int b) {
    foreground = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  void resetForegroundColor() {
    foreground = 0; // | CellColor.normal;
  }

  void setBackgroundColor16(int color) {
    background = color | CellColor.named;
  }

  void setBackgroundColor256(int color) {
    background = _paletteIndex(color) | CellColor.palette;
  }

  void setBackgroundColorRgb(int r, int g, int b) {
    background = (r << 16) | (g << 8) | b | CellColor.rgb;
  }

  void resetBackgroundColor() {
    background = 0; // | CellColor.normal;
  }

  void reset() {
    foreground = 0;
    background = 0;
    attrs = 0;
    underlineStyle = 0;
    underlineColor = 0;
    // SGR reset must not close an OSC 8 link: only `OSC 8;;` does.
  }
}

/// Clamps an SGR 256-colour index to the palette the painter actually has.
///
/// The parser accepts arbitrary parameter values; without this, `SGR 38;5;300`
/// stores 300 and the painter indexes a 256-entry list, throwing on every
/// repaint for as long as the cell is on screen.
int _paletteIndex(int color) => color.clamp(0, 255).toInt();

class CursorPosition {
  int x;

  int y;

  CursorPosition(this.x, this.y);
}
