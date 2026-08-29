import 'dart:math' show max;
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/buffer/range_block.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/core/buffer/segment.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/core/mouse/button.dart';
import 'package:xterm/src/core/mouse/button_state.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/selection_mode.dart';
import 'package:xterm/src/ui/terminal_size.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';
import 'package:xterm/src/ui/terminal_highlight.dart';
import 'package:xterm/src/utils/unicode_v11.dart';

typedef EditableRectCallback = void Function(
    Size editableSize, Matrix4 transform, Rect caretRect);

class RenderTerminal extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _TerminalParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _TerminalParentData>,
        RelayoutWhenSystemFontsChangeMixin {
  RenderTerminal({
    required Terminal terminal,
    required TerminalController controller,
    required ViewportOffset offset,
    required EdgeInsets padding,
    required bool autoResize,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    required TerminalTheme theme,
    required FocusNode focusNode,
    required TerminalCursorType cursorType,
    required bool cursorBlinkEnabled,
    required bool cursorBlinkVisible,
    required bool alwaysShowCursor,
    TerminalHighlightSource? highlightSource,
    double devicePixelRatio = 1.0,
    bool paintCursor = true,
    bool paintSelectionHandles = true,
    EditableRectCallback? onEditableRect,
    String? composingText,
  })  : _terminal = terminal,
        _controller = controller,
        _offset = offset,
        _padding = padding,
        _autoResize = autoResize,
        _focusNode = focusNode,
        _cursorType = cursorType,
        _cursorBlinkEnabled = cursorBlinkEnabled,
        _cursorBlinkVisible = cursorBlinkVisible,
        _alwaysShowCursor = alwaysShowCursor,
        _highlightSource = highlightSource,
        _paintCursor = paintCursor,
        _paintSelectionHandles = paintSelectionHandles,
        _shouldReportEditableRect = onEditableRect != null,
        _onEditableRect = onEditableRect,
        _composingText = composingText,
        _painter = TerminalPainter(
          theme: theme,
          textStyle: textStyle,
          textScaler: textScaler,
          devicePixelRatio: devicePixelRatio,
        ) {
    _composingLayer = _RenderComposingLayer(this);
    add(_composingLayer);
    _syncCompositionAnchor();
    _syncTerminalGeometryCache();
  }

  late final _RenderComposingLayer _composingLayer;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _TerminalParentData) {
      child.parentData = _TerminalParentData();
    }
  }

  Terminal _terminal;
  set terminal(Terminal terminal) {
    if (_terminal == terminal) return;
    if (attached) _terminal.removeListener(_onTerminalChange);
    _terminal = terminal;
    _compositionAnchor?.dispose();
    _compositionAnchor = null;
    _compositionAnchorBuffer = null;
    _syncCompositionAnchor();
    if (attached) _terminal.addListener(_onTerminalChange);
    _resizeTerminalIfNeeded();
    markNeedsLayout();
    _markComposingLayerNeedsPaint();
  }

  TerminalController _controller;
  set controller(TerminalController controller) {
    if (_controller == controller) return;
    if (attached) _controller.removeListener(_onControllerUpdate);
    _controller = controller;
    if (attached) _controller.addListener(_onControllerUpdate);
    markNeedsLayout();
  }

  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) return;
    if (attached) _offset.removeListener(_onScroll);
    _offset = value;
    if (attached) _offset.addListener(_onScroll);
    markNeedsLayout();
    _markComposingLayerNeedsPaint();
  }

  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
    _markComposingLayerNeedsPaint();
  }

  bool _autoResize;
  set autoResize(bool value) {
    if (value == _autoResize) return;
    _autoResize = value;
    markNeedsLayout();
    _markComposingLayerNeedsPaint();
  }

  set textStyle(TerminalStyle value) {
    if (value == _painter.textStyle) return;
    _painter.textStyle = value;
    markNeedsLayout();
    _markComposingLayerNeedsPaint();
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    markNeedsLayout();
    _markComposingLayerNeedsPaint();
  }

  set theme(TerminalTheme value) {
    if (value == _painter.theme) return;
    _painter.theme = value;
    markNeedsPaint();
    _markComposingLayerNeedsPaint();
  }

  set devicePixelRatio(double value) {
    if (value == _painter.devicePixelRatio) return;
    _painter.devicePixelRatio = value;
    markNeedsPaint();
    _markComposingLayerNeedsPaint();
  }

  FocusNode _focusNode;
  FocusNode get focusNode => _focusNode;
  set focusNode(FocusNode value) {
    if (value == _focusNode) return;
    if (attached) _focusNode.removeListener(_onFocusChange);
    _focusNode = value;
    if (attached) _focusNode.addListener(_onFocusChange);
    markNeedsPaint();
  }

  TerminalCursorType _cursorType;
  set cursorType(TerminalCursorType value) {
    if (value == _cursorType) return;
    _cursorType = value;
    markNeedsPaint();
  }

  bool _cursorBlinkEnabled;
  set cursorBlinkEnabled(bool value) {
    if (value == _cursorBlinkEnabled) return;
    _cursorBlinkEnabled = value;
    markNeedsPaint();
  }

  bool _cursorBlinkVisible;
  set cursorBlinkVisible(bool value) {
    if (value == _cursorBlinkVisible) return;
    _cursorBlinkVisible = value;
    markNeedsPaint();
  }

  bool _alwaysShowCursor;
  set alwaysShowCursor(bool value) {
    if (value == _alwaysShowCursor) return;
    _alwaysShowCursor = value;
    markNeedsPaint();
  }

  TerminalHighlightSource? _highlightSource;
  set highlightSource(TerminalHighlightSource? value) {
    if (identical(value, _highlightSource)) return;
    if (attached) {
      _highlightSource?.removeListener(_onHighlightSourceChange);
    }
    _highlightSource = value;
    if (attached) {
      _highlightSource?.addListener(_onHighlightSourceChange);
    }
    markNeedsPaint();
  }

  bool _paintCursor;
  set paintCursor(bool value) {
    if (value == _paintCursor) return;
    _paintCursor = value;
    markNeedsPaint();
  }

  bool _paintSelectionHandles;
  set paintSelectionHandles(bool value) {
    if (value == _paintSelectionHandles) return;
    _paintSelectionHandles = value;
    markNeedsPaint();
  }

  EditableRectCallback? _onEditableRect;
  set onEditableRect(EditableRectCallback? value) {
    if (value == _onEditableRect) return;
    _onEditableRect = value;
    _shouldReportEditableRect = value != null;
    if (_shouldReportEditableRect) {
      _scheduleEditableRectUpdate();
    }
  }

  bool _shouldReportEditableRect;

  String? _composingText;
  CellAnchor? _compositionAnchor;
  Buffer? _compositionAnchorBuffer;

  set composingText(String? value) {
    if (value == _composingText) return;
    final wasComposing = _isComposingText;
    _composingText = value;
    _syncCompositionAnchor();
    if (wasComposing != _isComposingText) {
      markNeedsPaint();
    }
    // The layer must also repaint when composition ends so its retained
    // raster is cleared before the committed terminal text is painted.
    if (wasComposing || _isComposingText) {
      _composingLayer.markNeedsPaint();
    }
    _scheduleEditableRectUpdate();
  }

  bool get isComposing => _isComposingText;

  void _syncCompositionAnchor() {
    if (!_isComposingText) {
      _compositionAnchor?.dispose();
      _compositionAnchor = null;
      _compositionAnchorBuffer = null;
      return;
    }
    if (_compositionAnchor == null ||
        !_compositionAnchor!.attached ||
        !identical(_compositionAnchorBuffer, _terminal.buffer)) {
      _compositionAnchor?.dispose();
      _compositionAnchor = _terminal.buffer.createAnchorFromCursor();
      _compositionAnchorBuffer = _terminal.buffer;
    }
  }

  void _markComposingLayerNeedsPaint() {
    if (_isComposingText) {
      _composingLayer.markNeedsPaint();
    }
  }

  TerminalSize? _viewportSize;

  final TerminalPainter _painter;

  var _stickToBottom = true;
  bool _editableRectUpdateScheduled = false;
  int _lastKnownLineCount = 0;
  int _lastKnownViewWidth = 0;
  int _lastKnownViewHeight = 0;
  late Buffer _lastKnownBuffer;

  // 添加滚动速率控制变量
  double _scrollSpeed = 0.2; // 默认滚动速率为1.0
  set scrollSpeed(double value) {
    if (value <= 0) return; // 确保速率大于0
    _scrollSpeed = value;
  }

  double get scrollSpeed => _scrollSpeed;

  void _onScroll() {
    // 允许半像素误差，避免高频输出时浮点导致 stick 状态抖掉。
    _stickToBottom = _scrollOffset >= _maxScrollExtent - 0.5;
    // 滚动只改变视口看到的内容，不改变终端几何信息。
    markNeedsPaint();
    _markComposingLayerNeedsPaint();
    _scheduleEditableRectUpdate();
  }

  void _onFocusChange() {
    markNeedsPaint();
    _scheduleEditableRectUpdate();
  }

  void _onTerminalChange() {
    // 终端内容变化并不总是需要重新 layout。
    // 只有行数、活动 buffer、列/行尺寸这些“几何信息”变化时，
    // 才需要重新计算 scroll extent 和 stick-to-bottom。
    final geometryChanged = _didTerminalGeometryChange();
    if (geometryChanged) {
      _syncTerminalGeometryCache();
      markNeedsLayout();
    }
    final previousAnchor = _compositionAnchor?.attached == true
        ? _compositionAnchor!.offset
        : null;
    final previousAnchorBuffer = _compositionAnchorBuffer;
    _syncCompositionAnchor();
    final compositionAnchorChanged =
        previousAnchorBuffer != _compositionAnchorBuffer ||
            previousAnchor !=
                (_compositionAnchor?.attached == true
                    ? _compositionAnchor!.offset
                    : null);
    markNeedsPaint();
    // The composing layer is a repaint boundary, so terminal style changes
    // must invalidate it even when geometry stays unchanged.
    _markComposingLayerNeedsPaint();
    // A re-anchored preedit caret must also move the platform candidate rect.
    if (!_isComposingText || geometryChanged || compositionAnchorChanged) {
      _scheduleEditableRectUpdate();
    }
  }

  void _onControllerUpdate() {
    // 选择、高亮等 controller 更新只影响覆盖层绘制。
    markNeedsPaint();
  }

  void _onHighlightSourceChange() {
    markNeedsPaint();
  }

  @override
  final isRepaintBoundary = true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_onScroll);
    _terminal.addListener(_onTerminalChange);
    _controller.addListener(_onControllerUpdate);
    _highlightSource?.addListener(_onHighlightSourceChange);
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void detach() {
    super.detach();
    _offset.removeListener(_onScroll);
    _terminal.removeListener(_onTerminalChange);
    _controller.removeListener(_onControllerUpdate);
    _highlightSource?.removeListener(_onHighlightSourceChange);
    _focusNode.removeListener(_onFocusChange);
  }

  @override
  void dispose() {
    _compositionAnchor?.dispose();
    super.dispose();
  }

  @override
  bool hitTestSelf(Offset position) {
    return true;
  }

  @override
  void systemFontsDidChange() {
    _painter.clearFontCache();
    _markComposingLayerNeedsPaint();
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    _composingLayer.layout(BoxConstraints.tight(size));
    final parentData = _composingLayer.parentData! as _TerminalParentData;
    parentData.offset = Offset.zero;

    _updateViewportSize();

    // applyContentDimensions 可能在 extent 变大后让 pixels 暂时离开底部；
    // 先锁住进入 layout 前的 stick 状态，避免本帧 stick-to-bottom 丢失。
    final stickToBottom = _stickToBottom;
    _updateScrollOffset();

    if (stickToBottom) {
      final delta = _maxScrollExtent - _scrollOffset;
      if (delta != 0.0) {
        _offset.correctBy(delta);
      }
      _stickToBottom = true;
    }

    _syncTerminalGeometryCache();
    _scheduleEditableRectUpdate();
  }

  /// Total height of the terminal in pixels. Includes scrollback buffer.
  double get _terminalHeight =>
      _terminal.buffer.lines.length * _painter.cellSize.height;

  /// The distance from the top of the terminal to the top of the viewport.
  // double get _scrollOffset => _offset.pixels;
  double get _scrollOffset {
    // return _offset.pixels ~/ _painter.cellSize.height * _painter.cellSize.height;
    return _offset.pixels;
  }

  /// The height of a terminal line in pixels. This includes the line spacing.
  /// Height of the entire terminal is expected to be a multiple of this value.
  double get lineHeight => _painter.cellSize.height;

  /// Get the top-left corner of the cell at [cellOffset] in pixels.
  Offset getOffset(CellOffset cellOffset) {
    final row = cellOffset.y;
    final col = cellOffset.x;
    final x = col * _painter.cellSize.width;
    final y = row * _painter.cellSize.height;
    return Offset(x + _padding.left, y + _padding.top - _scrollOffset);
  }

  /// Get the [CellOffset] of the cell that [offset] is in.
  CellOffset getCellOffset(Offset offset) {
    final x = offset.dx - _padding.left;
    final y = offset.dy - _padding.top + _scrollOffset;
    final row = y ~/ _painter.cellSize.height;
    final col = x ~/ _painter.cellSize.width;
    return CellOffset(
      col.clamp(0, _terminal.viewWidth - 1),
      row.clamp(0, _terminal.buffer.lines.length - 1),
    );
  }

  CellOffset _selectionStartFor(CellOffset offset) {
    final line = _terminal.buffer.lines[offset.y];
    return CellOffset(line.getCharacterStart(offset.x), offset.y);
  }

  CellOffset _selectionEndFor(CellOffset offset) {
    final line = _terminal.buffer.lines[offset.y];
    return CellOffset(line.getCharacterEnd(offset.x), offset.y);
  }

  Iterable<int> _getYOffsetForFindingWord(int y) sync* {
    yield 0;
    if (y > 0) yield -1;
    if (y < _terminal.buffer.lines.length - 1) yield 1;
  }

  /// Selects entire words in the terminal that contains [from] and [to].
  /// In order to better mobile experience, we need to find the word boundary
  /// in the range of [y, y+1, y-1] lines sequentially.
  /// But we should check y>0 before y-1 and y<terminalHeight before y+1.
  BufferRangeLine? selectWord(CellOffset from, [CellOffset? to]) {
    BufferRangeLine? fromBoundary;

    /// Toleration for the point position is not accurate.
    for (final yOffset in _getYOffsetForFindingWord(from.y)) {
      final fromOffset = CellOffset(from.x, from.y + yOffset);
      fromBoundary = _terminal.buffer.getWordBoundary(fromOffset);
      if (fromBoundary != null) break;
    }
    if (fromBoundary == null) return null;

    if (to == null) {
      return selectBufferRange(fromBoundary, mode: SelectionMode.line);
    } else {
      /// Same as find [fromBoundary]
      BufferRangeLine? toBoundary;
      for (final yOffset in _getYOffsetForFindingWord(to.y)) {
        final toOffset = CellOffset(to.x, to.y + yOffset);
        toBoundary = _terminal.buffer.getWordBoundary(toOffset);
        if (toBoundary != null) break;
      }
      if (toBoundary == null) return null;

      final range = fromBoundary.merge(toBoundary);
      return selectBufferRange(range, mode: SelectionMode.line);
    }
  }

  String? get selectedText {
    final selection = _controller.selection;
    if (selection == null) {
      return null;
    }
    return _terminal.buffer.getText(selection);
  }

  CellAnchor createSelectionAnchor(CellOffset offset) {
    return _terminal.buffer.createAnchorFromOffset(_selectionStartFor(offset));
  }

  void selectCharsetByCell(CellAnchor from, CellAnchor to) {
    _controller.setSelection(from, to);
  }

  BufferRangeLine selectCharactersFromAnchor(CellAnchor from, CellOffset to) {
    final normalizedFrom = _selectionStartFor(from.offset);
    final normalizedTo = _selectionStartFor(to);
    final forward = normalizedFrom.isBeforeOrSame(normalizedTo);
    final begin = forward ? normalizedFrom : normalizedTo;
    final end = forward
        ? _selectionEndFor(normalizedTo)
        : _selectionEndFor(normalizedFrom);

    _controller.setSelection(
      _terminal.buffer.createAnchorFromOffset(begin),
      _terminal.buffer.createAnchorFromOffset(end),
    );
    return BufferRangeLine(begin, end);
  }

  /// Selects characters in the terminal that starts from [from] to [to]. At
  /// least one cell is selected even if [from] and [to] are same.
  ///
  /// Returns the actual [BufferRangeLine] that was applied, with wide-character
  /// normalization applied to both endpoints.
  BufferRangeLine selectCharacters(CellOffset from, [CellOffset? to]) {
    final normalizedFrom = _selectionStartFor(from);

    if (to == null) {
      _controller.setSelection(
        _terminal.buffer.createAnchorFromOffset(normalizedFrom),
        _terminal.buffer.createAnchorFromOffset(normalizedFrom),
      );
      return BufferRangeLine.collapsed(normalizedFrom);
    }

    final normalizedTo = _selectionStartFor(to);
    final forward = normalizedFrom.isBeforeOrSame(normalizedTo);
    final begin = forward ? normalizedFrom : normalizedTo;
    final end = forward
        ? _selectionEndFor(normalizedTo)
        : _selectionEndFor(normalizedFrom);

    _controller.setSelection(
      _terminal.buffer.createAnchorFromOffset(begin),
      _terminal.buffer.createAnchorFromOffset(end),
    );
    return BufferRangeLine(begin, end);
  }

  /// Selects the given [range] in the terminal. Both endpoints are normalized
  /// for wide characters. The [range]'s exclusive-end is preserved.
  ///
  /// Returns the actual [BufferRangeLine] that was applied.
  BufferRangeLine selectBufferRange(BufferRange range, {SelectionMode? mode}) {
    final normalized = range.normalized;
    final begin = _selectionStartFor(normalized.begin);
    final end = _selectionStartFor(normalized.end);
    _controller.setSelection(
      _terminal.buffer.createAnchorFromOffset(begin),
      _terminal.buffer.createAnchorFromOffset(end),
      mode: mode ?? _controller.selectionMode,
    );
    return BufferRangeLine(begin, end);
  }

  /// Selects all content in the terminal buffer.
  void selectAll() {
    final buffer = _terminal.buffer;
    if (buffer.height == 0) {
      return;
    }
    final start = buffer.createAnchor(0, 0);
    final end = buffer.createAnchor(buffer.viewWidth, buffer.height - 1);
    _controller.setSelection(start, end);
  }

  void clearSelection() {
    _controller.clearSelection();
  }

  /// Send a mouse event at [offset] with [button] being currently in [buttonState].
  bool mouseEvent(
    TerminalMouseButton button,
    TerminalMouseButtonState buttonState,
    Offset offset, {
    bool motion = false,
  }) {
    final position = getCellOffset(offset);
    return _terminal.mouseInput(
      button,
      buttonState,
      position,
      motion: motion,
    );
  }

  void _notifyEditableRect() {
    final caretRect = _resolveImeCaretRect();
    final transform = getTransformTo(null);

    _onEditableRect?.call(size, transform, caretRect);
  }

  Rect _resolveImeCaretRect() {
    if (!_isComposingText) {
      return cursorOffset & _painter.cellSize;
    }

    return Rect.fromLTWH(
      editableCursorOffset.dx,
      editableCursorOffset.dy,
      0,
      _painter.cellSize.height,
    );
  }

  @visibleForTesting
  static Offset resolveComposingEndOffset({
    required Offset startOffset,
    required String text,
    required int viewWidth,
    required Size cellSize,
  }) {
    if (viewWidth <= 0 || cellSize.width <= 0 || cellSize.height <= 0) {
      return startOffset;
    }

    var column = (startOffset.dx / cellSize.width).round();
    var wrappedRows = 0;
    for (final rune in text.runes) {
      final width = max(0, unicodeV11.wcwidth(rune));
      if (width == 0) {
        continue;
      }
      if (width > viewWidth - column) {
        wrappedRows++;
        column = 0;
      }
      column += width;
      if (column == viewWidth) {
        wrappedRows++;
        column = 0;
      }
    }
    return Offset(
      column * cellSize.width,
      startOffset.dy + wrappedRows * cellSize.height,
    );
  }

  @visibleForTesting
  static List<Rect> resolveComposingBackdropRects({
    required Offset startOffset,
    required String text,
    required int viewWidth,
    required Size cellSize,
  }) {
    if (viewWidth <= 0 || cellSize.width <= 0 || cellSize.height <= 0) {
      return const [];
    }

    var column = (startOffset.dx / cellSize.width).round();
    column = column.clamp(0, viewWidth - 1).toInt();
    var rowOffset = startOffset.dy;
    final rects = <Rect>[];

    Rect? pending;
    void flushPending() {
      if (pending != null) {
        rects.add(pending!);
        pending = null;
      }
    }

    for (final rune in text.runes) {
      final width = max(0, unicodeV11.wcwidth(rune));
      if (width == 0) {
        continue;
      }
      if (width > viewWidth - column) {
        flushPending();
        column = 0;
        rowOffset += cellSize.height;
      }

      final rect = Rect.fromLTWH(
        column * cellSize.width,
        rowOffset,
        width * cellSize.width,
        cellSize.height,
      );
      if (pending != null &&
          pending!.top == rect.top &&
          pending!.right == rect.left) {
        pending = pending!.expandToInclude(rect);
      } else {
        flushPending();
        pending = rect;
      }

      column += width;
      if (column == viewWidth) {
        flushPending();
        column = 0;
        rowOffset += cellSize.height;
      }
    }
    flushPending();

    return rects;
  }

  @visibleForTesting
  static double resolveComposingParagraphWidth({
    required int viewWidth,
    required Size cellSize,
    required double fallbackWidth,
  }) {
    if (viewWidth <= 0 || cellSize.width <= 0) {
      return fallbackWidth;
    }
    return viewWidth * cellSize.width;
  }

  void _scheduleEditableRectUpdate() {
    if (_editableRectUpdateScheduled ||
        !_shouldReportEditableRect ||
        _onEditableRect == null) {
      return;
    }

    _editableRectUpdateScheduled = true;

    SchedulerBinding.instance.addPostFrameCallback((_) {
      _editableRectUpdateScheduled = false;

      if (!attached ||
          !hasSize ||
          !_shouldReportEditableRect ||
          _onEditableRect == null) {
        return;
      }

      _notifyEditableRect();
    });
  }

  /// Update the viewport size in cells based on the current widget size in
  /// pixels.
  void _updateViewportSize() {
    if (size <= _painter.cellSize) {
      return;
    }

    final viewportSize = TerminalSize(
      size.width ~/ _painter.cellSize.width,
      _viewportHeight ~/ _painter.cellSize.height,
    );

    if (_viewportSize != viewportSize) {
      _viewportSize = viewportSize;
      _resizeTerminalIfNeeded();
    }
  }

  /// Notify the underlying terminal that the viewport size has changed.
  void _resizeTerminalIfNeeded() {
    if (_autoResize && _viewportSize != null) {
      _terminal.resize(
        _viewportSize!.width,
        _viewportSize!.height,
        _painter.cellSize.width.round(),
        _painter.cellSize.height.round(),
      );
    }
  }

  /// Update the scroll offset based on the current terminal state. This should
  /// be called in [performLayout] after the viewport size has been updated.
  void _updateScrollOffset() {
    _offset.applyViewportDimension(_viewportHeight);
    _offset.applyContentDimensions(0, _maxScrollExtent);
  }

  bool get _isComposingText {
    return _composingText != null && _composingText!.isNotEmpty;
  }

  CellData get _composingCellStyle {
    final cursor = _terminal.cursor;
    return CellData(
      foreground: cursor.foreground,
      background: cursor.background,
      flags: cursor.attrs,
      content: 0,
    );
  }

  @visibleForTesting
  Color? get composingBackdropColor {
    return _painter.effectiveBackgroundColor(_composingCellStyle);
  }

  Color get _composingForegroundColor {
    return _painter.effectiveForegroundColor(_composingCellStyle);
  }

  bool get _shouldShowCursor {
    return _terminal.cursorVisibleMode || _alwaysShowCursor || _isComposingText;
  }

  bool get shouldShowCursor {
    return _shouldShowCursor;
  }

  bool shouldPaintCursor({required bool cursorBlinkVisible}) {
    return _shouldShowCursor &&
        (!_cursorBlinkEnabled ||
            !_focusNode.hasFocus ||
            cursorBlinkVisible ||
            _isComposingText);
  }

  bool get isCursorInViewport {
    if (!hasSize) {
      return false;
    }
    final y = editableCursorOffset.dy;
    final cellHeight = _painter.cellSize.height;
    return y + cellHeight > 0 && y < size.height;
  }

  bool get shouldHintWillChange {
    return _cursorBlinkEnabled &&
        _focusNode.hasFocus &&
        !_alwaysShowCursor &&
        !_isComposingText &&
        _terminal.cursorVisibleMode;
  }

  double get _viewportHeight {
    return size.height - _padding.vertical;
  }

  double get _maxScrollExtent {
    return max(_terminalHeight - _viewportHeight, 0.0);
  }

  double get _lineOffset {
    return -_scrollOffset + _padding.top;
  }

  /// The offset of the cursor from the top left corner of this render object.
  Offset get cursorOffset {
    return Offset(
      _terminal.buffer.cursorX * _painter.cellSize.width,
      _terminal.buffer.absoluteCursorY * _painter.cellSize.height + _lineOffset,
    );
  }

  Offset get compositionAnchorOffset {
    _syncCompositionAnchor();
    final anchor = _compositionAnchor;
    if (anchor == null || !anchor.attached) {
      return cursorOffset;
    }
    return Offset(
      anchor.x * _painter.cellSize.width,
      anchor.y * _painter.cellSize.height + _lineOffset,
    );
  }

  /// IME caret: live PTY cursor, or the end of frozen preedit during composition.
  Offset get editableCursorOffset {
    final composingText = _composingText;
    if (composingText == null || composingText.isEmpty) {
      return cursorOffset;
    }
    return resolveComposingEndOffset(
      startOffset: compositionAnchorOffset,
      text: composingText,
      viewWidth: _terminal.viewWidth,
      cellSize: _painter.cellSize,
    );
  }

  Size get cellSize {
    return _painter.cellSize;
  }

  bool get isCompositionInViewport {
    if (!hasSize || !_isComposingText) {
      return false;
    }
    return resolveComposingBackdropRects(
      startOffset: compositionAnchorOffset,
      text: _composingText!,
      viewWidth: _terminal.viewWidth,
      cellSize: _painter.cellSize,
    ).any((rect) => rect.overlaps(Offset.zero & size));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _paint(context, offset);
    context.paintChild(_composingLayer, offset);
  }

  void _paint(PaintingContext context, Offset offset) {
    final canvas = context.canvas;

    final lines = _terminal.buffer.lines;
    final charHeight = _painter.cellSize.height;

    final firstLineOffset = _scrollOffset - _padding.top;
    final lastLineOffset = _scrollOffset + size.height + _padding.bottom;

    final firstLine = firstLineOffset ~/ charHeight;
    final lastLine = lastLineOffset ~/ charHeight;

    final effectFirstLine = firstLine.clamp(0, lines.length - 1);
    final effectLastLine = lastLine.clamp(0, lines.length - 1);
    _highlightSource?.updateVisibleRange(effectFirstLine, effectLastLine);
    final selection = _controller.selection?.normalized;
    final cellData = CellData.empty();

    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      final lineOffset = offset.translate(
          0, (i * charHeight + _lineOffset).truncateToDouble());
      if (selection == null || !_selectionIntersectsLine(selection, i)) {
        final source = _highlightSource;
        _painter.paintLine(
          canvas,
          lineOffset,
          lines[i],
          highlightRevision: source?.revisionForLine(lines[i], i) ?? 0,
          highlightSource: source,
          highlightLineIndex: i,
        );
        continue;
      }
      _paintLineWithSelection(
        canvas,
        lineOffset,
        lines[i],
        i,
        selection,
        cellData,
        _highlightSource?.spansForLine(lines[i], i) ?? const [],
      );
    }

    if (isCursorInViewport &&
        _paintCursor &&
        shouldPaintCursor(cursorBlinkVisible: _cursorBlinkVisible)) {
      _painter.paintCursor(
        canvas,
        offset + cursorOffset,
        cursorType: _cursorType,
        hasFocus: _focusNode.hasFocus,
      );
    }

    _paintHighlights(
      canvas,
      _controller.highlights,
      effectFirstLine,
      effectLastLine,
    );
  }

  /// Paints the text that is currently being composed in IME to [canvas] at
  /// [offset]. [offset] is the frozen composition start, not the live PTY cursor.
  void _paintComposingText(Canvas canvas, Offset offset) {
    final composingText = _composingText;
    if (composingText == null) {
      return;
    }

    final backdropColor = composingBackdropColor;
    if (backdropColor != null) {
      final backdropPaint = Paint()
        ..color = backdropColor
        ..isAntiAlias = false;
      for (final rect in resolveComposingBackdropRects(
        startOffset: offset,
        text: composingText,
        viewWidth: _terminal.viewWidth,
        cellSize: _painter.cellSize,
      )) {
        canvas.drawRect(rect, backdropPaint);
      }
    }

    final style = _painter.textStyle.toTextStyle(
      color: _composingForegroundColor,
      underline: true,
    );

    final builder = ParagraphBuilder(style.getParagraphStyle());
    builder.addPlaceholder(
      offset.dx,
      _painter.cellSize.height,
      PlaceholderAlignment.middle,
    );
    builder.pushStyle(style.getTextStyle(textScaler: _painter.textScaler));
    builder.addText(composingText);

    final paragraph = builder.build();
    final paragraphWidth = resolveComposingParagraphWidth(
      viewWidth: _terminal.viewWidth,
      cellSize: _painter.cellSize,
      fallbackWidth: size.width,
    );
    paragraph.layout(ParagraphConstraints(width: paragraphWidth));

    canvas.drawParagraph(paragraph, Offset(0, offset.dy));
  }

  bool _selectionIntersectsLine(BufferRange selection, int line) {
    final begin = selection.begin;
    final end = selection.end;
    return line >= begin.y && line <= end.y;
  }

  void _paintLineWithSelection(
    Canvas canvas,
    Offset offset,
    BufferLine line,
    int lineIndex,
    BufferRange selection,
    CellData cellData,
    List<TerminalHighlightSpan> highlights,
  ) {
    final cellWidth = _painter.cellSize.width;
    final startColumn = selectedStartColumn(selection, lineIndex);
    final endColumn = selectedEndColumn(
      selection,
      lineIndex,
      _terminal.viewWidth,
    );
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

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);
      final isSelected = i >= startColumn && i < endColumn;

      if (isSelected) {
        _painter.paintSelectedCellWithHighlight(
          canvas,
          cellOffset,
          cellData,
          highlight,
        );
      } else {
        _painter.paintCellWithHighlight(
          canvas,
          cellOffset,
          cellData,
          highlight,
        );
      }

      if (charWidth == 2) {
        i++;
      }
    }
  }

  @visibleForTesting
  static int selectedStartColumn(BufferRange selection, int lineIndex) {
    if (selection is BufferRangeBlock) {
      return selection.begin.x;
    }
    if (lineIndex == selection.begin.y) {
      return selection.begin.x;
    }
    return 0;
  }

  @visibleForTesting
  static int selectedEndColumn(
    BufferRange selection,
    int lineIndex,
    int viewWidth,
  ) {
    if (selection is BufferRangeBlock) {
      return selection.end.x;
    }
    if (lineIndex == selection.end.y) {
      return selection.end.x;
    }
    return viewWidth;
  }

  void _paintHighlights(
    Canvas canvas,
    List<TerminalHighlight> highlights,
    int firstLine,
    int lastLine,
  ) {
    for (var highlight in _controller.highlights) {
      final range = highlight.range?.normalized;

      if (range == null ||
          range.begin.y > lastLine ||
          range.end.y < firstLine) {
        continue;
      }

      for (var segment in range.toSegments()) {
        if (segment.line < firstLine) {
          continue;
        }

        if (segment.line > lastLine) {
          break;
        }

        _paintSegment(canvas, segment, highlight.color);
      }
    }
  }

  @pragma('vm:prefer-inline')
  void _paintSegment(Canvas canvas, BufferSegment segment, Color color) {
    final start = segment.start ?? 0;
    final end = segment.end ?? _terminal.viewWidth;

    final startOffset = Offset(
      start * _painter.cellSize.width,
      segment.line * _painter.cellSize.height + _lineOffset,
    );

    _painter.paintHighlight(canvas, startOffset, end - start, color);
  }

  /// 滚动到指定行
  void scrollToLine(int line) {
    // 余量
    final above = 10;
    final cellHeight = _painter.cellSize.height;
    final currentScroll = _scrollOffset;
    final viewportHeight = _viewportHeight;

    // 计算目标行的像素位置
    final targetY = line * cellHeight;

    // 计算视口边界
    final visibleTop = currentScroll;
    final visibleBottom = currentScroll + viewportHeight;

    // 如果目标行不在视口范围内，需要滚动
    if (targetY < visibleTop - above ||
        targetY > visibleBottom - cellHeight - above) {
      print(
          'scrollToLine: $line, targetY: $targetY, visibleTop: $visibleTop, visibleBottom: $visibleBottom, cellHeight: $cellHeight');
      // 计算需要滚动的像素距离
      final scrollDelta = targetY - (visibleTop + viewportHeight / 2);
      _offset.jumpTo(currentScroll + scrollDelta);
      markNeedsPaint();
      _scheduleEditableRectUpdate();
    }
  }

  /// 获取当前视口范围（行号）
  List<int> getViewportRange() {
    final cellHeight = _painter.cellSize.height;
    final currentScroll = _scrollOffset;
    final viewportHeight = _viewportHeight;

    final startLine = (currentScroll / cellHeight).floor();
    final endLine = ((currentScroll + viewportHeight) / cellHeight).ceil();

    return [startLine, endLine];
  }

  bool _didTerminalGeometryChange() {
    return _lastKnownLineCount != _terminal.buffer.lines.length ||
        _lastKnownViewWidth != _terminal.viewWidth ||
        _lastKnownViewHeight != _terminal.viewHeight ||
        !identical(_lastKnownBuffer, _terminal.buffer);
  }

  void _syncTerminalGeometryCache() {
    _lastKnownLineCount = _terminal.buffer.lines.length;
    _lastKnownViewWidth = _terminal.viewWidth;
    _lastKnownViewHeight = _terminal.viewHeight;
    _lastKnownBuffer = _terminal.buffer;
  }
}

class _TerminalParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderComposingLayer extends RenderBox {
  _RenderComposingLayer(this._terminal);

  final RenderTerminal _terminal;

  @override
  bool get isRepaintBoundary => true;

  @override
  Rect get paintBounds {
    if (!_terminal.isComposing || !_terminal.isCompositionInViewport) {
      return Rect.zero;
    }
    final rects = RenderTerminal.resolveComposingBackdropRects(
      startOffset: _terminal.compositionAnchorOffset,
      text: _terminal._composingText!,
      viewWidth: _terminal._terminal.viewWidth,
      cellSize: _terminal.cellSize,
    );
    var bounds = rects.first;
    for (final rect in rects.skip(1)) {
      bounds = bounds.expandToInclude(rect);
    }
    return bounds.inflate(1).intersect(Offset.zero & _terminal.size);
  }

  @override
  void performLayout() {
    size = constraints.biggest;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_terminal.isComposing && _terminal.isCompositionInViewport) {
      _terminal._paintComposingText(
        context.canvas,
        offset + _terminal.compositionAnchorOffset,
      );
    }
  }
}
