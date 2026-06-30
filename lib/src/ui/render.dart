import 'dart:math' show max;
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range.dart';
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

typedef EditableRectCallback = void Function(
    Size editableSize, Matrix4 transform, Rect caretRect);

class RenderTerminal extends RenderBox with RelayoutWhenSystemFontsChangeMixin {
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
        _paintCursor = paintCursor,
        _paintSelectionHandles = paintSelectionHandles,
        _shouldReportEditableRect = onEditableRect != null,
        _onEditableRect = onEditableRect,
        _composingText = composingText,
        _painter = TerminalPainter(
          theme: theme,
          textStyle: textStyle,
          textScaler: textScaler,
        ) {
    _syncTerminalGeometryCache();
  }

  Terminal _terminal;
  set terminal(Terminal terminal) {
    if (_terminal == terminal) return;
    if (attached) _terminal.removeListener(_onTerminalChange);
    _terminal = terminal;
    if (attached) _terminal.addListener(_onTerminalChange);
    _resizeTerminalIfNeeded();
    markNeedsLayout();
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
  }

  EdgeInsets _padding;
  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  bool _autoResize;
  set autoResize(bool value) {
    if (value == _autoResize) return;
    _autoResize = value;
    markNeedsLayout();
  }

  set textStyle(TerminalStyle value) {
    if (value == _painter.textStyle) return;
    _painter.textStyle = value;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    markNeedsLayout();
  }

  set theme(TerminalTheme value) {
    if (value == _painter.theme) return;
    _painter.theme = value;
    markNeedsPaint();
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
  set composingText(String? value) {
    if (value == _composingText) return;
    _composingText = value;
    markNeedsPaint();
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
    _stickToBottom = _scrollOffset >= _maxScrollExtent;
    // 滚动只改变视口看到的内容，不改变终端几何信息。
    markNeedsPaint();
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
    if (_didTerminalGeometryChange()) {
      _syncTerminalGeometryCache();
      markNeedsLayout();
      return;
    }

    markNeedsPaint();
    _scheduleEditableRectUpdate();
  }

  void _onControllerUpdate() {
    // 选择、高亮等 controller 更新只影响覆盖层绘制。
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
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void detach() {
    super.detach();
    _offset.removeListener(_onScroll);
    _terminal.removeListener(_onTerminalChange);
    _controller.removeListener(_onControllerUpdate);
    _focusNode.removeListener(_onFocusChange);
  }

  @override
  bool hitTestSelf(Offset position) {
    return true;
  }

  @override
  void systemFontsDidChange() {
    _painter.clearFontCache();
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    size = constraints.biggest;

    _updateViewportSize();

    _updateScrollOffset();

    if (_stickToBottom) {
      _offset.correctBy(_maxScrollExtent - _scrollOffset);
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

  void selectCharsetByCell(CellAnchor from, CellAnchor to) {
    _controller.setSelection(from, to);
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
    final caretRect = cursorOffset & _painter.cellSize;
    final transform = getTransformTo(null);

    _onEditableRect?.call(size, transform, caretRect);
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

  Size get cellSize {
    return _painter.cellSize;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _paint(context, offset);
    context.setWillChangeHint();
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
    final selection = _controller.selection?.normalized;
    final cellData = CellData.empty();

    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      final lineOffset = offset.translate(
          0, (i * charHeight + _lineOffset).truncateToDouble());
      if (selection == null || !_selectionIntersectsLine(selection, i)) {
        _painter.paintLine(canvas, lineOffset, lines[i]);
        continue;
      }
      _paintLineWithSelection(
        canvas,
        lineOffset,
        lines[i],
        i,
        selection,
        cellData,
      );
    }

    if (_terminal.buffer.absoluteCursorY >= effectFirstLine &&
        _terminal.buffer.absoluteCursorY <= effectLastLine) {
      if (_isComposingText) {
        _paintComposingText(canvas, offset + cursorOffset);
      }

      if (_paintCursor &&
          shouldPaintCursor(cursorBlinkVisible: _cursorBlinkVisible)) {
        _painter.paintCursor(
          canvas,
          offset + cursorOffset,
          cursorType: _cursorType,
          hasFocus: _focusNode.hasFocus,
        );
      }
    }

    _paintHighlights(
      canvas,
      _controller.highlights,
      effectFirstLine,
      effectLastLine,
    );
  }

  /// Paints the text that is currently being composed in IME to [canvas] at
  /// [offset]. [offset] is usually the cursor position.
  void _paintComposingText(Canvas canvas, Offset offset) {
    final composingText = _composingText;
    if (composingText == null) {
      return;
    }

    final style = _painter.textStyle.toTextStyle(
      color: _painter.resolveForegroundColor(_terminal.cursor.foreground),
      backgroundColor: _painter.theme.background,
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
    paragraph.layout(ParagraphConstraints(width: size.width));

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
  ) {
    final cellWidth = _painter.cellSize.width;
    final startColumn = _selectedStartColumn(selection, lineIndex);
    final endColumn = _selectedEndColumn(selection, lineIndex);

    if (endColumn > startColumn) {
      _painter.paintHighlight(
        canvas,
        offset.translate(startColumn * cellWidth, 0),
        endColumn - startColumn,
        _painter.theme.selection,
      );
    }

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);
      final isSelected = i >= startColumn && i < endColumn;

      if (isSelected) {
        _painter.paintCellForeground(canvas, cellOffset, cellData);
      } else {
        _painter.paintCell(canvas, cellOffset, cellData);
      }

      if (charWidth == 2) {
        i++;
      }
    }
  }

  int _selectedStartColumn(BufferRange selection, int lineIndex) {
    if (lineIndex == selection.begin.y) {
      return selection.begin.x;
    }
    return 0;
  }

  int _selectedEndColumn(BufferRange selection, int lineIndex) {
    if (lineIndex == selection.end.y) {
      return selection.end.x;
    }
    return _terminal.viewWidth;
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
