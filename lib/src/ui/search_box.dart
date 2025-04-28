import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/themes.dart';

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

/// 搜索框的抽象接口
abstract class TerminalSearchDelegate {
  /// 搜索框的构建方法
  Widget build(BuildContext context, TerminalSearchController controller);

  /// 搜索框是否可见
  bool get isVisible;

  /// 显示搜索框
  void show();

  /// 隐藏搜索框
  void hide();

  /// 获取搜索控制器
  TerminalSearchController get searchController;
}

/// 搜索控制器，提供搜索相关的功能
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

  /// 获取当前搜索文本
  String get searchText => _lastSearchText;

  /// 是否区分大小写
  bool get caseSensitive => _caseSensitive;

  /// 是否全词匹配
  bool get wholeWord => _wholeWord;

  /// 是否使用正则表达式
  bool get regex => _regex;

  /// 当前匹配索引
  int get currentMatchIndex => _currentMatchIndex;

  /// 匹配总数
  int get matchCount => _matches.length;

  /// 当前匹配索引
  int get currentIdx => _currentMatchIndex % _matches.length;

  /// 设置搜索文本
  void setSearchText(String text) {
    _lastSearchText = text;
    _handleSearch(text);
    notifyListeners();
  }

  /// 设置是否区分大小写
  void setCaseSensitive(bool value) {
    _caseSensitive = value;
    _handleSearch(_lastSearchText);
    notifyListeners();
  }

  /// 设置是否全词匹配
  void setWholeWord(bool value) {
    _wholeWord = value;
    _handleSearch(_lastSearchText);
    notifyListeners();
  }

  /// 设置是否使用正则表达式
  void setRegex(bool value) {
    _regex = value;
    _handleSearch(_lastSearchText);
    notifyListeners();
  }

  /// 查找下一个匹配
  void findNext() {
    if (_matches.isEmpty) return;
    _currentMatchIndex = (_currentMatchIndex + 1) % _matches.length;
    _selectCurrentMatch();
    notifyListeners();
  }

  /// 查找上一个匹配
  void findPrevious() {
    if (_matches.isEmpty) return;
    _currentMatchIndex =
        (_currentMatchIndex - 1 + _matches.length) % _matches.length;
    _selectCurrentMatch();
    notifyListeners();
  }

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

  // 检索文字
  void _handleSearch(String text) {
    print(' search ctrl  _handleSearch: $text');
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

    // 获取终端宽度
    final terminalWidth = buffer.viewWidth;

    // 用于记录已经处理过的匹配位置，避免重复
    final Set<String> processedMatches = {};

    if (_regex) {
      // 正则表达式搜索
      String pattern = text;

      if (_wholeWord) {
        pattern = r'\b' + pattern + r'\b';
      }

      try {
        final regex = RegExp(pattern, caseSensitive: _caseSensitive);

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

    print(' search ctrl  _handleSearch: ${_matches.length}');
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

  const DefaultTerminalSearchBox({
    super.key,
    required TerminalSearchController searchController,
    this.isVisible = true,
    this.onHide,
    this.onClose,
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

    final theme = TerminalThemes.defaultTheme;

    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.brightBlack,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: theme.black.withOpacity(0.3),
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
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.search, color: Colors.grey, size: 20),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: TextStyle(color: theme.foreground),
                      decoration: InputDecoration(
                        hintText: '默认搜索...',
                        hintStyle: TextStyle(color: theme.brightBlack),
                        border: InputBorder.none,
                        suffixText: widget.searchController.matchCount > 0
                            ? '${widget.searchController.currentIdx + 1}/${widget.searchController.matchCount}'
                            : '',
                        suffixStyle: TextStyle(color: theme.brightBlack),
                      ),
                      onChanged: widget.searchController.setSearchText,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey, size: 20),
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
                      icon: const Icon(Icons.arrow_upward, color: Colors.white),
                      onPressed: widget.searchController.findPrevious,
                      tooltip: '上一个匹配',
                    ),
                    IconButton(
                      icon:
                          const Icon(Icons.arrow_downward, color: Colors.white),
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
                        color: _caseSensitive ? theme.blue : theme.brightBlack,
                      ),
                      onPressed: () => _updateCaseSensitive(!_caseSensitive),
                      tooltip: '区分大小写',
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.text_format,
                        color: _wholeWord ? theme.blue : theme.brightBlack,
                      ),
                      onPressed: () => _updateWholeWord(!_wholeWord),
                      tooltip: '全词匹配',
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.code,
                        color: _regex ? theme.blue : theme.brightBlack,
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
