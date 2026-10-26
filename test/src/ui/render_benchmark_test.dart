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

/// Headless 渲染性能 benchmark。
///
/// 测量目标：Dart 侧每次 [RenderTerminal.paint] 的 CPU 成本，
/// [TerminalPainter.linePictureBuildCount]，以及每帧发出的单元格绘制指令数
/// （`paragraphs/frame` 与 `bgRects/frame`）。后两项在命中行 Picture 时按
/// 录制时记下的数量计入，所以反映的是重放成本，正好对应真机光栅化要做的
/// 工作；合并 run 的效果主要看它们。
///
/// 不测量：Skia/Impeller 光栅化、合成器 bitmap cache、真机 CPU%。
///
/// 运行：
///   fvm flutter test test/src/ui/render_benchmark_test.dart
///
/// 对比必须同一机器、同命令，且**按场景单独跑**（`--plain-name "<场景名>"`，
/// 或用 `--name "<正则>$"` 精确匹配）。整个文件一起跑时，前面的场景会按自己
/// 录制了多少个 Picture 把绘制路径 JIT 预热到不同程度，于是后面便宜场景的
/// μs 随代码版本一起漂移：曾量到 sparse-typing 在一个版本里 +39%，而同一份
/// 代码单独跑只差 1.7%。单独跑时每个场景各自预热，数字才可比。
///
/// `per-cell-*` 场景把 `TerminalPainter.coalesceRuns` 关掉，作为同一构建内
/// 的逐格绘制对照组。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cols = 80;
  const rows = 24;
  // 与旧 harness 一致的近似 cell 几何；关注相对变化。
  const cellW = 9.0;
  const cellH = 18.0;
  final viewport = Size(cols * cellW, rows * cellH);

  (RenderTerminal, PipelineOwner, TerminalController, FocusNode) makeRender(
    Terminal terminal, {
    bool coalesceRuns = true,
  }) {
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
    render.debugPainter.coalesceRuns = coalesceRuns;
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

  /// 返回 (μs/frame, linePictureBuilds, paragraphs, background rects)。
  ///
  /// `paragraphs`/`rects` 统计的是一帧真正发出的单元格绘制指令：新录制的行
  /// 按实际调用计数，命中行 Picture 的按录制时记下的数量计入重放成本。
  ({
    double us,
    int builds,
    int paragraphs,
    int rects,
    int frames,
  }) measure({
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
    render.debugPainter.resetDebugDrawCounts();
    final sw = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      advanceInput(warmup + i, render, controller);
      afterInput?.call(owner, render);
      paintOnce(render);
    }
    sw.stop();
    final painter = render.debugPainter;
    return (
      us: sw.elapsedMicroseconds / frames,
      builds: painter.linePictureBuildCount,
      paragraphs: painter.debugDrawParagraphCount,
      rects: painter.debugDrawBackgroundRectCount,
      frames: frames,
    );
  }

  void report(
    String name,
    ({
      double us,
      int builds,
      int paragraphs,
      int rects,
      int frames,
    }) result,
  ) {
    // ignore: avoid_print
    print(
      '  [BENCH] $name: ${result.us.toStringAsFixed(1)} μs/frame, '
      'linePictureBuilds=${result.builds}, '
      'paragraphs/frame='
      '${(result.paragraphs / result.frames).toStringAsFixed(1)}, '
      'bgRects/frame='
      '${(result.rects / result.frames).toStringAsFixed(1)}',
    );
  }

  /// 一行 `ls -lta` 风格的输出：权限、大小、时间、文件名各用一种颜色。
  String lsLine(int i) {
    const colors = [31, 32, 33, 34, 35, 36];
    final name = 'file_${i.toString().padLeft(4, '0')}.txt';
    return '\x1b[${colors[i % 6]}m-rw-r--r--\x1b[0m 1 user group '
        '\x1b[33m${(i * 137) % 100000}\x1b[0m Oct 25 10:00 '
        '\x1b[${colors[(i + 2) % 6]}m$name\x1b[0m\r\n';
  }

  /// 一屏没有换行的 `ls` 文本，用于静态重绘场景。
  String lsScreen() {
    final buf = StringBuffer();
    for (var r = 0; r < rows; r++) {
      if (r > 0) buf.write('\r\n');
      buf.write(lsLine(r).replaceFirst('\r\n', ''));
    }
    return buf.toString();
  }

  group('RenderTerminal.paint benchmark', () {
    test('full-screen-refresh', () {
      final terminal = Terminal(maxLines: 1000);
      final result = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {
          final buf = StringBuffer('\r');
          for (var i = 0; i < cols * rows; i++) {
            buf.writeCharCode(33 + (frame * 7 + i) % 90);
          }
          terminal.write(buf.toString());
        },
      );
      report('full-screen-refresh', result);
      expect(result.us, greaterThan(0.0));
      expect(
        result.builds,
        lessThan(rows * 10),
        reason: 'content caching must keep full-screen picture builds well '
            'below one per row and frame (got ${result.builds})',
      );
    });

    test('sparse-typing', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write(' ' * (cols * rows));
      final result = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {
          terminal.write(String.fromCharCode(33 + frame % 90));
        },
      );
      report('sparse-typing', result);
      expect(result.us, greaterThan(0.0));
    });

    test('scroll-output', () {
      final terminal = Terminal(maxLines: 1000);
      final result = measure(
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
      report('scroll-output', result);
      expect(result.us, greaterThan(0.0));
    });

    test('static-with-blink', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('hello');
      final result = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {
          // 无 buffer 写入。仅反复 paint（不模拟 Timer blink 调度）。
        },
      );
      report('static-with-blink', result);
      expect(result.us, greaterThan(0.0));
    });

    test('redraw-same-screen', () {
      // TUI 每帧把自己的屏幕从头重画一遍（清屏 + 重写同样的文字）：cell 被
      // 重写（revision 动了）但屏幕看起来一模一样。picture 按内容缓存时，
      // 第一帧之后不再录制任何一行。
      final terminal = Terminal(maxLines: 1000);
      final screen = StringBuffer();
      for (var r = 0; r < rows; r++) {
        if (r > 0) screen.write('\r\n');
        // 比 cols 少一格：最后一格不留下待换行，整屏不会滚。
        screen.write('row $r'.padRight(cols - 1));
      }
      final text = screen.toString();

      final result = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {
          terminal.write('\x1b[H\x1b[2J');
          terminal.write(text);
        },
      );
      report('redraw-same-screen', result);
      expect(result.us, greaterThan(0.0));
      expect(
        result.builds,
        0,
        reason: '每帧重画的还是同一屏内容，应当全部命中内容缓存 '
            '(got ${result.builds} builds over ${result.frames} frames)',
      );
    });

    test('ls-streaming', () {
      // `ls -lta` 正在输出：每帧追加一行并滚动。目录列表每一行有 3 段颜色，
      // 但行内大部分字符同色，正是 run 合并的目标。
      final terminal = Terminal(maxLines: 1000);
      final result = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {
          terminal.write(lsLine(frame));
          render.markNeedsLayout();
        },
        afterInput: (owner, render) {
          render.markNeedsLayout();
          owner.flushLayout();
        },
      );
      report('ls-streaming', result);
      expect(result.us, greaterThan(0.0));
    });

    test('ls-static', () {
      // 一屏 `ls -lta` 已经画好，之后每帧只重绘（行 Picture 命中）。这个场景
      // 的 paragraphs/frame 反映的是重放成本，不是重新录制的成本。
      final terminal = Terminal(maxLines: 1000);
      terminal.write(lsScreen());
      final result = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {},
      );
      report('ls-static', result);
      expect(result.us, greaterThan(0.0));
      expect(
        result.builds,
        0,
        reason: '静态屏幕应当全部命中 line picture 缓存 '
            '(got ${result.builds} builds over ${result.frames} frames)',
      );
    });

    test('per-cell-full-screen-refresh', () {
      // 对照组：整屏每帧重写，逐格绘制。
      final terminal = Terminal(maxLines: 1000);
      final result = measure(
        setup: () => makeRender(terminal, coalesceRuns: false),
        advanceInput: (frame, render, controller) {
          final buf = StringBuffer('\r');
          for (var i = 0; i < cols * rows; i++) {
            buf.writeCharCode(33 + (frame * 7 + i) % 90);
          }
          terminal.write(buf.toString());
        },
      );
      report('per-cell-full-screen-refresh', result);
      expect(result.us, greaterThan(0.0));
    });

    test('per-cell-sparse-typing', () {
      // 对照组：逐格绘制时，每个按键只需缓存命中的单字符段落。
      final terminal = Terminal(maxLines: 1000);
      terminal.write(' ' * (cols * rows));
      final result = measure(
        setup: () => makeRender(terminal, coalesceRuns: false),
        advanceInput: (frame, render, controller) {
          terminal.write(String.fromCharCode(33 + frame % 90));
        },
      );
      report('per-cell-sparse-typing', result);
      expect(result.us, greaterThan(0.0));
    });

    test('bg-bars', () {
      // htop 风格的彩色条：每行 40 个格子共享一个背景色。合并后每行一个
      // rect；逐格绘制时是每行 40 个。
      final terminal = Terminal(maxLines: 1000);
      final screen = StringBuffer();
      for (var r = 0; r < rows; r++) {
        if (r > 0) screen.write('\r\n');
        screen.write('\x1b[48;5;${17 + r}m');
        screen.write(' ' * 40);
        screen.write('\x1b[0m');
        screen.write(' ' * (cols - 41));
      }
      terminal.write(screen.toString());

      final result = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame, render, controller) {},
      );
      report('bg-bars', result);
      expect(result.us, greaterThan(0.0));
      expect(
        result.rects,
        rows * result.frames,
        reason: 'one merged rect per row, replayed on every frame',
      );
    });

    test('ls-streaming-per-cell', () {
      // 同一场景关闭 run 合并，作为同一次构建内的对照组。
      final terminal = Terminal(maxLines: 1000);
      final result = measure(
        setup: () => makeRender(terminal, coalesceRuns: false),
        advanceInput: (frame, render, controller) {
          terminal.write(lsLine(frame));
          render.markNeedsLayout();
        },
        afterInput: (owner, render) {
          render.markNeedsLayout();
          owner.flushLayout();
        },
      );
      report('ls-streaming-per-cell', result);
      expect(result.us, greaterThan(0.0));
    });

    test('ls-static-per-cell', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write(lsScreen());
      final result = measure(
        setup: () => makeRender(terminal, coalesceRuns: false),
        advanceInput: (frame, render, controller) {},
      );
      report('ls-static-per-cell', result);
      expect(result.us, greaterThan(0.0));
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

      final result = measure(
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
      report('selection-drag', result);
      expect(result.us, greaterThan(0.0));
      // N2 success: selection geometry alone must not rebuild line pictures.
      // Allow a tiny budget for first-touch phase keys; not O(rows*frames).
      expect(
        result.builds,
        lessThan(rows * 2),
        reason: 'N2: selection-only frames must reuse paintLine cache '
            '(got ${result.builds} builds over ${result.frames} frames)',
      );
    });
  });
}
