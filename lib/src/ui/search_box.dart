import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/controller.dart';
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

  TerminalSearchController({
    required this.terminal,
    required this.controller,
    required this.scrollToLine,
    required this.setShowSearch,
  });

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

  /// current match index
  int get currentIdx => _currentMatchIndex % _matches.length;

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
    if (_currentMatchIndex >= 0 && _currentMatchIndex < _matches.length) {
      final match = _matches[_currentMatchIndex];

      if (match.isWrapped && match.wrappedPositions != null) {
        // 处理跨行匹配
        final positions = match.wrappedPositions!;
        final start =
            terminal.buffer.createAnchor(positions.first.x, positions.first.y);
        final end = terminal.buffer.createAnchor(
          positions.last.x + 1,
          positions.last.y,
        );
        controller.setSelection(start, end);
      } else {
        // 处理单行匹配
        final start = terminal.buffer.createAnchor(match.x, match.y);
        final end = terminal.buffer.createAnchor(
          match.x + match.length,
          match.y,
        );
        controller.setSelection(start, end);
      }

      // 滚动到匹配行
      scrollToLine(match.y);
    }
  }

  /// search text
  void _handleSearch(String text) {
    if (text.isEmpty) {
      controller.clearSelection();
      _matches.clear();
      _currentMatchIndex = -1;
      return;
    }

    _lastSearchText = text;
    final buffer = terminal.buffer;
    _matches.clear();
    _currentMatchIndex = -1;

    // get terminal width
    final terminalWidth = buffer.viewWidth;

    // used to record processed matches, avoid duplicate
    final Set<String> processedMatches = {};

    if (_regex) {
      // regex search
      String pattern = text;

      if (_wholeWord) {
        pattern = r'\b' + pattern + r'\b';
      }

      try {
        final regex = RegExp(pattern, caseSensitive: _caseSensitive);

        // handle wrapped line
        String currentLine = '';
        int startY = 0;
        int startX = 0;
        List<CellOffset> wrappedPositions = [];

        for (int y = 0; y < buffer.lines.length; y++) {
          final line = buffer.lines[y];
          final lineText = line.toString();

          // 使用 isWrapped 属性判断是否是自动换行
          bool isWrapped = line.isWrapped;

          if (isWrapped) {
            // 如果是自动换行，将文本拼接
            currentLine += lineText;
            wrappedPositions.add(CellOffset(startX, startY));
          } else {
            // 如果不是自动换行，开始新的行
            currentLine = lineText;
            startY = y;
            startX = 0;
            wrappedPositions = [CellOffset(0, y)];
          }

          // 在当前行（可能包含自动换行的文本）中搜索
          final searchText =
              _caseSensitive ? currentLine : currentLine.toLowerCase();
          final matches = regex.allMatches(searchText);

          for (final match in matches) {
            if (!_wholeWord ||
                _isWholeWord(currentLine, match.start, match.end)) {
              // 计算匹配在终端中的实际位置
              final matchStart = match.start;
              final matchEnd = match.end;

              // 检查匹配是否跨越自动换行
              bool isWrappedMatch = false;
              List<CellOffset> matchPositions = [];

              for (int i = matchStart; i < matchEnd; i++) {
                final lineIndex = i ~/ terminalWidth;
                final x = i % terminalWidth;
                final y = startY + lineIndex;
                matchPositions.add(CellOffset(x, y));

                if (lineIndex > 0) {
                  isWrappedMatch = true;
                }
              }

              // 生成匹配的唯一标识符
              final matchKey = '${matchStart}_${matchEnd}_${startY}';

              // 检查是否已经处理过这个匹配
              if (!processedMatches.contains(matchKey)) {
                processedMatches.add(matchKey);

                _matches.add(MatchInfo(
                  x: matchStart % terminalWidth,
                  y: startY + (matchStart ~/ terminalWidth),
                  length: matchEnd - matchStart,
                  matchedText: match.group(0)!,
                  isWrapped: isWrappedMatch,
                  wrappedPositions: isWrappedMatch ? matchPositions : null,
                ));
              }
            }
          }
        }
      } catch (e) {
        return;
      }
    } else {
      // 普通文本搜索
      final pattern = _caseSensitive ? text : text.toLowerCase();

      // 处理自动换行的情况
      String currentLine = '';
      int startY = 0;
      int startX = 0;
      List<CellOffset> wrappedPositions = [];

      for (int y = 0; y < buffer.lines.length; y++) {
        final line = buffer.lines[y];
        final lineText = line.toString();

        // 使用 isWrapped 属性判断是否是自动换行
        bool isWrapped = line.isWrapped;

        if (isWrapped) {
          // 如果是自动换行，将文本拼接
          currentLine += lineText;
          wrappedPositions.add(CellOffset(startX, startY));
        } else {
          // 如果不是自动换行，开始新的行
          currentLine = lineText;
          startY = y;
          startX = 0;
          wrappedPositions = [CellOffset(0, y)];
        }

        // 在当前行（可能包含自动换行的文本）中搜索
        final searchText =
            _caseSensitive ? currentLine : currentLine.toLowerCase();

        for (int x = 0; x <= searchText.length - pattern.length; x++) {
          final substring = searchText.substring(x, x + pattern.length);
          if (substring == pattern) {
            if (!_wholeWord ||
                _isWholeWord(currentLine, x, x + pattern.length)) {
              // 检查匹配是否跨越自动换行
              bool isWrappedMatch = false;
              List<CellOffset> matchPositions = [];

              for (int i = x; i < x + pattern.length; i++) {
                final lineIndex = i ~/ terminalWidth;
                final matchX = i % terminalWidth;
                final matchY = startY + lineIndex;
                matchPositions.add(CellOffset(matchX, matchY));

                if (lineIndex > 0) {
                  isWrappedMatch = true;
                }
              }

              // 生成匹配的唯一标识符
              final matchKey = '${x}_${x + pattern.length}_${startY}';

              // 检查是否已经处理过这个匹配
              if (!processedMatches.contains(matchKey)) {
                processedMatches.add(matchKey);

                _matches.add(MatchInfo(
                  x: x % terminalWidth,
                  y: startY + (x ~/ terminalWidth),
                  length: pattern.length,
                  matchedText: currentLine.substring(x, x + pattern.length),
                  isWrapped: isWrappedMatch,
                  wrappedPositions: isWrappedMatch ? matchPositions : null,
                ));
              }
            }
          }
        }
      }
    }

    // 过滤重复的匹配
    _matches = _filterDuplicateMatches(_matches);

    if (_matches.isNotEmpty) {
      _currentMatchIndex = 0;
      _selectCurrentMatch();
    } else {
      controller.clearSelection();
    }
  }

  // 过滤重复的匹配
  List<MatchInfo> _filterDuplicateMatches(List<MatchInfo> matches) {
    final Set<String> uniqueMatches = {};
    final List<MatchInfo> filteredMatches = [];

    for (final match in matches) {
      // 生成唯一标识符，包含位置和文本内容
      final matchKey =
          '${match.x}_${match.y}_${match.length}_${match.matchedText}';

      if (!uniqueMatches.contains(matchKey)) {
        uniqueMatches.add(matchKey);
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
    return (codeUnit >= 0x30 && codeUnit <= 0x39) || // 数字 0-9
        (codeUnit >= 0x41 && codeUnit <= 0x5A) || // 大写字母 A-Z
        (codeUnit >= 0x61 && codeUnit <= 0x7A); // 小写字母 a-z
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
