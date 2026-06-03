import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/themes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('RenderTerminal.selectBufferRange keeps exclusive end', () {
    final terminal = Terminal();
    terminal.write('foo bar');

    const vsync = TestVSync();
    final controller = TerminalController(vsync: vsync);
    final focusNode = FocusNode();

    final render = RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: ViewportOffset.zero(),
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
    );

    final owner = PipelineOwner();
    render.attach(owner);

    final range = BufferRangeLine(
      const CellOffset(0, 0),
      const CellOffset(3, 0),
    );
    render.selectBufferRange(range);

    final selection = controller.selection;
    expect(selection, isA<BufferRangeLine>());
    expect(selection, equals(range));

    render.detach();
    controller.dispose();
    focusNode.dispose();
  });

  test('TerminalPainter uses selection colors for selected cells', () {
    final terminal = Terminal();
    terminal.write('A');

    final cellData = CellData.empty();
    terminal.buffer.lines[0].getCellData(0, cellData);
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );

    expect(
      painter.effectiveForegroundColor(cellData),
      TerminalThemes.defaultTheme.foreground,
    );
    expect(painter.effectiveBackgroundColor(cellData), isNull);
  });

  group('RenderTerminal.selectCharacters with wide chars', () {
    (RenderTerminal, TerminalController) _createRender(Terminal terminal) {
      const vsync = TestVSync();
      final controller = TerminalController(vsync: vsync);
      final focusNode = FocusNode();
      final render = RenderTerminal(
        terminal: terminal,
        controller: controller,
        offset: ViewportOffset.zero(),
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
      );
      final owner = PipelineOwner();
      render.attach(owner);
      return (render, controller);
    }

    test('selects a wide char fully (emoji)', () {
      final terminal = Terminal();
      terminal.write('😀BC');

      final (render, controller) = _createRender(terminal);

      final result = render.selectCharacters(
        const CellOffset(0, 0),
        const CellOffset(0, 0),
      );

      // Should expand to include both cells of the wide char
      expect(result.begin, const CellOffset(0, 0));
      expect(result.end, const CellOffset(2, 0));

      final selection = controller.selection;
      expect(selection!.begin, const CellOffset(0, 0));
      expect(selection.end, const CellOffset(2, 0));

      render.detach();
      controller.dispose();
    });

    test('normalizes from when it falls on continuation cell', () {
      final terminal = Terminal();
      terminal.write('😀BC');

      final (render, controller) = _createRender(terminal);

      // Click on continuation cell (index 1) of the wide char
      final result = render.selectCharacters(
        const CellOffset(1, 0), // continuation cell
        const CellOffset(3, 0), // 'C'
      );

      // from should back up to char start
      expect(result.begin, const CellOffset(0, 0));
      // end should expand to char end of 'C' (index 3 → index 4)
      expect(result.end, const CellOffset(4, 0));

      final selection = controller.selection;
      expect(selection!.begin, const CellOffset(0, 0));
      expect(selection.end, const CellOffset(4, 0));

      render.detach();
      controller.dispose();
    });

    test('returns correct value for single-arg collapsed selection', () {
      final terminal = Terminal();
      terminal.write('😀BC');

      final (render, controller) = _createRender(terminal);

      // Single arg = collapsed selection at character start
      final result = render.selectCharacters(const CellOffset(1, 0));

      // From continuation cell 1, backed up to 0
      expect(result.begin, const CellOffset(0, 0));
      expect(result.end, const CellOffset(0, 0));
      expect(result.isCollapsed, isTrue);

      render.detach();
      controller.dispose();
    });

    test('selects CJK wide characters', () {
      final terminal = Terminal();
      terminal.write('中文AB');

      final (render, controller) = _createRender(terminal);

      // Each CJK char is width 2
      final result = render.selectCharacters(
        const CellOffset(0, 0),
        const CellOffset(1, 0),
      );

      expect(result.begin, const CellOffset(0, 0));
      expect(result.end, const CellOffset(2, 0));

      final selection = controller.selection;
      expect(selection!.begin, const CellOffset(0, 0));
      expect(selection.end, const CellOffset(2, 0));

      render.detach();
      controller.dispose();
    });
  });

  group('RenderTerminal.selectBufferRange with wide chars', () {
    (RenderTerminal, TerminalController) _createRender(Terminal terminal) {
      const vsync = TestVSync();
      final controller = TerminalController(vsync: vsync);
      final focusNode = FocusNode();
      final render = RenderTerminal(
        terminal: terminal,
        controller: controller,
        offset: ViewportOffset.zero(),
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
      );
      final owner = PipelineOwner();
      render.attach(owner);
      return (render, controller);
    }

    test('normalizes end when it falls on continuation cell', () {
      final terminal = Terminal();
      terminal.write('AB😀DE');

      final (render, controller) = _createRender(terminal);

      // '😀' occupies cells 2-3. end=3 is the continuation cell.
      final range = BufferRangeLine(
        const CellOffset(0, 0),
        const CellOffset(3, 0), // continuation cell of 😀
      );

      final result = render.selectBufferRange(range);

      // end should back up from continuation cell (3) to char start (2)
      expect(result.begin, const CellOffset(0, 0));
      expect(result.end, const CellOffset(2, 0));

      final selection = controller.selection;
      expect(selection!.begin, const CellOffset(0, 0));
      expect(selection.end, const CellOffset(2, 0));

      render.detach();
      controller.dispose();
    });

    test('end on wide char start is preserved (correct exclusive end)', () {
      final terminal = Terminal();
      terminal.write('😀BC');

      final (render, controller) = _createRender(terminal);

      // normalized range: begin=0, end=2. Neither needs adjustment.
      final range = BufferRangeLine(
        const CellOffset(2, 0),
        const CellOffset(0, 0),
      );

      final result = render.selectBufferRange(range);

      expect(result.begin, const CellOffset(0, 0));
      expect(result.end, const CellOffset(2, 0));

      render.detach();
      controller.dispose();
    });

    test('selecting a single wide char via BufferRange works', () {
      final terminal = Terminal();
      terminal.write('😀BC');

      final (render, controller) = _createRender(terminal);

      final range = BufferRangeLine(
        const CellOffset(0, 0),
        const CellOffset(2, 0),
      );

      final result = render.selectBufferRange(range);

      expect(result.begin, const CellOffset(0, 0));
      expect(result.end, const CellOffset(2, 0));

      final selection = controller.selection;
      expect(selection!.begin, const CellOffset(0, 0));
      expect(selection.end, const CellOffset(2, 0));

      render.detach();
      controller.dispose();
    });
  });
}
