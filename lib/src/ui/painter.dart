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
  final _paragraphCache = ParagraphCache<_GlyphKey>(10240);

  /// Laid out runs of cells. Smaller than [_paragraphCache] because each entry
  /// covers many cells, and because a run's text is far less repetitive than a
  /// single character.
  ///
  /// Not smaller than this, though: a screen of short differently coloured runs
  /// has a working set in the low thousands and would thrash below it.
  final _runCache = ParagraphCache<_RunKey>(2048);

  /// Run kinds (the style flags) whose glyphs do not advance by exactly one
  /// cell, found by measuring a run against the grid in [_flushRun].
  /// Coalescing is abandoned for these until the font changes.
  final _uncoalescableRuns = <int>{};

  /// Scratch objects for the synchronous per-line paint path.
  final _cellScratch = CellData.empty();
  final _backgroundPaint = Paint()..isAntiAlias = false;

  /// Characters accumulated for the run being built by [_paintLineForegrounds].
  final _runChars = <int>[];

  /// Memoized content hash per line, invalidated by [BufferLine.revision].
  final _lineContentCache = <BufferLine, _CachedLineContent>{};

  /// Pictures keyed by content, so equal-looking rows share a recording.
  ///
  /// The draw counts are kept alongside so a cache hit can report what
  /// replaying the picture costs, which is what the benchmark measures.
  final _linePictureCache = <int, _CachedLinePicture>{};

  int _linePictureBuildCount = 0;
  int _linePictureCacheHitCount = 0;
  int _lineHashCount = 0;

  /// Cell draws issued by the painting paths, whether recorded into a line
  /// picture now or replayed from one.
  int _debugDrawParagraphCount = 0;
  int _debugDrawBackgroundRectCount = 0;

  /// Bounded by distinct contents; eviction may cause one later re-record.
  static const _maximumLinePictureCacheSize = 512;

  /// Covers the viewport plus scrollback without retaining every line.
  static const _maximumLineContentCacheSize = 1024;

  /// The flags that reach [TerminalStyle.toTextStyle] and so change the laid
  /// out glyph. `faint` and `inverse` resolve into the colour instead, while
  /// `blink` and `invisible` decide whether the cell is painted at all.
  static const _layoutFlags =
      CellFlags.bold | CellFlags.italic | CellFlags.underline;

  /// Flags that change a run's painted output and therefore its cache key.
  static const _runFlagsMask =
      _layoutFlags | CellFlags.faint | CellFlags.inverse;

  /// Turned off on runs, and only on runs. A ligature would draw two cells'
  /// characters as one glyph of its own width, which puts the rest of the run
  /// off its columns, and the terminal's own idea of the cursor column does
  /// not change to match. Single glyphs have no neighbours to join with.
  static const _noLigatures = [
    FontFeature.disable('liga'),
    FontFeature.disable('clig'),
    FontFeature.disable('calt'),
    FontFeature.disable('dlig'),
  ];

  /// How far a run may end up from where painting it cell by cell would have
  /// put it, over the whole run, before it is rejected. Half a pixel, so no
  /// character can land in a different column than it would have.
  static const _gridTolerance = 0.5;

  /// A test can lower this to exercise the cell-by-cell fallback on a font that
  /// does not advance uniformly.
  @visibleForTesting
  double debugGridTolerance = _gridTolerance;

  /// Number of styles coalescing has been abandoned for.
  @visibleForTesting
  int get debugUncoalescableRunCount => _uncoalescableRuns.length;

  @visibleForTesting
  int get linePictureBuildCount => _linePictureBuildCount;

  /// Cache hits that reused an existing line Picture (drawPicture path).
  @visibleForTesting
  int get linePictureCacheHitCount => _linePictureCacheHitCount;

  /// Lines whose cells were hashed. An unchanged line must not be hashed again
  /// on the next frame, however many frames paint it.
  @visibleForTesting
  int get lineHashCount => _lineHashCount;

  @visibleForTesting
  void resetLinePictureBuildCount() {
    _linePictureBuildCount = 0;
    _linePictureCacheHitCount = 0;
    _lineHashCount = 0;
  }

  /// Glyphs drawn by the last painting pass, counting both the cells recorded
  /// into a line picture and the cells its replay draws.
  @visibleForTesting
  int get debugDrawParagraphCount => _debugDrawParagraphCount;

  /// Background rects drawn, with the same recording/replay accounting as
  /// [debugDrawParagraphCount].
  @visibleForTesting
  int get debugDrawBackgroundRectCount => _debugDrawBackgroundRectCount;

  @visibleForTesting
  void resetDebugDrawCounts() {
    _debugDrawParagraphCount = 0;
    _debugDrawBackgroundRectCount = 0;
  }

  /// Whether blinking text is in the visible half of its cycle. While this is
  /// false a cell carrying SGR 5 draws no glyph, and a row that holds one draws
  /// the other of its two pictures. The render object drives it.
  bool blinkVisible = true;

  /// Whether consecutive ASCII cells sharing a style are drawn as one
  /// [Paragraph]. A font that does not advance ASCII by exactly one cell is
  /// detected and falls back on its own; this switch is for a platform or font
  /// that misbehaves in a way the width check cannot see.
  bool get coalesceRuns => _coalesceRuns;
  bool _coalesceRuns = true;
  set coalesceRuns(bool value) {
    if (value == _coalesceRuns) return;
    _coalesceRuns = value;
    // Recorded pictures carry the old painting mode.
    _clearLinePictureCache();
  }

  /// Whether any row painted since [beginBlinkScan] held an SGR 5 cell. The
  /// render object runs a blink timer only while something on screen blinks, so
  /// a screen with none pays neither the timer nor the extra picture.
  bool get sawBlinkingText => _sawBlinkingText;
  bool _sawBlinkingText = false;

  void beginBlinkScan() {
    _sawBlinkingText = false;
  }

  TerminalStyle get textStyle => _textStyle;
  TerminalStyle _textStyle;
  set textStyle(TerminalStyle value) {
    if (value == _textStyle) return;
    _textStyle = value;
    _cellSize = _measureCharSize();
    _clearFontDependentCaches();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler = TextScaler.linear(1.0);
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    _cellSize = _measureCharSize();
    _clearFontDependentCaches();
  }

  TerminalTheme get theme => _theme;
  TerminalTheme _theme;
  set theme(TerminalTheme value) {
    if (value == _theme) return;
    _theme = value;
    _colorPalette = PaletteBuilder(value).build();
    _paragraphCache.clear();
    _runCache.clear();
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
    _clearFontDependentCaches();
  }

  /// [_uncoalescableRuns] is a verdict about the *font*, so it survives a
  /// theme change and only the font-dependent paths reset it.
  void _clearFontDependentCaches() {
    _paragraphCache.clear();
    _runCache.clear();
    _uncoalescableRuns.clear();
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
    final content = _resolveLineContent(line);
    if (content.hasBlink) {
      _sawBlinkingText = true;
    }

    final cacheable = highlights == null;
    final cacheKey = cacheable
        ? _linePictureKey(
            content,
            line,
            highlightRevision: highlightRevision,
            highlightSource: highlightSource,
            highlightLineIndex: highlightLineIndex,
          )
        : 0;

    if (cacheable) {
      final cached = _linePictureCache[cacheKey];
      if (cached != null) {
        _linePictureCacheHitCount++;
        _debugDrawParagraphCount += cached.paragraphs;
        _debugDrawBackgroundRectCount += cached.backgroundRects;
        _drawLinePicture(canvas, offset, cached.picture);
        return;
      }
    }

    final paragraphsBefore = _debugDrawParagraphCount;
    final backgroundRectsBefore = _debugDrawBackgroundRectCount;
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
      _linePictureCache[cacheKey] = _CachedLinePicture(
        picture,
        _debugDrawParagraphCount - paragraphsBefore,
        _debugDrawBackgroundRectCount - backgroundRectsBefore,
      );
      _evictLinePictureIfNeeded();
    }

    _drawLinePicture(canvas, offset, picture);
  }

  void _drawLinePicture(Canvas canvas, Offset offset, ui.Picture picture) {
    canvas.save();
    canvas.translate(offset.dx, offset.dy);
    canvas.drawPicture(picture);
    canvas.restore();
  }

  /// The memoized content of [line]: its hash, and whether it carries SGR 5.
  _CachedLineContent _resolveLineContent(BufferLine line) {
    var content = _lineContentCache[line];
    if (content == null) {
      content = _CachedLineContent();
      _lineContentCache[line] = content;
      _evictLineContentIfNeeded();
    }
    if (content.revision != line.revision) {
      _hashLine(line, content);
    }
    return content;
  }

  /// Key from cell content plus the overlay's resolved spans.
  ///
  /// Row index and source revision are deliberately excluded; only pixels
  /// matter. SGR 5 adds the phase to the key, but only for a blinking row.
  int _linePictureKey(
    _CachedLineContent content,
    BufferLine line, {
    required int highlightRevision,
    required TerminalHighlightSource? highlightSource,
    required int highlightLineIndex,
  }) {
    var key = content.hash;

    final source = highlightSource;
    if (source != null) {
      if (!content.overlayValid ||
          content.overlayRevision != highlightRevision ||
          !identical(content.overlaySource, source)) {
        content
          ..overlayRevision = highlightRevision
          ..overlaySource = source
          ..overlayValid = true
          ..overlayHash = _hashSpans(
            source.spansForLine(line, highlightLineIndex),
          );
      }
      key = _mixKey(key, content.overlayHash);
    }

    if (content.hasBlink && !blinkVisible) {
      key = _mixKey(key, _blinkHiddenSalt);
    }
    return key;
  }

  /// Combines two 30-bit hashes into one small-int key.
  static int _mixKey(int content, int overlay) {
    final high = (content >>> _laneBits) * _hashPrime & _hashMask;
    final low = ((content & _hashMask) * _hashPrime + overlay) & _hashMask;
    return (high << _laneBits) ^ low;
  }

  /// Hashes the fields that affect an overlay's pixels.
  int _hashSpans(List<TerminalHighlightSpan> spans) {
    var high = 0x2545f491 ^ spans.length;
    var low = 0x9e3779b9;
    for (final span in spans) {
      high = (high * _hashPrime + span.startColumn) & _hashMask;
      high = (high * _hashPrime + span.endColumn) & _hashMask;
      high = (high * _hashPrime + span.addFlags) & _hashMask;
      high = (high * _hashPrime + span.removeFlags) & _hashMask;
      high =
          (high * _hashPrime + (span.preserveAnsiColors ? 1 : 0)) & _hashMask;
      low = (low * _hashPrime + (span.foreground?.hashCode ?? 0)) & _hashMask;
      low = (low * _hashPrime + (span.background?.hashCode ?? 0)) & _hashMask;
    }
    return high * _hashPrime + low;
  }

  final _hashCell = CellData.empty();

  /// Hashes the four cell words read by [_paintLineCellsPlain].
  ///
  /// Two 30-bit lanes keep the key a small int and the pass allocation-free.
  /// The same pass also notes whether the row carries SGR 5.
  void _hashLine(BufferLine line, _CachedLineContent content) {
    _lineHashCount++;
    var sawBlink = false;
    var high = 0x1f123bb5 ^ line.length;
    var low = 0x5f356495 ^ line.length;
    final cell = _hashCell;
    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cell);
      if (cell.flags & CellFlags.blink != 0) {
        sawBlink = true;
      }
      high = (high * _hashPrime + cell.content) & _hashMask;
      high = (high * _hashPrime + cell.foreground) & _hashMask;
      low = (low * _hashPrime + cell.background) & _hashMask;
      low = (low * _hashPrime + cell.flags) & _hashMask;
      high = (high * _hashPrime + cell.underlineStyle) & _hashMask;
      low = (low * _hashPrime + cell.underlineColor) & _hashMask;
    }
    content
      ..revision = line.revision
      ..hash = high * _hashPrime + low
      ..hasBlink = sawBlink
      // A changed line must re-resolve its overlay.
      ..overlayValid = false;
  }

  static const int _laneBits = 30;

  /// 30 bits leaves room for one multiply and an add per cell word.
  static const int _hashMask = (1 << _laneBits) - 1;

  static const int _hashPrime = 0x01000193;

  /// Salt for the hidden phase of a blinking row.
  static const int _blinkHiddenSalt = 0x5bf03635;

  void _evictLinePictureIfNeeded() {
    while (_linePictureCache.length > _maximumLinePictureCacheSize) {
      final oldestKey = _linePictureCache.keys.first;
      _linePictureCache.remove(oldestKey)?.picture.dispose();
    }
  }

  void _evictLineContentIfNeeded() {
    while (_lineContentCache.length > _maximumLineContentCacheSize) {
      _lineContentCache.remove(_lineContentCache.keys.first);
    }
  }

  void _clearLinePictureCache() {
    for (final cached in _linePictureCache.values) {
      cached.picture.dispose();
    }
    _linePictureCache.clear();
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
    final cellData = _cellScratch;
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
    // Backgrounds first, then glyphs, each as maximal coalesced spans or runs.
    // Drawing every background before any glyph (rather than interleaving them
    // cell by cell) also keeps an overflowing italic or fallback glyph on top
    // of its neighbour's background instead of underneath it.
    if (paintBackground) _paintLineBackgroundsPlain(canvas, offset, line);
    if (paintForeground) {
      if (coalesceRuns) {
        _paintLineForegroundsPlain(canvas, offset, line);
      } else {
        _paintLineForegroundsPerCell(canvas, offset, line);
      }
    }
  }

  /// The pre-coalescing glyph path, kept for [coalesceRuns] and as the
  /// reference the run scanner must reproduce.
  void _paintLineForegroundsPerCell(
    Canvas canvas,
    Offset offset,
    BufferLine line,
  ) {
    final cellData = _cellScratch;
    final cellWidth = _cellSize.width;
    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);
      paintCellForeground(
        canvas,
        offset.translate(i * cellWidth, 0),
        cellData,
      );
      if (cellData.content >> CellContent.widthShift == 2) i++;
    }
  }

  /// Fills each maximal span of cells sharing a background colour with one
  /// rect.
  ///
  /// Cells are compared by the raw field their colour comes from rather than
  /// by the resolved [Color], which keeps this from allocating one per cell.
  /// The cost is that a span can split where it did not have to, since an
  /// inverse cell and a plain one can resolve to the same colour by different
  /// routes; that draws one extra rect and nothing else.
  void _paintLineBackgroundsPlain(
    Canvas canvas,
    Offset offset,
    BufferLine line,
  ) {
    final cellWidth = _cellSize.width;
    var spanStart = -1;
    var spanSource = 0;
    var spanInverse = false;
    var spanColor = const Color(0x00000000);

    void flush(int end) {
      if (spanStart < 0) return;
      _backgroundPaint.color = spanColor;
      canvas.drawRect(
        Rect.fromLTWH(
          offset.dx + spanStart * cellWidth,
          offset.dy,
          // Exactly the cells' width: the paint is not anti-aliased, so
          // adjacent rects share a device-pixel edge and no seam opens between
          // them. Widening it would bleed into the next cell's background.
          (end - spanStart) * cellWidth,
          _cellSize.height,
        ),
        _backgroundPaint,
      );
      _debugDrawBackgroundRectCount++;
      spanStart = -1;
    }

    for (var i = 0; i < line.length;) {
      final content = line.getContent(i);
      final cells = content >> CellContent.widthShift == 2 ? 2 : 1;
      final flags = line.getAttributes(i);
      final inverse = flags & CellFlags.inverse != 0;
      final source = inverse ? line.getForeground(i) : line.getBackground(i);
      final fills =
          inverse || (source & CellColor.typeMask) != CellColor.normal;

      if (spanStart >= 0) {
        if (fills && inverse == spanInverse && source == spanSource) {
          i += cells;
          continue;
        }
        flush(i);
      }

      if (fills) {
        spanStart = i;
        spanSource = source;
        spanInverse = inverse;
        spanColor = inverse
            ? resolveForegroundColor(source)
            : resolveBackgroundColor(source);
      }
      i += cells;
    }
    flush(line.length);
  }

  /// Draws each maximal run of cells that can share one [Paragraph], and every
  /// remaining cell on its own.
  ///
  /// A cell joins a run only if it is one column wide and ASCII printable:
  /// those are the characters a monospace font is relied on to advance exactly
  /// one cell for. Anything else — a wide character, a fallback font's glyph,
  /// or the empty second half of a wide character — is drawn at its own
  /// column, where its width cannot move its neighbours.
  void _paintLineForegroundsPlain(
    Canvas canvas,
    Offset offset,
    BufferLine line,
  ) {
    final cellWidth = _cellSize.width;
    final cellData = _cellScratch;

    var runStart = -1;
    var runForeground = 0;
    var runBackground = 0;
    var runFlags = 0;
    var runUnderlineStyle = 0;
    var runUnderlineColor = 0;

    void flush() {
      if (runStart < 0) return;
      _flushRun(
        canvas,
        offset,
        line,
        runStart,
        runForeground,
        runBackground,
        runFlags,
        runUnderlineStyle,
        runUnderlineColor,
      );
      runStart = -1;
      _runChars.clear();
    }

    for (var i = 0; i < line.length; i++) {
      final content = line.getContent(i);
      final charCode = content & CellContent.codepointMask;
      final width = content >> CellContent.widthShift;

      if (width == 2) {
        flush();
        line.getCellData(i, cellData);
        paintCellForeground(
          canvas,
          offset.translate(i * cellWidth, 0),
          cellData,
        );
        // The next cell is the empty second half of this character.
        i++;
        continue;
      }

      if (charCode == 0) {
        flush();
        continue;
      }

      final flags = line.getAttributes(i);
      if (flags & CellFlags.invisible != 0 ||
          (flags & CellFlags.blink != 0 && !blinkVisible)) {
        flush();
        continue;
      }

      final layoutFlags = flags & _layoutFlags;
      final joinable = width == 1 &&
          charCode >= 0x20 &&
          charCode <= 0x7E &&
          !_uncoalescableRuns.contains(layoutFlags);

      if (!joinable) {
        flush();
        line.getCellData(i, cellData);
        paintCellForeground(
          canvas,
          offset.translate(i * cellWidth, 0),
          cellData,
        );
        continue;
      }

      final foreground = line.getForeground(i);
      final inverse = flags & CellFlags.inverse != 0;
      final background = inverse ? line.getBackground(i) : 0;
      final visibleFlags = flags & _runFlagsMask;
      final underlineStyle = line.getUnderlineStyle(i);
      final underlineColor = line.getUnderlineColor(i);

      if (runStart >= 0 &&
          foreground == runForeground &&
          background == runBackground &&
          visibleFlags == runFlags &&
          underlineStyle == runUnderlineStyle &&
          underlineColor == runUnderlineColor) {
        _runChars.add(_runChar(charCode, visibleFlags));
        continue;
      }

      flush();
      runStart = i;
      runForeground = foreground;
      runBackground = background;
      runFlags = visibleFlags;
      runUnderlineStyle = underlineStyle;
      runUnderlineColor = underlineColor;
      _runChars.add(_runChar(charCode, visibleFlags));
    }

    flush();
  }

  /// Draws the accumulated run, if any, and clears its buffer state.
  void _flushRun(
    Canvas canvas,
    Offset lineOffset,
    BufferLine line,
    int start,
    int foreground,
    int background,
    int flags,
    int underlineStyle,
    int underlineColor,
  ) {
    final count = _runChars.length;
    if (count == 0) return;
    final runOffset = lineOffset.translate(start * _cellSize.width, 0);

    // A one-cell run gains nothing from a run-keyed paragraph; the per-cell
    // cache already shares it with every identical cell on screen.
    if (count == 1) {
      line.getCellData(start, _cellScratch);
      paintCellForeground(canvas, runOffset, _cellScratch);
      return;
    }

    final text = String.fromCharCodes(_runChars);
    final key = (
      text,
      foreground,
      background,
      flags,
      underlineStyle,
      underlineColor,
    );
    var paragraph = _runCache.getLayoutFromCache(key);

    if (paragraph == null) {
      paragraph = buildParagraph(
        text,
        _runTextStyle(
          foreground,
          background,
          flags,
          underlineStyle,
          underlineColor,
        ).copyWith(fontFeatures: _noLigatures),
        _textScaler,
      );

      // The run assumes every character advanced by exactly one cell. If the
      // font disagrees the glyphs would sit progressively further from their
      // columns, so give up on this style and draw it cell by cell.
      final expected = count * _cellSize.width;
      if ((paragraph.maxIntrinsicWidth - expected).abs() > debugGridTolerance) {
        paragraph.dispose();
        _uncoalescableRuns.add(flags & _layoutFlags);

        for (var i = 0; i < count; i++) {
          line.getCellData(start + i, _cellScratch);
          paintCellForeground(
            canvas,
            lineOffset.translate((start + i) * _cellSize.width, 0),
            _cellScratch,
          );
        }
        return;
      }

      _runCache.put(key, paragraph);
    }

    canvas.drawParagraph(paragraph, runOffset);
    _debugDrawParagraphCount++;
  }

  TextStyle _runTextStyle(
    int foreground,
    int background,
    int flags,
    int underlineStyle,
    int underlineColor,
  ) {
    var color = flags & CellFlags.inverse != 0
        ? resolveBackgroundColor(background)
        : resolveForegroundColor(foreground);
    if (flags & CellFlags.faint != 0) {
      color = color.withOpacity(0.5);
    }
    final underline = flags & CellFlags.underline != 0;
    return _textStyle.toTextStyle(
      color: color,
      bold: flags & CellFlags.bold != 0,
      italic: flags & CellFlags.italic != 0,
      underline: underline,
      underlineStyle: underlineStyle,
      underlineColor: underline && underlineColor != 0
          ? resolveForegroundColor(underlineColor)
          : null,
    );
  }

  /// Flutter does not draw an underline below a space unless it sits between
  /// other regular characters. As a run has neighbours, only the underlined
  /// spaces are substituted; the glyph is identical.
  @pragma('vm:prefer-inline')
  static int _runChar(int charCode, int flags) {
    if (charCode == 0x20 && flags & CellFlags.underline != 0) {
      return 0xA0;
    }
    return charCode;
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
    final cellData = _cellScratch;
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
  List<({int startColumn, int endColumn, bool dashed})> resolveLinkDecorations(
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

    // SGR 5 draws its glyph only in the visible half of the blink cycle. The
    // cell's background is left alone, as xterm does: what blinks is the
    // character, not the block behind it.
    if (!blinkVisible && cellFlags & CellFlags.blink != 0) return;

    // SGR 8 hides the character while keeping what it covers.
    if (cellFlags & CellFlags.invisible != 0) return;

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

    final cacheKey = (
      cellData.content,
      cellData.foreground,
      cellData.background,
      cellFlags,
      cellData.underlineStyle,
      cellData.underlineColor,
      _textScaler.hashCode,
      foregroundOverride,
      backgroundOverride,
    );
    var paragraph = _paragraphCache.getLayoutFromCache(cacheKey);

    if (paragraph == null) {
      var color = cellFlags & CellFlags.inverse != 0
          ? backgroundOverride ?? resolveBackgroundColor(cellData.background)
          : foregroundOverride ?? resolveForegroundColor(cellData.foreground);

      if (cellFlags & CellFlags.faint != 0) {
        color = color.withOpacity(0.5);
      }

      final underline = cellFlags & CellFlags.underline != 0;
      final style = _textStyle.toTextStyle(
        color: color,
        bold: cellFlags & CellFlags.bold != 0,
        italic: cellFlags & CellFlags.italic != 0,
        underline: underline,
        underlineStyle: cellData.underlineStyle,
        underlineColor: underline && cellData.underlineColor != 0
            ? resolveForegroundColor(cellData.underlineColor)
            : null,
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
    _debugDrawParagraphCount++;
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

    final paint = _backgroundPaint..color = color;
    final doubleWidth = cellData.content >> CellContent.widthShift == 2;
    final widthScale = doubleWidth ? 2 : 1;
    final size = Size(_cellSize.width * widthScale, _cellSize.height);
    canvas.drawRect(offset & size, paint);
    _debugDrawBackgroundRectCount++;
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

/// Identifies one laid out glyph: the cell's raw fields and the overrides that
/// reach the [TextStyle].
///
/// A record rather than a hashed int, so the components are compared
/// structurally. A hashed key that collides hands back a [Paragraph] laid out
/// for a different cell, and the terminal paints the wrong glyph: silently,
/// and depending on what else happens to be in the LRU at that moment.
typedef _GlyphKey = (
  int content,
  int foreground,
  int background,
  int flags,
  int underlineStyle,
  int underlineColor,
  int textScalerHash,
  Color? foregroundOverride,
  Color? backgroundOverride,
);

/// Identifies a run of cells laid out as one [Paragraph].
///
/// [flags] holds only the flags that change the painted output; `blink` and
/// `invisible` are resolved before a run is built. [background] is the cell's
/// background only when `inverse` is set, because that is the only time it
/// reaches the style.
typedef _RunKey = (
  String text,
  int foreground,
  int background,
  int flags,
  int underlineStyle,
  int underlineColor,
);

/// A recorded line plus what replaying it costs.
class _CachedLinePicture {
  _CachedLinePicture(this.picture, this.paragraphs, this.backgroundRects);

  final ui.Picture picture;
  final int paragraphs;
  final int backgroundRects;
}

/// Cached hash and overlay state for one line.
class _CachedLineContent {
  /// A revision no [BufferLine] reports, so the first lookup misses.
  int revision = -1;

  int hash = 0;

  /// Whether the row has an SGR 5 cell and therefore two pictures.
  bool hasBlink = false;

  /// Source/version for [overlayHash]; identity catches source switches.
  int overlayRevision = 0;
  TerminalHighlightSource? overlaySource;
  bool overlayValid = false;
  int overlayHash = 0;
}

class _CachedLinkSpans {
  _CachedLinkSpans(this.revision, this.includePlainUrls, this.spans);

  final int revision;
  final bool includePlainUrls;
  final List<TerminalLinkSpan> spans;
}
