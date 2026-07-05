import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:xterm/src/ui/char_metrics.dart';
import 'package:xterm/src/ui/custom_glyphs.dart';
import 'package:xterm/src/ui/palette_builder.dart';
import 'package:xterm/src/ui/paragraph_cache.dart';
import 'package:xterm/xterm.dart';

/// Encapsulates the logic for painting various terminal elements.
class TerminalPainter {
  TerminalPainter({
    required TerminalTheme theme,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    double devicePixelRatio = 1.0,
  })  : _textStyle = textStyle,
        _theme = theme,
        _textScaler = textScaler,
        _devicePixelRatio = devicePixelRatio;

  /// A lookup table from terminal colors to Flutter colors.
  late var _colorPalette = PaletteBuilder(_theme).build();

  /// Size of each character in the terminal.
  late var _cellSize = _measureCharSize();

  /// The cached for cells in the terminal. Should be cleared when the same
  /// cell no longer produces the same visual output. For example, when
  /// [_textStyle] is changed, or when the system font changes.
  final _paragraphCache = ParagraphCache(10240);

  /// 复用的 Paint 对象，避免每帧每个 cell 都分配新 Paint。
  /// Paint 是可变对象，绘制调用会立即提交到 canvas，所以在顺序绘制中
  /// 跨帧/跨 cell 复用是安全的——只需在每次绘制前设置 color。
  final _cellBackgroundPaint = Paint()..isAntiAlias = false;

  /// 高亮用的 Paint（需要 strokeWidth = 1）。
  final _highlightPaint = Paint()
    ..isAntiAlias = false
    ..strokeWidth = 1;

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
  }

  double get devicePixelRatio => _devicePixelRatio;
  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
  }

  Size _measureCharSize() {
    return CharMetricsCache.instance.measure(_textStyle, _textScaler);
  }

  /// The size of each character in the terminal.
  Size get cellSize => _cellSize;

  /// When the set of font available to the system changes, call this method to
  /// clear cached state related to font rendering.
  void clearFontCache() {
    CharMetricsCache.instance.clear();
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
  }

  /// Paints the cursor based on the current cursor type.
  void paintCursor(
    Canvas canvas,
    Offset offset, {
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    paintCursorShape(
      canvas,
      offset,
      color: _theme.cursor,
      cellSize: _cellSize,
      cursorType: cursorType,
      hasFocus: hasFocus,
    );
  }

  static void paintCursorShape(
    Canvas canvas,
    Offset offset, {
    required Color color,
    required Size cellSize,
    required TerminalCursorType cursorType,
    bool hasFocus = true,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;

    if (!hasFocus) {
      paint.style = PaintingStyle.stroke;
      canvas.drawRect(offset & cellSize, paint);
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.block:
        paint.style = PaintingStyle.fill;
        canvas.drawRect(offset & cellSize, paint);
        return;
      case TerminalCursorType.underline:
        return canvas.drawLine(
          Offset(offset.dx, offset.dy + cellSize.height - 1),
          Offset(
            offset.dx + cellSize.width,
            offset.dy + cellSize.height - 1,
          ),
          paint,
        );
      case TerminalCursorType.verticalBar:
        return canvas.drawLine(
          Offset(offset.dx, offset.dy),
          Offset(offset.dx, offset.dy + cellSize.height),
          paint,
        );
    }
  }

  @pragma('vm:prefer-inline')
  void paintHighlight(Canvas canvas, Offset offset, int length, Color color) {
    final endOffset = offset.translate(
      length * _cellSize.width,
      _cellSize.height,
    );

    final paint = _highlightPaint..color = color;
    canvas.drawRect(Rect.fromPoints(offset, endOffset), paint);
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  void paintLine(Canvas canvas, Offset offset, BufferLine line) {
    _paintLineCells(canvas, offset, line);
  }

  void paintLineBackgrounds(Canvas canvas, Offset offset, BufferLine line) {
    _paintLineCells(
      canvas,
      offset,
      line,
      paintForeground: false,
    );
  }

  void paintLineForegrounds(Canvas canvas, Offset offset, BufferLine line) {
    _paintLineCells(
      canvas,
      offset,
      line,
      paintBackground: false,
    );
  }

  void _paintLineCells(
    Canvas canvas,
    Offset offset,
    BufferLine line, {
    bool paintBackground = true,
    bool paintForeground = true,
  }) {
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);

      if (paintBackground) {
        paintCellBackground(canvas, cellOffset, cellData);
      }
      if (paintForeground) {
        paintCellForeground(canvas, cellOffset, cellData);
      }

      if (charWidth == 2) {
        i++;
      }
    }
  }

  @pragma('vm:prefer-inline')
  void paintCell(Canvas canvas, Offset offset, CellData cellData) {
    paintCellBackground(canvas, offset, cellData);
    paintCellForeground(canvas, offset, cellData);
  }

  @pragma('vm:prefer-inline')
  void paintSelectedCell(Canvas canvas, Offset offset, CellData cellData) {
    paintHighlight(
      canvas,
      offset,
      cellData.content >> CellContent.widthShift == 2 ? 2 : 1,
      _theme.selection,
    );
    paintCellForeground(canvas, offset, cellData);
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(
    Canvas canvas,
    Offset offset,
    CellData cellData,
  ) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;

    final glyphPaint = customGlyphPaint(cellData);
    if (glyphPaint != null) {
      TerminalCustomGlyphRasterizer(
        canvas: canvas,
        offset: offset,
        cellSize: _cellSize,
        color: glyphPaint.color,
        fontSize: _textScaler.scale(_textStyle.fontSize),
        devicePixelRatio: _devicePixelRatio,
      ).paint(glyphPaint.glyph);
      return;
    }

    final cacheKey = cellData.getHash() ^ _textScaler.hashCode;
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      final cellFlags = cellData.flags;

      var color = effectiveForegroundColor(cellData);

      if (cellData.flags & CellFlags.faint != 0) {
        color = color.withOpacity(0.5);
      }

      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        underline: cellFlags & CellFlags.underline != 0,
      );

      // Flutter does not draw an underline below a space which is not between
      // other regular characters. As only single characters are drawn, this
      // will never produce an underline below a space in the terminal. As a
      // workaround the regular space CodePoint 0x20 is replaced with
      // the CodePoint 0xA0. This is a non breaking space and a underline can be
      // drawn below it.
      var char = String.fromCharCode(charCode);
      if (cellFlags & CellFlags.underline != 0 && charCode == 0x20) {
        char = String.fromCharCode(0xA0);
      }

      paragraph = _paragraphCache.performAndCacheLayout(
        char,
        style,
        _textScaler,
        cacheKey,
      );
    }

    canvas.drawParagraph(paragraph, offset);
  }

  @visibleForTesting
  ({Color color, TerminalCustomGlyph glyph})? customGlyphPaint(
    CellData cellData,
  ) {
    if (cellData.flags & CellFlags.invisible != 0) {
      return null;
    }

    final glyph = TerminalCustomGlyphs.forCodePoint(
      cellData.content & CellContent.codepointMask,
    );
    if (glyph == null) {
      return null;
    }

    var color = effectiveForegroundColor(cellData);
    if (cellData.flags & CellFlags.faint != 0) {
      color = color.withOpacity(0.5);
    }

    return (color: color, glyph: glyph);
  }

  @visibleForTesting
  Color effectiveForegroundColor(CellData cellData) {
    return cellData.flags & CellFlags.inverse == 0
        ? resolveForegroundColor(cellData.foreground)
        : resolveBackgroundColor(cellData.background);
  }

  @visibleForTesting
  Color? effectiveBackgroundColor(CellData cellData) {
    final colorType = cellData.background & CellColor.typeMask;

    if (cellData.flags & CellFlags.inverse != 0) {
      return resolveForegroundColor(cellData.foreground);
    }

    if (colorType == CellColor.normal) {
      return null;
    }

    return resolveBackgroundColor(cellData.background);
  }

  /// Paints the background of a cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellBackground(Canvas canvas, Offset offset, CellData cellData) {
    late Color color;
    final colorType = cellData.background & CellColor.typeMask;

    if (cellData.flags & CellFlags.inverse != 0) {
      color = resolveForegroundColor(cellData.foreground);
    } else if (colorType == CellColor.normal) {
      return;
    } else {
      color = resolveBackgroundColor(cellData.background);
    }

    final paint = _cellBackgroundPaint..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(_cellSize.width * widthScale, _cellSize.height);
    canvas.drawRect(offset & size, paint);
  }

  /// Get the effective foreground color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveForegroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.foreground;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }

  /// Get the effective background color for a cell from information encoded in
  /// [cellColor].
  @pragma('vm:prefer-inline')
  Color resolveBackgroundColor(int cellColor) {
    final colorType = cellColor & CellColor.typeMask;
    final colorValue = cellColor & CellColor.valueMask;

    switch (colorType) {
      case CellColor.normal:
        return _theme.background;
      case CellColor.named:
      case CellColor.palette:
        return _colorPalette[colorValue];
      case CellColor.rgb:
      default:
        return Color(colorValue | 0xFF000000);
    }
  }
}
