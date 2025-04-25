import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/render.dart';

class MatchInfo {
  final int x;
  final int y;
  final int length;
  final String matchedText;

  const MatchInfo({
    required this.x,
    required this.y,
    required this.length,
    required this.matchedText,
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
}

/// 搜索控制器，提供搜索相关的功能
class TerminalSearchController {
  final Terminal terminal;
  final void Function(String text, CellAnchor? start, CellAnchor? end) onSearch;
  final void Function(int line) onScrollToLine;
  final VoidCallback onClose;

  String _lastSearchText = '';
  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _regex = false;
  List<MatchInfo> _matches = [];
  int _currentMatchIndex = -1;

  TerminalSearchController({
    required this.terminal,
    required this.onSearch,
    required this.onClose,
    required this.onScrollToLine,
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

  /// 设置搜索文本
  void setSearchText(String text) {
    _lastSearchText = text;
    _handleSearch(text);
  }

  /// 设置是否区分大小写
  void setCaseSensitive(bool value) {
    _caseSensitive = value;
    _handleSearch(_lastSearchText);
  }

  /// 设置是否全词匹配
  void setWholeWord(bool value) {
    _wholeWord = value;
    _handleSearch(_lastSearchText);
  }

  /// 设置是否使用正则表达式
  void setRegex(bool value) {
    _regex = value;
    _handleSearch(_lastSearchText);
  }

  /// 查找下一个匹配
  void findNext() {
    if (_matches.isEmpty) return;
    _currentMatchIndex = (_currentMatchIndex + 1) % _matches.length;
    _selectCurrentMatch();
  }

  /// 查找上一个匹配
  void findPrevious() {
    if (_matches.isEmpty) return;
    _currentMatchIndex = (_currentMatchIndex - 1 + _matches.length) % _matches.length;
    _selectCurrentMatch();
  }

  void _selectCurrentMatch() {
    if (_currentMatchIndex >= 0 && _currentMatchIndex < _matches.length) {
      final match = _matches[_currentMatchIndex];
      onScrollToLine(match.y);
      final start = terminal.buffer.createAnchor(match.x, match.y);
      final end = terminal.buffer.createAnchor(
        match.x + match.length,
        match.y,
      );
      onSearch(_lastSearchText, start, end);
    }
  }

  void _handleSearch(String text) {
    if (text.isEmpty) {
      onSearch('', null, null);
      _matches.clear();
      _currentMatchIndex = -1;
      return;
    }

    _lastSearchText = text;
    final buffer = terminal.buffer;
    final textContent = buffer.getText();
    _matches.clear();
    _currentMatchIndex = -1;

    RegExp regex;
    if (_regex) {
      try {
        regex = RegExp(text, caseSensitive: _caseSensitive);
      } catch (e) {
        return;
      }
    } else {
      final pattern = _caseSensitive ? text : text.toLowerCase();
      regex = RegExp(RegExp.escape(pattern), caseSensitive: _caseSensitive);
    }

    int currentLine = 0;
    int currentColumn = 0;
    
    for (int i = 0; i < textContent.length; i++) {
      if (textContent[i] == '\n') {
        currentLine++;
        currentColumn = 0;
        continue;
      }
      
      if (i + text.length <= textContent.length) {
        final lineText = textContent.substring(i, i + text.length);
        final match = regex.firstMatch(lineText);
        if (match != null) {
          if (!_wholeWord || _isWholeWord(textContent, i, i + match.group(0)!.length)) {
            _matches.add(MatchInfo(
              x: currentColumn,
              y: currentLine,
              length: match.group(0)!.length,
              matchedText: match.group(0)!,
            ));
          }
        }
      }
      currentColumn++;
    }

    if (_matches.isNotEmpty) {
      _currentMatchIndex = 0;
      _selectCurrentMatch();
    } else {
      onSearch('', null, null);
    }
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
           (codeUnit >= 0x61 && codeUnit <= 0x7A);   // 小写字母 a-z
  }
}

/// 默认的搜索框实现
class DefaultTerminalSearchBox extends StatefulWidget implements TerminalSearchDelegate {
  final TerminalSearchController controller;
  final bool isVisible;

  const DefaultTerminalSearchBox({
    super.key,
    required this.controller,
    this.isVisible = true,
  });

  @override
  Widget build(BuildContext context, TerminalSearchController controller) {
    return this;
  }

  @override
  State<StatefulWidget> createState() => _DefaultTerminalSearchBoxState();

  @override
  void show() {
    // 默认实现不需要额外操作
  }

  @override
  void hide() {
    // 默认实现不需要额外操作
  }

  Offset get position {
    final state = _DefaultTerminalSearchBoxState();
    return state._position;
  }

  void onPanStart(DragStartDetails details) {
    final state = _DefaultTerminalSearchBoxState();
    state._onPanStart(details);
  }

  void onPanUpdate(DragUpdateDetails details) {
    final state = _DefaultTerminalSearchBoxState();
    state._onPanUpdate(details);
  }

  void onPanEnd(DragEndDetails details) {
    final state = _DefaultTerminalSearchBoxState();
    state._onPanEnd(details);
  }
}

class _DefaultTerminalSearchBoxState extends State<DefaultTerminalSearchBox> {
  final _controller = TextEditingController();
  Offset _position = const Offset(0, 0);
  bool _isDragging = false;
  Offset _dragStartPosition = Offset.zero;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.controller.searchText;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPanStart(DragStartDetails details) {
    _isDragging = true;
    _dragStartPosition = details.globalPosition;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_isDragging) {
      setState(() {
        _position += details.delta;
        
        // 获取父容器大小
        final renderBox = context.findRenderObject() as RenderBox?;
        if (renderBox != null) {
          final parent = renderBox.parent as RenderBox?;
          if (parent != null) {
            final parentSize = parent.size;
            // 限制水平范围
            if (_position.dx < 0) {
              _position = Offset(0, _position.dy);
            } else if (_position.dx + 300 > parentSize.width) {
              _position = Offset(parentSize.width - 300, _position.dy);
            }
            
            // 限制垂直范围
            if (_position.dy < 0) {
              _position = Offset(_position.dx, 0);
            } else if (_position.dy + 100 > parentSize.height) {
              _position = Offset(_position.dx, parentSize.height - 100);
            }
          }
        }
      });
    }
  }

  void _onPanEnd(DragEndDetails details) {
    _isDragging = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isVisible) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: GestureDetector(
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: Container(
          width: 300,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(4),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: '搜索...',
                        hintStyle: const TextStyle(color: Colors.grey),
                        border: InputBorder.none,
                        suffixText: widget.controller.matchCount > 0
                            ? '${widget.controller.currentMatchIndex + 1}/${widget.controller.matchCount}'
                            : '',
                        suffixStyle: const TextStyle(color: Colors.grey),
                      ),
                      onChanged: widget.controller.setSearchText,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () {
                      widget.controller.onClose();
                      _controller.clear();
                    },
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, color: Colors.white),
                    onPressed: widget.controller.findPrevious,
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_downward, color: Colors.white),
                    onPressed: widget.controller.findNext,
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.text_format,
                      color: widget.controller.caseSensitive ? Colors.blue : Colors.white,
                    ),
                    onPressed: () {
                      widget.controller.setCaseSensitive(!widget.controller.caseSensitive);
                    },
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.text_fields,
                      color: widget.controller.wholeWord ? Colors.blue : Colors.white,
                    ),
                    onPressed: () {
                      widget.controller.setWholeWord(!widget.controller.wholeWord);
                    },
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.code,
                      color: widget.controller.regex ? Colors.blue : Colors.white,
                    ),
                    onPressed: () {
                      widget.controller.setRegex(!widget.controller.regex);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 搜索框包装器，用于在终端视图中显示搜索框
class TerminalSearchBox extends StatelessWidget {
  final Terminal terminal;
  final TerminalSearchDelegate searchDelegate;
  final void Function(String text, CellAnchor? start, CellAnchor? end) onSearch;
  final VoidCallback onClose;
  final void Function(int line) onScrollToLine;

  const TerminalSearchBox({
    super.key,
    required this.terminal,
    required this.searchDelegate,
    required this.onSearch,
    required this.onClose,
    required this.onScrollToLine,
  });

  @override
  Widget build(BuildContext context) {
    final controller = TerminalSearchController(
      terminal: terminal,
      onSearch: onSearch,
      onClose: onClose,
      onScrollToLine: onScrollToLine,
    );

    return searchDelegate.build(context, controller);
  }
} 