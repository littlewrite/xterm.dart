import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

enum _DragHandleType { none, start, end }

enum _MagnifierSource { longPress, dragHandle }

// Tuned for responsive edge-selection scrolling without flooding the app.
const Duration _kSelectionAutoScrollInterval = Duration(milliseconds: 70);

class TerminalGestureHandler extends StatefulWidget {
  const TerminalGestureHandler({
    super.key,
    required this.terminalView,
    required this.terminalController,
    this.child,
    this.onTapUp,
    this.onTapDown,
    this.onSecondaryTapDown,
    this.onSecondaryTapUp,
    this.onTertiaryTapDown,
    this.onTertiaryTapUp,
    this.linkAtPosition,
    this.onLinkTap,
    this.readOnly = false,
    this.viewOffset = Offset.zero,
    this.showToolbar = true,
    this.showMagnifier = true,
    this.cursorColor = Colors.cyan,
    this.scrollController,
  });

  final TerminalViewState terminalView;
  final TerminalController terminalController;
  final Widget? child;
  final GestureTapUpCallback? onTapUp;
  final GestureTapDownCallback? onTapDown;
  final GestureTapDownCallback? onSecondaryTapDown;
  final GestureTapUpCallback? onSecondaryTapUp;
  final GestureTapDownCallback? onTertiaryTapDown;
  final GestureTapUpCallback? onTertiaryTapUp;

  /// Hyperlink that should capture a tap at [localPosition], or null.
  final TerminalHyperlink? Function(Offset localPosition)? linkAtPosition;

  /// Invoked instead of [onTapUp] when a tap activates a hyperlink.
  final void Function(TerminalHyperlink link)? onLinkTap;

  final bool readOnly;
  final Offset viewOffset;
  final bool showToolbar;
  final bool showMagnifier;
  final Color cursorColor;
  final ScrollController? scrollController;

  @override
  State<TerminalGestureHandler> createState() => _TerminalGestureHandlerState();
}

class _TerminalGestureHandlerState extends State<TerminalGestureHandler> {
  TerminalViewState get terminalView => widget.terminalView;
  RenderTerminal get renderTerminal => terminalView.renderTerminal;

  BufferRangeLine? _selectedRange;
  late double _originTextSize = terminalView.widget.textStyle.fontSize;

  // 拖杆相关状态
  _DragHandleType _activeDragHandle = _DragHandleType.none;
  CellOffset? _dragHandleFixedPoint; // 拖动时不变的选区端点
  bool _isDragHandleReady = false; // 拖杆是否准备就绪（点击检测到拖杆）

  // 优化的容忍度设置
  static const double _selectionTolerance = 20.0; // 点击选区附近的容忍度
  static const Duration _tapTolerance = Duration(milliseconds: 150); // 点击时间容忍度

  // Flutter's 22/26 is tuned for a one-line TextField, too close for terminal rows.
  static const double _magnifierRowClearance = 48.0;

  static const double _magnifierEdgePadding = 8.0;

  // 防抖相关
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;
  bool _isDraggingHandle = false;

  // 桌面端拖动选区相关状态
  bool _isMouseDeviceDown = false;
  bool _isMouseSelectionInProgress = false;
  CellOffset? _mouseSelectionBase;
  CellAnchor? _mouseSelectionBaseAnchor;
  PointerDeviceKind? _mousePointerKind;
  TerminalMouseButton _mouseButton = TerminalMouseButton.left;
  bool _suppressNextTapUp = false;
  bool _mouseDragWasHandledByTerminal = false;
  bool _mouseDownWasHandledByTerminal = false;
  bool _mousePressReported = false;
  TerminalHyperlink? _claimedLink;
  Offset? _linkPointerDownPosition;
  bool _linkSuppressedPtyDown = false;
  /// [_handleTapCancel] 把按下补发给了程序：松手时要补上对应的抬起。
  bool _linkPressHandedBackToPty = false;
  Timer? _autoScrollTimer;
  Offset? _pendingAutoScrollPosition;

  // 双指缩放追踪
  final Map<int, Offset> _trackedPointers = {};
  double? _zoomInitialDistance;

  static final TextSelectionControls _materialSelectionControls =
      MaterialTextSelectionControls();
  static final TextSelectionControls _cupertinoSelectionControls =
      CupertinoTextSelectionControls();

  TextSelectionControls get _selectionControls {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return _cupertinoSelectionControls;
      default:
        return _materialSelectionControls;
    }
  }

  ScrollController? _attachedScrollController;

  Terminal? _attachedTerminal;
  bool _scrollUpdateScheduled = false;
  ValueListenable<bool>? _scrollActivityNotifier;
  bool _selectionHandlesVisible = false;

  Offset? _magnifierFocalPoint;

  // Don't reuse _isMouseDeviceDown: _clearSelection resets it on long-press start,
  // which would misclassify a mouse long press as touch.
  PointerDeviceKind? _activePointerKind;

  BufferRangeLine? _longPressAnchorRange;

  CellOffset? _longPressMoveCell;

  _MagnifierSource? _magnifierSource;

  bool get _shouldShowHandles =>
      widget.showToolbar &&
      _selectionHandlesVisible &&
      _selectedRange != null &&
      !_selectedRange!.isCollapsed;

  @visibleForTesting
  bool get debugShowsSelectionHandles => _shouldShowHandles;

  bool get _isTouchInteraction =>
      _activePointerKind == PointerDeviceKind.touch;

  bool get _isViewportScrolling => _scrollActivityNotifier?.value ?? false;

  @override
  void initState() {
    super.initState();
    widget.terminalController.addListener(_handleControllerSelectionChanged);
    _attachTerminal(widget.terminalView.terminal);
    _syncSelectionFromController();
    _attachScrollController(widget.scrollController);
  }

  @override
  Widget build(BuildContext context) {
    Widget content = widget.child ?? const SizedBox.shrink();

    final List<Widget> handles = _buildSelectionHandles();
    final Widget? magnifier = _buildMagnifier();
    if (handles.isNotEmpty || magnifier != null) {
      content = Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          content,
          ...handles,
          // Must stay after the handles: a BackdropFilter can only magnify what
          // was already painted, so the highlight and handles get magnified too.
          if (magnifier != null) magnifier,
        ],
      );
    }

    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        child: content,
        onTapUp: onTapUp,
        onTapDown: onTapDown,
        onTapCancel: _handleTapCancel,
        onSecondaryTapDown: onSecondaryTapDown,
        onSecondaryTapUp: onSecondaryTapUp,
        onTertiaryTapDown: widget.onTertiaryTapDown,
        onTertiaryTapUp: widget.onTertiaryTapUp,
        onDoubleTapDown: onDoubleTapDown,
        onLongPressStart: _onLongPressStart,
        onLongPressMoveUpdate: _onLongPressMoveUpdate,
        onLongPressEnd: _onLongPressEnd,
        onLongPressCancel: () {
          _hideMagnifier(_MagnifierSource.longPress);
          _stopSelectionAutoScroll();
          // This gesture never reaches _onLongPressEnd, so clear the anchor
          // here too; otherwise the next long press extends from it.
          _longPressAnchorRange = null;
          _longPressMoveCell = null;
        },
      ),
    );
  }

  @override
  void didUpdateWidget(TerminalGestureHandler oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.terminalController != widget.terminalController) {
      oldWidget.terminalController.removeListener(
        _handleControllerSelectionChanged,
      );
      widget.terminalController.addListener(_handleControllerSelectionChanged);
      _syncSelectionFromController();
    }
    // The terminal outlives widget updates: TerminalView supports swapping it
    // while keeping the same state, so re-check on every update. _attachTerminal
    // is a no-op when the instance is unchanged.
    _attachTerminal(widget.terminalView.terminal);
    if (oldWidget.scrollController != widget.scrollController) {
      _detachScrollController(oldWidget.scrollController);
      _attachScrollController(widget.scrollController);
    }
  }

  @override
  void dispose() {
    widget.terminalController.removeListener(_handleControllerSelectionChanged);
    _attachedTerminal?.removeListener(_handleTerminalChanged);
    _detachScrollController(_attachedScrollController);
    _trackedPointers.clear();
    _resetMouseSelectionState();
    super.dispose();
  }

  bool get _shouldSendTapEvent =>
      !widget.readOnly &&
      widget.terminalController.shouldSendPointerInput(PointerInput.tap);

  // ---- Listener 回调 ----

  void _onPointerDown(PointerDownEvent event) {
    _trackedPointers[event.pointer] = event.localPosition;
    _activePointerKind = event.kind;

    if (_isPointerKindMouse(event.kind)) {
      _isMouseDeviceDown = true;
      _mousePointerKind = event.kind;
      _mouseButton = _mouseButtonFor(event.buttons);
      _mouseDragWasHandledByTerminal = false;
      _mouseDownWasHandledByTerminal = false;
      _mousePressReported = false;
      _mouseSelectionBase = renderTerminal.getCellOffset(
        event.localPosition,
      );
      _mouseSelectionBaseAnchor =
          renderTerminal.createSelectionAnchor(_mouseSelectionBase!);
      _isMouseSelectionInProgress = false;
      _resetDragHandleState();
      _maybeReportMousePress(event.localPosition);
    } else {
      // 触摸设备：检查是否点击了拖杆
      if (_shouldShowHandles) {
        final dragHandle = _detectDragHandle(event.localPosition);
        if (dragHandle != _DragHandleType.none) {
          _prepareDragHandle(dragHandle);
        }
      }
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    // 更新追踪的指针位置
    _trackedPointers[event.pointer] = event.localPosition;

    // 1. 拖杆拖动
    if (_isDragHandleReady || _isDraggingHandle) {
      if (!_isDraggingHandle) {
        // 从准备状态进入拖动状态
        _isDraggingHandle = true;
        if (widget.showToolbar) {
          widget.terminalView.hideSelectionToolbar();
        }
        HapticFeedback.selectionClick();
        _showMagnifier(event.localPosition, _MagnifierSource.dragHandle);
      }
      _handleDragUpdate(event.localPosition);
      return;
    }

    // 2. 鼠标拖动选区（无延迟！）
    if (_isPointerKindMouse(event.kind) && _isMouseDeviceDown) {
      if (widget.terminalController.shouldSendPointerInput(PointerInput.drag) &&
          !_shouldForceLocalMouseSelection) {
        final handled = renderTerminal.mouseEvent(
          _mouseButton,
          TerminalMouseButtonState.down,
          event.localPosition,
          motion: true,
        );
        if (handled) {
          _mouseDragWasHandledByTerminal = true;
          return;
        }
      }
      _handleMouseSelectionUpdate(event.localPosition);
      return;
    }

    if (_isPointerKindMouse(event.kind) &&
        widget.terminalController.shouldSendPointerInput(PointerInput.move) &&
        !_shouldForceLocalMouseSelection) {
      renderTerminal.mouseEvent(
        _mouseButtonFor(event.buttons),
        TerminalMouseButtonState.up,
        event.localPosition,
        motion: true,
      );
      return;
    }

    // 3. 双指缩放
    if (_trackedPointers.length == 2 &&
        !_isDraggingHandle &&
        !_isDragHandleReady) {
      _handlePinchZoomUpdate();
      return;
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    // 链接手势中途变成拖动、按下已经被补发过一次：抬起必须跟着补，否则程序
    // 里的鼠标键会一直按着（触摸拖拽走的就是这条路，_onPointerUp 的鼠标分支
    // 根本不会执行）。
    if (_linkPressHandedBackToPty) {
      _linkPressHandedBackToPty = false;
      renderTerminal.mouseEvent(
        TerminalMouseButton.left,
        TerminalMouseButtonState.up,
        event.localPosition,
      );
      _suppressNextTapUp = true;
      _resetMouseSelectionState();
      _trackedPointers.remove(event.pointer);
      if (_trackedPointers.length < 2) {
        _zoomInitialDistance = null;
      }
      return;
    }

    if (_isPointerKindMouse(event.kind)) {
      if (_mouseDragWasHandledByTerminal) {
        renderTerminal.mouseEvent(
          _mouseButton,
          TerminalMouseButtonState.up,
          event.localPosition,
        );
        _suppressNextTapUp = true;
        _resetMouseSelectionState();
        _trackedPointers.remove(event.pointer);
        if (_trackedPointers.length < 2) {
          _zoomInitialDistance = null;
        }
        return;
      }

      if (_isMouseSelectionInProgress) {
        if (_mouseDownSentToPty) {
          renderTerminal.mouseEvent(
            _mouseButton,
            TerminalMouseButtonState.up,
            event.localPosition,
          );
        }
        _finishMouseSelection();
      } else {
        _resetMouseSelectionState();
      }
    } else if (_isDraggingHandle || _isDragHandleReady) {
      _finishHandleDrag();
    }

    _trackedPointers.remove(event.pointer);
    if (_trackedPointers.length < 2) {
      _zoomInitialDistance = null;
    }
    if (_trackedPointers.isEmpty) {
      // The auto-scroll timer has no event to stop it; left running it keeps
      // writing wheel events to the PTY.
      _stopSelectionAutoScroll();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _trackedPointers.remove(event.pointer);
    _zoomInitialDistance = null;
    // Another finger is still down, so this cancel isn't from the dragging one.
    if (_trackedPointers.isNotEmpty) {
      return;
    }
    _hideMagnifier();
    // The gesture is over but no pointer-up will follow. If the PTY was told
    // the button went down (link hand-back, early mouse press, or a forwarded
    // drag), hand it the release now so the button does not stay pressed.
    if (_linkPressHandedBackToPty) {
      _linkPressHandedBackToPty = false;
      renderTerminal.mouseEvent(
        TerminalMouseButton.left,
        TerminalMouseButtonState.up,
        event.localPosition,
      );
    } else if (_mouseDownSentToPty) {
      renderTerminal.mouseEvent(
        _mouseButton,
        TerminalMouseButtonState.up,
        event.localPosition,
      );
    }
    _resetInteractionState();
  }

  // ---- 双指缩放 ----

  void _handlePinchZoomUpdate() {
    if (_trackedPointers.length != 2) return;

    final positions = _trackedPointers.values.toList();
    final currentDistance = (positions[0] - positions[1]).distance;

    if (_zoomInitialDistance == null) {
      _zoomInitialDistance = currentDistance;
      _originTextSize = terminalView.textSizeNoti.value;
      return;
    }

    if (_zoomInitialDistance! <= 0) return;

    final scale = currentDistance / _zoomInitialDistance!;
    final clampedScale = math.pow(scale, 0.3);
    final fontSize = _originTextSize * clampedScale;

    // 限制字体大小范围
    if (fontSize >= 7 && fontSize <= 17) {
      terminalView.textSizeNoti.value = fontSize;
    }
  }

  // ---- 原有方法 ----

  void _handleControllerSelectionChanged() {
    if (!mounted) {
      return;
    }
    _syncSelectionFromController();
  }

  /// Keeps the drag handles anchored while the buffer mutates underneath them.
  ///
  /// Handle positions come from [_selectedRange], a snapshot of cell offsets
  /// taken when the selection was committed, whereas the painted highlight is
  /// recomputed from the live [CellAnchor]s on every paint. Buffer mutations
  /// (scrolling output, scrollback trim, `clear`) move the anchors without
  /// going through [TerminalController.setSelection], so without this the
  /// handles would stay behind while the highlight moves away.
  ///
  /// [Terminal] already batches its notifications to at most one per frame, so
  /// this stays off the per-write path.
  void _handleTerminalChanged() {
    if (!mounted || _selectedRange == null) {
      return;
    }
    _syncSelectionFromController(repositionToolbar: false);
  }

  void _attachTerminal(Terminal terminal) {
    if (identical(terminal, _attachedTerminal)) {
      return;
    }
    _attachedTerminal?.removeListener(_handleTerminalChanged);
    terminal.addListener(_handleTerminalChanged);
    _attachedTerminal = terminal;
  }

  void _syncSelectionFromController({bool repositionToolbar = true}) {
    final selection = widget.terminalController.selection;

    BufferRangeLine? nextRange;
    if (selection == null) {
      nextRange = null;
    } else {
      nextRange = _controllerRangeAsLine(selection);
    }

    final previousRange = _selectedRange;
    final bool changed = previousRange != nextRange;

    if (changed) {
      setState(() {
        _selectedRange = nextRange;
        if (nextRange == null || nextRange.isCollapsed) {
          _selectionHandlesVisible = false;
        }
      });
    } else {
      if (nextRange == null || nextRange.isCollapsed) {
        _selectionHandlesVisible = false;
      }
    }

    if (nextRange == null || nextRange.isCollapsed) {
      // The range the handles were anchored to is gone (controller cleared,
      // switched to an unsupported range, or a different controller was
      // swapped in). Drop the drag state so _handleDragUpdate cannot read a
      // stale _selectedRange.
      _resetDragHandleState();
    }

    if (!widget.showToolbar ||
        !widget.terminalView.isSelectionToolbarShown ||
        nextRange == null ||
        nextRange.isCollapsed) {
      if (widget.showToolbar &&
          widget.terminalView.isSelectionToolbarShown &&
          (nextRange == null || nextRange.isCollapsed)) {
        widget.terminalView.hideSelectionToolbar();
      }
      return;
    }

    if (_isViewportScrolling) {
      return;
    }

    if (!repositionToolbar) {
      return;
    }

    final Rect? rect = _selectionRectForRange(nextRange);
    if (rect != null) {
      widget.terminalView.showSelectionToolbar(rect);
    }
  }

  List<Widget> _buildSelectionHandles() {
    if (!_shouldShowHandles) {
      return const <Widget>[];
    }

    final BufferRangeLine range = _selectedRange!.normalized;
    final _SelectionGeometry? geometry = _selectionGeometry(range);
    if (geometry == null) {
      return const <Widget>[];
    }

    final TextDirection textDirection = Directionality.of(context);
    final TextSelectionHandleType startHandleType = _startHandleTypeFor(
      textDirection,
    );
    final TextSelectionHandleType endHandleType = _endHandleTypeFor(
      textDirection,
    );

    return <Widget>[
      _buildHandleWidget(
        geometry.startAnchor,
        startHandleType,
        _DragHandleType.start,
      ),
      _buildHandleWidget(
        geometry.endAnchor,
        endHandleType,
        _DragHandleType.end,
      ),
    ];
  }

  TextSelectionHandleType _startHandleTypeFor(TextDirection textDirection) {
    return textDirection == TextDirection.ltr
        ? TextSelectionHandleType.left
        : TextSelectionHandleType.right;
  }

  TextSelectionHandleType _endHandleTypeFor(TextDirection textDirection) {
    return textDirection == TextDirection.ltr
        ? TextSelectionHandleType.right
        : TextSelectionHandleType.left;
  }

  Widget _buildHandleWidget(
    Offset anchor,
    TextSelectionHandleType visualType,
    _DragHandleType dragType,
  ) {
    final Offset handleAnchor = _selectionControls.getHandleAnchor(
      visualType,
      renderTerminal.cellSize.height,
    );
    final Offset position = anchor - handleAnchor;

    return Positioned(
      left: position.dx,
      top: position.dy,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (PointerDownEvent event) {
          _prepareDragHandle(dragType);
        },
        onPointerUp: (PointerUpEvent event) => _finishHandleDrag(),
        onPointerCancel: (PointerCancelEvent event) => _finishHandleDrag(),
        child: _selectionControls.buildHandle(
          context,
          visualType,
          renderTerminal.cellSize.height,
          widget.showToolbar
              ? () {
                  final Rect? rect = _currentSelectionGlobalRect();
                  if (rect != null) {
                    widget.terminalView.showSelectionToolbar(rect);
                  }
                }
              : null,
        ),
      ),
    );
  }

  // ---- Selection magnifier ----

  bool get _magnifierEnabled =>
      widget.showMagnifier && _isTouchInteraction;

  void _showMagnifier(Offset localPosition, _MagnifierSource source) {
    if (!_magnifierEnabled) {
      return;
    }
    setState(() {
      _magnifierFocalPoint = localPosition;
      _magnifierSource = source;
    });
  }

  void _updateMagnifier(Offset localPosition) {
    if (_magnifierFocalPoint == null || _magnifierFocalPoint == localPosition) {
      return;
    }
    setState(() => _magnifierFocalPoint = localPosition);
  }

  void _hideMagnifier([_MagnifierSource? source]) {
    if (_magnifierFocalPoint == null ||
        (source != null && _magnifierSource != source)) {
      return;
    }
    setState(() {
      _magnifierFocalPoint = null;
      _magnifierSource = null;
    });
  }

  Widget? _buildMagnifier() {
    final focalPoint = _magnifierFocalPoint;
    if (focalPoint == null) {
      return null;
    }
    if (!widget.showMagnifier) {
      return null;
    }

    final viewport = renderTerminal.hasSize ? renderTerminal.size : Size.zero;
    if (viewport.isEmpty) {
      return null;
    }

    final cellOffset = renderTerminal.getCellOffset(focalPoint);
    final rowCenterY =
        renderTerminal.getOffset(CellOffset(0, cellOffset.y)).dy +
            renderTerminal.cellSize.height / 2;

    // Material lens on every platform: CupertinoMagnifier never magnifies (no
    // magnificationScale, stays 1.0x; flutter/flutter#155275).
    // ignore: invalid_use_of_visible_for_testing_member
    const size = Magnifier.kDefaultMagnifierSize;
    // ignore: invalid_use_of_visible_for_testing_member
    const focalBiasBase = Magnifier.kStandardVerticalFocalPointShift;

    if (viewport.width < size.width + _magnifierEdgePadding * 2 ||
        viewport.height < size.height + _magnifierEdgePadding * 2) {
      return null;
    }

    var top = rowCenterY - _magnifierRowClearance - size.height;
    if (top < _magnifierEdgePadding) {
      top = rowCenterY + _magnifierRowClearance;
    }
    top = clampDouble(
      top,
      _magnifierEdgePadding,
      viewport.height - size.height - _magnifierEdgePadding,
    );

    final left = clampDouble(
      focalPoint.dx - size.width / 2,
      _magnifierEdgePadding,
      viewport.width - size.width - _magnifierEdgePadding,
    );

    final center = Offset(left + size.width / 2, top + size.height / 2);

    // Magnifier adds its own "lift above the focal point" bias; cancel it or the
    // focal point drifts.
    final focalBias = Offset(0, focalBiasBase + size.height / 2);
    final focalPointOffset =
        Offset(focalPoint.dx - center.dx, rowCenterY - center.dy) - focalBias;

    return Positioned(
      left: left,
      top: top,
      // _RenderMagnification is not a repaint boundary, so without this every
      // pointer move repaints the handles and the Stack they sit in too.
      child: RepaintBoundary(
        child: IgnorePointer(
          child: Magnifier(
            shadows: _magnifierShadows(),
            additionalFocalPointOffset: focalPointOffset,
          ),
        ),
      ),
    );
  }

  /// Halo is the inverted terminal background (light on dark, dark on light);
  /// the built-in shadow is too faint to separate the lens.
  List<BoxShadow> _magnifierShadows() {
    final Color backdrop = terminalView.widget.theme.background;
    final Color halo = Color.fromARGB(
      255,
      255 - backdrop.red,
      255 - backdrop.green,
      255 - backdrop.blue,
    );
    return <BoxShadow>[
      BoxShadow(
        color: halo.withOpacity(0.35),
        blurRadius: 14,
        // _DonutClip sizes its clip from spreadRadius; too small clips the blur.
        spreadRadius: 3,
      ),
    ];
  }

  _SelectionGeometry? _selectionGeometry(BufferRangeLine range) {
    final BufferRangeLine normalized = range.normalized;
    final Size cellSize = renderTerminal.cellSize;
    final Offset startTopLeft = renderTerminal.getOffset(normalized.begin);
    final Offset startAnchor = startTopLeft + Offset(0, cellSize.height);

    final Offset endBottomRight =
        renderTerminal.getOffset(_lastSelectedCell(normalized.end)) +
            Offset(cellSize.width, cellSize.height);

    return _SelectionGeometry(
      localRect: Rect.fromPoints(startTopLeft, endBottomRight),
      startAnchor: startAnchor,
      endAnchor: endBottomRight,
    );
  }

  bool _selectionContains(BufferRangeLine range, CellOffset offset) {
    // end is exclusive; BufferRangeLine.contains is inclusive.
    final BufferRangeLine normalized = range.normalized;
    return !offset.isBefore(normalized.begin) && offset.isBefore(normalized.end);
  }

  BufferRangeLine? _controllerRangeAsLine(BufferRange selection) {
    if (selection is BufferRangeLine) {
      return selection.normalized;
    }
    if (selection.isCollapsed) {
      return BufferRangeLine(selection.begin, selection.begin);
    }
    return null;
  }

  /// Controller ranges end exclusive; handles and rects need the last selected
  /// cell. Only call for non-empty ranges.
  CellOffset _lastSelectedCell(CellOffset exclusiveEnd) {
    if (exclusiveEnd.x > 0) {
      return CellOffset(exclusiveEnd.x - 1, exclusiveEnd.y);
    }
    final int lastColumn = terminalView.widget.terminal.viewWidth - 1;
    final int previousRow = math.max(0, exclusiveEnd.y - 1);
    return CellOffset(lastColumn, previousRow);
  }

  /// 检测点击位置是否在拖杆范围内
  _DragHandleType _detectDragHandle(Offset localPosition) {
    final BufferRangeLine? range = _selectedRange;
    if (range == null || range.isCollapsed) {
      return _DragHandleType.none;
    }

    final _SelectionGeometry? geometry = _selectionGeometry(range);
    if (geometry == null) {
      return _DragHandleType.none;
    }

    final TextDirection textDirection = Directionality.of(context);
    final TextSelectionHandleType startHandleType = _startHandleTypeFor(
      textDirection,
    );
    final TextSelectionHandleType endHandleType = _endHandleTypeFor(
      textDirection,
    );
    final double lineHeight = renderTerminal.cellSize.height;
    final Size handleSize = _selectionControls.getHandleSize(lineHeight);

    (_DragHandleType, double)? bestMatch;

    void considerHandle(
      _DragHandleType type,
      Offset anchor,
      TextSelectionHandleType visualType,
    ) {
      final Offset handleAnchor = _selectionControls.getHandleAnchor(
        visualType,
        lineHeight,
      );
      final Rect drawnRect = Rect.fromLTWH(
        anchor.dx - handleAnchor.dx,
        anchor.dy - handleAnchor.dy,
        handleSize.width,
        handleSize.height,
      );
      // Grow the drawn handle to the platform's minimum touch target rather
      // than inflating it by a fixed radius on every side. The drawn handle is
      // small — Material is 22x22, Cupertino 12 x line height — so a fixed 32px
      // inflation left a single handle claiming roughly 76x94px. A tap on blank
      // area inside that blob counted as grabbing a handle, and a grabbed
      // handle deliberately does nothing on tap-up, so the selection could not
      // be dismissed by tapping away from it.
      final Rect hitRect = Rect.fromCenter(
        center: drawnRect.center,
        width: math.max(drawnRect.width, kMinInteractiveDimension),
        height: math.max(drawnRect.height, kMinInteractiveDimension),
      );

      if (!hitRect.contains(localPosition)) {
        return;
      }

      final Offset center = hitRect.center;
      final double dx = localPosition.dx - center.dx;
      final double dy = localPosition.dy - center.dy;
      final double distanceSquared = dx * dx + dy * dy;

      if (bestMatch == null || distanceSquared < bestMatch!.$2) {
        bestMatch = (type, distanceSquared);
      }
    }

    considerHandle(
      _DragHandleType.start,
      geometry.startAnchor,
      startHandleType,
    );
    considerHandle(
      _DragHandleType.end,
      geometry.endAnchor,
      endHandleType,
    );

    return bestMatch?.$1 ?? _DragHandleType.none;
  }

  /// 检查点击位置是否在选区附近（容忍度范围内）
  bool _isNearSelection(Offset localPosition) {
    final BufferRangeLine? range = _selectedRange;
    if (range == null || range.isCollapsed) {
      return false;
    }

    final cellOffset = renderTerminal.getCellOffset(localPosition);

    if (_selectionContains(range, cellOffset)) {
      return true;
    }

    final _SelectionGeometry? geometry = _selectionGeometry(range);
    if (geometry == null) {
      return false;
    }

    final Rect expandedRect = geometry.localRect.inflate(_selectionTolerance);
    return expandedRect.contains(localPosition);
  }

  /// 防抖检查
  bool _isDuplicateTap(Offset position) {
    final now = DateTime.now();
    if (_lastTapTime != null && _lastTapPosition != null) {
      final timeDiff = now.difference(_lastTapTime!);
      final positionDiff = (position - _lastTapPosition!).distance;

      if (timeDiff < _tapTolerance && positionDiff < 10.0) {
        return true;
      }
    }

    _lastTapTime = now;
    _lastTapPosition = position;
    return false;
  }

  bool _isPointerKindMouse(PointerDeviceKind? kind) {
    return kind == PointerDeviceKind.mouse ||
        kind == PointerDeviceKind.trackpad ||
        kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus;
  }

  bool get _shouldForceLocalMouseSelection {
    return HardwareKeyboard.instance.isShiftPressed;
  }

  /// Whether the PTY was actually told the mouse button went down during this
  /// gesture. The press can be handed over at pointer-down
  /// ([_mousePressReported]), at tap-down ([_mouseDownWasHandledByTerminal]), or
  /// by the first forwarded drag motion ([_mouseDragWasHandledByTerminal]);
  /// whichever fired, the matching release must still be sent exactly once.
  bool get _mouseDownSentToPty =>
      _mousePressReported ||
      _mouseDownWasHandledByTerminal ||
      _mouseDragWasHandledByTerminal;

  TerminalMouseButton _mouseButtonFor(int buttons) {
    if ((buttons & kSecondaryMouseButton) != 0) {
      return TerminalMouseButton.right;
    }
    if ((buttons & kMiddleMouseButton) != 0) {
      return TerminalMouseButton.middle;
    }
    return TerminalMouseButton.left;
  }

  /// A fast drag loses the gesture arena before the tap recognizer fires, so
  /// [_tapDown] never runs and the program would see motion, and a release, for
  /// a button it was never told was down. Hand the press over at pointer-down.
  void _maybeReportMousePress(Offset localPosition) {
    if (!_shouldSendTapEvent ||
        _shouldForceLocalMouseSelection ||
        _isNearSelection(localPosition) ||
        widget.linkAtPosition?.call(localPosition) != null) {
      return;
    }
    _mousePressReported = renderTerminal.mouseEvent(
      _mouseButton,
      TerminalMouseButtonState.down,
      localPosition,
    );
  }

  bool _tapDown(
    GestureTapDownCallback? callback,
    TapDownDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    // For a mouse this already went out from _onPointerDown.
    var handled = _mousePressReported;
    if (!handled &&
        _shouldSendTapEvent &&
        !_shouldForceLocalMouseSelection &&
        !_isNearSelection(details.localPosition)) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.down,
        details.localPosition,
      );
    }
    if (!handled || forceCallback) {
      callback?.call(details);
    }
    return handled;
  }

  void _tapUp(
    GestureTapUpCallback? callback,
    TapUpDetails details,
    TerminalMouseButton button, {
    bool forceCallback = false,
  }) {
    var handled = false;
    if (_shouldSendTapEvent &&
        !_shouldForceLocalMouseSelection &&
        !_isNearSelection(details.localPosition)) {
      handled = renderTerminal.mouseEvent(
        button,
        TerminalMouseButtonState.up,
        details.localPosition,
      );
    }
    if (!handled || forceCallback) {
      callback?.call(details);
    }
  }

  bool _handleMouseSelectionUpdate(Offset localPosition) {
    // 是否转发 drag 给应用，已在 _onPointerMove 里用 mouseEvent(handled) 判断。
    // 走到这里说明当前未消费该拖动（mouse mode off / 不支持 motion），应允许本地选区。
    // 若仍用 shouldSendPointerInput(drag) 短路，PointerInputs.all() 时普通 shell 将无法拖选。
    if (!_isMouseDeviceDown ||
        !_isPointerKindMouse(_mousePointerKind) ||
        _isDraggingHandle ||
        _isDragHandleReady) {
      return false;
    }

    final base = _mouseSelectionBase;
    final baseAnchor = _mouseSelectionBaseAnchor;
    if (base == null || baseAnchor == null || !baseAnchor.attached) {
      return false;
    }

    final current = renderTerminal.getCellOffset(localPosition);

    if (!_isMouseSelectionInProgress) {
      if (current == base) {
        return false;
      }

      _isMouseSelectionInProgress = true;
      _selectionHandlesVisible = false;
        _resetDragHandleState();

      if (widget.showToolbar) {
        widget.terminalView.hideSelectionToolbar();
      }
    }

    if (current == base) {
      _commitSelection(renderTerminal.selectCharacters(base));
      return false;
    }

    _commitSelection(
      renderTerminal.selectCharactersFromAnchor(baseAnchor, current),
      scrollPosition: localPosition,
    );
    return true;
  }

  void _finishMouseSelection() {
    _stopSelectionAutoScroll();
    if (!_isMouseSelectionInProgress) {
      _resetInteractionState();
      return;
    }

    _selectionHandlesVisible = false;
    if (widget.showToolbar && widget.terminalView.isSelectionToolbarShown) {
      widget.terminalView.hideSelectionToolbar();
    }

    _resetInteractionState();
    _suppressNextTapUp = true;
  }

  void _resetMouseSelectionState() {
    _stopSelectionAutoScroll();
    _isMouseDeviceDown = false;
    _isMouseSelectionInProgress = false;
    _mouseDragWasHandledByTerminal = false;
    _mouseDownWasHandledByTerminal = false;
    _mousePressReported = false;
    _mouseSelectionBase = null;
    _mouseSelectionBaseAnchor?.dispose();
    _mouseSelectionBaseAnchor = null;
    _mousePointerKind = null;
  }

  void onTapUp(TapUpDetails details) {
    final claimedLink = _claimedLink;
    if (claimedLink != null) {
      _claimedLink = null;
      _linkPointerDownPosition = null;
      _linkSuppressedPtyDown = false;
      _resetMouseSelectionState();
      widget.onLinkTap?.call(claimedLink);
      return;
    }

    if (_suppressNextTapUp) {
      _suppressNextTapUp = false;
      _resetMouseSelectionState();
      return;
    }

    if (_isMouseSelectionInProgress) {
      _finishMouseSelection();
      return;
    }

    _resetMouseSelectionState();

    // 防抖检查
    if (_isDuplicateTap(details.localPosition)) {
      return;
    }

    // 如果之前检测到拖杆准备状态但没有实际拖动，重置状态
    if (_isDragHandleReady && !_isDraggingHandle) {
      _resetDragHandleState();
    }

    _tapUp(
      widget.onTapUp,
      details,
      TerminalMouseButton.left,
      forceCallback: true,
    );

    if (_selectedRange != null) {
      // 检查是否点击了拖杆
      final dragHandle = _shouldShowHandles
          ? _detectDragHandle(details.localPosition)
          : _DragHandleType.none;
      if (dragHandle != _DragHandleType.none) {
        // 点击了拖杆，不做任何操作，等待可能的拖动
        return;
      }

      // 点击选区内部或外部都清除选择
      _clearSelection();
    }
  }

  void onTapDown(TapDownDetails details) {
    _suppressNextTapUp = false;

    // Hyperlinks win over both PTY mouse reporting and the app's tap handling:
    // the down/up pair is withheld here and only the tap-up opens the link.
    final link = widget.linkAtPosition?.call(details.localPosition);
    if (link != null) {
      _claimedLink = link;
      _linkPointerDownPosition = details.localPosition;
      _linkSuppressedPtyDown = true;
      return;
    }

    if (_isPointerKindMouse(details.kind)) {
      // 鼠标状态已在 _onPointerDown 中设置
      // 如果此时已有选区且在选区外，先清除选区以便重新选择
    } else {
      _resetMouseSelectionState();
    }

    // 优先检查是否点击了拖杆（如果已有选区）— 触摸端在 _onPointerDown 中已检查
    if (_shouldShowHandles) {
      final dragHandle = _detectDragHandle(details.localPosition);
      if (dragHandle != _DragHandleType.none) {
        // 点击了拖杆，准备拖动状态
        _prepareDragHandle(dragHandle);
        // 不执行 tapDown，因为这是拖杆操作
        return;
      }
    }

    // 鼠标设备立即执行，触摸设备由 GestureArena 消歧后自然调用
    if (_isPointerKindMouse(details.kind) || _shouldSendTapEvent) {
      final handled = _tapDown(
        widget.onTapDown,
        details,
        TerminalMouseButton.left,
      );
      if (_isPointerKindMouse(details.kind)) {
        _mouseDownWasHandledByTerminal = handled;
      }
    }
  }

  /// A claimed link gesture turned into a drag: give the pointer-down back to
  /// the program so mouse-tracking TUIs do not see motion without a press.
  void _handleTapCancel() {
    final hadClaim = _claimedLink != null;
    _claimedLink = null;
    final position = _linkPointerDownPosition;
    _linkPointerDownPosition = null;
    final suppressed = _linkSuppressedPtyDown;
    _linkSuppressedPtyDown = false;
    if (!hadClaim || !suppressed || position == null) {
      return;
    }
    if (!_shouldSendTapEvent ||
        _shouldForceLocalMouseSelection ||
        _isNearSelection(position)) {
      return;
    }
    final handled = renderTerminal.mouseEvent(
      TerminalMouseButton.left,
      TerminalMouseButtonState.down,
      position,
    );
    if (handled) {
      // 记账：松手时补上抬起（见 [_onPointerUp]）。
      _linkPressHandedBackToPty = true;
    }
  }

  /// 准备拖杆拖动状态
  void _prepareDragHandle(_DragHandleType dragHandle) {
    if (_selectedRange == null) {
      return;
    }
    final BufferRangeLine range = _selectedRange!.normalized;
    _activeDragHandle = dragHandle;
    _isDragHandleReady = true;
    _dragHandleFixedPoint = dragHandle == _DragHandleType.start
        ? _lastSelectedCell(range.end)
        : range.begin;

    // 提供轻微的触觉反馈表示检测到拖杆
    HapticFeedback.lightImpact();
  }

  void _finishHandleDrag() {
    _hideMagnifier(_MagnifierSource.dragHandle);
    _stopSelectionAutoScroll();

    if (_activeDragHandle == _DragHandleType.none) {
      return;
    }
    if (widget.showToolbar) {
      final Rect? rect = _currentSelectionGlobalRect();
      if (rect != null) {
        _selectionHandlesVisible = true;
        widget.terminalView.showSelectionToolbar(rect);
      }
    }
    _resetDragHandleState();
  }

  void _onViewportChanged() {
    if (!mounted) {
      return;
    }
    if (_selectedRange == null || _selectedRange!.isCollapsed) {
      if (widget.showToolbar && widget.terminalView.isSelectionToolbarShown) {
        widget.terminalView.hideSelectionToolbar();
      }
      return;
    }

    setState(() {});

    if (widget.showToolbar &&
        widget.terminalView.isSelectionToolbarShown &&
        !_isViewportScrolling) {
      final Rect? rect = _currentSelectionGlobalRect();
      if (rect != null) {
        widget.terminalView.showSelectionToolbar(rect);
      }
    }
  }

  void _handleScrollChange() {
    if (_scrollUpdateScheduled || !mounted) {
      return;
    }
    if (_scrollActivityNotifier == null) {
      _ensureScrollActivityBinding();
    }
    _scrollUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _scrollUpdateScheduled = false;
        return;
      }
      _scrollUpdateScheduled = false;
      _onViewportChanged();
    });
  }

  void _attachScrollController(ScrollController? controller) {
    if (controller == null || controller == _attachedScrollController) {
      return;
    }
    controller.addListener(_handleScrollChange);
    _attachedScrollController = controller;
    _ensureScrollActivityBinding();
  }

  void _detachScrollController(ScrollController? controller) {
    if (controller == null) {
      return;
    }
    controller.removeListener(_handleScrollChange);
    if (_attachedScrollController == controller) {
      _scrollActivityNotifier?.removeListener(_handleScrollActivityChanged);
      _scrollActivityNotifier = null;
      _attachedScrollController = null;
    }
  }

  void _ensureScrollActivityBinding() {
    final controller = _attachedScrollController;
    if (controller == null) {
      return;
    }
    if (!controller.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _attachedScrollController != controller) {
          return;
        }
        _ensureScrollActivityBinding();
      });
      return;
    }

    final ValueListenable<bool> notifier =
        controller.position.isScrollingNotifier;
    if (identical(_scrollActivityNotifier, notifier)) {
      return;
    }
    _scrollActivityNotifier?.removeListener(_handleScrollActivityChanged);
    _scrollActivityNotifier = notifier;
    _scrollActivityNotifier!.addListener(_handleScrollActivityChanged);
    _handleScrollActivityChanged();
  }

  void _handleScrollActivityChanged() {
    if (!mounted) {
      return;
    }
    if (_isViewportScrolling) {
      if (widget.showToolbar && widget.terminalView.isSelectionToolbarShown) {
        widget.terminalView.hideSelectionToolbar();
      }
      return;
    }

    if (!widget.showToolbar ||
        _selectedRange == null ||
        _selectedRange!.isCollapsed ||
        !widget.terminalView.isSelectionToolbarShown) {
      return;
    }

    final Rect? rect = _currentSelectionGlobalRect();
    if (rect != null) {
      widget.terminalView.showSelectionToolbar(rect);
    }
  }

  /// Apply [range] to local state. The selection must already be set on the
  /// controller via [renderTerminal.selectCharacters] or
  /// [renderTerminal.selectBufferRange] before calling this.
  void _commitSelection(BufferRangeLine range, {Offset? scrollPosition}) {
    final BufferRangeLine nextRange = range.normalized;
    if (_selectedRange != nextRange) {
      setState(() {
        _selectedRange = nextRange;
      });
    }
    if (scrollPosition != null) {
      if (terminalView.autoScrollSelection(scrollPosition)) {
        _startSelectionAutoScroll(scrollPosition);
      } else {
        _stopSelectionAutoScroll();
      }
    } else {
      _stopSelectionAutoScroll();
    }
  }

  /// Starts a repeating edge-auto-scroll loop while the pointer remains
  /// near the viewport boundary during selection drag.
  void _startSelectionAutoScroll(Offset localPosition) {
    _pendingAutoScrollPosition = localPosition;
    _autoScrollTimer ??= Timer.periodic(
      _kSelectionAutoScrollInterval,
      (_) {
        final pending = _pendingAutoScrollPosition;
        if (!mounted || pending == null) {
          _stopSelectionAutoScroll();
          return;
        }
        try {
          // Stop once the finger leaves the edge; nothing else stops this timer.
          if (!terminalView.autoScrollSelection(pending)) {
            _stopSelectionAutoScroll();
          }
        } catch (error, stackTrace) {
          FlutterError.reportError(FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'xterm',
            context: ErrorDescription('while auto-scrolling a selection drag'),
          ));
          _stopSelectionAutoScroll();
        }
      },
    );
  }

  void _stopSelectionAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _pendingAutoScrollPosition = null;
  }

  /// 重置拖杆状态
  void _resetDragHandleState() {
    _activeDragHandle = _DragHandleType.none;
    _isDragHandleReady = false;
    _dragHandleFixedPoint = null;
    _isDraggingHandle = false;
  }

  /// 统一重置所有交互状态。
  /// 在开始新的交互前调用，确保状态干净。
  void _resetInteractionState() {
    _resetMouseSelectionState();
    _resetDragHandleState();
    _longPressAnchorRange = null;
    _longPressMoveCell = null;
    _suppressNextTapUp = false;
    _trackedPointers.clear();
    _zoomInitialDistance = null;
  }

  void onSecondaryTapDown(TapDownDetails details) {
    _tapDown(widget.onSecondaryTapDown, details, TerminalMouseButton.right);
  }

  void onSecondaryTapUp(TapUpDetails details) {
    _tapUp(widget.onSecondaryTapUp, details, TerminalMouseButton.right);
  }

  void onTertiaryTapDown(TapDownDetails details) {
    _tapDown(widget.onTertiaryTapDown, details, TerminalMouseButton.middle);
  }

  void onTertiaryTapUp(TapUpDetails details) {
    _tapUp(widget.onTertiaryTapUp, details, TerminalMouseButton.middle);
  }

  void onDoubleTapDown(TapDownDetails details) {
    // 双击时重置拖杆状态
    _resetDragHandleState();

    final cellOffset = renderTerminal.getCellOffset(details.localPosition);
    final usesTouchSelectionUi =
        _isTouchInteraction;

    final wordRange = renderTerminal.selectWord(cellOffset);
    if (wordRange != null) {
      _commitSelection(wordRange);
    } else {
      _commitSelection(renderTerminal.selectCharacters(cellOffset, cellOffset));
    }
    _selectionHandlesVisible = usesTouchSelectionUi;

    if (widget.showToolbar && usesTouchSelectionUi) {
      final Rect? selectionRect = _currentSelectionGlobalRect();
      if (selectionRect != null) {
        widget.terminalView.showSelectionToolbar(selectionRect);
      }
    }

    // 提供触觉反馈
    HapticFeedback.lightImpact();
  }

  void _handleDragUpdate(Offset localPosition) {
    if (_dragHandleFixedPoint == null) return;

    _updateMagnifier(localPosition);

    final currentCellOffset = renderTerminal.getCellOffset(localPosition);

    // 防止拖动到相同位置
    final BufferRangeLine? handleRange = _selectedRange?.normalized;
    if (handleRange == null) {
      // Selection was invalidated mid-drag; _syncSelectionFromController owns
      // the reset, this is just a belt-and-suspenders guard.
      _resetDragHandleState();
      return;
    }
    final CellOffset currentHandleEnd = _activeDragHandle == _DragHandleType.start
        ? handleRange.begin
        : _lastSelectedCell(handleRange.end);
    if (currentCellOffset == currentHandleEnd) {
      return;
    }

    // 计算选区范围（统一处理开始和结束拖杆）
    final isBefore = currentCellOffset.isBefore(_dragHandleFixedPoint!);
    final newStart = isBefore ? currentCellOffset : _dragHandleFixedPoint!;
    final newEnd = isBefore ? _dragHandleFixedPoint! : currentCellOffset;

    // 当拖动起点超过终点时自动交换拖杆类型
    if (_activeDragHandle == _DragHandleType.start &&
        currentCellOffset.isAfter(_dragHandleFixedPoint!)) {
      _activeDragHandle = _DragHandleType.end;
      _dragHandleFixedPoint = newStart;
    } else if (_activeDragHandle == _DragHandleType.end && isBefore) {
      _activeDragHandle = _DragHandleType.start;
      _dragHandleFixedPoint = newEnd;
    }

    _commitSelection(
      renderTerminal.selectCharacters(newStart, newEnd),
      scrollPosition: localPosition,
    );
  }

  void _clearSelection() {
    if (_selectedRange != null) {
      setState(() {
        _selectedRange = null;
        _selectionHandlesVisible = false;
      });
    } else {
      _selectionHandlesVisible = false;
    }
    renderTerminal.clearSelection();
    _resetInteractionState();
    if (widget.showToolbar) {
      widget.terminalView.hideSelectionToolbar();
    }
  }

  void _onLongPressStart(LongPressStartDetails details) {
    // 如果已经在拖杆准备状态，不处理长按
    if (_isDragHandleReady) {
      return;
    }

    // 长按只用于初始化选区，不处理已有选区的调整
    if (_selectedRange != null && !_selectedRange!.isCollapsed) {
      // 如果点击在选区外，清除选区并重新开始
      if (!_isNearSelection(details.localPosition)) {
        _clearSelection();
      } else {
        // 在选区内或附近的长按不做处理
        return;
      }
    }

    // 执行原有的长按逻辑 - 直接选中单词
    _clearSelection();

    _showMagnifier(details.localPosition, _MagnifierSource.longPress);

    final longPressCellOffset = renderTerminal.getCellOffset(
      details.localPosition,
    );

    if (_isTouchInteraction) {
      _beginTouchLongPressSelection(longPressCellOffset);
    } else {
      _beginMouseLongPressSelection(longPressCellOffset);
    }

    // 重置拖杆状态
    _resetDragHandleState();

    // 提供长按反馈
    HapticFeedback.lightImpact();
  }

  void _beginTouchLongPressSelection(CellOffset cellOffset) {
    final anchor = _wordOrCellAt(cellOffset);
    _longPressAnchorRange = anchor;
    _longPressMoveCell = null;
    _commitSelection(anchor);
    _selectionHandlesVisible = true;
  }

  void _beginMouseLongPressSelection(CellOffset cellOffset) {
    _commitSelection(_wordOrCellAt(cellOffset));
    _selectionHandlesVisible = false;
  }

  BufferRangeLine _wordOrCellAt(CellOffset cellOffset) {
    return renderTerminal.selectWord(cellOffset) ??
        renderTerminal.selectCharacters(cellOffset, cellOffset);
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    _updateMagnifier(details.localPosition);

    // 如果在拖杆模式，不处理长按移动
    if (_isDragHandleReady || _isDraggingHandle) {
      return;
    }

    final anchor = _longPressAnchorRange;
    if (anchor == null) {
      return;
    }

    final normalized = anchor.normalized;
    final currentCellOffset = renderTerminal.getCellOffset(
      details.localPosition,
    );

    if (currentCellOffset == _longPressMoveCell) {
      return;
    }
    _longPressMoveCell = currentCellOffset;

    final BufferRangeLine applied;
    // normalized.end is exclusive, so the first cell past the selection is
    // exactly (end). isBefore(end) stays true for every cell inside the
    // selection, so this only fires once the finger leaves it.
    if (!currentCellOffset.isBefore(normalized.end)) {
      // selectCharacters, not (x + 1): wide glyphs fold x+1 back to the start.
      applied = renderTerminal.selectCharacters(
        normalized.begin,
        currentCellOffset,
      );
    } else if (currentCellOffset.isBefore(normalized.begin)) {
      applied = renderTerminal.selectBufferRange(
        BufferRangeLine(currentCellOffset, normalized.end),
      );
    } else {
      applied = renderTerminal.selectBufferRange(normalized);
    }

    _commitSelection(applied, scrollPosition: details.localPosition);
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    _hideMagnifier(_MagnifierSource.longPress);
    _stopSelectionAutoScroll();

    if (_longPressAnchorRange == null) {
      return;
    }
    _longPressAnchorRange = null;
    _selectionHandlesVisible = true;

    if (widget.showToolbar &&
        _selectedRange != null &&
        !_selectedRange!.isCollapsed) {
      final Rect? selectionRect = _currentSelectionGlobalRect();
      if (selectionRect != null) {
        widget.terminalView.showSelectionToolbar(selectionRect);
      }
    }
  }

  Rect? _selectionRectForRange(BufferRangeLine range) {
    final _SelectionGeometry? geometry = _selectionGeometry(range);
    if (geometry == null) {
      return null;
    }
    final Offset globalTopLeft = renderTerminal.localToGlobal(
      geometry.localRect.topLeft,
    );
    final Offset globalBottomRight = renderTerminal.localToGlobal(
      geometry.localRect.bottomRight,
    );
    return Rect.fromPoints(globalTopLeft, globalBottomRight);
  }

  Rect? _currentSelectionGlobalRect() {
    final range = _selectedRange;
    if (range == null || range.isCollapsed) {
      return null;
    }
    return _selectionRectForRange(range);
  }
}

class _SelectionGeometry {
  const _SelectionGeometry({
    required this.localRect,
    required this.startAnchor,
    required this.endAnchor,
  });

  final Rect localRect;
  final Offset startAnchor;
  final Offset endAnchor;
}
