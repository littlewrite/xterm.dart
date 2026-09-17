import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/terminal_view.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/themes.dart';

/// N1 (perf-plan-v2): 光标真隔离调度断言。
///
/// headless μs 对 blink 隔离不敏感；本文件用 markNeedsPaint 计数证明：
/// - paintCursor:false 时 blink 翻转 **不** dirty 主内容层
/// - paintCursor:true（legacy）时 blink 仍 dirty 主层
/// - TerminalView 产品路径 blink 不脏内容层
/// - buffer notify 且 cursor fingerprint 不变时，overlay 不 dirty
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const viewport = Size(80 * 9.0, 24 * 18.0);

  (RenderTerminal, FocusNode, TerminalController) makeRender({
    required bool paintCursor,
    required bool cursorBlinkVisible,
  }) {
    final terminal = Terminal(maxLines: 1000);
    terminal.write('hello');
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
      cursorBlinkEnabled: true,
      cursorBlinkVisible: cursorBlinkVisible,
      alwaysShowCursor: false,
      paintCursor: paintCursor,
    );
    final owner = PipelineOwner();
    render.attach(owner);
    render.layout(BoxConstraints.tight(viewport), parentUsesSize: true);
    owner.flushLayout();
    // Baseline after layout noise.
    render.debugMarkNeedsPaintCount = 0;

    addTearDown(() {
      render.detach();
      controller.dispose();
      focusNode.dispose();
    });
    return (render, focusNode, controller);
  }

  test('blink flip does not dirty content layer when paintCursor is false', () {
    final (render, _, _) = makeRender(
      paintCursor: false,
      cursorBlinkVisible: true,
    );

    render.cursorBlinkVisible = false;
    render.cursorBlinkVisible = true;
    render.cursorBlinkEnabled = false;
    expect(
      render.debugMarkNeedsPaintCount,
      0,
      reason: 'N1: blink must not markNeedsPaint on content layer',
    );
  });

  test('blink flip still dirties content layer when paintCursor is true', () {
    final (render, _, _) = makeRender(
      paintCursor: true,
      cursorBlinkVisible: true,
    );

    render.cursorBlinkVisible = false;
    expect(
      render.debugMarkNeedsPaintCount,
      greaterThan(0),
      reason: 'legacy/in-layer cursor path still needs blink dirty',
    );
  });

  testWidgets(
    'TerminalView blink ticks do not dirty content layer',
    (tester) async {
      final terminal = Terminal(maxLines: 200);
      terminal.write('static line\r\n');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 480,
              height: 320,
              child: TerminalView(
                terminal,
                autofocus: true,
                cursorBlink: true,
                cursorBlinkInterval: const Duration(milliseconds: 40),
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump();

      final render =
          tester.allRenderObjects.whereType<RenderTerminal>().first;
      render.debugMarkNeedsPaintCount = 0;

      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 45));
      }

      expect(
        render.debugMarkNeedsPaintCount,
        0,
        reason: 'blink ticks must not markNeedsPaint RenderTerminal content',
      );
    },
  );

  testWidgets(
    'buffer write that keeps cursor geometry does not dirty overlay',
    (tester) async {
      final terminal = Terminal(maxLines: 200);
      terminal.write('line0\r\n');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 480,
              height: 320,
              child: TerminalView(
                terminal,
                cursorBlink: false,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final viewRo = tester.renderObject(find.byType(TerminalView));
      final dirtyBefore = debugCursorOverlayVisualDirtyCount(viewRo);

      // SGR reset: may notify terminal listeners without moving cursor.
      terminal.write('\x1b[0m');
      await tester.pump();

      final dirtyAfter = debugCursorOverlayVisualDirtyCount(viewRo);
      expect(
        dirtyAfter,
        dirtyBefore,
        reason:
            'N1 fingerprint: non-cursor terminal notify must not dirty overlay',
      );

      terminal.write('\x1b[1;5H');
      await tester.pump();
      expect(
        debugCursorOverlayVisualDirtyCount(viewRo),
        greaterThan(dirtyAfter),
        reason: 'cursor move must dirty overlay',
      );
    },
  );
}
