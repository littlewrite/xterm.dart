import 'dart:ui' as ui;

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
  final _linePictureCache = <BufferLine, _CachedLinePictures>{};
  int _linePictureBuildCount = 0;
  int _linePictureCacheEntryCount = 0;

  static const _maximumLinePictureCacheSize = 512;
  static const _maximumLinePicturePhases = 8;

  @visibleForTesting
  int get linePictureBuildCount => _linePictureBuildCount;

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _clearLinePictureCache();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _paragraphCache.clear();
    _clearLinePictureCache();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
    _clearLinePictureCache();
  }

  double get devicePixelRatio => _devicePixelRatio;
  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    _clearLinePictureCache();
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
    _clearLinePictureCache();
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

    final paint = Paint()
      ..color = color
      ..isAntiAlias = false
      ..strokeWidth = 1;

    canvas.drawRect(Rect.fromPoints(offset, endOffset), paint);
  }

  /// Paints [line] to [canvas] at [offset]. The x offset of [offset] is usually
  /// 0, and the y offset is the top of the line.
  void paintLine(
    Canvas canvas,
    Offset offset,
    BufferLine line, {
    List<TerminalHighlightSpan>? highlights,
    int highlightRevision = 0,
    TerminalHighlightSource? highlightSource,
    int highlightLineIndex = -1,
  }) {
    final originPhase = _devicePixelPhase(offset);
    // An explicit span list has no revision/identity contract. Avoid reusing
    // a cached picture unless a source can describe when it changed.
    final cacheable = highlights == null;
    var cached = cacheable ? _linePictureCache.remove(line) : null;
    if (cached != null &&
        (cached.revision != line.revision ||
            cached.highlightRevision != highlightRevision ||
            !identical(cached.highlightSource, highlightSource) ||
            cached.highlightLineIndex != highlightLineIndex)) {
      _linePictureCacheEntryCount -= cached.pictures.length;
      cached.dispose();
      cached = null;
    }

    final cachedPicture = cached?.pictures.remove(originPhase);
    if (cachedPicture != null) {
      cached!.pictures[originPhase] = cachedPicture;
      _linePictureCache[line] = cached;
      canvas.save();
      canvas.translate(
        offset.dx - originPhase.dx,
        offset.dy - originPhase.dy,
      );
      canvas.drawPicture(cachedPicture);
      canvas.restore();
      return;
    }

    final recorder = ui.PictureRecorder();
    final recordingCanvas = Canvas(recorder);
    final resolvedHighlights = highlights ??
        highlightSource?.spansForLine(line, highlightLineIndex) ??
        const [];
    _paintLineCells(
      recordingCanvas,
      originPhase,
      line,
      highlights: resolvedHighlights,
    );
    final picture = recorder.endRecording();
    _linePictureBuildCount++;

    if (cacheable) {
      cached ??= _CachedLinePictures(
        line.revision,
        highlightRevision,
        highlightSource,
        highlightLineIndex,
      );
      cached.pictures[originPhase] = picture;
      _linePictureCacheEntryCount++;
      while (cached.pictures.length > _maximumLinePicturePhases) {
        final oldestPhase = cached.pictures.keys.first;
        cached.pictures.remove(oldestPhase)?.dispose();
        _linePictureCacheEntryCount--;
      }
      _linePictureCache[line] = cached;
      _evictLinePictureIfNeeded();
    }

    canvas.save();
    canvas.translate(
      offset.dx - originPhase.dx,
      offset.dy - originPhase.dy,
    );
    canvas.drawPicture(picture);
    canvas.restore();
  }

  Offset _devicePixelPhase(Offset offset) {
    if (_devicePixelRatio <= 0) return Offset.zero;

    double phase(double value) {
      final deviceValue = value * _devicePixelRatio;
      return (deviceValue - deviceValue.floor()) / _devicePixelRatio;
    }

    return Offset(phase(offset.dx), phase(offset.dy));
  }

  void _evictLinePictureIfNeeded() {
    while (_linePictureCacheEntryCount > _maximumLinePictureCacheSize) {
      final oldestLine = _linePictureCache.keys.first;
      final cached = _linePictureCache[oldestLine]!;
      final oldestPhase = cached.pictures.keys.first;
      cached.pictures.remove(oldestPhase)?.dispose();
      _linePictureCacheEntryCount--;
      if (cached.pictures.isEmpty) {
        _linePictureCache.remove(oldestLine);
      }
    }
  }

  void _clearLinePictureCache() {
    for (final cached in _linePictureCache.values) {
      cached.dispose();
    }
    _linePictureCache.clear();
    _linePictureCacheEntryCount = 0;
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
    List<TerminalHighlightSpan> highlights = const [],
  }) {
    if (highlights.isEmpty) {
      _paintLineCellsPlain(
        canvas,
        offset,
        line,
        paintBackground: paintBackground,
        paintForeground: paintForeground,
      );
      return;
    }
    final cellData = CellData.empty();
    final cellWidth = _cellSize.width;
    var highlightIndex = 0;

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      while (highlightIndex < highlights.length &&
          highlights[highlightIndex].endColumn <= i) {
        highlightIndex++;
      }
      final highlight = highlightIndex < highlights.length &&
              highlights[highlightIndex].contains(i)
          ? highlights[highlightIndex]
          : null;
      final foregroundOverride = _highlightForegroundOverride(
        cellData,
        highlight,
      );
      final backgroundOverride = _highlightBackgroundOverride(
        cellData,
        highlight,
      );

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);

      if (paintBackground) {
        paintCellBackground(
          canvas,
          cellOffset,
          cellData,
          foregroundOverride: foregroundOverride,
          backgroundOverride: backgroundOverride,
          flagsOverride: highlight == null
              ? null
              : (cellData.flags | highlight.addFlags) & ~highlight.removeFlags,
        );
      }
      if (paintForeground) {
        paintCellForeground(
          canvas,
          cellOffset,
          cellData,
          foregroundOverride: foregroundOverride,
          backgroundOverride: backgroundOverride,
          flagsOverride: highlight == null
              ? null
              : (cellData.flags | highlight.addFlags) & ~highlight.removeFlags,
        );
      }

      if (charWidth == 2) {
        i++;
      }
    }
  }

  void _paintLineCellsPlain(
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
      final cellOffset = offset.translate(i * cellWidth, 0);
      if (paintBackground) paintCellBackground(canvas, cellOffset, cellData);
      if (paintForeground) paintCellForeground(canvas, cellOffset, cellData);
      if (cellData.content >> CellContent.widthShift == 2) i++;
    }
  }

  @pragma('vm:prefer-inline')
  void paintCell(
    Canvas canvas,
    Offset offset,
    CellData cellData, {
    Color? foregroundOverride,
    Color? backgroundOverride,
    int? flagsOverride,
  }) {
    paintCellBackground(
      canvas,
      offset,
      cellData,
      foregroundOverride: foregroundOverride,
      backgroundOverride: backgroundOverride,
      flagsOverride: flagsOverride,
    );
    paintCellForeground(
      canvas,
      offset,
      cellData,
      foregroundOverride: foregroundOverride,
      backgroundOverride: backgroundOverride,
      flagsOverride: flagsOverride,
    );
  }

  @pragma('vm:prefer-inline')
  void paintCellWithHighlight(
    Canvas canvas,
    Offset offset,
    CellData cellData,
    TerminalHighlightSpan? highlight,
  ) {
    final foregroundOverride = _highlightForegroundOverride(
      cellData,
      highlight,
    );
    final backgroundOverride = _highlightBackgroundOverride(
      cellData,
      highlight,
    );
    paintCell(
      canvas,
      offset,
      cellData,
      foregroundOverride: foregroundOverride,
      backgroundOverride: backgroundOverride,
      flagsOverride: highlight == null
          ? null
          : (cellData.flags | highlight.addFlags) & ~highlight.removeFlags,
    );
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

  @pragma('vm:prefer-inline')
  void paintSelectedCellWithHighlight(
    Canvas canvas,
    Offset offset,
    CellData cellData,
    TerminalHighlightSpan? highlight,
  ) {
    paintHighlight(
      canvas,
      offset,
      cellData.content >> CellContent.widthShift == 2 ? 2 : 1,
      _theme.selection,
    );
    final foregroundOverride = _highlightForegroundOverride(
      cellData,
      highlight,
    );
    final backgroundOverride = _highlightBackgroundOverride(
      cellData,
      highlight,
    );
    paintCellForeground(
      canvas,
      offset,
      cellData,
      foregroundOverride: foregroundOverride,
      backgroundOverride: backgroundOverride,
      flagsOverride: highlight == null
          ? null
          : (cellData.flags | highlight.addFlags) & ~highlight.removeFlags,
    );
  }

  /// Paints the character in the cell represented by [cellData] to [canvas] at
  /// [offset].
  @pragma('vm:prefer-inline')
  void paintCellForeground(
    Canvas canvas,
    Offset offset,
    CellData cellData, {
    Color? foregroundOverride,
    Color? backgroundOverride,
    int? flagsOverride,
  }) {
    final charCode = cellData.content & CellContent.codepointMask;
    if (charCode == 0) return;
    final cellFlags = flagsOverride ?? cellData.flags;

    final glyphPaint = customGlyphPaint(
      cellData,
      foregroundOverride: foregroundOverride,
      backgroundOverride: backgroundOverride,
      flagsOverride: flagsOverride,
    );
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

    var cacheKey = cellData.getHash() ^ _textScaler.hashCode;
    if (foregroundOverride != null) {
      cacheKey ^= foregroundOverride.hashCode;
    }
    if (backgroundOverride != null) {
      cacheKey ^= backgroundOverride.hashCode;
    }
    if (flagsOverride != null) {
      cacheKey ^= flagsOverride;
    }
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      var color = cellFlags & CellFlags.inverse != 0
          ? backgroundOverride ?? resolveBackgroundColor(cellData.background)
          : foregroundOverride ?? resolveForegroundColor(cellData.foreground);

      if (cellFlags & CellFlags.faint != 0) {
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
    CellData cellData, {
    Color? foregroundOverride,
    Color? backgroundOverride,
    int? flagsOverride,
  }) {
    final flags = flagsOverride ?? cellData.flags;
    if (flags & CellFlags.invisible != 0) {
      return null;
    }

    final glyph = TerminalCustomGlyphs.forCodePoint(
      cellData.content & CellContent.codepointMask,
    );
    if (glyph == null) {
      return null;
    }

    var color = flags & CellFlags.inverse != 0
        ? backgroundOverride ?? resolveBackgroundColor(cellData.background)
        : foregroundOverride ?? resolveForegroundColor(cellData.foreground);
    if (flags & CellFlags.faint != 0) {
      color = color.withOpacity(0.5);
    }

    return (color: color, glyph: glyph);
  }

  Color? _highlightForegroundOverride(
    CellData cellData,
    TerminalHighlightSpan? highlight,
  ) {
    if (highlight == null ||
        (highlight.preserveAnsiColors &&
            cellData.foreground & CellColor.typeMask != CellColor.normal)) {
      return null;
    }
    return highlight.foreground;
  }

  Color? _highlightBackgroundOverride(
    CellData cellData,
    TerminalHighlightSpan? highlight,
  ) {
    if (highlight == null ||
        (highlight.preserveAnsiColors &&
            cellData.background & CellColor.typeMask != CellColor.normal)) {
      return null;
    }
    return highlight.background;
  }

  Color effectiveForegroundColor(CellData cellData, {int? flags}) {
    final effectiveFlags = flags ?? cellData.flags;
    return effectiveFlags & CellFlags.inverse == 0
        ? resolveForegroundColor(cellData.foreground)
        : resolveBackgroundColor(cellData.background);
  }

  Color? effectiveBackgroundColor(CellData cellData, {int? flags}) {
    final colorType = cellData.background & CellColor.typeMask;
    final effectiveFlags = flags ?? cellData.flags;

    if (effectiveFlags & CellFlags.inverse != 0) {
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
  void paintCellBackground(
    Canvas canvas,
    Offset offset,
    CellData cellData, {
    Color? foregroundOverride,
    Color? backgroundOverride,
    int? flagsOverride,
  }) {
    late Color color;
    final colorType = cellData.background & CellColor.typeMask;
    final flags = flagsOverride ?? cellData.flags;

    if (backgroundOverride != null) {
      color = backgroundOverride;
    } else if (flags & CellFlags.inverse != 0) {
      color = foregroundOverride ?? resolveForegroundColor(cellData.foreground);
    } else if (colorType == CellColor.normal) {
      return;
    } else {
      color = resolveBackgroundColor(cellData.background);
    }

    final paint = Paint()
      ..color = color
      ..isAntiAlias = false;
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

class _CachedLinePictures {
  _CachedLinePictures(
    this.revision,
    this.highlightRevision,
    this.highlightSource,
    this.highlightLineIndex,
  );

  final int revision;
  final int highlightRevision;
  final TerminalHighlightSource? highlightSource;
  final int highlightLineIndex;
  final pictures = <Offset, ui.Picture>{};

  void dispose() {
    for (final picture in pictures.values) {
      picture.dispose();
    }
    pictures.clear();
  }
}
