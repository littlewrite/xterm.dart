import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/selection_mode.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/themes.dart';

/// N2 (perf-plan-v2): 选区 O1 — selection 几何变化不打爆 line Picture cache。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cols = 80;
  const rows = 24;
  const cellW = 9.0;
  const cellH = 18.0;
  final viewport = Size(cols * cellW, rows * cellH);

  (RenderTerminal, TerminalController, Terminal) makeFilled() {
    final terminal = Terminal(maxLines: 1000);
    final fill = StringBuffer();
    for (var r = 0; r < rows; r++) {
      fill.writeln('row $r ${'x' * (cols - 10)}');
    }
    terminal.write(fill.toString());

    final controller = TerminalController();
    final focusNode = FocusNode();
    final render = RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: ViewportOffset.fixed(0),
      padding: EdgeInsets.zero,
      autoResize: false,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
      theme: TerminalThemes.defaultTheme,
      focusNode: focusNode,
      cursorType: TerminalCursorType.block,
      cursorBlinkEnabled: false,
      cursorBlinkVisible: true,
      alwaysShowCursor: false,
      paintCursor: false,
    );
    final owner = PipelineOwner();
    render.attach(owner);
    render.layout(BoxConstraints.tight(viewport), parentUsesSize: true);
    owner.flushLayout();

    addTearDown(() {
      render.detach();
      controller.dispose();
      focusNode.dispose();
    });
    return (render, controller, terminal);
  }

  void paintOnce(RenderTerminal render) {
    final layer = ContainerLayer();
    final context = PaintingContext(
      layer,
      Rect.fromLTWH(0, 0, viewport.width, viewport.height),
    );
    render.paint(context, Offset.zero);
  }

  test('selection geometry change reuses line pictures', () {
    final (render, controller, terminal) = makeFilled();

    // Warm line pictures with no selection.
    paintOnce(render);
    render.debugPainter.resetLinePictureBuildCount();

    // Half-screen selection, then grow it — content unchanged.
    controller.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(cols ~/ 2, rows ~/ 2),
      mode: SelectionMode.line,
    );
    paintOnce(render);

    controller.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(cols - 1, rows - 1),
      mode: SelectionMode.line,
    );
    paintOnce(render);

    expect(
      render.debugPainter.linePictureBuildCount,
      0,
      reason: 'N2: selection-only paints must not rebuild line pictures',
    );
  });

  test('block selection also reuses line pictures', () {
    final (render, controller, terminal) = makeFilled();

    paintOnce(render);
    render.debugPainter.resetLinePictureBuildCount();

    controller.setSelection(
      terminal.buffer.createAnchor(2, 2),
      terminal.buffer.createAnchor(20, 10),
      mode: SelectionMode.block,
    );
    paintOnce(render);
    controller.setSelection(
      terminal.buffer.createAnchor(5, 3),
      terminal.buffer.createAnchor(30, 12),
      mode: SelectionMode.block,
    );
    paintOnce(render);

    expect(render.debugPainter.linePictureBuildCount, 0);
  });
}
