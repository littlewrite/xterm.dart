import 'dart:convert';
import 'dart:io';

import 'package:example/src/platform_menu.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

void main() {
  runApp(MyApp());
}

bool get isDesktop {
  if (kIsWeb) return false;
  return [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ].contains(defaultTargetPlatform);
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'xterm.dart demo',
      debugShowCheckedModeBanner: false,
      home: AppPlatformMenu(child: Home()),
      // shortcuts: ,
    );
  }
}

class Home extends StatefulWidget {
  Home({super.key});

  @override
  // ignore: library_private_types_in_public_api
  _HomeState createState() => _HomeState();
}

class CustomSearchBox extends StatefulWidget implements TerminalSearchDelegate {
  final TerminalSearchController _searchController;
  @override
  final bool isVisible;
  final VoidCallback? onHide;
  final VoidCallback? onClose;

  const CustomSearchBox({
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
  State<StatefulWidget> createState() => _CustomSearchBoxState();

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

class _CustomSearchBoxState extends State<CustomSearchBox> {
  final _controller = TextEditingController();
  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _regex = false;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.searchController.searchText;
    _caseSensitive = widget.searchController.caseSensitive;
    _wholeWord = widget.searchController.wholeWord;
    _regex = widget.searchController.regex;
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

    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.grey[800]!,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
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
                color: Colors.grey[800],
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: Colors.grey[700]!,
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
                      autofocus: true,
                      controller: _controller,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: '搜索...',
                        hintStyle: const TextStyle(color: Colors.grey),
                        border: InputBorder.none,
                        suffixText: widget.searchController.matchCount > 0
                            ? '${widget.searchController.currentIdx + 1}/${widget.searchController.matchCount}'
                            : '',
                        suffixStyle: const TextStyle(color: Colors.grey),
                      ),
                      onChanged: widget.searchController.setSearchText,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                    onPressed: widget.searchController.close,
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
                        color: _caseSensitive ? Colors.blue : Colors.grey,
                      ),
                      onPressed: () => _updateCaseSensitive(!_caseSensitive),
                      tooltip: '区分大小写',
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.text_format,
                        color: _wholeWord ? Colors.blue : Colors.grey,
                      ),
                      onPressed: () => _updateWholeWord(!_wholeWord),
                      tooltip: '全词匹配',
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.code,
                        color: _regex ? Colors.blue : Colors.grey,
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

class _HomeState extends State<Home> {
  late Terminal terminal;
  late TerminalSearchController searchController;
  bool _useCustomSearch = false;
  final GlobalKey _terminalKey = GlobalKey();

  late Pty pty;

  void _initTerminal() {
    terminal = Terminal(
      maxLines: 10000,
    );

    terminal.setCursorBlink();

    // 初始化 PTY
    WidgetsBinding.instance.endOfFrame.then(
      (_) {
        if (mounted) _startPty();
      },
    );
  }

  @override
  void initState() {
    super.initState();
    _initTerminal();
  }

  void _startPty() {
    pty = Pty.start(
      shell,
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );

    pty.output
        .cast<List<int>>()
        .transform(Utf8Decoder())
        .listen(terminal.write);

    pty.exitCode.then((code) {
      terminal.write('the process exited with exit code $code');
    });

    terminal.onOutput = (data) {
      pty.write(const Utf8Encoder().convert(data));
    };

    terminal.onResize = (w, h, pw, ph) {
      pty.resize(h, w);
    };
  }

  void _tapUp(TapUpDetails details, CellOffset offset) {}

  void _secondTapUp(
    TapUpDetails details,
    CellOffset offset,
  ) {}

  Widget _setSearchBox(controller) {
    return CustomSearchBox(
      searchController: controller,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                ElevatedButton(
                  onPressed: () {
                    terminal.showSearch();
                  },
                  child: const Text('搜索'),
                ),
                ElevatedButton(
                  onPressed: () {
                    terminal.closeSearch();
                  },
                  child: const Text('关闭搜索'),
                ),
                Switch(
                  value: _useCustomSearch,
                  onChanged: (value) {
                    setState(() {
                      _useCustomSearch = value;
                    });
                  },
                  activeColor: Colors.blue,
                ),
                Text(_useCustomSearch ? '自定义搜索' : '默认搜索'),
              ],
            ),
            Expanded(
              child: TerminalView(
                key: _terminalKey,
                terminal,
                autofocus: true,
                backgroundOpacity: 0.7,
                onTapUp: _tapUp,
                onSecondaryTapUp: _secondTapUp,
                getCustomSearchDelegate:
                    _useCustomSearch ? _setSearchBox : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String get shell {
  if (Platform.isMacOS || Platform.isLinux) {
    return Platform.environment['SHELL'] ?? 'bash';
  }

  if (Platform.isWindows) {
    return 'cmd.exe';
  }

  return 'sh';
}
