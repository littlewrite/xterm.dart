import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/range_line.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/custom_glyphs.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';
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

  test('TerminalPainter uses geometry-based custom glyph painting', () {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );

    final fullBlock = CellData(
      foreground: CellColor.rgb | 0x336699,
      background: 0,
      flags: 0,
      content: 0x2588 | (1 << CellContent.widthShift),
    );
    final lowerHalf = CellData(
      foreground: CellColor.rgb | 0x112233,
      background: 0,
      flags: 0,
      content: 0x2584 | (1 << CellContent.widthShift),
    );
    final quadrant = CellData(
      foreground: CellColor.rgb | 0xabcdef,
      background: 0,
      flags: 0,
      content: 0x259A | (1 << CellContent.widthShift),
    );
    final lightShade = CellData(
      foreground: CellColor.rgb | 0x778899,
      background: 0,
      flags: 0,
      content: 0x2591 | (1 << CellContent.widthShift),
    );
    final powerlineSeparator = CellData(
      foreground: CellColor.rgb | 0xff8800,
      background: 0,
      flags: 0,
      content: 0xE0B0 | (1 << CellContent.widthShift),
    );

    final fullBlockPaint = painter.customGlyphPaint(fullBlock);
    final lowerHalfPaint = painter.customGlyphPaint(lowerHalf);
    final quadrantPaint = painter.customGlyphPaint(quadrant);
    final lightShadePaint = painter.customGlyphPaint(lightShade);
    final powerlinePaint = painter.customGlyphPaint(powerlineSeparator);

    expect(fullBlockPaint, isNotNull);
    expect(fullBlockPaint!.color, const Color(0xFF336699));
    expect(
      fullBlockPaint.glyph.type,
      TerminalCustomGlyphType.solidOctantBlockVector,
    );
    expect(
      fullBlockPaint.glyph.blocks.single,
      const TerminalCustomGlyphBlock(x: 0, y: 0, w: 8, h: 8),
    );

    expect(lowerHalfPaint, isNotNull);
    expect(
      lowerHalfPaint!.glyph.blocks.single,
      const TerminalCustomGlyphBlock(x: 0, y: 4, w: 8, h: 4),
    );

    expect(quadrantPaint, isNotNull);
    expect(
      quadrantPaint!.glyph.blocks,
      const [
        TerminalCustomGlyphBlock(x: 0, y: 0, w: 4, h: 4),
        TerminalCustomGlyphBlock(x: 4, y: 4, w: 4, h: 4),
      ],
    );

    expect(lightShadePaint, isNotNull);
    expect(
      lightShadePaint!.glyph.type,
      TerminalCustomGlyphType.blockPattern,
    );
    expect(lightShadePaint.glyph.pattern, const [
      [1, 0],
      [0, 0],
    ]);

    expect(powerlinePaint, isNotNull);
    expect(
      powerlinePaint!.glyph.type,
      TerminalCustomGlyphType.vectorShape,
    );
    expect(powerlinePaint.glyph.path, 'M0,0 L1,.5 L0,1');
    expect(powerlinePaint.glyph.vectorType, TerminalCustomGlyphVectorType.fill);
    expect(powerlinePaint.glyph.leftPadding, 0);
    expect(powerlinePaint.glyph.rightPadding, 2);
  });

  test('TerminalCustomGlyphRasterizer ignores malformed vector instructions',
      () {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rasterizer = TerminalCustomGlyphRasterizer(
      canvas: canvas,
      offset: Offset.zero,
      cellSize: const Size(16, 16),
      color: const Color(0xFF336699),
      fontSize: 14,
      devicePixelRatio: 2,
    );

    expect(
      () => rasterizer.paint(
        const TerminalCustomGlyph.vectorShape(
          path: 'M0,0 C1,0,1,1',
          vectorType: TerminalCustomGlyphVectorType.fill,
        ),
      ),
      returnsNormally,
    );
    expect(
      () => rasterizer.paint(
        const TerminalCustomGlyph.vectorShape(
          path: 'M0,0 Q1,0,1',
          vectorType: TerminalCustomGlyphVectorType.fill,
        ),
      ),
      returnsNormally,
    );
    expect(
      () => rasterizer.paint(
        const TerminalCustomGlyph.vectorShape(
          path: 'M0,0 H, V',
          vectorType: TerminalCustomGlyphVectorType.fill,
        ),
      ),
      returnsNormally,
    );
    expect(
      () => rasterizer.paint(
        const TerminalCustomGlyph.vectorShape(
          path: 'M0,0 L1,1',
          vectorType: TerminalCustomGlyphVectorType.fill,
        ),
      ),
      returnsNormally,
    );

    recorder.endRecording();
  });

  test('TerminalPainter selected cells do not paint the original background',
      () async {
    const selectionColor = Color(0x802222FF);
    final defaultTheme = TerminalThemes.defaultTheme;
    final theme = TerminalTheme(
      cursor: defaultTheme.cursor,
      selectionCursor: defaultTheme.selectionCursor,
      selection: selectionColor,
      foreground: defaultTheme.foreground,
      background: defaultTheme.background,
      black: defaultTheme.black,
      white: defaultTheme.white,
      red: defaultTheme.red,
      green: defaultTheme.green,
      yellow: defaultTheme.yellow,
      blue: defaultTheme.blue,
      magenta: defaultTheme.magenta,
      cyan: defaultTheme.cyan,
      brightBlack: defaultTheme.brightBlack,
      brightRed: defaultTheme.brightRed,
      brightGreen: defaultTheme.brightGreen,
      brightYellow: defaultTheme.brightYellow,
      brightBlue: defaultTheme.brightBlue,
      brightMagenta: defaultTheme.brightMagenta,
      brightCyan: defaultTheme.brightCyan,
      brightWhite: defaultTheme.brightWhite,
      searchHitBackground: defaultTheme.searchHitBackground,
      searchHitBackgroundCurrent: defaultTheme.searchHitBackgroundCurrent,
      searchHitForeground: defaultTheme.searchHitForeground,
    );
    final painter = TerminalPainter(
      theme: theme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final cellData = CellData(
      foreground: CellColor.normal,
      background: CellColor.rgb | 0x00FF0000,
      flags: 0,
      content: 1 << CellContent.widthShift,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    painter.paintSelectedCell(canvas, Offset.zero, cellData);

    final picture = recorder.endRecording();
    final image = await picture.toImage(
      painter.cellSize.width.ceil(),
      painter.cellSize.height.ceil(),
    );
    final byteData = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );

    expect(byteData, isNotNull);

    final bytes = byteData!.buffer.asUint8List();
    final width = painter.cellSize.width.ceil();
    final height = painter.cellSize.height.ceil();
    final centerX = width ~/ 2;
    final centerY = height ~/ 2;
    final pixelOffset = (centerY * width + centerX) * 4;
    final pixelColor = Color.fromARGB(
      bytes[pixelOffset + 3],
      bytes[pixelOffset],
      bytes[pixelOffset + 1],
      bytes[pixelOffset + 2],
    );

    expect(pixelColor, selectionColor);
  });

  test('RenderTerminal exposes cursor visibility state for overlay', () {
    final terminal = Terminal();
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
      cursorBlinkEnabled: true,
      cursorBlinkVisible: false,
      alwaysShowCursor: false,
    );

    expect(render.shouldShowCursor, isTrue);
    expect(render.shouldPaintCursor(cursorBlinkVisible: false), isTrue);
    expect(render.shouldPaintCursor(cursorBlinkVisible: true), isTrue);

    focusNode.dispose();
    controller.dispose();
  });

  test('RenderTerminal hides cursor when terminal visibility mode is disabled',
      () {
    final terminal = Terminal();
    terminal.write('\x1b[?25l');
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

    expect(render.shouldShowCursor, isFalse);
    expect(render.shouldPaintCursor(cursorBlinkVisible: true), isFalse);

    focusNode.dispose();
    controller.dispose();
  });

  group('RenderTerminal.selectCharacters with wide chars', () {
    (RenderTerminal, TerminalController) createRender(Terminal terminal) {
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

      final (render, controller) = createRender(terminal);

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

      final (render, controller) = createRender(terminal);

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

      final (render, controller) = createRender(terminal);

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

      final (render, controller) = createRender(terminal);

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
    (RenderTerminal, TerminalController) createRender(Terminal terminal) {
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

      final (render, controller) = createRender(terminal);

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

      final (render, controller) = createRender(terminal);

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

      final (render, controller) = createRender(terminal);

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
