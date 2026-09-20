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

/// Content-layer invalidation channels (perf-plan-v2 N3 / WT Invalidate*).
///
/// Cursor blink/position on the product path is handled by the cursor overlay
/// (N1 fingerprint), not [TerminalInvalidation.cursor] on this layer.
enum TerminalInvalidation {
  cursor,
  selection,
  /// Controller notified but selection geometry / highlights unchanged.
  selectionSkipped,
  content,
  chrome,
}

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
    _releaseViewportAnchor();
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
    // Painter setter already clears line pictures; layout for new cell metrics.
    markNeedsLayout();
    _markComposingLayerNeedsPaint();
    _debugNoteInvalidation(TerminalInvalidation.chrome);
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    markNeedsLayout();
    _markComposingLayerNeedsPaint();
    _debugNoteInvalidation(TerminalInvalidation.chrome);
  }

  set theme(TerminalTheme value) {
    if (value == _painter.theme) return;
    _painter.theme = value;
    invalidateChrome();
    _markComposingLayerNeedsPaint();
  }

  set devicePixelRatio(double value) {
    if (value == _painter.devicePixelRatio) return;
    _painter.devicePixelRatio = value;
    // devicePixelRatio also clears line pictures inside painter setter.
    invalidateChrome();
    _markComposingLayerNeedsPaint();
  }

  FocusNode _focusNode;
  FocusNode get focusNode => _focusNode;
  set focusNode(FocusNode value) {
    if (value == _focusNode) return;
    if (attached) _focusNode.removeListener(_onFocusChange);
    _focusNode = value;
    if (attached) _focusNode.addListener(_onFocusChange);
    // Focus only changes cursor chrome on the content layer when this RO
    // paints the cursor itself; product path uses the overlay (N1).
    invalidateCursor();
  }

  TerminalCursorType _cursorType;
  set cursorType(TerminalCursorType value) {
    if (value == _cursorType) return;
    _cursorType = value;
    invalidateCursor();
  }

  bool _cursorBlinkEnabled;
  set cursorBlinkEnabled(bool value) {
    if (value == _cursorBlinkEnabled) return;
    _cursorBlinkEnabled = value;
    // Blink enable/disable only affects cursor overlay drawing when the
    // product path keeps paintCursor:false. Dirty the content layer only if
    // this render object still paints the cursor itself.
    invalidateCursor();
  }

  bool _cursorBlinkVisible;
  set cursorBlinkVisible(bool value) {
    if (value == _cursorBlinkVisible) return;
    _cursorBlinkVisible = value;
    // N1 (perf-plan-v2): blink is an overlay paint param (Ghostty blink_visible
    // / WT cursor mutation id). Never dirty the content layer for blink ticks.
    // When paintCursor is true (tests / legacy), still dirty so the main paint
    // path can hide/show the in-layer cursor.
    invalidateCursor();
  }

  bool _alwaysShowCursor;
  set alwaysShowCursor(bool value) {
    if (value == _alwaysShowCursor) return;
    _alwaysShowCursor = value;
    invalidateCursor();
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
    // New source identity must not reuse pictures keyed by the previous one.
    invalidateChrome();
  }

  bool _paintCursor;
  set paintCursor(bool value) {
    if (value == _paintCursor) return;
    _paintCursor = value;
    // Toggling whether content paints cursor is a content-layer concern.
    invalidateContent();
  }

  bool _paintSelectionHandles;
  set paintSelectionHandles(bool value) {
    if (value == _paintSelectionHandles) return;
    _paintSelectionHandles = value;
    invalidateSelection();
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
      // Composing start/end can change cursor visibility on content layer
      // when paintCursor is true; always treat as content for safety.
      invalidateContent();
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

  /// Benchmark/test access to the line-picture painter. Not for product use.
  @visibleForTesting
  TerminalPainter get debugPainter => _painter;

  var _stickToBottom = true;

  /// 重排前锚定的「视口顶行」。字号变化、拖窗口/面板都会触发重排，此时按像素
  /// 保留的滚动偏移对应的已经是另一段文本了；锚点会随重排 reparent，用它还原
  /// 才能让视口停在原来那段内容上。
  CellAnchor? _viewportAnchor;

  /// 锚定行之内的分数偏移，范围 `[0, 1)`。不能存旧字号下的像素余量，
  /// 否则还原时和新 `cellHeight` 相加会单位混用。
  double _viewportAnchorFraction = 0;

  /// 上一次 layout 时的 cell 高度，用来把 [_scrollOffset] 换算成行号。
  double _lastLayoutCellHeight = 0;

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
    // Scroll changes which buffer rows are visible — content channel.
    invalidateContent();
    _markComposingLayerNeedsPaint();
    _scheduleEditableRectUpdate();
  }

  void _onFocusChange() {
    // Product path: cursor is on overlay (N1). Content layer only dirties when
    // it paints the cursor itself.
    invalidateCursor();
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
    invalidateContent();
    // The composing layer is a repaint boundary, so terminal style changes
    // must invalidate it even when geometry stays unchanged.
    _markComposingLayerNeedsPaint();
    // A re-anchored preedit caret must also move the platform candidate rect.
    if (!_isComposingText || geometryChanged || compositionAnchorChanged) {
      _scheduleEditableRectUpdate();
    }
  }

  void _onControllerUpdate() {
    // Selection / controller highlights: selection channel with geometry gate.
    invalidateSelection();
  }

  void _onHighlightSourceChange() {
    // Span/revision updates for the current highlight source. Pictures already
    // key on highlightRevision, so a paint is enough (no full chrome clear).
    invalidateContent();
  }

  // --- N3 typed invalidation (WT Invalidate* semantics, Flutter carriers) ---

  /// Last selection geometry fingerprint used to skip no-op controller notifies
  /// (e.g. pointer-input-only updates that still call notifyListeners).
  Object? _lastSelectionVisualFingerprint;

  /// Last content-layer invalidation channel (test / debug).
  @visibleForTesting
  TerminalInvalidation? debugLastInvalidation;

  @visibleForTesting
  final Map<TerminalInvalidation, int> debugInvalidationCounts = {
    for (final v in TerminalInvalidation.values) v: 0,
  };

  void _debugNoteInvalidation(TerminalInvalidation channel) {
    debugLastInvalidation = channel;
    debugInvalidationCounts[channel] =
        (debugInvalidationCounts[channel] ?? 0) + 1;
  }

  /// Cursor channel: content layer only if it paints the cursor (`paintCursor`).
  /// Overlay handles blink/focus/position via its own fingerprint (N1).
  void invalidateCursor() {
    _debugNoteInvalidation(TerminalInvalidation.cursor);
    if (_paintCursor) {
      markNeedsPaint();
    }
  }

  /// Selection channel: dirty content when selection geometry (or controller
  /// highlights / mode) actually changes. Pointer-input-only notifies skip.
  void invalidateSelection() {
    final fingerprint = _selectionVisualFingerprint();
    if (fingerprint == _lastSelectionVisualFingerprint) {
      _debugNoteInvalidation(TerminalInvalidation.selectionSkipped);
      return;
    }
    _lastSelectionVisualFingerprint = fingerprint;
    _debugNoteInvalidation(TerminalInvalidation.selection);
    markNeedsPaint();
  }

  /// Content channel: buffer / scroll / composing — always paint content layer.
  void invalidateContent() {
    _debugNoteInvalidation(TerminalInvalidation.content);
    markNeedsPaint();
  }

  /// Chrome channel: theme / font metrics / highlight source identity.
  /// Clears line Picture cache then dirties content.
  void invalidateChrome() {
    _debugNoteInvalidation(TerminalInvalidation.chrome);
    _painter.clearLinePictureCache();
    markNeedsPaint();
  }

  Object? _selectionVisualFingerprint() {
    final selection = _controller.selection?.normalized;
    final highlights = _controller.highlights;
    return Object.hash(
      selection?.begin.x,
      selection?.begin.y,
      selection?.end.x,
      selection?.end.y,
      selection?.runtimeType,
      _controller.selectionMode,
      highlights.length,
      // Identity of highlight entries (add/remove) without deep range walk.
      Object.hashAll(highlights.map((h) => identityHashCode(h))),
      _paintSelectionHandles,
    );
  }

  /// N1 test hook: content-layer markNeedsPaint invocations (debug only).
  @visibleForTesting
  int debugMarkNeedsPaintCount = 0;

  @override
  void markNeedsPaint() {
    assert(() {
      debugMarkNeedsPaintCount++;
      return true;
    }());
    super.markNeedsPaint();
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
    _releaseViewportAnchor();
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

    _captureViewportAnchor();
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
    } else {
      _restoreViewportAnchor();
    }

    _lastLayoutCellHeight = _painter.cellSize.height;
    _syncTerminalGeometryCache();
    _scheduleEditableRectUpdate();
  }

  /// 记录当前视口顶行（含行内分数偏移），供本帧重排后还原。
  void _captureViewportAnchor() {
    _releaseViewportAnchor();
    // 贴着底部时由 stick-to-bottom 负责，不需要锚点。
    if (_stickToBottom) return;

    final lines = _terminal.buffer.lines;
    // `_scrollOffset` 是上一次 layout 那个字号下的像素值：改字号时 painter 在
    // layout 之前就已经换成新高度了，换算行号必须用旧高度。
    final cellHeight = _lastLayoutCellHeight > 0
        ? _lastLayoutCellHeight
        : _painter.cellSize.height;
    final scroll = _scrollOffset;
    if (lines.length == 0 || cellHeight <= 0 || scroll <= 0) return;

    final topLineExact = scroll / cellHeight;
    final topLine = topLineExact.floor().clamp(0, lines.length - 1);
    _viewportAnchor = _terminal.buffer.createAnchor(0, topLine);
    _viewportAnchorFraction = (topLineExact - topLine).clamp(0.0, 1.0 - 1e-9);
  }

  /// 重排后把锚定的那一行放回视口顶部。
  void _restoreViewportAnchor() {
    final anchor = _viewportAnchor;
    _viewportAnchor = null;
    if (anchor == null) return;

    // anchor.attached / anchor.y 必须在 dispose 之前读：dispose 会摘掉 owner。
    final cellHeight = _painter.cellSize.height;
    final double target;
    if (anchor.attached && cellHeight > 0) {
      target = ((anchor.y + _viewportAnchorFraction) * cellHeight)
          .clamp(0.0, _maxScrollExtent);
    } else {
      // 锚定行被裁掉时没法还原原内容，至少把旧像素偏移夹回合法范围。
      target = _scrollOffset.clamp(0.0, _maxScrollExtent);
    }
    anchor.dispose();

    if ((target - _scrollOffset).abs() < 0.5) return;
    _jumpViewportTo(target);
  }

  void _releaseViewportAnchor() {
    _viewportAnchor?.dispose();
    _viewportAnchor = null;
  }

  /// 跳转视口并刷新受影响的图层（内容层 + 输入法合成层 + 光标矩形）。
  void _jumpViewportTo(double offset) {
    _offset.jumpTo(offset);
    invalidateContent();
    _markComposingLayerNeedsPaint();
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
    final source = _highlightSource;

    // N2 + selection look (editors / pre-N2 selected cell path):
    //   1) paintLine — always (line Picture cache)
    //   2) flatten selection range (terminal bg wipe + selection fill) so ANSI
    //      cell backgrounds do not stripe through translucent selection
    //   3) glyphs only in selected columns, with TerminalHighlightSpan overrides
    // Keep fingerprint in sync with what we actually painted (N3 gate).
    final cellData = CellData.empty();
    for (var i = effectFirstLine; i <= effectLastLine; i++) {
      final lineOffset = offset.translate(
          0, (i * charHeight + _lineOffset).truncateToDouble());
      final line = lines[i];
      final lineHighlights = source?.spansForLine(line, i) ?? const [];
      _painter.paintLine(
        canvas,
        lineOffset,
        line,
        highlightRevision: source?.revisionForLine(line, i) ?? 0,
        highlightSource: source,
        highlightLineIndex: i,
      );
      if (selection != null && _selectionIntersectsLine(selection, i)) {
        _paintSelectionRectOnLine(canvas, lineOffset, i, selection);
        _paintSelectionForegroundsOnLine(
          canvas,
          lineOffset,
          line,
          i,
          selection,
          cellData,
          lineHighlights,
        );
      }
    }
    _lastSelectionVisualFingerprint = _selectionVisualFingerprint();

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

  /// Selection range fill for [lineIndex]. Does not touch line Picture keys.
  ///
  /// Wipes with [TerminalTheme.background] first so translucent selection does
  /// not blend with ANSI cell backgrounds baked into the line picture (old
  /// selected-cell path never painted cell bg under selection).
  void _paintSelectionRectOnLine(
    Canvas canvas,
    Offset lineOffset,
    int lineIndex,
    BufferRange selection,
  ) {
    final startColumn = selectedStartColumn(selection, lineIndex);
    final endColumn = selectedEndColumn(
      selection,
      lineIndex,
      _terminal.viewWidth,
    );
    final length = endColumn - startColumn;
    if (length <= 0) return;

    final cellOffset = lineOffset.translate(
      startColumn * _painter.cellSize.width,
      0,
    );
    // Flatten line-picture content in the range (glyphs + ANSI bg).
    _painter.paintHighlight(
      canvas,
      cellOffset,
      length,
      _painter.theme.background,
    );
    _painter.paintHighlight(
      canvas,
      cellOffset,
      length,
      _painter.theme.selection,
    );
  }

  /// Glyphs in the selected columns above the selection fill (original colors
  /// + optional syntax/search [TerminalHighlightSpan] overrides).
  void _paintSelectionForegroundsOnLine(
    Canvas canvas,
    Offset lineOffset,
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
    if (endColumn <= startColumn) return;

    var highlightIndex = 0;
    while (highlightIndex < highlights.length &&
        highlights[highlightIndex].endColumn <= startColumn) {
      highlightIndex++;
    }

    for (var i = startColumn; i < endColumn && i < line.length; i++) {
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
      final cellOffset = lineOffset.translate(i * cellWidth, 0);
      _painter.paintSelectionCellForeground(
        canvas,
        cellOffset,
        cellData,
        highlight,
      );
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

  /// 滚动到指定行。
  ///
  /// 全程按「行」换算：像素偏移只有在 cellSize 不变时才和行号一一对应，而缩放
  /// （改字号 / 拖窗口）会让 cellSize 变化，混着用会算出离谱的目标位置。
  void scrollToLine(int line) {
    final cellHeight = _painter.cellSize.height;
    if (cellHeight <= 0) return;

    final currentScroll = _scrollOffset;
    final viewportHeight = _viewportHeight;
    final visibleFromLine = currentScroll / cellHeight;
    final visibleLines = viewportHeight / cellHeight;

    // 目标行已经在视口内就不动。余量随可见行数收敛，避免 4~5 行小面板里
    // `margin=2` 让守卫恒不成立、每次 F3 都强制跳到中部。
    final margin = (visibleLines / 2 - 0.5).clamp(0.0, 2.0);
    if (line > visibleFromLine + margin &&
        line < visibleFromLine + visibleLines - margin) {
      return;
    }

    // 把目标行放到视口中部。
    final target = ((line - visibleLines / 2) * cellHeight)
        .clamp(0.0, _maxScrollExtent);
    if ((target - currentScroll).abs() < 0.5) return;
    _jumpViewportTo(target);
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
