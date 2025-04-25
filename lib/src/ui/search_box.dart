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

class TerminalSearchBox extends StatefulWidget {
  const TerminalSearchBox({
    super.key,
    required this.terminal,
    required this.onSearch,
    required this.onClose,
    required this.onScrollToLine,
  });

  final Terminal terminal;
  final void Function(String text, CellAnchor? start, CellAnchor? end) onSearch;
  final VoidCallback onClose;
  final void Function(int line) onScrollToLine;

  @override
  State<TerminalSearchBox> createState() => _TerminalSearchBoxState();
}

class _TerminalSearchBoxState extends State<TerminalSearchBox> {
  final _controller = TextEditingController();
  String _lastSearchText = '';
  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _regex = false;
  List<MatchInfo> _matches = [];
  int _currentMatchIndex = -1;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _findNext() {
    if (_matches.isEmpty) return;
    setState(() {
      _currentMatchIndex = (_currentMatchIndex + 1) % _matches.length;
      _selectCurrentMatch();
    });
  }

  void _findPrevious() {
    if (_matches.isEmpty) return;
    setState(() {
      _currentMatchIndex = (_currentMatchIndex - 1 + _matches.length) % _matches.length;
      _selectCurrentMatch();
    });
  }

  void _selectCurrentMatch() {
    if (_currentMatchIndex >= 0 && _currentMatchIndex < _matches.length) {
      final match = _matches[_currentMatchIndex];
      
      // 通知父组件滚动到指定行
      widget.onScrollToLine(match.y);

      // 创建新的锚点
      final start = widget.terminal.buffer.createAnchor(match.x, match.y);
      final end = widget.terminal.buffer.createAnchor(
        match.x + match.length,
        match.y,
      );
      widget.onSearch(_lastSearchText, start, end);
    }
  }

  void _handleSearch(String text) {
    if (text.isEmpty) {
      widget.onSearch('', null, null);
      _matches.clear();
      _currentMatchIndex = -1;
      return;
    }

    _lastSearchText = text;
    final buffer = widget.terminal.buffer;
    final textContent = buffer.getText();
    _matches.clear();
    _currentMatchIndex = -1;

    // 处理正则表达式
    RegExp regex;
    if (_regex) {
      try {
        regex = RegExp(text, caseSensitive: _caseSensitive);
      } catch (e) {
        // 正则表达式无效
        return;
      }
    } else {
      final pattern = _caseSensitive ? text : text.toLowerCase();
      regex = RegExp(RegExp.escape(pattern), caseSensitive: _caseSensitive);
    }

    // 查找所有匹配项
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
      widget.onSearch('', null, null);
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

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      right: 0,
      child: Container(
        width: 300,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(4),
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
                      suffixText: _matches.isNotEmpty
                          ? '${_currentMatchIndex + 1}/${_matches.length}'
                          : '',
                      suffixStyle: const TextStyle(color: Colors.grey),
                    ),
                    onChanged: _handleSearch,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: widget.onClose,
                ),
              ],
            ),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward, color: Colors.white),
                  onPressed: _findPrevious,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward, color: Colors.white),
                  onPressed: _findNext,
                ),
                IconButton(
                  icon: Icon(
                    Icons.text_format,
                    color: _caseSensitive ? Colors.blue : Colors.white,
                  ),
                  onPressed: () {
                    setState(() {
                      _caseSensitive = !_caseSensitive;
                      _handleSearch(_lastSearchText);
                    });
                  },
                ),
                IconButton(
                  icon: Icon(
                    Icons.text_fields,
                    color: _wholeWord ? Colors.blue : Colors.white,
                  ),
                  onPressed: () {
                    setState(() {
                      _wholeWord = !_wholeWord;
                      _handleSearch(_lastSearchText);
                    });
                  },
                ),
                IconButton(
                  icon: Icon(
                    Icons.code,
                    color: _regex ? Colors.blue : Colors.white,
                  ),
                  onPressed: () {
                    setState(() {
                      _regex = !_regex;
                      _handleSearch(_lastSearchText);
                    });
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
} 