import 'package:flutter/material.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/selection_mode.dart';
import 'package:xterm/src/ui/themes.dart';
import 'package:xterm/src/ui/terminal_theme.dart'; // 导入 TerminalTheme

class MatchInfo {
  final int x;
  final int y;
  final int length;
  final String matchedText;
  final bool isWrapped; // 是否是自动换行的匹配
  final List<CellOffset>? wrappedPositions; // 如果是自动换行，记录所有匹配位置

  const MatchInfo({
    required this.x,
    required this.y,
    required this.length,
    required this.matchedText,
    this.isWrapped = false,
    this.wrappedPositions,
  });
}

/// search widget abstract interface
abstract class TerminalSearchDelegate {
  /// build search widget
  Widget build(BuildContext context, TerminalSearchController controller);

  /// search widget is visible
  bool get isVisible;

  /// show search widget
  void show();

  /// hide search widget
  void hide();

  /// get search controller
  TerminalSearchController get searchController;
}

/// search controller, provide search related functions
class TerminalSearchController extends ChangeNotifier {
  final Terminal terminal;
  final TerminalController controller;
  final void Function(int line) scrollToLine;
  final void Function(bool show) setShowSearch;

  String _lastSearchText = '';
  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _regex = false;
  List<MatchInfo> _matches = [];
  int _currentMatchIndex = -1;

  /// Last buffer geometry used for search; resize/reflow triggers re-search (F3).
  int _lastSearchViewWidth = -1;
  int _lastSearchLineCount = -1;
  bool _listeningTerminal = false;

  TerminalSearchController({
    required this.terminal,
    required this.controller,
    required this.scrollToLine,
    required this.setShowSearch,
  }) {
    terminal.addListener(_onTerminalChanged);
    _listeningTerminal = true;
    _lastSearchViewWidth = terminal.viewWidth;
    _lastSearchLineCount = terminal.buffer.lines.length;
  }

  /// get current search text
  String get searchText => _lastSearchText;

  /// whether区分大小写
  bool get caseSensitive => _caseSensitive;

  /// whether whole word match
  bool get wholeWord => _wholeWord;

  /// whether use regex
  bool get regex => _regex;

  /// current match index
  int get currentMatchIndex => _currentMatchIndex;

  /// match count
  int get matchCount => _matches.length;

  /// current match index for UI (1-based display uses +1)
  int get currentIdx =>
      _matches.isEmpty ? 0 : _currentMatchIndex.clamp(0, _matches.length - 1);

  void _onTerminalChanged() {
    final width = terminal.viewWidth;
    final lines = terminal.buffer.lines.length;
    if (width == _lastSearchViewWidth && lines == _lastSearchLineCount) {
      return;
    }
    _lastSearchViewWidth = width;
    _lastSearchLineCount = lines;
    if (_lastSearchText.isEmpty) return;
    _handleSearch(_lastSearchText, preserveCurrent: true);
    notifyListeners();
  }

  /// Detach terminal listener when the search UI is torn down.
  void detach() {
    if (_listeningTerminal) {
      terminal.removeListener(_onTerminalChanged);
      _listeningTerminal = false;
    }
  }

  /// set search text
  void setSearchText(String text) {
    _lastSearchText = text;
    _handleSearch(text);
    notifyListeners();
  }

  /// set whether case sensitive
  void setCaseSensitive(bool value) {
    _caseSensitive = value;
    _handleSearch(_lastSearchText);
    notifyListeners();
  }

  /// set whether whole word match
  void setWholeWord(bool value) {
    _wholeWord = value;
    _handleSearch(_lastSearchText);
    notifyListeners();
  }

  /// set whether use regex
  void setRegex(bool value) {
    _regex = value;
    _handleSearch(_lastSearchText);
    notifyListeners();
  }

  /// find next match
  void findNext() {
    if (_matches.isEmpty) return;
    _currentMatchIndex = (_currentMatchIndex + 1) % _matches.length;
    _selectCurrentMatch();
    notifyListeners();
  }

  /// find previous match
  void findPrevious() {
    if (_matches.isEmpty) return;
    _currentMatchIndex =
        (_currentMatchIndex - 1 + _matches.length) % _matches.length;
    _selectCurrentMatch();
    notifyListeners();
  }

  /// close search widget
  void close() {
    setShowSearch(false);
    controller.clearSelection();
    notifyListeners();
  }

  void _selectCurrentMatch() {
    if (_currentMatchIndex < 0 || _currentMatchIndex >= _matches.length) {
      return;
    }
    final match = _matches[_currentMatchIndex];
    final positions = match.wrappedPositions;
    if (positions != null && positions.isNotEmpty) {
      final first = positions.first;
      final last = positions.last;
      final start = terminal.buffer.createAnchor(first.x, first.y);
      final end = terminal.buffer.createAnchor(last.x + 1, last.y);
      controller.setSelection(start, end, mode: SelectionMode.line);
    } else {
      final start = terminal.buffer.createAnchor(match.x, match.y);
      final end = terminal.buffer.createAnchor(
        match.x + match.length,
        match.y,
      );
      controller.setSelection(start, end, mode: SelectionMode.line);
    }
    scrollToLine(match.y);
  }

  /// Physical line → list of (UTF-16 unit, cell) for index-aligned search.
  List<({int codeUnit, CellOffset cell})> _lineCharCells(
    BufferLine line,
    int y,
  ) {
    final out = <({int codeUnit, CellOffset cell})>[];
    final to = line.getTrimmedLength();
    for (var i = 0; i < to; i++) {
      final codePoint = line.getCodePoint(i);
      if (codePoint != 0) {
        final s = String.fromCharCode(codePoint);
        for (final unit in s.codeUnits) {
          out.add((codeUnit: unit, cell: CellOffset(i, y)));
        }
      } else if (!line.isWideCharContinuationCell(i)) {
        out.add((codeUnit: 0x20, cell: CellOffset(i, y)));
      }
    }
    return out;
  }

  void _handleSearch(String text, {bool preserveCurrent = false}) {
    if (text.isEmpty) {
      controller.clearSelection();
      _matches.clear();
      _currentMatchIndex = -1;
      return;
    }

    _lastSearchText = text;
    _lastSearchViewWidth = terminal.viewWidth;
    _lastSearchLineCount = terminal.buffer.lines.length;

    String? preserveKey;
    if (preserveCurrent &&
        _currentMatchIndex >= 0 &&
        _currentMatchIndex < _matches.length) {
      preserveKey = _matchStableKey(_matches[_currentMatchIndex]);
    }

    final buffer = terminal.buffer;
    _matches.clear();
    _currentMatchIndex = -1;

    final lines = buffer.lines;
    if (lines.length == 0) {
      controller.clearSelection();
      return;
    }

    var cells = <({int codeUnit, CellOffset cell})>[];
    void flushLogicalLine() {
      if (cells.isEmpty) return;
      _collectMatchesOnLogicalLine(text, cells);
      cells = <({int codeUnit, CellOffset cell})>[];
    }

    for (var y = 0; y < lines.length; y++) {
      final line = lines[y];
      cells.addAll(_lineCharCells(line, y));
      // isWrapped means this row continues onto the next physical row.
      if (!line.isWrapped || y == lines.length - 1) {
        flushLogicalLine();
      }
    }

    _matches = _filterDuplicateMatches(_matches);

    if (_matches.isEmpty) {
      controller.clearSelection();
      return;
    }

    if (preserveKey != null) {
      final idx = _matches.indexWhere((m) => _matchStableKey(m) == preserveKey);
      _currentMatchIndex = idx >= 0 ? idx : 0;
    } else {
      _currentMatchIndex = 0;
    }
    _selectCurrentMatch();
  }

  void _collectMatchesOnLogicalLine(
    String query,
    List<({int codeUnit, CellOffset cell})> cells,
  ) {
    final buffer = StringBuffer();
    for (final c in cells) {
      buffer.writeCharCode(c.codeUnit);
    }
    final lineText = buffer.toString();
    if (lineText.isEmpty || query.isEmpty) return;

    void addMatch(int start, int end, String matchedText) {
      if (start < 0 || end > cells.length || start >= end) return;
      if (_wholeWord && !_isWholeWord(lineText, start, end)) return;

      final slice = cells.sublist(start, end);
      final first = slice.first.cell;
      final last = slice.last.cell;
      final multiLine = first.y != last.y;
      // Deduplicate consecutive identical cells (multi code-unit chars).
      final positions = <CellOffset>[];
      for (final s in slice) {
        if (positions.isEmpty ||
            positions.last.x != s.cell.x ||
            positions.last.y != s.cell.y) {
          positions.add(s.cell);
        }
      }
      final cellLen = multiLine
          ? positions.length
          : (positions.last.x - positions.first.x + 1);

      _matches.add(
        MatchInfo(
          x: first.x,
          y: first.y,
          length: cellLen,
          matchedText: matchedText,
          isWrapped: multiLine,
          wrappedPositions: multiLine ? positions : null,
        ),
      );
    }

    if (_regex) {
      var pattern = query;
      if (_wholeWord) {
        pattern = r'\b' + pattern + r'\b';
      }
      try {
        final re = RegExp(pattern, caseSensitive: _caseSensitive);
        for (final m in re.allMatches(lineText)) {
          addMatch(m.start, m.end, m.group(0)!);
        }
      } catch (_) {
        return;
      }
      return;
    }

    final hay = _caseSensitive ? lineText : lineText.toLowerCase();
    final needle = _caseSensitive ? query : query.toLowerCase();
    if (needle.isEmpty) return;
    var from = 0;
    while (from <= hay.length - needle.length) {
      final x = hay.indexOf(needle, from);
      if (x < 0) break;
      addMatch(x, x + needle.length, lineText.substring(x, x + needle.length));
      from = x + 1;
    }
  }

  String _matchStableKey(MatchInfo m) =>
      '${m.y}:${m.x}:${m.length}:${m.matchedText}';

  List<MatchInfo> _filterDuplicateMatches(List<MatchInfo> matches) {
    final uniqueMatches = <String>{};
    final filteredMatches = <MatchInfo>[];
    for (final match in matches) {
      final matchKey = _matchStableKey(match);
      if (uniqueMatches.add(matchKey)) {
        filteredMatches.add(match);
      }
    }
    return filteredMatches;
  }

  bool _isWholeWord(String text, int start, int end) {
    if (start > 0) {
      final prevChar = text[start - 1];
      if (_isLetterOrDigit(prevChar) || prevChar == '_') {
        return false;
      }
    }
    if (end < text.length) {
      final nextChar = text[end];
      if (_isLetterOrDigit(nextChar) || nextChar == '_') {
        return false;
      }
    }
    return true;
  }

  bool _isLetterOrDigit(String char) {
    if (char.isEmpty) return false;
    final codeUnit = char.codeUnitAt(0);
    return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
        (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
        (codeUnit >= 0x61 && codeUnit <= 0x7A);
  }
}

/// 默认的搜索框实现
class DefaultTerminalSearchBox extends StatefulWidget
    implements TerminalSearchDelegate {
  final TerminalSearchController _searchController;
  final bool isVisible;
  final VoidCallback? onHide;
  final VoidCallback? onClose;
  final TerminalTheme theme; // 添加主题参数

  const DefaultTerminalSearchBox({
    super.key,
    required TerminalSearchController searchController,
    this.isVisible = true,
    this.onHide,
    this.onClose,
    this.theme = TerminalThemes.defaultTheme, // 初始化时需要传入主题
  }) : _searchController = searchController;

  @override
  Widget build(BuildContext context, TerminalSearchController controller) {
    return this;
  }

  @override
  State<StatefulWidget> createState() => _DefaultTerminalSearchBoxState();

  @override
  void show() {
    // 自定义实现
  }

  @override
  void hide() {
    onHide?.call();
  }

  @override
  TerminalSearchController get searchController => _searchController;
}

class _DefaultTerminalSearchBoxState extends State<DefaultTerminalSearchBox> {
  final _controller = TextEditingController();
  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _regex = false;

  @override
  void initState() {
    print(' initState default search box');
    super.initState();
    _controller.text = widget.searchController.searchText;
    _caseSensitive = widget.searchController.caseSensitive;
    _wholeWord = widget.searchController.wholeWord;
    _regex = widget.searchController.regex;

    // 添加监听器
    widget.searchController.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    // 移除监听器
    widget.searchController.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    setState(() {
      _caseSensitive = widget.searchController.caseSensitive;
      _wholeWord = widget.searchController.wholeWord;
      _regex = widget.searchController.regex;
    });
  }

  void _updateCaseSensitive(bool value) {
    setState(() {
      _caseSensitive = value;
    });
    widget.searchController.setCaseSensitive(value);
  }

  void _updateWholeWord(bool value) {
    setState(() {
      _wholeWord = value;
    });
    widget.searchController.setWholeWord(value);
  }

  void _updateRegex(bool value) {
    setState(() {
      _regex = value;
    });
    widget.searchController.setRegex(value);
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isVisible) {
      return const SizedBox.shrink();
    }

    final theme = widget.theme; // 使用传入的主题

    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: theme.background.withOpacity(0.8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.brightBlack,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: theme.foreground.withOpacity(0.8),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 搜索输入框
            Container(
              decoration: BoxDecoration(
                color: theme.brightBlack,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: theme.brightBlack,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.search, color: theme.white, size: 20),
                  ),
                  Expanded(
                    child: TextField(
                      autofocus: true,
                      controller: _controller,
                      style: TextStyle(color: theme.foreground),
                      decoration: InputDecoration(
                        hintText: '搜索...',
                        hintStyle: TextStyle(color: theme.foreground),
                        border: InputBorder.none,
                        suffixText: widget.searchController.matchCount > 0
                            ? '${widget.searchController.currentIdx + 1}/${widget.searchController.matchCount}'
                            : '',
                        suffixStyle: TextStyle(color: theme.foreground),
                      ),
                      onChanged: widget.searchController.setSearchText,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: theme.white, size: 20),
                    onPressed: () {
                      widget.searchController.setSearchText(''); // 关闭时情况检索内容
                      widget.searchController.close();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // 搜索控制按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 导航按钮
                Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.arrow_upward, color: theme.foreground),
                      hoverColor: theme.brightBlack.withOpacity(0.6),
                      onPressed: widget.searchController.findPrevious,
                      tooltip: '上一个匹配',
                    ),
                    IconButton(
                      icon: Icon(Icons.arrow_downward, color: theme.foreground),
                      hoverColor: theme.brightBlack.withOpacity(0.6),
                      onPressed: widget.searchController.findNext,
                      tooltip: '下一个匹配',
                    ),
                  ],
                ),
                // 搜索选项按钮
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.text_fields,
                        color: _caseSensitive ? theme.brightCyan : theme.brightBlack,
                      ),
                      onPressed: () => _updateCaseSensitive(!_caseSensitive),
                      tooltip: '区分大小写',
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.text_format,
                        color: _wholeWord ? theme.brightCyan : theme.brightBlack,
                      ),
                      onPressed: () => _updateWholeWord(!_wholeWord),
                      tooltip: '全词匹配',
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.code,
                        color: _regex ? theme.brightCyan : theme.brightBlack,
                      ),
                      onPressed: () => _updateRegex(!_regex),
                      tooltip: '正则表达式',
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
