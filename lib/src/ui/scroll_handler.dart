import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/core.dart';
import 'package:xterm/src/ui/infinite_scroll_view.dart';

const int _kMaxAltBufferScrollEventsPerFrame = 20;

/// Handles scrolling gestures in the alternate screen buffer. In alternate
/// screen buffer, the terminal don't have a scrollback buffer, instead, the
/// scroll gestures are converted to escape sequences based on the current
/// report mode declared by the application.
class TerminalScrollGestureHandler extends StatefulWidget {
  const TerminalScrollGestureHandler({
    super.key,
    required this.terminal,
    required this.getCellOffset,
    required this.getLineHeight,
    this.simulateScroll = true,
    this.invertWheelScroll = false,
    this.wheelScrollLinesPerEvent = 1,
    required this.child,
  });

  final Terminal terminal;

  /// Returns the cell offset for the pixel offset.
  final CellOffset Function(Offset) getCellOffset;

  /// Returns the pixel height of lines in the terminal.
  final double Function() getLineHeight;

  /// Whether to simulate scroll events in the terminal when the application
  /// doesn't declare it supports mouse wheel events. true by default as it
  /// is the default behavior of most terminals.
  final bool simulateScroll;

  final bool invertWheelScroll;

  final double wheelScrollLinesPerEvent;

  final Widget child;

  @override
  State<TerminalScrollGestureHandler> createState() =>
      _TerminalScrollGestureHandlerState();
}

class _TerminalScrollGestureHandlerState
    extends State<TerminalScrollGestureHandler> {
  /// Whether the application is in alternate screen buffer. If false, then this
  /// widget does nothing.
  var isAltBuffer = false;

  /// This variable tracks the last offset where the scroll gesture started.
  /// Used to calculate the cell offset of the terminal mouse event.
  var lastPointerPosition = Offset.zero;

  /// The variable that tracks the line offset in last drag scroll event. Used
  /// to determine how many the scroll events should be sent to the terminal.
  var lastDragLineOffset = 0;

  double _accumulatedVerticalDelta = 0;

  @override
  void initState() {
    widget.terminal.addListener(_onTerminalUpdated);
    isAltBuffer = widget.terminal.isUsingAltBuffer;
    super.initState();
  }

  @override
  void dispose() {
    widget.terminal.removeListener(_onTerminalUpdated);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerminalScrollGestureHandler oldWidget) {
    if (oldWidget.terminal != widget.terminal) {
      oldWidget.terminal.removeListener(_onTerminalUpdated);
      widget.terminal.addListener(_onTerminalUpdated);
      isAltBuffer = widget.terminal.isUsingAltBuffer;
    }
    super.didUpdateWidget(oldWidget);
  }

  void _onTerminalUpdated() {
    if (isAltBuffer != widget.terminal.isUsingAltBuffer) {
      isAltBuffer = widget.terminal.isUsingAltBuffer;
      _accumulatedVerticalDelta = 0;
      setState(() {});
    }
  }

  /// Send a single scroll event to the terminal. If [simulateScroll] is true,
  /// then if the application doesn't recognize mouse wheel events, this method
  /// will simulate scroll events by sending up/down arrow keys.
  void _sendScrollEvent(bool up) {
    final position = widget.getCellOffset(lastPointerPosition);

    final handled = widget.terminal.mouseInput(
      up ? TerminalMouseButton.wheelUp : TerminalMouseButton.wheelDown,
      TerminalMouseButtonState.down,
      position,
    );

    if (!handled &&
        (widget.simulateScroll || widget.terminal.altBufferMouseScrollMode)) {
      widget.terminal.keyInput(
        up ? TerminalKey.arrowUp : TerminalKey.arrowDown,
      );
    }
  }

  void _handlePointerScroll(PointerScrollEvent event) {
    lastPointerPosition = event.localPosition;
    final verticalDelta =
        widget.invertWheelScroll ? -event.scrollDelta.dy : event.scrollDelta.dy;
    _accumulatedVerticalDelta += verticalDelta;

    final lineHeight = widget.getLineHeight();
    if (lineHeight <= 0) return;

    final speed = widget.wheelScrollLinesPerEvent <= 0
        ? 1.0
        : widget.wheelScrollLinesPerEvent;
    final lines = (_accumulatedVerticalDelta / lineHeight * speed).truncate();
    if (lines == 0) return;

    final iterations = lines.abs() > _kMaxAltBufferScrollEventsPerFrame
        ? _kMaxAltBufferScrollEventsPerFrame
        : lines.abs();
    for (var i = 0; i < iterations; i++) {
      _sendScrollEvent(lines < 0);
    }

    _accumulatedVerticalDelta -= lines * lineHeight / speed;
  }

  void _handleResolvedPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      _handlePointerScroll(event);
    }
  }

  void _handleDragScroll(double offset) {
    final lineHeight = widget.getLineHeight();
    if (lineHeight <= 0) return;

    final currentLineOffset = offset ~/ lineHeight;
    final delta = currentLineOffset - lastDragLineOffset;

    final iterations = delta.abs() > _kMaxAltBufferScrollEventsPerFrame
        ? _kMaxAltBufferScrollEventsPerFrame
        : delta.abs();
    for (var i = 0; i < iterations; i++) {
      _sendScrollEvent(delta < 0);
    }

    lastDragLineOffset = currentLineOffset;
  }

  @override
  Widget build(BuildContext context) {
    if (!isAltBuffer) {
      return widget.child;
    }

    return Listener(
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          GestureBinding.instance.pointerSignalResolver.register(
            event,
            _handleResolvedPointerSignal,
          );
        }
      },
      onPointerDown: (event) {
        lastPointerPosition = event.localPosition;
        _accumulatedVerticalDelta = 0;
        lastDragLineOffset = 0;
      },
      child: InfiniteScrollView(
        onScroll: _handleDragScroll,
        child: widget.child,
      ),
    );
  }
}
