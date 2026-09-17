import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/pointer_input.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/selection_mode.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/terminal_theme.dart';
import 'package:xterm/src/ui/themes.dart';

/// N3 (perf-plan-v2): typed invalidation 通道可读 + selection 几何 gate。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const viewport = Size(80 * 9.0, 24 * 18.0);

  (RenderTerminal, TerminalController, Terminal, FocusNode) make({
    bool paintCursor = false,
  }) {
    final terminal = Terminal(maxLines: 200);
    terminal.write('hello\r\n');
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
      paintCursor: paintCursor,
    );
    final owner = PipelineOwner();
    render.attach(owner);
    render.layout(BoxConstraints.tight(viewport), parentUsesSize: true);
    owner.flushLayout();
    render.debugMarkNeedsPaintCount = 0;
    render.debugInvalidationCounts.updateAll((key, value) => 0);
    render.debugLastInvalidation = null;

    addTearDown(() {
      render.detach();
      controller.dispose();
      focusNode.dispose();
    });
    return (render, controller, terminal, focusNode);
  }

  test('cursor channel does not dirty content when paintCursor is false', () {
    final (render, _, _, _) = make(paintCursor: false);
    render.invalidateCursor();
    expect(render.debugLastInvalidation, TerminalInvalidation.cursor);
    expect(render.debugMarkNeedsPaintCount, 0);
  });

  test('cursor channel dirties content when paintCursor is true', () {
    final (render, _, _, _) = make(paintCursor: true);
    render.invalidateCursor();
    expect(render.debugLastInvalidation, TerminalInvalidation.cursor);
    expect(render.debugMarkNeedsPaintCount, greaterThan(0));
  });

  test('selection geometry change dirties; identical notify is skipped', () {
    final (render, controller, terminal, _) = make();

    controller.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(3, 0),
      mode: SelectionMode.line,
    );
    expect(render.debugLastInvalidation, TerminalInvalidation.selection);
    final paintsAfterSet = render.debugMarkNeedsPaintCount;
    expect(paintsAfterSet, greaterThan(0));

    // Same geometry again via setSelection with same anchors rebuilt —
    // fingerprint uses range coords, so equal ranges skip.
    controller.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(3, 0),
      mode: SelectionMode.line,
    );
    expect(
      render.debugLastInvalidation,
      TerminalInvalidation.selectionSkipped,
    );
    expect(render.debugMarkNeedsPaintCount, paintsAfterSet);

    // Pointer-input-only notify must not dirty content.
    controller.setPointerInputs(const PointerInputs({PointerInput.tap}));
    expect(
      render.debugLastInvalidation,
      TerminalInvalidation.selectionSkipped,
    );
    expect(render.debugMarkNeedsPaintCount, paintsAfterSet);
  });

  test('content channel dirties content layer', () {
    final (render, _, _, _) = make();
    render.invalidateContent();
    expect(render.debugLastInvalidation, TerminalInvalidation.content);
    expect(render.debugMarkNeedsPaintCount, greaterThan(0));
  });

  test('chrome channel clears line pictures and dirties', () {
    final (render, _, _, _) = make();

    // Warm a picture.
    final layer = ContainerLayer();
    final context = PaintingContext(
      layer,
      Rect.fromLTWH(0, 0, viewport.width, viewport.height),
    );
    render.paint(context, Offset.zero);
    expect(render.debugPainter.linePictureBuildCount, greaterThan(0));
    render.debugPainter.resetLinePictureBuildCount();
    render.debugMarkNeedsPaintCount = 0;

    render.theme = TerminalTheme(
      cursor: TerminalThemes.defaultTheme.cursor,
      selectionCursor: TerminalThemes.defaultTheme.selectionCursor,
      selection: const Color(0x88FF0000),
      foreground: TerminalThemes.defaultTheme.foreground,
      background: TerminalThemes.defaultTheme.background,
      black: TerminalThemes.defaultTheme.black,
      red: TerminalThemes.defaultTheme.red,
      green: TerminalThemes.defaultTheme.green,
      yellow: TerminalThemes.defaultTheme.yellow,
      blue: TerminalThemes.defaultTheme.blue,
      magenta: TerminalThemes.defaultTheme.magenta,
      cyan: TerminalThemes.defaultTheme.cyan,
      white: TerminalThemes.defaultTheme.white,
      brightBlack: TerminalThemes.defaultTheme.brightBlack,
      brightRed: TerminalThemes.defaultTheme.brightRed,
      brightGreen: TerminalThemes.defaultTheme.brightGreen,
      brightYellow: TerminalThemes.defaultTheme.brightYellow,
      brightBlue: TerminalThemes.defaultTheme.brightBlue,
      brightMagenta: TerminalThemes.defaultTheme.brightMagenta,
      brightCyan: TerminalThemes.defaultTheme.brightCyan,
      brightWhite: TerminalThemes.defaultTheme.brightWhite,
      searchHitBackground: TerminalThemes.defaultTheme.searchHitBackground,
      searchHitBackgroundCurrent:
          TerminalThemes.defaultTheme.searchHitBackgroundCurrent,
      searchHitForeground: TerminalThemes.defaultTheme.searchHitForeground,
    );

    expect(render.debugLastInvalidation, TerminalInvalidation.chrome);
    expect(render.debugMarkNeedsPaintCount, greaterThan(0));

    // After chrome clear, next paint must rebuild line pictures.
    render.paint(context, Offset.zero);
    expect(
      render.debugPainter.linePictureBuildCount,
      greaterThan(0),
      reason: 'chrome invalidation must drop line picture cache',
    );
  });

  test('focus change is cursor channel and skips content when overlay-only', () {
    final (render, _, _, _) = make(paintCursor: false);
    render.debugMarkNeedsPaintCount = 0;
    render.debugLastInvalidation = null;
    // alwaysShowCursor / cursorType go through invalidateCursor.
    render.alwaysShowCursor = true;
    expect(render.debugLastInvalidation, TerminalInvalidation.cursor);
    expect(render.debugMarkNeedsPaintCount, 0);

    render.cursorType = TerminalCursorType.underline;
    expect(render.debugLastInvalidation, TerminalInvalidation.cursor);
    expect(render.debugMarkNeedsPaintCount, 0);
  });
}
