import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/input/keys.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';
import 'package:xterm/src/ui/gesture/gesture_handler.dart';
import 'package:xterm/src/ui/input_map.dart';
import 'package:xterm/src/ui/keyboard_listener.dart';
import 'package:xterm/src/ui/keyboard_visibility.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/search_box.dart';
import 'package:xterm/src/ui/scroll_handler.dart';
import 'package:xterm/src/ui/shortcut/actions.dart';
import 'package:xterm/src/ui/shortcut/shortcuts.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';
import 'package:xterm/src/ui/themes.dart';

class TerminalView extends StatefulWidget {
  const TerminalView(
    this.terminal, {
    super.key,
    this.controller,
    this.theme = TerminalThemes.defaultTheme,
    this.textStyle = const TerminalStyle(),
    this.textScaler,
    this.padding,
    this.scrollController,
    this.autoResize = true,
    this.backgroundOpacity = 1,
    this.focusNode,
    this.autofocus = false,
    this.onTapUp,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.mouseCursor = SystemMouseCursors.text,
    this.keyboardType = TextInputType.emailAddress,
    this.keyboardAppearance = Brightness.dark,
    this.cursorType = TerminalCursorType.block,
    this.cursorBlink = false,
    this.cursorBlinkInterval = const Duration(milliseconds: 530),
    this.alwaysShowCursor = false,
    this.deleteDetection = false,
    this.shortcuts,
    this.onKeyEvent,
    this.readOnly = false,
    this.hardwareKeyboardOnly = false,
    this.simulateScroll = true,
    this.getCustomSearchDelegate,
    this.hideScrollBar = true,
    this.viewOffset = Offset.zero,
    this.showToolbar = true,
    this.enableSuggestions = true,
    this.scrollBehavior,
    this.toolbarBuilder,
    this.onCopied,
    this.onSelectAll,
    this.onPaste,
  });

  /// The underlying terminal that this widget renders.
  final Terminal terminal;

  final TerminalController? controller;

  /// The theme to use for this terminal.
  final TerminalTheme theme;

  /// The style to use for painting characters.
  final TerminalStyle textStyle;

  final TextScaler? textScaler;

  /// Padding around the inner [Scrollable] widget.
  final EdgeInsets? padding;

  /// Scroll controller for the inner [Scrollable] widget.
  final ScrollController? scrollController;

  /// Should this widget automatically notify the underlying terminal when its
  /// size changes. [true] by default.
  final bool autoResize;

  /// Opacity of the terminal background. Set to 0 to make the terminal
  /// background transparent.
  final double backgroundOpacity;

  /// An optional focus node to use as the focus node for this widget.
  final FocusNode? focusNode;

  /// True if this widget will be selected as the initial focus when no other
  /// node in its scope is currently focused.
  final bool autofocus;

  /// Callback for when the user taps on the terminal.
  final void Function(TapUpDetails, CellOffset)? onTapUp;

  /// Function called when the user taps on the terminal with a secondary
  /// button.
  final void Function(TapDownDetails, CellOffset)? onSecondaryTapDown;

  /// Function called when the user stops holding down a secondary button.
  final void Function(TapUpDetails, CellOffset)? onSecondaryTapUp;

  final Widget Function(TerminalSearchController)? getCustomSearchDelegate;

  /// The mouse cursor for mouse pointers that are hovering over the terminal.
  /// [SystemMouseCursors.text] by default.
  final MouseCursor mouseCursor;

  /// The type of information for which to optimize the text input control.
  /// [TextInputType.emailAddress] by default.
  final TextInputType keyboardType;

  /// The appearance of the keyboard. [Brightness.dark] by default.
  ///
  /// This setting is only honored on iOS devices.
  final Brightness keyboardAppearance;

  /// The type of cursor to use. [TerminalCursorType.block] by default.
  final TerminalCursorType cursorType;

  /// Whether the cursor should blink. [false] by default to match legacy behavior.
  final bool cursorBlink;

  /// Interval used when [cursorBlink] is enabled.
  final Duration cursorBlinkInterval;

  /// Whether to always show the cursor. This is useful for debugging.
  /// [false] by default.
  final bool alwaysShowCursor;

  /// Workaround to detect delete key for platforms and IMEs that does not
  /// emit hardware delete event. Prefered on mobile platforms. [false] by
  /// default.
  final bool deleteDetection;

  /// Shortcuts for this terminal. This has higher priority than input handler
  /// of the terminal If not provided, [defaultTerminalShortcuts] will be used.
  final Map<ShortcutActivator, Intent>? shortcuts;

  /// Keyboard event handler of the terminal. This has higher priority than
  /// [shortcuts] and input handler of the terminal.
  final FocusOnKeyEventCallback? onKeyEvent;

  /// True if no input should send to the terminal.
  final bool readOnly;

  /// True if only hardware keyboard events should be used as input. This will
  /// also prevent any on-screen keyboard to be shown.
  final bool hardwareKeyboardOnly;

  /// If true, when the terminal is in alternate buffer (for example running
  /// vim, man, etc), if the application does not declare that it can handle
  /// scrolling, the terminal will simulate scrolling by sending up/down arrow
  /// keys to the application. This is standard behavior for most terminal
  /// emulators. True by default.
  final bool simulateScroll;

  final bool hideScrollBar;

  final Offset viewOffset;

  final bool showToolbar;

  /// If this is false, some Chinese Android will open safe keyboard.
  final bool enableSuggestions;

  /// Allows customizing the scroll behavior used by the terminal viewport.
  final ScrollBehavior? scrollBehavior;

  /// Optional builder to customize selection toolbar items shown by the input bridge.
  final CustomTextEditToolbarBuilder? toolbarBuilder;

  /// Callback to show toast after copy operation.
  final void Function()? onCopied;

  /// Callback to select all text in the terminal.
  final void Function()? onSelectAll;

  /// Callback to paste text from clipboard to terminal.
  final void Function()? onPaste;

  @override
  State<TerminalView> createState() => TerminalViewState();
}

class TerminalViewState extends State<TerminalView> {
  late FocusNode _focusNode;

  late final ShortcutManager _shortcutManager;

  final _customTextEditKey = GlobalKey<CustomTextEditState>();

  final _scrollableKey = GlobalKey<ScrollableState>();

  final _viewportKey = GlobalKey();

  final _searchBoxKey = GlobalKey();

  bool _hasInputConnection = false;
  bool _scrollToBottomScheduled = false;
  Timer? _cursorBlinkTimer;
  final _cursorBlinkVisible = ValueNotifier<bool>(true);
  bool _previousBlinkEnabled = false;

  final _composingText = ValueNotifier<String?>(null);

  late TerminalController _controller;

  late ScrollController _scrollController;

  late TerminalSearchController _searchController;

  bool _showSearchBox = false;

  Offset _searchBoxPosition = const Offset(0, 0);

  bool _isDragging = false;

  RenderTerminal get renderTerminal =>
      _viewportKey.currentContext!.findRenderObject() as RenderTerminal;

  late Widget _searchBox;
  late final textSizeNoti = ValueNotifier(widget.textStyle.fontSize);

  @override
  void initState() {
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChange);
    _controller = widget.controller ?? TerminalController();
    _scrollController = widget.scrollController ?? ScrollController();
    _shortcutManager = ShortcutManager(
      shortcuts: widget.shortcuts ?? defaultTerminalShortcuts,
    );
    super.initState();
    _updateCursorBlink(scheduleSetState: false);
    _initSearchBox();
    widget.terminal.onSearch = _showSearch;
    widget.terminal.onCloseSearch = _closeSearch;
  }

  void _initSearchBox() {
    _searchController = TerminalSearchController(
      terminal: widget.terminal,
      controller: _controller,
      scrollToLine: _scrollToLine,
      setShowSearch: (show) => setState(() => _showSearchBox = show),
    );

    if (widget.getCustomSearchDelegate != null) {
      _searchBox = widget.getCustomSearchDelegate!(_searchController);
    } else {
      _searchBox = DefaultTerminalSearchBox(
        theme: widget.theme,
        searchController: _searchController,
      );
    }
  }

  @override
  void didUpdateWidget(TerminalView oldWidget) {
    if (oldWidget.focusNode != widget.focusNode) {
      _focusNode.removeListener(_handleFocusChange);
      if (oldWidget.focusNode == null) {
        _focusNode.dispose();
      }
      _focusNode = widget.focusNode ?? FocusNode();
      _focusNode.addListener(_handleFocusChange);
      _updateCursorBlink(resetVisible: true);
    }
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller == null) {
        _controller.dispose();
      }
      _controller = widget.controller ?? TerminalController();
    }
    if (oldWidget.scrollController != widget.scrollController) {
      if (oldWidget.scrollController == null) {
        _scrollController.dispose();
      }
      _scrollController = widget.scrollController ?? ScrollController();
    }
    _shortcutManager.shortcuts = widget.shortcuts ?? defaultTerminalShortcuts;
    if (oldWidget.textStyle.fontSize != widget.textStyle.fontSize) {
      textSizeNoti.value = widget.textStyle.fontSize;
    }
    if (oldWidget.cursorBlink != widget.cursorBlink ||
        oldWidget.cursorBlinkInterval != widget.cursorBlinkInterval ||
        oldWidget.alwaysShowCursor != widget.alwaysShowCursor) {
      _updateCursorBlink(resetVisible: true);
    }
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.onSearch = null;
      oldWidget.terminal.onCloseSearch = null;
    }
    if (oldWidget.terminal != widget.terminal ||
        oldWidget.controller != widget.controller ||
        oldWidget.getCustomSearchDelegate != widget.getCustomSearchDelegate ||
        oldWidget.theme != widget.theme) {
      _initSearchBox();
      widget.terminal.onSearch = _showSearch;
      widget.terminal.onCloseSearch = _closeSearch;
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    if (widget.controller == null) {
      _controller.dispose();
    }
    if (widget.scrollController == null) {
      _scrollController.dispose();
    }
    _shortcutManager.dispose();
    textSizeNoti.dispose();
    _cursorBlinkTimer?.cancel();
    _cursorBlinkVisible.dispose();
    _composingText.dispose();
    widget.terminal.onSearch = null;
    widget.terminal.onCloseSearch = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = ScrollConfiguration(
      behavior: widget.scrollBehavior ?? const _TerminalScrollBehavior(),
      child: Scrollable(
        key: _scrollableKey,
        controller: _scrollController,
        physics: const ClampingScrollPhysics(),
        viewportBuilder: (context, offset) {
          return ValueListenableBuilder(
            valueListenable: textSizeNoti,
            builder: (context1, textSize, child1) {
              return ValueListenableBuilder(
                valueListenable: _cursorBlinkVisible,
                builder: (context2, cursorBlinkVisible, child2) {
                  return ValueListenableBuilder(
                    valueListenable: _composingText,
                    builder: (context3, composingText, child3) {
                      return _TerminalView(
                        key: _viewportKey,
                        terminal: widget.terminal,
                        controller: _controller,
                        offset: offset,
                        padding: MediaQuery.of(context).padding,
                        autoResize: widget.autoResize,
                        textStyle:
                            widget.textStyle.copyWith(fontSize: textSize),
                        textScaler: widget.textScaler ??
                            MediaQuery.textScalerOf(context),
                        theme: widget.theme,
                        focusNode: _focusNode,
                        cursorType: widget.cursorType,
                        cursorBlinkEnabled: _cursorBlinkEnabled,
                        cursorBlinkVisible: cursorBlinkVisible,
                        alwaysShowCursor: widget.alwaysShowCursor,
                        paintSelectionHandles: widget.showToolbar,
                        onEditableRect: _hasInputConnection &&
                                !widget.hardwareKeyboardOnly &&
                                !widget.readOnly
                            ? _onEditableRect
                            : null,
                        composingText: composingText,
                      );
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );

    if (!widget.hideScrollBar) {
      child = Scrollbar(controller: _scrollController, child: child);
    }

    child = TerminalScrollGestureHandler(
      terminal: widget.terminal,
      simulateScroll: widget.simulateScroll,
      getCellOffset: (offset) => renderTerminal.getCellOffset(offset),
      getLineHeight: () => renderTerminal.lineHeight,
      child: child,
    );

    if (!widget.hardwareKeyboardOnly) {
      child = CustomTextEdit(
        key: _customTextEditKey,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        inputType: widget.keyboardType,
        keyboardAppearance: widget.keyboardAppearance,
        deleteDetection: widget.deleteDetection,
        enableSuggestions: widget.enableSuggestions,
        onInsert: _onInsert,
        onDelete: () {
          _scrollToBottom();
          widget.terminal.keyInput(TerminalKey.backspace);
          _updateCursorBlink(resetVisible: true);
        },
        onComposing: _onComposing,
        onAction: (action) {
          _scrollToBottom();
          // Android sends TextInputAction.newline when the user presses the virtual keyboard's enter key.
          if (action == TextInputAction.done ||
              action == TextInputAction.newline) {
            widget.terminal.keyInput(TerminalKey.enter);
            _updateCursorBlink(resetVisible: true);
          }
        },
        onKeyEvent: _handleKeyEvent,
        onInputConnectionChange: _onInputConnectionChange,
        readOnly: widget.readOnly,
        toolbarBuilder: widget.toolbarBuilder,
        hasSelection: () => _controller.selection != null,
        getSelectedText: () => renderTerminal.selectedText ?? '',
        onCopied: widget.onCopied,
        onSelectAll: widget.onSelectAll ?? () => renderTerminal.selectAll(),
        onPaste: widget.onPaste,
        child: child,
      );
    } else if (!widget.readOnly) {
      // Only listen for key input from a hardware keyboard.
      child = CustomKeyboardListener(
        child: child,
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        onInsert: _onInsert,
        onComposing: _onComposing,
        onKeyEvent: _handleKeyEvent,
      );
    }

    child = TerminalActions(
      terminal: widget.terminal,
      controller: _controller,
      child: child,
    );

    child = KeyboardVisibilty(
      onKeyboardShow: _onKeyboardShow,
      child: child,
    );

    child = TerminalGestureHandler(
      viewOffset: widget.viewOffset,
      showToolbar: widget.showToolbar,
      terminalView: this,
      terminalController: _controller,
      onTapUp: _onTapUp,
      onTapDown: _onTapDown,
      onSecondaryTapDown:
          widget.onSecondaryTapDown != null ? _onSecondaryTapDown : null,
      onSecondaryTapUp:
          widget.onSecondaryTapUp != null ? _onSecondaryTapUp : null,
      readOnly: widget.readOnly,
      scrollController: _scrollController,
      child: child,
    );

    child = MouseRegion(cursor: widget.mouseCursor, child: child);

    child = Container(
      color: widget.theme.background.withOpacity(widget.backgroundOpacity),
      padding: widget.padding,
      child: Stack(
        children: [
          child,
          if (_showSearchBox)
            Positioned(
              right: _searchBoxPosition.dx,
              top: _searchBoxPosition.dy,
              child: GestureDetector(
                key: _searchBoxKey,
                onPanStart: _onSearchBoxPanStart,
                onPanUpdate: _onSearchBoxPanUpdate,
                onPanEnd: _onSearchBoxPanEnd,
                child: _searchBox,
              ),
            ),
        ],
      ),
    );

    return child;
  }

  void requestKeyboard() {
    _customTextEditKey.currentState?.requestKeyboard();
  }

  void closeKeyboard() {
    _customTextEditKey.currentState?.closeKeyboard();
  }

  void unFocus() {
    _focusNode.unfocus();
    _customTextEditKey.currentState?.closeKeyboard();
  }

  void showSelectionToolbar(Rect globalSelectionRect) {
    _customTextEditKey.currentState?.showToolbar(
      globalSelectionRect: globalSelectionRect,
    );
  }

  void hideSelectionToolbar() {
    _customTextEditKey.currentState?.hideToolbar();
  }

  bool get isSelectionToolbarShown =>
      _customTextEditKey.currentState?.isToolbarShown ?? false;

  void toggleFocus() {
    _customTextEditKey.currentState?.toggleKeyboard();
    if (_focusNode.hasFocus) {
      _focusNode.unfocus();
    } else {
      _focusNode.requestFocus();
    }
  }

  Rect get cursorRect {
    return renderTerminal.cursorOffset & renderTerminal.cellSize;
  }

  Rect get globalCursorRect {
    return MatrixUtils.transformRect(
      renderTerminal.getTransformTo(null),
      cursorRect,
    );
  }

  bool get _cursorBlinkEnabled {
    return widget.cursorBlink &&
        _focusNode.hasFocus &&
        !widget.alwaysShowCursor;
  }

  void _handleFocusChange() {
    _updateCursorBlink(resetVisible: true);
  }

  void _updateCursorBlink({
    bool resetVisible = false,
    bool scheduleSetState = true,
  }) {
    final shouldBlink = _cursorBlinkEnabled;
    final blinkChanged = shouldBlink != _previousBlinkEnabled;
    _previousBlinkEnabled = shouldBlink;

    _cursorBlinkTimer?.cancel();

    var shouldNotify = blinkChanged;

    if ((resetVisible || !shouldBlink) && !_cursorBlinkVisible.value) {
      _cursorBlinkVisible.value = true;
      shouldNotify = true;
    }

    if (shouldBlink) {
      _cursorBlinkTimer = Timer.periodic(widget.cursorBlinkInterval, (_) {
        if (!mounted) {
          return;
        }
        _cursorBlinkVisible.value = !_cursorBlinkVisible.value;
      });
    }

    if (shouldNotify && scheduleSetState && mounted) {
      setState(() {});
    }
  }

  void _onTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onTapUp?.call(details, offset);
  }

  void _onTapDown(TapDownDetails details) {
    if (_controller.selection == null) {
      if (!widget.hardwareKeyboardOnly) {
        _customTextEditKey.currentState?.requestKeyboard();
      } else {
        _focusNode.requestFocus();
      }
    }

    _updateCursorBlink(resetVisible: true);
  }

  void _onSecondaryTapDown(TapDownDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapDown?.call(details, offset);
  }

  void _onSecondaryTapUp(TapUpDetails details) {
    final offset = renderTerminal.getCellOffset(details.localPosition);
    widget.onSecondaryTapUp?.call(details, offset);
  }

  bool get hasInputConnection {
    return _customTextEditKey.currentState?.hasInputConnection == true;
  }

  void _onInsert(String text) {
    final key = charToTerminalKey(text.trim());

    // On mobile platforms there is no guarantee that virtual keyboard will
    // generate hardware key events. So we need first try to send the key
    // as a hardware key event. If it fails, then we send it as a text input.
    final consumed = key == null ? false : widget.terminal.keyInput(key);

    if (!consumed) {
      widget.terminal.textInput(text);
    }

    _scrollToBottom();
    _updateCursorBlink(resetVisible: true);
  }

  void _onComposing(String? text) {
    _composingText.value = text;
    _updateCursorBlink(resetVisible: true);
  }

  KeyEventResult _handleKeyEvent(FocusNode focusNode, KeyEvent event) {
    final resultOverride = widget.onKeyEvent?.call(focusNode, event);
    if (resultOverride != null && resultOverride != KeyEventResult.ignored) {
      return resultOverride;
    }

    // ignore: invalid_use_of_protected_member
    final shortcutResult = _shortcutManager.handleKeypress(
      focusNode.context!,
      event,
    );

    if (shortcutResult != KeyEventResult.ignored) {
      return shortcutResult;
    }

    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final key = keyToTerminalKey(event.logicalKey);
    if (key == null) {
      return KeyEventResult.ignored;
    }

    final handled = _sendTerminalKey(key);

    if (!handled) {
      return KeyEventResult.ignored;
    }

    return KeyEventResult.handled;
  }

  bool _sendTerminalKey(TerminalKey key) {
    final handled = widget.terminal.keyInput(
      key,
      ctrl: HardwareKeyboard.instance.isControlPressed,
      alt: HardwareKeyboard.instance.isAltPressed,
      shift: HardwareKeyboard.instance.isShiftPressed,
    );

    if (handled) {
      _scrollToBottom();
      _updateCursorBlink(resetVisible: true);
    }

    return handled;
  }

  void _onEditableRect(
    Size editableSize,
    Matrix4 transform,
    Rect caretRect,
  ) {
    _customTextEditKey.currentState?.setEditableRect(
      editableSize,
      transform,
      caretRect,
    );
  }

  void _onInputConnectionChange(bool hasInputConnection) {
    if (_hasInputConnection == hasInputConnection || !mounted) {
      return;
    }

    setState(() {
      _hasInputConnection = hasInputConnection;
    });
  }

  void _onKeyboardShow() {
    if (_focusNode.hasFocus) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    _jumpToBottomIfNeeded();

    if (_scrollToBottomScheduled || !mounted) {
      return;
    }

    _scrollToBottomScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottomScheduled = false;
      _jumpToBottomIfNeeded();
    });
  }

  void _jumpToBottomIfNeeded() {
    if (!mounted || !_scrollController.hasClients) {
      return;
    }

    final position = _scrollController.position;
    final target = position.maxScrollExtent;
    if ((position.pixels - target).abs() < 0.5) {
      return;
    }

    position.jumpTo(target);
  }

  void autoScrollDown(Offset localPointerPosition) {
    final scrollThrshold = renderTerminal.lineHeight * 3;
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final notBottom = position.pixels < position.maxScrollExtent;
    final shouldScrollDown =
        localPointerPosition.dy > renderTerminal.size.height - scrollThrshold;
    if (shouldScrollDown && notBottom) {
      final target = (position.pixels + scrollThrshold)
          .clamp(0.0, position.maxScrollExtent)
          .toDouble();
      position.jumpTo(target);
    }
    final notTop = position.pixels > 0;
    final shouldScrollUp = localPointerPosition.dy < scrollThrshold;
    if (shouldScrollUp && notTop) {
      final target = (position.pixels - scrollThrshold)
          .clamp(0.0, position.maxScrollExtent)
          .toDouble();
      position.jumpTo(target);
    }
  }

  void _showSearch() {
    setState(() {
      _showSearchBox = true;
    });
  }

  void _closeSearch() {
    setState(() {
      _showSearchBox = false;
    });
  }

  void _scrollToLine(int line) {
    print('scroll to line: $line');
    final renderTerminal =
        _viewportKey.currentContext?.findRenderObject() as RenderTerminal?;
    if (renderTerminal != null) {
      renderTerminal.scrollToLine(line);
    }
  }

  void _onSearchBoxPanStart(DragStartDetails details) {
    _isDragging = true;
  }

  void _onSearchBoxPanUpdate(DragUpdateDetails details) {
    if (_isDragging) {
      setState(() {
        _searchBoxPosition = Offset(_searchBoxPosition.dx - details.delta.dx,
            _searchBoxPosition.dy + details.delta.dy);

        // 获取父容器大小
        final renderBox =
            _searchBoxKey.currentContext?.findRenderObject() as RenderBox?;
        if (renderBox != null) {
          final parent = renderBox.parent as RenderBox?;
          if (parent != null) {
            final parentSize = parent.size;
            final searchBoxSize = renderBox.size;

            // 限制水平范围
            if (_searchBoxPosition.dx < 0) {
              _searchBoxPosition = Offset(0, _searchBoxPosition.dy);
            } else if (_searchBoxPosition.dx + searchBoxSize.width >
                parentSize.width) {
              _searchBoxPosition = Offset(
                  parentSize.width - searchBoxSize.width,
                  _searchBoxPosition.dy);
            }

            // 限制垂直范围
            if (_searchBoxPosition.dy < 0) {
              _searchBoxPosition = Offset(_searchBoxPosition.dx, 0);
            } else if (_searchBoxPosition.dy + searchBoxSize.height >
                parentSize.height) {
              _searchBoxPosition = Offset(_searchBoxPosition.dx,
                  parentSize.height - searchBoxSize.height);
            }
          }
        }
      });
    }
  }

  void _onSearchBoxPanEnd(DragEndDetails details) {
    _isDragging = false;
  }
}

class _TerminalView extends LeafRenderObjectWidget {
  const _TerminalView({
    super.key,
    required this.terminal,
    required this.controller,
    required this.offset,
    required this.padding,
    required this.autoResize,
    required this.textStyle,
    required this.textScaler,
    required this.theme,
    required this.focusNode,
    required this.cursorType,
    required this.cursorBlinkEnabled,
    required this.cursorBlinkVisible,
    required this.alwaysShowCursor,
    required this.paintSelectionHandles,
    this.onEditableRect,
    this.composingText,
  });

  final Terminal terminal;

  final TerminalController controller;

  final ViewportOffset offset;

  final EdgeInsets padding;

  final bool autoResize;

  final TerminalStyle textStyle;

  final TextScaler textScaler;

  final TerminalTheme theme;

  final FocusNode focusNode;

  final TerminalCursorType cursorType;

  final bool cursorBlinkEnabled;

  final bool cursorBlinkVisible;

  final bool alwaysShowCursor;

  final bool paintSelectionHandles;

  final EditableRectCallback? onEditableRect;

  final String? composingText;

  @override
  RenderTerminal createRenderObject(BuildContext context) {
    return RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: offset,
      padding: padding,
      autoResize: autoResize,
      textStyle: textStyle,
      textScaler: textScaler,
      theme: theme,
      focusNode: focusNode,
      cursorType: cursorType,
      cursorBlinkEnabled: cursorBlinkEnabled,
      cursorBlinkVisible: cursorBlinkVisible,
      alwaysShowCursor: alwaysShowCursor,
      paintSelectionHandles: paintSelectionHandles,
      onEditableRect: onEditableRect,
      composingText: composingText,
    );
  }

  @override
  void updateRenderObject(BuildContext context, RenderTerminal renderObject) {
    renderObject
      ..terminal = terminal
      ..controller = controller
      ..offset = offset
      ..padding = padding
      ..autoResize = autoResize
      ..textStyle = textStyle
      ..textScaler = textScaler
      ..theme = theme
      ..focusNode = focusNode
      ..cursorType = cursorType
      ..cursorBlinkEnabled = cursorBlinkEnabled
      ..cursorBlinkVisible = cursorBlinkVisible
      ..alwaysShowCursor = alwaysShowCursor
      ..paintSelectionHandles = paintSelectionHandles
      ..onEditableRect = onEditableRect
      ..composingText = composingText;
  }
}

class _TerminalScrollBehavior extends ScrollBehavior {
  const _TerminalScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}
