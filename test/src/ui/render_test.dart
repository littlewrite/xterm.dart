import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/buffer/range_block.dart';
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

  test('RenderTerminal keeps block selection columns on middle rows', () {
    final selection = BufferRangeBlock(
      const CellOffset(5, 5),
      const CellOffset(20, 10),
    ).normalized;

    expect(RenderTerminal.selectedStartColumn(selection, 5), 5);
    expect(RenderTerminal.selectedStartColumn(selection, 7), 5);
    expect(RenderTerminal.selectedStartColumn(selection, 10), 5);
    expect(RenderTerminal.selectedEndColumn(selection, 5, 80), 20);
    expect(RenderTerminal.selectedEndColumn(selection, 7, 80), 20);
    expect(RenderTerminal.selectedEndColumn(selection, 10, 80), 20);
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

  test('TerminalPainter reuses unchanged line pictures', () {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
    );
    final line = BufferLine(8)..setCodePoint(0, 65);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    painter.paintLine(canvas, Offset.zero, line);
    painter.paintLine(canvas, Offset.zero, line);

    expect(painter.linePictureBuildCount, 1);

    line.setCodePoint(0, 66);
    painter.paintLine(canvas, Offset.zero, line);

    expect(painter.linePictureBuildCount, 2);
    recorder.endRecording().dispose();
  });

  test('TerminalPainter reuses line pictures across fractional DPR phases', () {
    final painter = TerminalPainter(
      theme: TerminalThemes.defaultTheme,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
      devicePixelRatio: 1.25,
    );
    final line = BufferLine(8)..setCodePoint(0, 65);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    for (var pass = 0; pass < 2; pass++) {
      for (var y = 0; y < 5; y++) {
        painter.paintLine(canvas, Offset(0, y.toDouble()), line);
      }
    }

    expect(painter.linePictureBuildCount, 4);
    recorder.endRecording().dispose();
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

  test('RenderTerminal tracks the terminal cursor while composing', () {
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
      cursorBlinkEnabled: false,
      cursorBlinkVisible: true,
      alwaysShowCursor: false,
    );

    terminal.write('\x1b[2;3H');
    render.composingText = 'pin';
    final initialOffset = render.editableCursorOffset;

    terminal.write('\x1b[8;12H');

    expect(render.cursorOffset, isNot(initialOffset));
    expect(render.editableCursorOffset, render.cursorOffset);

    focusNode.dispose();
    controller.dispose();
  });

  test('RenderTerminal isolates composing text in a repaint boundary', () {
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
      cursorBlinkEnabled: false,
      cursorBlinkVisible: true,
      alwaysShowCursor: false,
    );

    expect(render.firstChild, isNotNull);
    expect(render.firstChild!.isRepaintBoundary, isTrue);

    focusNode.dispose();
    controller.dispose();
  });

  test('RenderTerminal scopes the composing layer to the preedit rows', () {
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
      cursorBlinkEnabled: false,
      cursorBlinkVisible: true,
      alwaysShowCursor: false,
    );

    render.layout(BoxConstraints.tight(const Size(800, 400)));
    render.composingText = 'pinyin';

    final paintBounds = render.firstChild!.paintBounds;
    expect(paintBounds.height, lessThan(render.size.height));
    expect(paintBounds.width, lessThan(render.size.width));
    expect(paintBounds.height, greaterThanOrEqualTo(render.cellSize.height));
    expect(paintBounds.height, lessThanOrEqualTo(render.cellSize.height + 2));

    focusNode.dispose();
    controller.dispose();
  });

  test('RenderTerminal uses an explicit cursor background for composing text',
      () {
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
      cursorBlinkEnabled: false,
      cursorBlinkVisible: true,
      alwaysShowCursor: false,
    );

    terminal.write('\x1b[48;2;18;52;86m');

    expect(render.composingBackdropColor, const Color(0xFF123456));

    focusNode.dispose();
    controller.dispose();
  });

  test('RenderTerminal keeps the default composing background transparent', () {
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
      cursorBlinkEnabled: false,
      cursorBlinkVisible: true,
      alwaysShowCursor: false,
    );

    expect(render.composingBackdropColor, isNull);

    focusNode.dispose();
    controller.dispose();
  });

  test('RenderTerminal aligns the composing backdrop to terminal cells', () {
    expect(
      RenderTerminal.resolveComposingBackdropRects(
        startOffset: const Offset(20, 40),
        text: '中文',
        viewWidth: 10,
        cellSize: const Size(10, 20),
      ),
      const [Rect.fromLTWH(20, 40, 40, 20)],
    );
  });

  test('RenderTerminal wraps the composing backdrop at terminal width', () {
    expect(
      RenderTerminal.resolveComposingBackdropRects(
        startOffset: const Offset(80, 0),
        text: 'abc',
        viewWidth: 10,
        cellSize: const Size(10, 20),
      ),
      const [
        Rect.fromLTWH(80, 0, 20, 20),
        Rect.fromLTWH(0, 20, 10, 20),
      ],
    );
  });

  test('RenderTerminal wraps composing paragraphs at the terminal grid width',
      () {
    expect(
      RenderTerminal.resolveComposingParagraphWidth(
        viewWidth: 10,
        cellSize: const Size(7.5, 14),
        fallbackWidth: 80,
      ),
      75,
    );
  });

  test('RenderTerminal resolves Linux IME anchor after ASCII composition', () {
    final offset = RenderTerminal.resolveComposingEndOffset(
      startOffset: const Offset(20, 40),
      text: 'pin',
      viewWidth: 80,
      cellSize: const Size(10, 20),
    );

    expect(offset, const Offset(50, 40));
  });

  test('RenderTerminal wraps Linux IME anchor at the terminal width', () {
    final offset = RenderTerminal.resolveComposingEndOffset(
      startOffset: const Offset(70, 40),
      text: 'pinyin',
      viewWidth: 10,
      cellSize: const Size(10, 20),
    );

    expect(offset, const Offset(30, 60));
  });

  test('RenderTerminal counts wide runes in the Linux IME anchor', () {
    final offset = RenderTerminal.resolveComposingEndOffset(
      startOffset: const Offset(20, 40),
      text: '中文',
      viewWidth: 80,
      cellSize: const Size(10, 20),
    );

    expect(offset, const Offset(60, 40));
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
