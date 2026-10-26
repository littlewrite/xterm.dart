import 'package:xterm/src/utils/hash_values.dart';

class CellData {
  CellData({
    required this.foreground,
    required this.background,
    required this.flags,
    required this.content,
    this.underlineStyle = 0,
    this.underlineColor = 0,
  });

  factory CellData.empty() {
    return CellData(
      foreground: 0,
      background: 0,
      flags: 0,
      content: 0,
      underlineStyle: 0,
      underlineColor: 0,
    );
  }

  int foreground;

  int background;

  int flags;

  int content;

  /// Underline style: see [CellAttr.underlineStyleNone] and friends.
  int underlineStyle;

  /// Underline colour, encoded like foreground/background; 0 means "the
  /// foreground colour".
  int underlineColor;

  int getHash() {
    return hashValues(
      foreground,
      background,
      flags,
      content,
      underlineStyle,
      underlineColor,
    );
  }

  @override
  String toString() {
    return 'CellData{foreground: $foreground, background: $background, flags: $flags, content: $content, underlineStyle: $underlineStyle, underlineColor: $underlineColor}';
  }
}

abstract class CellAttr {
  static const bold = 1 << 0;
  static const faint = 1 << 1;
  static const italic = 1 << 2;
  static const underline = 1 << 3;
  static const blink = 1 << 4;
  static const inverse = 1 << 5;
  static const invisible = 1 << 6;
  static const strikethrough = 1 << 7;

  // Underline styles (`SGR 4:x`), stored in [CellData.underlineStyle].
  static const underlineStyleNone = 0;
  static const underlineStyleSingle = 1;
  static const underlineStyleDouble = 2;
  static const underlineStyleCurly = 3;
  static const underlineStyleDotted = 4;
  static const underlineStyleDashed = 5;
}

abstract class CellColor {
  static const valueMask = 0xFFFFFF;

  static const typeShift = 25;
  static const typeMask = 3 << typeShift;

  static const normal = 0 << typeShift;
  static const named = 1 << typeShift;
  static const palette = 2 << typeShift;
  static const rgb = 3 << typeShift;
}

abstract class CellContent {
  static const codepointMask = 0x1fffff;

  static const widthShift = 22;
  // static const widthMask = 3 << widthShift;
}
