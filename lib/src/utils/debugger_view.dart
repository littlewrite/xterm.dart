import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/src/utils/debugger.dart';

class TerminalDebuggerView extends StatefulWidget {
  const TerminalDebuggerView(
    this.debugger, {
    super.key,
    this.scrollController,
    this.onSeek,
  });

  final TerminalDebugger debugger;

  final ScrollController? scrollController;

  final void Function(int?)? onSeek;

  @override
  State<TerminalDebuggerView> createState() => _TerminalDebuggerViewState();
}

class _TerminalDebuggerViewState extends State<TerminalDebuggerView> {
  int? selectedCommand;
  late final FocusNode _focusNode;
  late final ScrollController _internalScrollController;
  int _lastCommandCount = 0;

  @override
  void initState() {
    widget.debugger.addListener(_onDebuggerChanged);
    _focusNode = FocusNode();
    _internalScrollController = widget.scrollController ?? ScrollController();
    _lastCommandCount = widget.debugger.commands.length;
    super.initState();
  }

  @override
  void didUpdateWidget(covariant TerminalDebuggerView oldWidget) {
    if (oldWidget.debugger != widget.debugger) {
      oldWidget.debugger.removeListener(_onDebuggerChanged);
      widget.debugger.addListener(_onDebuggerChanged);
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    widget.debugger.removeListener(_onDebuggerChanged);
    _focusNode.dispose();
    // Only dispose the scroll controller if we created it internally
    if (widget.scrollController == null) {
      _internalScrollController.dispose();
    }
    super.dispose();
  }

  void _onDebuggerChanged() {
    final currentCommandCount = widget.debugger.commands.length;
    
    setState(() {});
    
    // Auto-scroll to bottom when new commands are added
    if (currentCommandCount > _lastCommandCount) {
      _lastCommandCount = currentCommandCount;
      
      // Use WidgetsBinding to ensure the ListView has been rebuilt before scrolling
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_internalScrollController.hasClients) {
          _internalScrollController.animateTo(
            _internalScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    final commands = widget.debugger.commands;
    if (commands.isEmpty) return;
    
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        setState(() {
          if (selectedCommand == null) {
            // 如果没有选择，不执行任何操作
            return;
          }
          // 向上选择
          selectedCommand = (selectedCommand! > 0) ? selectedCommand! - 1 : 0;
          widget.onSeek?.call(selectedCommand);
        });
      } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        setState(() {
          if (selectedCommand == null) {
            // 如果没有选择，不执行任何操作
            return;
          }
          // 向下选择
          selectedCommand = (selectedCommand! < commands.length - 1) 
              ? selectedCommand! + 1 
              : commands.length - 1;
          widget.onSeek?.call(selectedCommand);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final commands = widget.debugger.commands;
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        _handleKeyEvent(event);
        return KeyEventResult.handled;
      },
      child: ListView.builder(
        itemExtent: 20,
        controller: _internalScrollController,
        itemCount: commands.length,
        itemBuilder: (context, index) {
          final command = commands[index];
          return _CommandItem(
            index,
            command,
            selected: selectedCommand == index,
            onTap: () {
              if (selectedCommand == index) {
                selectedCommand = null;
              } else {
                setState(() => selectedCommand = index);
              }
              widget.onSeek?.call(selectedCommand);
            },
          );
        },
      ),
    );
  }
}

class _CommandItem extends StatelessWidget {
  const _CommandItem(
    this.index,
    this.command, {
    this.onTap,
    this.selected = false,
  });

  final int index;

  final TerminalCommand command;

  final bool selected;

  final void Function()? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (event) {
          if (event.down) {
            onTap?.call();
          }
        },
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? Colors.blue : Colors.transparent,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(
            children: [
              Container(
                width: 50,
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    color: selected ? Colors.blue : Colors.black,
                    fontSize: 14,
                    fontFamily: 'monospace',
                    fontFamilyFallback: [
                      'Menlo',
                      'Monaco',
                      'Consolas',
                      'Liberation Mono',
                      'Courier New',
                      'Noto Sans Mono CJK SC',
                      'Noto Sans Mono CJK TC',
                      'Noto Sans Mono CJK KR',
                      'Noto Sans Mono CJK JP',
                      'Noto Sans Mono CJK HK',
                      'Noto Color Emoji',
                      'Noto Sans Symbols',
                      'monospace',
                      'sans-serif',
                    ],
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
              SizedBox(width: 20),
              Container(
                width: 400,
                child: Text(
                  command.escapedChars,
                  style: TextStyle(
                    color: command.error ? Colors.red : null,
                    fontSize: 14,
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  child: Text(
                    command.explanation.join(','),
                    style: TextStyle(
                      color: command.error ? Colors.red : null,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
