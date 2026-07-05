import 'dart:math' show max, min;

import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/core/buffer/range.dart';
import 'package:xterm/src/core/charset.dart';
import 'package:xterm/src/core/cursor.dart';
import 'package:xterm/src/core/reflow.dart';
import 'package:xterm/src/core/state.dart';
import 'package:xterm/src/utils/circular_buffer.dart';
import 'package:xterm/src/utils/unicode_v11.dart';

class Buffer {
  final TerminalState terminal;

  final int maxLines;

  final bool isAltBuffer;

  /// Characters that break selection when calling [getWordBoundary]. If null,
  /// defaults to [defaultWordSeparators].
  final Set<int>? wordSeparators;

  Buffer(
    this.terminal, {
    required this.maxLines,
    required this.isAltBuffer,
    this.wordSeparators,
  }) {
    for (int i = 0; i < terminal.viewHeight; i++) {
      lines.push(_newEmptyLine());
    }

    resetVerticalMargins();
  }

  int _cursorX = 0;

  int _cursorY = 0;

  late int _marginTop;

  late int _marginBottom;

  var _savedCursorX = 0;

  var _savedCursorY = 0;

  final _savedCursorStyle = CursorStyle();

  final charset = Charset();

  /// Width of the viewport in columns. Also the index of the last column.
  int get viewWidth => terminal.viewWidth;

  /// Height of the viewport in rows. Also the index of the last line.
  int get viewHeight => terminal.viewHeight;

  /// lines of the buffer. the length of [lines] should always be equal or
  /// greater than [viewHeight].
  late final lines = IndexAwareCircularBuffer<BufferLine>(maxLines);

  // ---------------------------------------------------------------------------
  // 行级 dirty 追踪
  //
  // 渲染层 paint 时只需重画"自上次 paint 后内容变化的行"，避免每帧全屏遍历。
  // dirty 以**相对索引**（即 lines[i] 的 i，与渲染层 paint 循环一致）记录。
  //
  // 设计取舍（见 docs/perf-optimization.md §3.1）：
  // - 单行修改（writeChar/eraseLine/...）→ 标脏 cursorY 单行，走优化路径。
  // - 行引用移动 / 结构变化（scrollUp/Down/insertLines/deleteLines/clear/
  //   clearScrollback/resize/reflow/alt-buffer 切换）→ 标全脏。这些场景视觉
  //   本就是大面积变化，全画与现状一致，不引入额外开销，且正确性容易保证。
  // - 渲染层另维护"上次 paint 的视口"，scrollOffset 变化时全画（覆盖
  //   scrollback 增长等视口平移场景）。
  //
  // 漏标 dirty = 画面不更新（用户可见 bug），所以宁可多标不可漏标。
  // ---------------------------------------------------------------------------

  /// 自上次 [takeDirtyLines] 以来被标脏的相对行索引集合。
  /// 当 [_allDirty] 为 true 时本集合无意义（视为全部 dirty）。
  final Set<int> _dirtyLines = {};

  /// 是否所有行都应视为 dirty。结构变化时置 true，避免逐行标记。
  var _allDirty = true;

  /// 标脏单行（相对索引）。
  @pragma('vm:prefer-inline')
  void _markLineDirty(int relativeIndex) {
    if (_allDirty) return;
    if (relativeIndex >= 0 && relativeIndex < height) {
      _dirtyLines.add(relativeIndex);
    }
  }

  /// 标脏 [start, end] 闭区间的相对行。
  @pragma('vm:prefer-inline')
  void _markRangeDirty(int start, int end) {
    if (_allDirty) return;
    for (var i = start; i <= end; i++) {
      if (i >= 0 && i < height) {
        _dirtyLines.add(i);
      }
    }
  }

  /// 标全脏（结构变化时使用）。
  @pragma('vm:prefer-inline')
  void _markAllDirty() {
    _allDirty = true;
    _dirtyLines.clear();
  }

  /// 渲染层调用：取走当前的 dirty 行索引集合。
  /// - 若返回的 `allDirty` 为 true，调用方应重画整个视口；
  /// - 否则只重画 `lines` 集合中与视口相交的行；
  /// - 调用后 dirty 状态被清空（由消费方在 paint 完成后调 [clearDirty]）。
  ///
  /// 注意：取走不立即清空，因为 paint 可能因异常未完成；消费方应在 paint
  /// 成功后调 [clearDirty]。若 paint 中途取了又没清，下次仍会拿到同一批。
  DirtyLinesResult takeDirtyLines() {
    return DirtyLinesResult(allDirty: _allDirty, lines: Set<int>.from(_dirtyLines));
  }

  /// 渲染层在成功 paint 后调用，清空 dirty 状态。
  void clearDirty() {
    _allDirty = false;
    _dirtyLines.clear();
  }

  /// Total number of lines in the buffer. Always equal or greater than
  /// [viewHeight].
  int get height => lines.length;

  /// Horizontal position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorX => _cursorX.clamp(0, terminal.viewWidth - 1);

  /// Vertical position of the cursor relative to the top-left cornor of the
  /// screen, starting from 0.
  int get cursorY => _cursorY;

  /// Index of the first line in the scroll region.
  int get marginTop => _marginTop;

  /// Index of the last line in the scroll region.
  int get marginBottom => _marginBottom;

  /// The number of lines above the viewport.
  int get scrollBack => height - viewHeight;

  /// Vertical position of the cursor relative to the top of the buffer,
  /// starting from 0.
  int get absoluteCursorY => _cursorY + scrollBack;

  /// Absolute index of the first line in the scroll region.
  int get absoluteMarginTop => _marginTop + scrollBack;

  /// Absolute index of the last line in the scroll region.
  int get absoluteMarginBottom => _marginBottom + scrollBack;

  /// Writes data to the _terminal. Terminal sequences or special characters are
  /// not interpreted and directly added to the buffer.
  ///
  /// See also: [Terminal.write]
  void write(String text) {
    for (var char in text.runes) {
      writeChar(char);
    }
  }

  /// Writes a single character to the _terminal. Escape sequences or special
  /// characters are not interpreted and directly added to the buffer.
  ///
  /// See also: [Terminal.writeChar]
  void writeChar(int codePoint) {
    codePoint = charset.translate(codePoint);

    final cellWidth = unicodeV11.wcwidth(codePoint);
    if (_cursorX >= terminal.viewWidth) {
      if (terminal.autoWrapMode) {
        currentLine.isWrapped = true;
      }
      index();
      setCursorX(0);
    }

    final line = currentLine;
    line.setCell(_cursorX, codePoint, cellWidth, terminal.cursor);
    _markLineDirty(absoluteCursorY);

    if (_cursorX < viewWidth) {
      _cursorX++;
    }

    if (cellWidth == 2) {
      writeChar(0);
    }
  }

  /// The line at the current cursor position.
  BufferLine get currentLine {
    return lines[absoluteCursorY];
  }

  /// Get the lines around the current line.
  List<BufferLine> currentAroundLines(int count) {
    final List<BufferLine> result = [];
    for (var i = absoluteCursorY - count; i <= absoluteCursorY + count; i++) {
      if (i < 0 || i >= lines.length) {
        continue;
      }
      result.add(lines[i]);
    }
    return result;
  }

  void backspace() {
    if (_cursorX == 0 && currentLine.isWrapped) {
      currentLine.isWrapped = false;
      moveCursor(viewWidth - 1, -1);
    } else if (_cursorX == viewWidth) {
      moveCursor(-2, 0);
    } else {
      moveCursor(-1, 0);
    }
  }

  /// Erases the viewport from the cursor position to the end of the buffer,
  /// including the cursor position.
  void eraseDisplayFromCursor() {
    eraseLineFromCursor();

    for (var i = absoluteCursorY + 1; i < height; i++) {
      final line = lines[i];
      line.isWrapped = false;
      line.eraseRange(0, viewWidth, terminal.cursor);
    }
    _markRangeDirty(absoluteCursorY, height - 1);
  }

  /// Erases the viewport from the top-left corner to the cursor, including the
  /// cursor.
  void eraseDisplayToCursor() {
    eraseLineToCursor();

    for (var i = 0; i < _cursorY; i++) {
      final line = lines[i + scrollBack];
      line.isWrapped = false;
      line.eraseRange(0, viewWidth, terminal.cursor);
    }
    _markRangeDirty(scrollBack, absoluteCursorY);
  }

  /// Erases the whole viewport.
  void eraseDisplay() {
    for (var i = 0; i < viewHeight; i++) {
      final line = lines[i + scrollBack];
      line.isWrapped = false;
      line.eraseRange(0, viewWidth, terminal.cursor);
    }
    _markRangeDirty(scrollBack, scrollBack + viewHeight - 1);
  }

  /// Erases the line from the cursor to the end of the line, including the
  /// cursor position.
  void eraseLineFromCursor() {
    currentLine.isWrapped = false;
    currentLine.eraseRange(_cursorX, viewWidth, terminal.cursor);
    _markLineDirty(absoluteCursorY);
  }

  /// Erases the line from the start of the line to the cursor, including the
  /// cursor.
  void eraseLineToCursor() {
    currentLine.isWrapped = false;
    currentLine.eraseRange(0, _cursorX, terminal.cursor);
    _markLineDirty(absoluteCursorY);
  }

  /// Erases the line at the current cursor position.
  void eraseLine() {
    currentLine.isWrapped = false;
    currentLine.eraseRange(0, viewWidth, terminal.cursor);
    _markLineDirty(absoluteCursorY);
  }

  // This line of text ends, line break.
  void endLine() {
    currentLine.isWrapped = false;
    index();
    setCursorX(0);
  }

  /// Erases [count] cells starting at the cursor position.
  void eraseChars(int count) {
    final start = _cursorX;
    currentLine.eraseRange(start, start + count, terminal.cursor);
    _markLineDirty(absoluteCursorY);
  }

  void scrollDown(int lines) {
    for (var i = absoluteMarginBottom; i >= absoluteMarginTop; i--) {
      if (i >= absoluteMarginTop + lines) {
        this.lines[i] = this.lines[i - lines];
      } else {
        this.lines[i] = _newEmptyLine();
      }
    }
    // 行引用移动：滚动区域内的相对位置内容全部重映射，全脏最稳妥。
    _markAllDirty();
  }

  void scrollUp(int lines) {
    for (var i = absoluteMarginTop; i <= absoluteMarginBottom; i++) {
      if (i <= absoluteMarginBottom - lines) {
        this.lines[i] = this.lines[i + lines];
      } else {
        this.lines[i] = _newEmptyLine();
      }
    }
    // 行引用移动：滚动区域内的相对位置内容全部重映射，全脏最稳妥。
    _markAllDirty();
  }

  /// https://vt100.net/docs/vt100-ug/chapter3.html#IND IND – Index
  ///
  /// ESC D
  ///
  /// [index] causes the active position to move downward one line without
  /// changing the column position. If the active position is at the bottom
  /// margin, a scroll up is performed.
  void index() {
    if (isInVerticalMargin) {
      if (_cursorY == _marginBottom) {
        if (marginTop == 0 && !isAltBuffer) {
          // main buffer 底部换行：在末尾 insert 一行新空行。
          // 与 push 分支同理：既有行内容不变，只是视口随 stick-to-bottom
          // 整体下移一行（lineDelta=1），由渲染层用平移复用处理。
          // 不标全脏，避免撤销 dirty 优化。
          lines.insert(absoluteMarginBottom + 1, _newEmptyLine());
        } else {
          scrollUp(1);
        }
      } else {
        moveCursorY(1);
      }
      return;
    }

    // the cursor is not in the scrollable region
    if (_cursorY >= viewHeight - 1) {
      // we are at the bottom
      if (isAltBuffer) {
        scrollUp(1);
      } else {
        // scrollback 增长：新空行加在末尾，既有行相对索引不变、内容不变，
        // 故不标脏。视口若 stick-to-bottom 会跟随移动，由渲染层按视口变化
        // 触发全画。
        lines.push(_newEmptyLine());
      }
    } else {
      // there're still lines so we simply move cursor down.
      moveCursorY(1);
    }
  }

  void lineFeed() {
    index();
    if (terminal.lineFeedMode) {
      setCursorX(0);
    }
  }

  /// https://terminalguide.namepad.de/seq/a_esc_cm/
  void reverseIndex() {
    if (isInVerticalMargin) {
      if (_cursorY == _marginTop) {
        scrollDown(1);
      } else {
        moveCursorY(-1);
      }
    } else {
      moveCursorY(-1);
    }
  }

  void cursorGoForward() {
    // Allow one-past-the-edge "pending wrap" so the next printable character
    // can trigger autowrap. Callers that need an in-bounds cursor should use
    // setCursorX/moveCursorX instead.
    _cursorX = min(_cursorX + 1, viewWidth);
  }

  void setCursorX(int cursorX) {
    _cursorX = cursorX.clamp(0, viewWidth - 1);
  }

  void setCursorY(int cursorY) {
    _cursorY = cursorY.clamp(0, viewHeight - 1);
  }

  void moveCursorX(int offset) {
    setCursorX(_cursorX + offset);
  }

  void moveCursorY(int offset) {
    setCursorY(_cursorY + offset);
  }

  void setCursor(int cursorX, int cursorY) {
    var maxCursorY = viewHeight - 1;

    if (terminal.originMode) {
      cursorY += _marginTop;
      maxCursorY = _marginBottom;
    }

    _cursorX = cursorX.clamp(0, viewWidth - 1);
    _cursorY = cursorY.clamp(0, maxCursorY);
  }

  void moveCursor(int offsetX, int offsetY) {
    final cursorX = _cursorX + offsetX;
    final cursorY = _cursorY + offsetY;
    setCursor(cursorX, cursorY);
  }

  /// Save cursor position, charmap and text attributes.
  void saveCursor() {
    _savedCursorX = _cursorX;
    _savedCursorY = _cursorY;
    _savedCursorStyle.foreground = terminal.cursor.foreground;
    _savedCursorStyle.background = terminal.cursor.background;
    _savedCursorStyle.attrs = terminal.cursor.attrs;
    charset.save();
  }

  /// Restore cursor position, charmap and text attributes.
  void restoreCursor() {
    _cursorX = _savedCursorX;
    _cursorY = _savedCursorY;
    terminal.cursor.foreground = _savedCursorStyle.foreground;
    terminal.cursor.background = _savedCursorStyle.background;
    terminal.cursor.attrs = _savedCursorStyle.attrs;
    charset.restore();
  }

  /// Sets the vertical scrolling margin to [top] and [bottom].
  /// Both values must be between 0 and [viewHeight] - 1.
  void setVerticalMargins(int top, int bottom) {
    _marginTop = top.clamp(0, viewHeight - 1);
    _marginBottom = bottom.clamp(0, viewHeight - 1);

    _marginTop = min(_marginTop, _marginBottom);
    _marginBottom = max(_marginTop, _marginBottom);
  }

  bool get isInVerticalMargin {
    return _cursorY >= _marginTop && _cursorY <= _marginBottom;
  }

  void resetVerticalMargins() {
    setVerticalMargins(0, viewHeight - 1);
  }

  void deleteChars(int count) {
    final start = _cursorX.clamp(0, viewWidth);
    count = min(count, viewWidth - start);
    currentLine.removeCells(start, count, terminal.cursor);
    _markLineDirty(absoluteCursorY);
  }

  /// Remove all lines above the top of the viewport.
  void clearScrollback() {
    if (height <= viewHeight) {
      return;
    }

    lines.trimStart(scrollBack);
    // 头部丢弃改变了所有行的相对索引，全脏。
    _markAllDirty();
  }

  /// Clears the viewport and scrollback buffer. Then fill with empty lines.
  void clear() {
    lines.clear();
    for (int i = 0; i < viewHeight; i++) {
      lines.push(_newEmptyLine());
    }
    _markAllDirty();
  }

  void insertBlankChars(int count) {
    currentLine.insertCells(_cursorX, count, terminal.cursor);
    _markLineDirty(absoluteCursorY);
  }

  void insertLines(int count) {
    if (!isInVerticalMargin) {
      return;
    }

    setCursorX(0);

    // Number of lines from the cursor to the bottom of the scrollable region
    // including the cursor itself.
    final linesBelow = absoluteMarginBottom - absoluteCursorY + 1;

    // Number of empty lines to insert.
    final linesToInsert = min(count, linesBelow);

    // Number of lines to move up.
    final linesToMove = linesBelow - linesToInsert;

    for (var i = 0; i < linesToMove; i++) {
      final index = absoluteMarginBottom - i;
      lines[index] = lines.swap(index - linesToInsert, _newEmptyLine());
    }

    for (var i = linesToMove; i < linesToInsert; i++) {
      lines[absoluteCursorY + i] = _newEmptyLine();
    }
    // 行引用移动 + 插入空行，全脏。
    _markAllDirty();
  }

  /// Remove [count] lines starting at the current cursor position. Lines below
  /// the removed lines are shifted up. This only affects the scrollable region.
  /// Lines outside the scrollable region are not affected.
  void deleteLines(int count) {
    if (!isInVerticalMargin) {
      return;
    }

    setCursorX(0);

    count = min(count, absoluteMarginBottom - absoluteCursorY + 1);

    final linesToMove = absoluteMarginBottom - absoluteCursorY + 1 - count;

    for (var i = 0; i < linesToMove; i++) {
      final index = absoluteCursorY + i;
      lines[index] = lines[index + count];
    }

    for (var i = 0; i < count; i++) {
      lines[absoluteMarginBottom - i] = _newEmptyLine();
    }
    // 行引用移动 + 末尾填空行，全脏。
    _markAllDirty();
  }

  void resize(int oldWidth, int oldHeight, int newWidth, int newHeight) {
    // 1. Adjust the height.
    if (newHeight > oldHeight) {
      // Grow larger
      for (var i = 0; i < newHeight - oldHeight; i++) {
        if (newHeight > lines.length) {
          lines.push(_newEmptyLine(newWidth));
        } else {
          _cursorY++;
        }
      }
    } else {
      // Shrink smaller
      for (var i = 0; i < oldHeight - newHeight; i++) {
        if (_cursorY > newHeight - 1) {
          _cursorY--;
        } else {
          lines.pop();
        }
      }
    }

    // Ensure cursor is within the screen.
    _cursorX = _cursorX.clamp(0, newWidth - 1);
    _cursorY = _cursorY.clamp(0, newHeight - 1);

    // 2. Adjust the width.
    if (newWidth != oldWidth) {
      if (terminal.reflowEnabled && !isAltBuffer) {
        final reflowResult = reflow(lines, oldWidth, newWidth);

        while (reflowResult.length < newHeight) {
          reflowResult.add(_newEmptyLine(newWidth));
        }

        lines.replaceWith(reflowResult);
      } else {
        lines.forEach((item) => item.resize(newWidth));
      }
    }

    // 尺寸/reflow 后行结构可能与几何都变了，全脏。
    _markAllDirty();
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchor(int x, int y) {
    return lines[y].createAnchor(x);
  }

  /// Create a new [CellAnchor] at the specified [x] and [y] coordinates.
  CellAnchor createAnchorFromOffset(CellOffset offset) {
    return lines[offset.y].createAnchor(offset.x);
  }

  CellAnchor createAnchorFromCursor() {
    return createAnchor(cursorX, absoluteCursorY);
  }

  /// Create a new empty [BufferLine] with the current [viewWidth] if [width]
  /// is not specified.
  BufferLine _newEmptyLine([int? width]) {
    final line = BufferLine(width ?? viewWidth);
    return line;
  }

  static final defaultWordSeparators = <int>{
    0,
    r' '.codeUnitAt(0),
    r'\t'.codeUnitAt(0),
    r'!'.codeUnitAt(0),
    r'"'.codeUnitAt(0),
    r'#'.codeUnitAt(0),
    r'%'.codeUnitAt(0),
    r'&'.codeUnitAt(0),
    r"'".codeUnitAt(0),
    r'('.codeUnitAt(0),
    r')'.codeUnitAt(0),
    r'*'.codeUnitAt(0),
    r'+'.codeUnitAt(0),
    r'.'.codeUnitAt(0),
    r','.codeUnitAt(0),
    r'/'.codeUnitAt(0),
    r':'.codeUnitAt(0),
    r';'.codeUnitAt(0),
    r'<'.codeUnitAt(0),
    r'='.codeUnitAt(0),
    r'>'.codeUnitAt(0),
    r'?'.codeUnitAt(0),
    r'@'.codeUnitAt(0),
    r'['.codeUnitAt(0),
    r'\'.codeUnitAt(0),
    r']'.codeUnitAt(0),
    r'^'.codeUnitAt(0),
    r'`'.codeUnitAt(0),
    r'{'.codeUnitAt(0),
    r'|'.codeUnitAt(0),
    r'}'.codeUnitAt(0),
    r'~'.codeUnitAt(0),
  };

  BufferRangeLine? getWordBoundary(CellOffset position) {
    var separators = wordSeparators ?? defaultWordSeparators;
    if (position.y >= lines.length) {
      return null;
    }

    var lineIndex = position.y;
    var line = lines[lineIndex];
    var start = line.getCharacterStart(position.x);
    var end = line.getCharacterEnd(position.x);
    final currentChar = line.getCodePoint(start);

    if (separators.contains(currentChar)) {
      return null;
    }

    do {
      if (start == 0) {
        if (lineIndex <= 0) {
          break;
        }
        final previousLineIndex = lineIndex - 1;
        final previousLine = lines[previousLineIndex];
        if (!previousLine.isWrapped) {
          break;
        }
        final previousLineEnd = previousLine.getTrimmedLength(viewWidth);
        if (previousLineEnd == 0) {
          break;
        }
        lineIndex = previousLineIndex;
        line = previousLine;
        start = line.getCharacterStart(previousLineEnd - 1);
        continue;
      }
      final previousIndex = line.getCharacterStart(start - 1);
      final char = line.getCodePoint(previousIndex);
      if (separators.contains(char)) {
        break;
      }
      start = previousIndex;
    } while (true);

    final startLineIndex = lineIndex;
    final startColumn = start;

    lineIndex = position.y;
    line = lines[lineIndex];

    do {
      if (end >= viewWidth || end >= line.getTrimmedLength(viewWidth)) {
        if (!line.isWrapped || lineIndex >= lines.length - 1) {
          break;
        }
        final nextLineIndex = lineIndex + 1;
        final nextLine = lines[nextLineIndex];
        if (nextLine.getTrimmedLength(viewWidth) == 0) {
          break;
        }
        lineIndex = nextLineIndex;
        line = nextLine;
        end = line.getCharacterEnd(0);
        continue;
      }
      final nextIndex = line.getCharacterStart(end);
      final char = line.getCodePoint(nextIndex);
      if (separators.contains(char)) {
        break;
      }
      end = line.getCharacterEnd(nextIndex);
    } while (true);

    if (start == end) {
      return null;
    }

    return BufferRangeLine(
      CellOffset(startColumn, startLineIndex),
      CellOffset(end, lineIndex),
    );
  }

  /// Get the plain text content of the buffer including the scrollback.
  /// Accepts an optional [range] to get a specific part of the buffer.
  String getText([BufferRange? range]) {
    range ??= BufferRangeLine(
      CellOffset(0, 0),
      CellOffset(viewWidth - 1, height - 1),
    );

    range = range.normalized;

    final builder = StringBuffer();
    var isFirstSegment = true;

    for (var segment in range.toSegments()) {
      if (segment.line < 0 || segment.line >= height) {
        continue;
      }
      final line = lines[segment.line];
      // Add newline before this line UNLESS this is the first segment or
      // the previous line wraps into this line (soft wrap).
      if (!isFirstSegment) {
        final isPrevLineWrapped = lines[segment.line - 1].isWrapped;
        if (!isPrevLineWrapped) {
          builder.write('\n');
        }
      }
      isFirstSegment = false;
      builder.write(line.getText(segment.start, segment.end));
    }

    return builder.toString();
  }

  /// Returns a debug representation of the buffer.
  @override
  String toString() {
    final builder = StringBuffer();
    final lineNumberLength = lines.length.toString().length;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      builder.write('${i.toString().padLeft(lineNumberLength)}: |${lines[i]}|');

      if (line.isWrapped) {
        builder.write(' (⏎)');
      }

      builder.write('\n');
    }

    return builder.toString();
  }
}

/// [Buffer.takeDirtyLines] 的返回结果。
class DirtyLinesResult {
  /// 是否所有行都应视为 dirty（结构变化，如 scroll/resize/reflow/clear）。
  final bool allDirty;

  /// 被标脏的相对行索引集合。仅在 [allDirty] 为 false 时有意义。
  final Set<int> lines;

  const DirtyLinesResult({required this.allDirty, required this.lines});
}
