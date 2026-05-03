import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:example/src/virtual_keyboard.dart';
import 'package:flutter/cupertino.dart';
import 'package:xterm/xterm.dart';

const host = '127.0.0.1';
const port = 22;
const username = 'root';
const password = '';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      title: 'xterm.dart demo',
      home: MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({super.key});

  @override
  // ignore: library_private_types_in_public_api
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late final terminal = Terminal(inputHandler: keyboard);

  final keyboard = VirtualKeyboard(defaultInputHandler);

  var title = host;

  @override
  void initState() {
    super.initState();
    initTerminal();
  }

  Future<void> initTerminal() async {
    terminal.write('Connecting...\r\n');

    final client = SSHClient(
      await SSHSocket.connect(host, port),
      username: username,
      onPasswordRequest: () => password,
    );

    terminal.write('Connected\r\n');

    final session = await client.shell(
      pty: SSHPtyConfig(
        width: terminal.viewWidth,
        height: terminal.viewHeight,
      ),
    );

    terminal.buffer.clear();
    terminal.buffer.setCursor(0, 0);

    terminal.onTitleChange = (title) {
      setState(() => this.title = title);
    };

    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      session.resizeTerminal(width, height, pixelWidth, pixelHeight);
    };

    terminal.onOutput = (data) {
      session.write(utf8.encode(data));
    };

    session.stdout
        .cast<List<int>>()
        .transform(Utf8Decoder())
        .listen(terminal.write);

    session.stderr
        .cast<List<int>>()
        .transform(Utf8Decoder())
        .listen(terminal.write);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(title),
        backgroundColor:
            CupertinoTheme.of(context).barBackgroundColor.withOpacity(0.5),
      ),
      child: Column(
        children: [
          Expanded(
            child: TerminalView(
              terminal,
              contextMenuBuilder: _buildTerminalContextMenu,
            ),
          ),
          VirtualKeyboardView(
            keyboard,
            actions: [
              CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                onPressed: terminal.showSearch,
                child: const Text('Search'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTerminalContextMenu(
    BuildContext context,
    TerminalContextMenu menu,
  ) {
    return CupertinoAdaptiveTextSelectionToolbar.buttonItems(
      anchors: menu.anchors,
      buttonItems: _buildContextMenuButtonItems(menu),
    );
  }

  List<ContextMenuButtonItem> _buildContextMenuButtonItems(
    TerminalContextMenu menu,
  ) {
    final actions = _orderedContextMenuActions(menu);
    return actions
        .map(
          (action) => ContextMenuButtonItem(
            label: action.label,
            onPressed: action.enabled
                ? () {
                    action.onSelected();
                    menu.hide();
                  }
                : null,
          ),
        )
        .toList(growable: false);
  }

  List<TerminalContextMenuAction> _orderedContextMenuActions(
    TerminalContextMenu menu,
  ) {
    final actions = List<TerminalContextMenuAction>.from(menu.actions);
    final preferredOrder = switch (menu.triggerKind) {
      TerminalContextMenuTriggerKind.secondaryTap =>
        <TerminalContextMenuActionType>[
          TerminalContextMenuActionType.copy,
          TerminalContextMenuActionType.paste,
          TerminalContextMenuActionType.selectAll,
          TerminalContextMenuActionType.clearSelection,
          TerminalContextMenuActionType.custom,
        ],
      _ => <TerminalContextMenuActionType>[
          TerminalContextMenuActionType.copy,
          TerminalContextMenuActionType.selectAll,
          TerminalContextMenuActionType.paste,
          TerminalContextMenuActionType.clearSelection,
          TerminalContextMenuActionType.custom,
        ],
    };

    actions.sort((a, b) {
      final aIndex = preferredOrder.indexOf(a.type);
      final bIndex = preferredOrder.indexOf(b.type);
      final normalizedA = aIndex == -1 ? preferredOrder.length : aIndex;
      final normalizedB = bIndex == -1 ? preferredOrder.length : bIndex;
      return normalizedA.compareTo(normalizedB);
    });

    return actions;
  }
}
