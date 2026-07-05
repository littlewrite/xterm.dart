import 'dart:math' show max;
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/core/buffer/buffer.dart';
import 'package:xterm/src/utils/circular_buffer.dart';
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
import 'package:xterm/src/ui/paint_debug.dart';
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
    _invalidateComposingCache();
    _invalidateContentCache();
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (value == _painter.textScaler) return;
    _painter.textScaler = value;
    _invalidateComposingCache();
    _invalidateContentCache();
    markNeedsLayout();
  }

  set theme(TerminalTheme value) {
    if (value == _painter.theme) return;
    _painter.theme = value;
    _invalidateContentCache();
    markNeedsPaint();
  }

  void _invalidateComposingCache() {
    _composingParagraph = null;
    _composingCacheText = null;
  }

  // [调试] 上一帧 paint 走的路径：0=全画, 1=滚动复用, 2=增量, 3=零成本滚动。
  // 仅用于 benchmark/测试观察，正式版可删。
  int dbgLastPaintMode = -1;

  // [调试] 上一帧 paint 实际重画的行索引集合（全画=所有可见行，
  // 增量/scroll=dirty+新露出）。测试用，验证新内容行确实被画。
  Set<int>? dbgLastPaintedLines;

  // [调试] performLayout 调用次数。用于验证持续输出时是否仍然每行都 layout。
  int dbgLayoutCount = 0;

  // 零成本滚动路径专用：本次 paint 时，缓存 Picture 相对当前视口需要的 y 偏移。
  // > 0 表示缓存内容需上移这么多像素（视口下移了）；画缓存 Picture 前要 translate。
  // 仅在走 zeroCostScroll 路径时有效，其他路径为 0。
  double _scrollTranslateDy = 0;

  void _invalidateContentCache() {
    if (TerminalPaintDebug.enabled) {
      // 打印调用方栈顶几帧，定位是谁清了缓存。
      // 通常只关心前 3-5 帧（去掉 dart:core 和当前方法自身）。
      final frames = StackTrace.current.toString().split('\n');
      final callers = frames
          .where((l) =>
              l.contains('render.dart') &&
              !l.contains('_invalidateContentCache'))
          .take(3)
          .join(' | ');
      TerminalPaintDebug.log(
          '    _invalidateContentCache by: ${callers.isEmpty ? "(external)" : callers}');
    }
    _contentPicture = null;
    _picLineCount = -1;
    _picFirstLine = -1;
    _picLastLine = -1;
    _picScrollOffset = double.nan;
    _picSize = Size.zero;
    // 缓存失效：累积的"自缓存 dirty"也一并清空（无缓存时本集合无意义）。
    _dirtySinceCache.clear();
  }

  set devicePixelRatio(double value) {
    if (value == _painter.devicePixelRatio) return;
    _painter.devicePixelRatio = value;
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
    // 主层不画光标（_paintCursor 在 TerminalView 里恒为 false，光标由独立的
    // _RenderTerminalCursorOverlay 覆盖层绘制），所以光标闪烁不应牵连主层重画。
    // 之前这里 markNeedsPaint() 导致光标每 ~530ms 闪烁一次就让主层全画一次，
    // 抵消了 dirty 缓存优化。去掉它，光标闪烁只影响覆盖层。
    // 若将来主层重新启用光标绘制（_paintCursor=true），需恢复这里的 markNeedsPaint。
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

  /// IME 合成文本 Paragraph 的轻量缓存，避免每次 paint 都 rebuild+layout。
  /// 键：composingText + 前景色 + 背景色 + 占位 dx + 可用宽度。
  Paragraph? _composingParagraph;
  String? _composingCacheText;
  int _composingCacheFg = 0;
  Color _composingCacheBg = const Color(0x00000000);
  double _composingCacheDx = -1;
  double _composingCacheWidth = -1;

  TerminalSize? _viewportSize;

  final TerminalPainter _painter;

  // ---------------------------------------------------------------------------
  // 行级 dirty + 内容 Picture 缓存
  //
  // Flutter 每帧给 paint 一个新的录制 canvas，"跳过某行不画"会让该行空白，
  // 所以不能简单跳过未变行。这里缓存上一帧画好的整屏内容 [ui.Picture]，
  // 未变行通过 drawPicture 一次重现；只有 dirty 行才重新 cell 级绘制。
  //
  // 收益：稀疏输入（敲字、单行刷新）场景，从每帧遍历 80×24=1920 cell 降到
  // 一次 drawPicture + N 行重画（N 通常 1~3）。这是行级 dirty 的核心价值。
  //
  // 安全约束（强制全画、不增量）：
  //  - buffer 报告 allDirty（结构变化：scroll/resize/reflow/clear）
  //  - 视口变化（scrollOffset / size / cellSize / 可见行集变化）
  //  - 有 selection 或 highlights（这些叠加层会跨行，增量覆盖会破坏它们）
  //  - 首次 paint 或缓存失效
  // 光标 / IME 合成文本不进缓存，每帧画在 Picture 之上。
  // ---------------------------------------------------------------------------

  Picture? _contentPicture;
  double _picScrollOffset = double.nan;
  Size _picSize = Size.zero;
  int _picLineCount = -1;
  // 缓存对应的可见行范围 [firstLine, lastLine]（相对索引）。
  int _picFirstLine = -1;
  int _picLastLine = -1;

  // 自缓存 Picture 录制以来，缓冲区内容已变、但缓存里仍是旧内容的行（相对索引）。
  //
  // 为什么需要它：mode=2（原地编辑、不平移）每帧都 drawPicture(缓存) 当底——
  // 缓存里画的是录制时的旧内容。若只重画"本帧 dirty"，上一帧画过的 delta 行
  // 会被缓存里的旧内容擦掉，表现为"内容逐帧从上往下消失"（用户反馈：光换行、
  // 之前的内容没了）。所以 mode=2 必须把"自缓存以来所有编辑过的行"都重画。
  //
  // mode=1/3（滚动）走 translate 复用——旧行内容不变、整体平移，缓存的旧内容
  // 平移后仍正确，故不需要这个集合（且要求它为空才允许走滚动，否则提升全画）。
  final Set<int> _dirtySinceCache = {};

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
    // 只有活动 buffer、列/行尺寸这些“视口几何”变化时，才必须走 layout。
    // lineCount 变化同样会影响 scroll extent，因此仍需在 layout 阶段更新
    // ScrollPosition 的 content dimensions。
    final viewportChanged = _didViewportGeometryChange();
    final extentChanged = _didContentExtentChange();
    TerminalPaintDebug.log(
        'onTerminalChange viewport=$viewportChanged extent=$extentChanged '
        'lines=${_terminal.buffer.lines.length} '
        'cursorAbsY=${_terminal.buffer.absoluteCursorY}');
    if (viewportChanged) {
      _syncTerminalGeometryCache();
      markNeedsLayout();
      // 注意：必须同时 markNeedsPaint。markNeedsLayout 不保证触发 paint——
      // 若 layout 后 size 未变且无 paint 标记，Flutter 会跳过本帧 paint 阶段,
      // 导致"内容已写入 buffer 但画面没更新"（症状：回车/输出后要等一下或
      // 滚动一下才显示）。早期版本靠光标闪烁定时器的 markNeedsPaint 心跳
      // 兜底（每 ~530ms 强制重画），批 3 移除该心跳后这个隐患暴露了。
      // 这里显式标记，不再依赖兜底。
      markNeedsPaint();
      return;
    }

    if (extentChanged) {
      _syncTerminalGeometryCache();
      markNeedsLayout();
      markNeedsPaint();
      return;
    }

    markNeedsPaint();
    _scheduleEditableRectUpdate();
  }

  void _onControllerUpdate() {
    // 选择、高亮等 controller 更新会影响内容 Picture（选区行用不同绘制路径）。
    // 失效缓存，下次全画。叠加层 highlights 本身每帧重画，不在缓存里。
    TerminalPaintDebug.log('    _onControllerUpdate (invalidate cache) '
        'selection=${_controller.selection != null} '
        'highlights=${_controller.highlights.length}');
    _invalidateContentCache();
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
    _invalidateContentCache();
    super.systemFontsDidChange();
  }

  @override
  void performLayout() {
    dbgLayoutCount++;
    size = constraints.biggest;

    _updateViewportSize();

    _updateScrollOffset();

    final before = _scrollOffset;
    if (_stickToBottom) {
      _offset.correctBy(_maxScrollExtent - _scrollOffset);
    }
    TerminalPaintDebug.log(
        '  performLayout scrollOff $before→$_scrollOffset max=$_maxScrollExtent '
        'stick=$_stickToBottom termH=$_terminalHeight viewH=$_viewportHeight');

    _syncTerminalGeometryCache();
    _scheduleEditableRectUpdate();
  }

  /// 模拟"终端变化 + stick-to-bottom 跟随"。
  /// 仅用于 benchmark/测试：真实 widget 中由 _onTerminalChange + Scrollable 驱动。
  /// 调用此方法会像终端刚写入数据那样：标记需要 layout（重算 scroll extent）、
  /// 应用 stick-to-bottom、标记需要 paint。
  void simulateTerminalChangeForTest() {
    if (_didViewportGeometryChange() || _didContentExtentChange()) {
      _syncTerminalGeometryCache();
      markNeedsLayout();
    }
    markNeedsPaint();
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

  bool get isCursorInViewport {
    final lines = _terminal.lines;
    if (lines.length == 0) {
      return false;
    }
    final firstLine = _scrollOffset ~/ _painter.cellSize.height;
    final lastLine = (_scrollOffset + size.height - _padding.vertical) ~/
        _painter.cellSize.height;
    final effectFirstLine = firstLine.clamp(0, lines.length - 1);
    final effectLastLine = lastLine.clamp(0, lines.length - 1);
    return _terminal.buffer.absoluteCursorY >= effectFirstLine &&
        _terminal.buffer.absoluteCursorY <= effectLastLine;
  }

  bool get shouldHintWillChange {
    return _cursorBlinkEnabled &&
        _focusNode.hasFocus &&
        !_alwaysShowCursor &&
        !_isComposingText &&
        _terminal.cursorVisibleMode;
  }

  /// 返回光标视觉状态的指纹。光标覆盖层用它判断终端内容变化是否真的
  /// 影响光标视觉，从而跳过无关变化（如其他行写入、上方滚屏）触发的
  /// 无谓重绘。涉及光标位置、滚动、可见性、类型、焦点。
  int get cursorVisualFingerprint {
    return Object.hash(
      _terminal.buffer.cursorX,
      _terminal.buffer.absoluteCursorY,
      _scrollOffset,
      _terminal.cursorVisibleMode,
      _cursorType,
      _focusNode.hasFocus,
      _painter.cellSize,
      _isComposingText,
    );
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
    // 不再无条件调用 context.setWillChangeHint()。
    //
    // 原实现每次 paint 都标记本层 willChangeHint，告知合成器"这层下一帧
    // 还会变，别 raster-cache 它"。结果：终端静止、app 中有其他 widget
    // 在动（触发合成）时，合成器每帧都要重新光栅化整个终端层，浪费 GPU。
    //
    // 事实上：本层只在 _onTerminalChange / _onScroll / _onFocusChange /
    // _onControllerUpdate（即"内容真的变了"）时被 markNeedsPaint。静止时
    // Flutter 根本不会再 paint 本层，上一帧的 layer 应当被合成器按启发式
    // 缓存复用。本层是 isRepaintBoundary，本身就是 raster cache 的候选。
    //
    // 光标闪烁的"频繁变"提示已由独立的 _RenderTerminalCursorOverlay 层
    // （它自己的 paint 里按 shouldHintWillChange 条件给 hint）处理，
    // 不需要主层配合。
    //
    // 如果将来发现静止帧出现光标残影/内容不刷新，说明 markNeedsPaint 路径
    // 有遗漏，应在那里修，而不是靠这里的 hint 兜底。
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
    final hasOverlay = selection != null || _controller.highlights.isNotEmpty;

    // 取 dirty（不清空，paint 成功后再清）。
    final dirty = _terminal.buffer.takeDirtyLines();
    // ignore: avoid_print
    if (const bool.fromEnvironment('xterm.debug.dirty')) {
      print('[xterm-dirty] allDirty=${dirty.allDirty} lines=${dirty.lines}');
    }

    // 视口变化判定。
    final sizeChanged = _picSize != size;
    final lineDelta = effectFirstLine - _picFirstLine;
    final picRows = _picLastLine - _picFirstLine;
    final curRows = effectLastLine - effectFirstLine;
    // 纯滚动：size 不变、只是整体平移 lineDelta 行。
    // 注意：picRows 和 curRows 可能差 ±1——平滑滚动（触控板）下 scrollOff 是
    // 分数，charHeight 也常是分数（如 15.53），effectFirstLine/LastLine 因
    // ~/charHeight 取整会在边界抖动，使 curRows 在 N 和 N±1 之间跳。若严格
    // 要求 picRows==curRows，这种抖动会让 isPureScroll 反复失败 → 每滚一步
    // 全画整屏。这里容忍 |picRows-curRows|<=1，多/少的那行在 scroll 路径里
    // 当作 exposed 单独重画。
    final rowsDelta = (picRows - curRows).abs();
    // 注意：滚动复用要求 _dirtySinceCache 为空——缓存 Picture 只是整体平移，
    // 它画的是"录制时的旧行内容"，原地编辑过的行平移后仍是旧的。若已有
    // 自缓存以来的编辑未消化，必须走全画（或等 mode=2 先消化）。
    final hasStaleEdits = _dirtySinceCache.isNotEmpty;
    final isPureScroll = _contentPicture != null &&
        !sizeChanged &&
        rowsDelta <= 1 &&
        picRows > 0 &&
        lineDelta != 0 &&
        lineDelta.abs() < picRows &&
        !hasStaleEdits;
    if (TerminalPaintDebug.enabled &&
        !isPureScroll &&
        lineDelta != 0 &&
        _contentPicture != null &&
        !hasOverlay) {
      // 滚动本应走 scroll 复用，却走了全画——打印为什么 isPureScroll 失败。
      TerminalPaintDebug.log('    isPureScroll=false despite scroll: '
          'picFirst=$_picFirstLine picLast=$_picLastLine '
          'effFirst=$effectFirstLine effLast=$effectLastLine '
          'picRows=$picRows curRows=$curRows '
          'rowsEqual=${picRows == curRows} '
          'lineDelta=$lineDelta '
          'deltaLtRows=${lineDelta.abs() < picRows} '
          'sizeChanged=$sizeChanged');
    }

    final viewportChanged = _picScrollOffset != _scrollOffset ||
        _picSize != size ||
        _picFirstLine != effectFirstLine ||
        _picLastLine != effectLastLine ||
        _picLineCount != lines.length;

    // 全画条件：allDirty / 无缓存 / 有叠加层 / 非纯滚动的视口变化。
    final fullRepaint = dirty.allDirty ||
        _contentPicture == null ||
        hasOverlay ||
        (!isPureScroll && viewportChanged);

    if (TerminalPaintDebug.enabled && fullRepaint && !dirty.allDirty) {
      // 排查"dirty=0 却全画"的浪费：打印触发原因。
      TerminalPaintDebug.log('    fullRepaint reason: '
          'noCache=${_contentPicture == null} '
          'overlay=$hasOverlay '
          'viewportChanged=$viewportChanged '
          '(scrollOff=${_picScrollOffset != _scrollOffset} '
          'size=${_picSize != size} '
          'firstLine=${_picFirstLine != effectFirstLine} '
          'lastLine=${_picLastLine != effectLastLine} '
          'lineCount=${_picLineCount != lines.length})');
    }

    // 缓存 Picture 的"有效半径"：当前视口相对缓存基准视口偏移超过这个值，
    // 缓存内容已大部分不在视口内，强制全画重建。设为半屏行数。
    final maxTranslateRows = picRows > 0 ? picRows ~/ 2 : 10;
    final cacheDrift = (_picScrollOffset - _scrollOffset).abs() / charHeight;
    final cacheTooFar =
        _contentPicture != null && cacheDrift > maxTranslateRows;

    // mode=2（原地编辑、不平移）每帧以缓存 Picture 当底。缓存是录制时的旧内容，
    // 所以"自缓存以来编辑过的行"(_dirtySinceCache) 每帧都要重画，否则上一帧画
    // 的 delta 会被缓存里的旧内容擦掉。但累积的 stale 行越多，每帧重画成本越高；
    // 超过半屏时不如直接全画重建缓存（同时清空 stale 集合）。
    final staleTooMany = _dirtySinceCache.length > maxTranslateRows;

    if (fullRepaint || cacheTooFar || staleTooMany) {
      dbgLastPaintMode = 0;
      _scrollTranslateDy = 0;
      _contentPicture = _recordContentPicture(
        offset: offset,
        lines: lines,
        effectFirstLine: effectFirstLine,
        effectLastLine: effectLastLine,
        charHeight: charHeight,
        selection: selection,
      );
      dbgLastPaintedLines = {
        for (var i = effectFirstLine; i <= effectLastLine; i++) i,
      };
      _picScrollOffset = _scrollOffset;
      _picSize = size;
      _picFirstLine = effectFirstLine;
      _picLastLine = effectLastLine;
      _picLineCount = lines.length;
      // 缓存重建为最新内容——累积的 stale 行已反映在缓存里，清空。
      final staleCount = _dirtySinceCache.length;
      _dirtySinceCache.clear();
      if (cacheTooFar) {
        TerminalPaintDebug.log(
            '    cache reset (drift=${cacheDrift.toStringAsFixed(1)} rows '
            '> $maxTranslateRows)');
      } else if (staleTooMany) {
        TerminalPaintDebug.log(
            '    cache reset (stale=$staleCount > $maxTranslateRows)');
      }
    } else if (isPureScroll) {
      // 滚动：缓存 Picture + translate 复用，exposed 行 + dirty 行画到 canvas。
      // 不录新 Picture，避免嵌套 drawPicture 导致缓存字节量滚雪球式增长。
      final exposed = <int>{};
      if (lineDelta > 0) {
        for (var i = effectLastLine - lineDelta + 1; i <= effectLastLine; i++) {
          if (i >= 0) exposed.add(i);
        }
      } else if (lineDelta < 0) {
        final n = -lineDelta;
        for (var i = effectFirstLine; i < effectFirstLine + n; i++) {
          if (i >= 0) exposed.add(i);
        }
      }
      // 是否纯滚动无 dirty（零成本）；否则 dirty 行也要画到 canvas。
      final zeroCost = dirty.lines.isEmpty && !hasOverlay;
      dbgLastPaintMode = zeroCost ? 3 : 1;
      _scrollTranslateDy = _picScrollOffset - _scrollOffset;
      dbgLastPaintedLines = {...exposed, ...dirty.lines};
      TerminalPaintDebug.log(
          '    scroll ${zeroCost ? "(zero-cost)" : "(with dirty)"}: '
          'lineDelta=$lineDelta exposed=${exposed.length} '
          'dirty=${dirty.lines.length} translateDy=${_scrollTranslateDy.toStringAsFixed(1)} '
          '(no Picture rebuild)');
      // 缓存基准视口字段不变——继续复用同一缓存。
    } else {
      // 增量（原地编辑、不平移）：缓存 Picture 当底 + 本帧 dirty 行画到 canvas。
      // 不录新 Picture，避免字节量膨胀。
      //
      // 关键：缓存是"录制时的旧内容"，本帧 drawPicture(缓存) 会把上一帧画过的
      // delta 行擦回旧内容。所以这里要重画"自缓存以来所有编辑过的行"
      // (_dirtySinceCache ∩ 视口)，而不只是本帧 dirty——否则内容会逐帧消失
      // （用户反馈：光换行、之前内容没了）。本帧 dirty 同时加入 stale 集合，
      // 供后续帧补画；累积超半屏则提升全画（见上 staleTooMany）。
      final staleInView = _dirtySinceCache
          .where((i) => i >= effectFirstLine && i <= effectLastLine)
          .toSet();
      final toPaint = {...dirty.lines, ...staleInView};
      _dirtySinceCache.addAll(dirty.lines);
      dbgLastPaintMode = 2;
      _scrollTranslateDy = _picScrollOffset - _scrollOffset;
      dbgLastPaintedLines = toPaint;
      TerminalPaintDebug.log('    incremental: dirty=${dirty.lines.length} '
          'stale=${staleInView.length} '
          'translateDy=${_scrollTranslateDy.toStringAsFixed(1)} '
          '(no Picture rebuild)');
    }

    TerminalPaintDebug.log(
        '  paint mode=$dbgLastPaintMode effFirst=$effectFirstLine '
        'effLast=$effectLastLine scrollOff=$_scrollOffset '
        'allDirty=${dirty.allDirty} dirty=${dirty.lines.length} '
        'painted=$dbgLastPaintedLines');

    // paint 成功，清 dirty。
    _terminal.buffer.clearDirty();

    if (dbgLastPaintMode == 0) {
      // 全画：直接画缓存 Picture（无 translate）。
      canvas.drawPicture(_contentPicture!);
    } else {
      // mode 1/2/3：translate + drawPicture(缓存)，再在 canvas 画 delta 行。
      // 不录新 Picture，避免缓存字节量滚雪球膨胀。
      canvas.save();
      if (_scrollTranslateDy != 0) {
        canvas.translate(0, _scrollTranslateDy);
      }
      canvas.drawPicture(_contentPicture!);
      canvas.restore();

      // delta 行（exposed + dirty）画到 canvas，覆盖在缓存内容之上。
      final delta = dbgLastPaintedLines ?? const <int>{};
      if (delta.isNotEmpty) {
        final bgPaint = Paint()..color = _painter.theme.background;
        for (final i in delta) {
          if (i < effectFirstLine || i > effectLastLine) continue;
          final lineTop = (i * charHeight + _lineOffset).truncateToDouble();
          canvas.drawRect(
            Offset(0, lineTop) & Size(size.width, charHeight),
            bgPaint,
          );
          _painter.paintLine(canvas, offset.translate(0, lineTop), lines[i]);
        }
      }
    }

    // 叠加层（不进缓存，每帧画）。
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

  /// 录制整屏内容 Picture（全画路径）。
  Picture _recordContentPicture({
    required Offset offset,
    required IndexAwareCircularBuffer<BufferLine> lines,
    required int effectFirstLine,
    required int effectLastLine,
    required double charHeight,
    BufferRange? selection,
  }) {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    final cellData = CellData.empty();

    // 必须先铺整屏背景色：paintCellBackground 对默认背景的 cell 直接 return
    // 不画，所以缓存 Picture 必须自带背景，否则默认背景区域会是透明的。
    // 增量路径 drawPicture 复用时，透明区域会露出底层 widget 背景，与
    // theme.background 不一致就会产生色差。
    final bgPaint = Paint()..color = _painter.theme.background;
    final bgTop =
        (effectFirstLine * charHeight + _lineOffset).truncateToDouble();
    final bgBottom =
        ((effectLastLine + 1) * charHeight + _lineOffset).truncateToDouble();
    canvas.drawRect(
      Offset(0, bgTop) & Size(size.width, bgBottom - bgTop),
      bgPaint,
    );

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

    return recorder.endRecording();
  }

  /// Paints the text that is currently being composed in IME to [canvas] at
  /// [offset]. [offset] is usually the cursor position.
  void _paintComposingText(Canvas canvas, Offset offset) {
    final composingText = _composingText;
    if (composingText == null) {
      return;
    }

    final fg = _terminal.cursor.foreground;
    final bg = _painter.theme.background;
    final fgColor = _painter.resolveForegroundColor(fg);

    // 缓存命中判断：文本、颜色、占位 dx、可用宽度都未变则复用上次 Paragraph。
    final width = size.width;
    if (_composingParagraph == null ||
        _composingCacheText != composingText ||
        _composingCacheFg != fg ||
        _composingCacheBg != bg ||
        _composingCacheDx != offset.dx ||
        _composingCacheWidth != width) {
      final style = _painter.textStyle.toTextStyle(
        color: fgColor,
        backgroundColor: bg,
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
      paragraph.layout(ParagraphConstraints(width: width));

      _composingParagraph = paragraph;
      _composingCacheText = composingText;
      _composingCacheFg = fg;
      _composingCacheBg = bg;
      _composingCacheDx = offset.dx;
      _composingCacheWidth = width;
    }

    canvas.drawParagraph(_composingParagraph!, Offset(0, offset.dy));
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

    for (var i = 0; i < line.length; i++) {
      line.getCellData(i, cellData);

      final charWidth = cellData.content >> CellContent.widthShift;
      final cellOffset = offset.translate(i * cellWidth, 0);
      final isSelected = i >= startColumn && i < endColumn;

      if (isSelected) {
        _painter.paintSelectedCell(canvas, cellOffset, cellData);
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

  bool _didViewportGeometryChange() {
    return _lastKnownViewWidth != _terminal.viewWidth ||
        _lastKnownViewHeight != _terminal.viewHeight ||
        !identical(_lastKnownBuffer, _terminal.buffer);
  }

  bool _didContentExtentChange() {
    return _lastKnownLineCount != _terminal.buffer.lines.length;
  }

  void _syncTerminalGeometryCache() {
    _lastKnownLineCount = _terminal.buffer.lines.length;
    _lastKnownViewWidth = _terminal.viewWidth;
    _lastKnownViewHeight = _terminal.viewHeight;
    _lastKnownBuffer = _terminal.buffer;
  }
}
