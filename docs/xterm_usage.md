## xterm 使用文档

### 搜索框

#### 使用内置搜索框

`xterm.dart` 内置了搜索框能力，最简单的触发方式是直接调用：

```dart
terminal.showSearch();
```

例如在页面上放一个按钮：

```dart
CupertinoButton(
  onPressed: terminal.showSearch,
  child: const Text('Search'),
)
```

`TerminalView` 会负责显示默认搜索框：

```dart
TerminalView(terminal)
```

默认快捷键：

- Windows / Linux / Android: `Ctrl + F`
- macOS / iOS: `Cmd + F`

#### 注入自定义搜索组件

如果你要自定义搜索 UI，可以通过 `getCustomSearchDelegate` 注入自己的搜索组件：

```dart
TerminalView(
  terminal,
  getCustomSearchDelegate: (controller) {
    return MySearchBox(controller);
  },
)
```

自定义组件里会拿到 `TerminalSearchController`，常用方法包括：

- `setSearchText(...)`
- `findNext()`
- `findPrevious()`
- `close()`
- `setCaseSensitive(...)`
- `setWholeWord(...)`
- `setRegex(...)`

一个最小例子：

```dart
class MySearchBox extends StatelessWidget {
  const MySearchBox(this.controller, {super.key});

  final TerminalSearchController controller;

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Row(
        children: [
          Expanded(
            child: TextField(
              autofocus: true,
              onChanged: controller.setSearchText,
              onSubmitted: (_) => controller.findNext(),
            ),
          ),
          IconButton(
            onPressed: controller.findPrevious,
            icon: const Icon(Icons.keyboard_arrow_up),
          ),
          IconButton(
            onPressed: controller.findNext,
            icon: const Icon(Icons.keyboard_arrow_down),
          ),
          IconButton(
            onPressed: controller.close,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
```

### Context Menu

`TerminalView` 默认会使用内置的自适应 context menu，并且现在区分两类场景：

- `selection` 菜单
  触发于文本选区、selection handle、选中后右键等场景
- `terminal` 菜单
  触发于“没有选区”的终端区域
  桌面端通常是右键空白区域
  移动端通常是长按空白区域

#### 默认行为

默认语义动作大致如下：

- `selection` 菜单：`copy`、`paste`、`selectAll`，以及有清选回调时的 `clearSelection`
- `terminal` 菜单：`paste`、`selectAll`

菜单触发来源可通过 `menu.triggerKind` 判断：

- `programmatic`
- `touchSelection`
- `selectionHandle`
- `secondaryTap`
- `blankAreaLongPress`

#### 接管菜单渲染

如果你想让宿主应用自己决定菜单样式、顺序和交互，可以注册 `contextMenuBuilder`：

```dart
TerminalView(
  terminal,
  contextMenuBuilder: (context, menu) {
    final items = menu.actions
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
        .toList();

    return CupertinoAdaptiveTextSelectionToolbar.buttonItems(
      anchors: menu.anchors,
      buttonItems: items,
    );
  },
)
```

`menu` 中可用的信息：

- `menu.kind`: 当前是 `selection` 菜单还是 `terminal` 菜单
- `menu.actions`: 当前可用的语义动作列表
- `menu.triggerKind`: 菜单触发来源
- `menu.anchorRect` / `menu.anchors`: 菜单定位信息
- `menu.cellOffset`: 触发菜单的终端单元格位置，主要用于 `terminal` 菜单
- `menu.selectedText`: 当前选中文本，主要用于 `selection` 菜单
- `menu.hide()`: 宿主菜单执行动作后可主动关闭菜单

#### 只扩展动作，不重写整套 UI

如果你只想往默认菜单里加动作，而不想完全接管渲染，优先使用 `contextMenuActionsBuilder`：

```dart
TerminalView(
  terminal,
  contextMenuActionsBuilder: (context, menu) {
    if (menu.kind == TerminalContextMenuKind.selection &&
        menu.selectedText != null) {
      return [
        ...menu.actions,
        TerminalContextMenuAction(
          type: TerminalContextMenuActionType.custom,
          label: 'Translate',
          onSelected: () {
            final text = menu.selectedText!;
            debugPrint('translate: $text');
          },
        ),
        TerminalContextMenuAction(
          type: TerminalContextMenuActionType.custom,
          label: 'Ask AI',
          onSelected: () {
            final text = menu.selectedText!;
            debugPrint('ask ai: $text');
          },
        ),
      ];
    }

    if (menu.kind == TerminalContextMenuKind.terminal) {
      return [
        ...menu.actions,
        TerminalContextMenuAction(
          type: TerminalContextMenuActionType.custom,
          label: 'Switch Theme',
          onSelected: () {
            debugPrint('switch theme at ${menu.cellOffset}');
          },
        ),
        TerminalContextMenuAction(
          type: TerminalContextMenuActionType.custom,
          label: 'Disconnect',
          onSelected: () {
            debugPrint('disconnect');
          },
        ),
      ];
    }

    return menu.actions;
  },
)
```

这个接口适合：

- 在选区菜单中增加 `Translate`、`Ask AI`、`Search Web`
- 在空白区域菜单中增加“切主题”“新建连接”“断开连接”
- 基于 `menu.kind` 和 `menu.triggerKind` 决定不同动作集

#### 完整自定义 selection / terminal 菜单

你也可以把 `contextMenuActionsBuilder` 和 `contextMenuBuilder` 组合使用：

- `contextMenuActionsBuilder` 负责生成动作
- `contextMenuBuilder` 负责决定这些动作怎么渲染

例如：

```dart
TerminalView(
  terminal,
  contextMenuActionsBuilder: (context, menu) {
    return menu.actions;
  },
  contextMenuBuilder: (context, menu) {
    if (menu.kind == TerminalContextMenuKind.selection) {
      return MySelectionMenu(menu);
    }
    return MyTerminalMenu(menu);
  },
)
```

#### 兼容入口 toolbarBuilder

如果你只想调整旧的 selection toolbar 按钮列表，而不想接管整个渲染，也可以继续使用 `toolbarBuilder`。

但要注意：

- `toolbarBuilder` 只作用于 `selection` 菜单
- `terminal` 菜单不走 `toolbarBuilder`
- 新项目更推荐 `contextMenuActionsBuilder` + `contextMenuBuilder`

### 快捷键

#### 默认快捷键

Windows / Linux / Android 默认快捷键：

- `Ctrl + F`: 打开搜索
- `Ctrl + Shift + C`: 复制
- `Ctrl + V`: 粘贴
- `Ctrl + Shift + V`: 粘贴
- `Ctrl + A`: 全选
- `Ctrl + X`: 剪切意图
- `Ctrl + Insert`: 复制
- `Shift + Insert`: 粘贴
- `Shift + Delete`: 剪切意图

macOS / iOS 默认快捷键：

- `Cmd + F`: 打开搜索
- `Cmd + C`: 复制
- `Cmd + V`: 粘贴
- `Cmd + A`: 全选
- `Cmd + X`: 剪切意图

说明：

- 当前终端快捷键层里，“剪切”对终端场景本质上等同于复制语义，并不会像传统文本框那样删除终端内容
- 粘贴会读取系统剪贴板并调用 `terminal.paste(...)`

#### 自定义快捷键

可以通过 `shortcuts` 覆盖默认快捷键表：

```dart
TerminalView(
  terminal,
  shortcuts: {
    const SingleActivator(LogicalKeyboardKey.keyF, control: true):
        const ShowSearchIntent(),
    const SingleActivator(LogicalKeyboardKey.keyL, control: true):
        const ShowSearchIntent(),
  },
)
```

注意：

- `shortcuts` 是覆盖，不是增量 merge
- 如果你传了自定义 `shortcuts`，默认快捷键不会自动保留
- 如果你想“在默认基础上追加”，请自己先拷贝一份默认表再扩展

例如：

```dart
final shortcuts = <ShortcutActivator, Intent>{
  ...defaultTerminalShortcuts,
  const SingleActivator(LogicalKeyboardKey.keyL, control: true):
      const ShowSearchIntent(),
};

TerminalView(
  terminal,
  shortcuts: shortcuts,
)
```

### 复制 / 粘贴行为说明

#### 右键是否自动粘贴

默认没有“右键自动粘贴”。

当前默认行为是：

- 右键已有选区：弹出 `selection` context menu
- 右键无选区：弹出 `terminal` context menu

如果你想做“右键直接粘贴”，需要宿主自己实现，例如：

- 通过 `onSecondaryTapUp` 自己处理
- 或在 `terminal` context menu 里只保留 `paste` 并自动触发

#### 选择后是否自动复制

默认没有“选中即自动复制”。

当前默认行为是：

- 选中文本后只创建选区
- 复制需要用户显式执行 `copy`
  可以来自 context menu
  也可以来自快捷键

如果你想实现“选中自动复制”，需要宿主自己加逻辑，例如监听选区变化后主动写入剪贴板。

#### 默认复制 / 粘贴入口

默认支持这些入口：

- context menu 的 `copy` / `paste`
- 快捷键复制 / 粘贴
- 你自行调用 `terminal.paste(...)`

