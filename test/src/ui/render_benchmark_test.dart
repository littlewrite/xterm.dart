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

/// Headless 渲染性能 benchmark（perf-plan-v2 批 N0）。
///
/// 测量目标：Dart 侧每次 [RenderTerminal.paint] 的 CPU 成本，以及可选的
/// [TerminalPainter.linePictureBuildCount]。
///
/// 不测量：Skia/Impeller 光栅化、合成器 bitmap cache、真机 CPU%。
///
/// 运行：
///   fvm flutter test test/src/ui/render_benchmark_test.dart
///
/// 数字写入 docs/perf-plan-v2.md §5.4。对比必须同一机器、同命令。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cols = 80;
  const rows = 24;
  // 与旧 harness 一致的近似 cell 几何；关注相对变化。
  const cellW = 9.0;
  const cellH = 18.0;
  final viewport = Size(cols * cellW, rows * cellH);

  (RenderTerminal, PipelineOwner, TerminalController, FocusNode) makeRender(
    Terminal terminal,
  ) {
    final controller = TerminalController();
    final focusNode = FocusNode();
    // 可校正的 offset：scroll-output 场景依赖 stick-to-bottom 的 correctBy。
    final offset = ViewportOffset.fixed(0);
    final render = RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: offset,
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
    return (render, owner, controller, focusNode);
  }

  void paintOnce(RenderTerminal render) {
    final layer = ContainerLayer();
    final context = PaintingContext(
      layer,
      Rect.fromLTWH(0, 0, viewport.width, viewport.height),
    );
    render.paint(context, Offset.zero);
  }

  /// 返回 (μs/frame, linePictureBuilds during measured frames)。
  (double, int) measure({
    required (RenderTerminal, PipelineOwner, TerminalController, FocusNode)
            Function()
        setup,
    required void Function(
      int frame,
      RenderTerminal render,
      TerminalController controller,
    ) advanceInput,
    void Function(PipelineOwner owner, RenderTerminal render)? afterInput,
    int warmup = 20,
    int frames = 200,
  }) {
    final (render, owner, controller, _) = setup();

    for (var i = 0; i < warmup; i++) {
      advanceInput(i, render, controller);
      afterInput?.call(owner, render);
      paintOnce(render);
    }

    render.debugPainter.resetLinePictureBuildCount();
    final sw = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      advanceInput(warmup + i, render, controller);
      afterInput?.call(owner, render);
      paintOnce(render);
    }
    sw.stop();
    final builds = render.debugPainter.linePictureBuildCount;
    return (sw.elapsedMicroseconds / frames, builds);
  }

  void report(String name, double usPerFrame, int pictureBuilds) {
    // ignore: avoid_print
    print(
      '  [BENCH] $name: ${usPerFrame.toStringAsFixed(1)} μs/frame, '
      'linePictureBuilds=$pictureBuilds',
    );
  }

  group('RenderTerminal.paint benchmark', () {
    test('full-screen-refresh', () {
      final terminal = Terminal(maxLines: 1000);
      final (us, builds) = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {
          final buf = StringBuffer('\r');
          for (var i = 0; i < cols * rows; i++) {
            buf.writeCharCode(33 + (frame * 7 + i) % 90);
          }
          terminal.write(buf.toString());
        },
      );
      report('full-screen-refresh', us, builds);
      expect(us, greaterThan(0.0));
    });

    test('sparse-typing', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write(' ' * (cols * rows));
      final (us, builds) = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {
          terminal.write(String.fromCharCode(33 + frame % 90));
        },
      );
      report('sparse-typing', us, builds);
      expect(us, greaterThan(0.0));
    });

    test('scroll-output', () {
      final terminal = Terminal(maxLines: 1000);
      final (us, builds) = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {
          terminal.write('line $frame: the quick brown fox jumps\r\n');
        },
        afterInput: (owner, render) {
          // 模拟终端变化后的 layout / stick-to-bottom，不依赖已删除的
          // simulateTerminalChangeForTest hook。
          render.markNeedsLayout();
          owner.flushLayout();
        },
      );
      report('scroll-output', us, builds);
      expect(us, greaterThan(0.0));
    });

    test('static-with-blink', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('hello');
      final (us, builds) = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {
          // 无 buffer 写入。仅反复 paint（不模拟 Timer blink 调度）。
        },
      );
      report('static-with-blink', us, builds);
      expect(us, greaterThan(0.0));
    });

    test('selection-drag', () {
      // 内容固定，每帧只改选区几何。N2：linePictureBuilds 在测量段应 ≈0
      //（始终 paintLine + selection rect，选区不进 line Picture key）。
      final terminal = Terminal(maxLines: 1000);
      final fill = StringBuffer();
      for (var r = 0; r < rows; r++) {
        fill.writeln('row $r ${'x' * (cols - 10)}');
      }
      terminal.write(fill.toString());

      final (us, builds) = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {
          final endCol = (frame % (cols - 1)) + 1;
          final endRow = (frame ~/ cols) % rows;
          controller.setSelection(
            terminal.buffer.createAnchor(0, 0),
            terminal.buffer.createAnchor(endCol, endRow),
            mode: SelectionMode.line,
          );
        },
      );
      report('selection-drag', us, builds);
      expect(us, greaterThan(0.0));
      // N2 success: selection geometry alone must not rebuild line pictures.
      // Allow a tiny budget for first-touch phase keys; not O(rows*frames).
      expect(
        builds,
        lessThan(rows * 2),
        reason:
            'N2: selection-only frames must reuse paintLine cache '
            '(got $builds builds over 200 frames)',
      );
    });
  });
}
