import 'package:flutter/material.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/terminal.dart';

class TerminalSearchBox extends StatefulWidget {
  const TerminalSearchBox({
    super.key,
    required this.terminal,
    required this.onSearch,
    required this.onClose,
  });

  final Terminal terminal;
  final void Function(String text, CellAnchor? start, CellAnchor? end) onSearch;
  final VoidCallback onClose;

  @override
  State<TerminalSearchBox> createState() => _TerminalSearchBoxState();
}

class _TerminalSearchBoxState extends State<TerminalSearchBox> {
  final _controller = TextEditingController();
  String _lastSearchText = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleSearch(String text) {
    if (text.isEmpty) {
      widget.onSearch('', null, null);
      return;
    }

    _lastSearchText = text;
    final buffer = widget.terminal.buffer;
    final textContent = buffer.getText();
    print('textContent: 【${textContent.trim()}】');
    final index = textContent.indexOf(text);
    
    if (index != -1) {
      // 计算匹配文本的起始和结束位置
      int currentLine = 0;
      int currentColumn = 0;
      int targetIndex = 0;
      
      for (int i = 0; i < textContent.length; i++) {
        if (i == index) {
          targetIndex = i;
          break;
        }
        if (textContent[i] == '\n') {
          currentLine++;
          currentColumn = 0;
        } else {
          currentColumn++;
        }
      }
      
      final start = buffer.createAnchor(currentColumn, currentLine);
      final end = buffer.createAnchor(currentColumn + text.length, currentLine);
      
      widget.onSearch(text, start, end);
      print('start: $start, end: $end');
    } else {
      widget.onSearch(text, null, null);
    }
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
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: '搜索...',
                  hintStyle: TextStyle(color: Colors.grey),
                  border: InputBorder.none,
                ),
                onChanged: _handleSearch,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () {
                widget.onClose();
              },
            ),
          ],
        ),
      ),
    );
  }
} 