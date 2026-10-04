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
  int _linePictureCacheHitCount = 0;
  int _linePictureCacheEntryCount = 0;

  static const _maximumLinePictureCacheSize = 512;

  @visibleForTesting
  int get linePictureBuildCount => _linePictureBuildCount;

  /// Cache hits that reused an existing line Picture (drawPicture path).
  @visibleForTesting
  int get linePictureCacheHitCount => _linePictureCacheHitCount;

  @visibleForTesting
  void resetLinePictureBuildCount() {
    _linePictureBuildCount = 0;
    _linePictureCacheHitCount = 0;
  }

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
    // Line pictures are recorded at the origin and no longer depend on the
    // ratio for glyph placement, but custom glyphs (custom_glyphs.dart) still
    // bake the ratio in at recording time, so this invalidation is required.
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
    // Recording is translation-invariant: the picture is always recorded at
    // the origin and translated to [offset] at draw time, so the rasterized
    // output is identical for any sub-pixel offset. Keeping one picture per
    // line (instead of one per sub-pixel phase) avoids recording N redundant
    // pictures on fractional devicePixelRatios (e.g. 125%/150% on Windows).
    // An explicit span list has no revision/identity contract. Avoid reusing
    // a cached picture unless a source can describe when it changed.
    final cacheable = highlights == null;
    var cached = cacheable ? _linePictureCache.remove(line) : null;
    if (cached != null &&
        (cached.revision != line.revision ||
            cached.highlightRevision != highlightRevision ||
            !identical(cached.highlightSource, highlightSource) ||
            cached.highlightLineIndex != highlightLineIndex)) {
      _linePictureCacheEntryCount--;
      cached.dispose();
      cached = null;
    }

    final cachedPicture = cached?.picture;
    if (cachedPicture != null) {
      _linePictureCache[line] = cached!;
      _linePictureCacheHitCount++;
      canvas.save();
      canvas.translate(offset.dx, offset.dy);
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
      Offset.zero,
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
      cached.picture = picture;
      _linePictureCacheEntryCount++;
      _linePictureCache[line] = cached;
      _evictLinePictureIfNeeded();
    }

    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.drawPicture(picture);
    canvas.restore();
  }

  void _evictLinePictureIfNeeded() {
    while (_linePictureCacheEntryCount > _maximumLinePictureCacheSize) {
      final oldestLine = _linePictureCache.keys.first;
      _linePictureCache.remove(oldestLine)?.dispose();
      _linePictureCacheEntryCount--;
    }
  }

  void _clearLinePictureCache() {
    for (final cached in _linePictureCache.values) {
      cached.dispose();
    }
    _linePictureCache.clear();
    _linePictureCacheEntryCount = 0;
  }

  /// Drop all cached line pictures (chrome invalidation: theme/font/highlight).
  void clearLinePictureCache() {
    _clearLinePictureCache();
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
      final flags = highlight == null
          ? null
          : (cellData.flags | highlight.addFlags) & ~highlight.removeFlags;

      if (paintBackground) {
        paintCellBackground(
          canvas,
          cellOffset,
          cellData,
          foregroundOverride: foregroundOverride,
          backgroundOverride: backgroundOverride,
          flagsOverride: flags,
        );
      }
      if (paintForeground) {
        paintCellForeground(
          canvas,
          cellOffset,
          cellData,
          foregroundOverride: foregroundOverride,
          backgroundOverride: backgroundOverride,
          flagsOverride: flags,
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

  /// Underline overlay for one painted row.
  ///
  /// iTerm2-style: a web link is underlined only while the modifier is held
  /// *and* the pointer is on it ([armedLink]). Links whose scheme has no
  /// handler (file:, ssh:, …) are drawn dashed all the time and turn solid
  /// while armed. Mobile ([underlineAllWebLinks]) draws web links without an
  /// armed pointer.
  void paintLinkDecorations(
    Canvas canvas,
    Offset offset,
    BufferLine line, {
    int lineIndex = -1,
    int? armedLineIndex,
    bool underlineAllWebLinks = false,
    bool underlineFileLinks = false,
    TerminalHyperlink? armedLink,
  }) {
    final decorations = resolveLinkDecorations(
      line,
      lineIndex: lineIndex,
      armedLineIndex: armedLineIndex,
      underlineAllWebLinks: underlineAllWebLinks,
      underlineFileLinks: underlineFileLinks,
      armedLink: armedLink,
    );
    if (decorations.isEmpty) {
      return;
    }
    final cellWidth = _cellSize.width;
    final underlineY = offset.dy + _cellSize.height - 1;
    final cellData = CellData.empty();
    for (final decoration in decorations) {
      line.getCellData(decoration.startColumn, cellData);
      _paintUnderlineStroke(
        canvas,
        offset.dx + decoration.startColumn * cellWidth,
        underlineY,
        (decoration.endColumn - decoration.startColumn) * cellWidth,
        resolveForegroundColor(cellData.foreground),
        dashed: decoration.dashed,
      );
    }
  }

  /// Ranges of [line] that should show an underline right now.
  @visibleForTesting
  List<({int startColumn, int endColumn, bool dashed})>
      resolveLinkDecorations(
    BufferLine line, {
    int lineIndex = -1,
    int? armedLineIndex,
    bool underlineAllWebLinks = false,
    bool underlineFileLinks = false,
    TerminalHyperlink? armedLink,
  }) {
    if (!underlineAllWebLinks && !underlineFileLinks && armedLink == null) {
      return const [];
    }
    // Plain-text URLs are only searched when the armed link is a web link on
    // this very row, so hovering stays bounded to one line per frame.
    final includePlainUrls = underlineAllWebLinks ||
        (armedLink != null &&
            armedLink.hasVisibleAffordance &&
            (armedLineIndex == null || armedLineIndex == lineIndex));
    if (!line.hasLinks && !includePlainUrls) {
      return const [];
    }
    final spans = _linkSpansCached(line, includePlainUrls: includePlainUrls);
    if (spans.isEmpty) {
      return const [];
    }
    final decorations = <({int startColumn, int endColumn, bool dashed})>[];
    for (final span in spans) {
      final armed = armedLink != null && span.link == armedLink;
      final bool dashed;
      if (span.link.hasVisibleAffordance) {
        if (!armed && !underlineAllWebLinks) {
          continue;
        }
        dashed = false;
      } else {
        if (!underlineFileLinks) {
          continue;
        }
        dashed = !armed;
      }
      decorations.add((
        startColumn: span.startColumn,
        endColumn: span.endColumn,
        dashed: dashed,
      ));
    }
    return decorations;
  }

  void _paintUnderlineStroke(
    Canvas canvas,
    double left,
    double y,
    double width,
    Color color, {
    required bool dashed,
  }) {
    if (width <= 0) {
      return;
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    final end = left + width;
    if (!dashed) {
      canvas.drawLine(Offset(left, y), Offset(left + width, y), paint);
      return;
    }
    const dash = 3.0;
    const gap = 2.0;
    var x = left;
    while (x < end) {
      final segmentEnd = x + dash > end ? end : x + dash;
      canvas.drawLine(Offset(x, y), Offset(segmentEnd, y), paint);
      x = segmentEnd + gap;
    }
  }

  final _linkSpanCache = <BufferLine, _CachedLinkSpans>{};
  static const _maximumLinkSpanCacheSize = 512;

  /// Link spans are reused per (line, revision) so drawing the overlay every
  /// frame never rescans cells or runs the URL pattern again.
  List<TerminalLinkSpan> _linkSpansCached(
    BufferLine line, {
    required bool includePlainUrls,
  }) {
    final cached = _linkSpanCache[line];
    if (cached != null &&
        cached.revision == line.revision &&
        (cached.includePlainUrls || !includePlainUrls)) {
      return cached.spans;
    }
    final spans = linkSpansInLine(line, includePlainUrls: includePlainUrls);
    _linkSpanCache[line] =
        _CachedLinkSpans(line.revision, includePlainUrls, spans);
    while (_linkSpanCache.length > _maximumLinkSpanCacheSize) {
      _linkSpanCache.remove(_linkSpanCache.keys.first);
    }
    return spans;
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

  /// Selection cell without syntax-highlight overrides (tests / simple callers).
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

  /// Glyph pass for a selected cell, including optional [TerminalHighlightSpan]
  /// overrides (search / syntax). Does not paint selection fill — caller draws
  /// the range strip once.
  @pragma('vm:prefer-inline')
  void paintSelectionCellForeground(
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
  ui.Picture? picture;

  void dispose() {
    picture?.dispose();
    picture = null;
  }
}

class _CachedLinkSpans {
  _CachedLinkSpans(this.revision, this.includePlainUrls, this.spans);

  final int revision;
  final bool includePlainUrls;
  final List<TerminalLinkSpan> spans;
}
