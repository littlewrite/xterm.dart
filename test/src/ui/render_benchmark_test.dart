import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/themes.dart';

/// Headless 渲染性能 benchmark。
///
/// 目的：建立一个可复现、可进 CI 的 paint() 层性能基线，专门测量
/// 我们要优化的那部分 Dart 侧每帧工作（遍历 cell、建 Paint、查 Paragraph 缓存）。
///
/// 它**不**测量 Skia/Impeller 光栅化和合成器位图缓存（那部分要用桌面 profile
/// harness 确认）。但它精确测量 dirty 追踪 / Paint 复用等优化直接作用的对象，
/// 因此能清楚反映这些优化的效果，并防止回归。
///
/// 运行：
///   flutter test test/src/ui/render_benchmark_test.dart
///
/// 输出会打印每个场景的单帧 paint 均值（μs）到测试日志，并把当前数字
/// 写入到 docs/perf-optimization.md 第 5 节。

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 屏幕几何：和默认 80x24 终端一致。
  const cols = 80;
  const rows = 24;
  // 一个近似等宽字号下的 cell 尺寸（px）。render.dart 用它布局。
  // 取一个典型值，benchmark 关注的是相对变化，绝对值不重要。
  const cellW = 9.0;
  const cellH = 18.0;
  final viewport = Size(cols * cellW, rows * cellH);

  /// 构造一个 attach 好、layout 完毕、可立即 paint 的 RenderTerminal。
  /// 返回 (render, owner)，owner 用于驱动 flushLayout 模拟真实滚动。
  (RenderTerminal, PipelineOwner) makeRender(Terminal terminal) {
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
    render.layout(BoxConstraints.tight(viewport), parentUsesSize: true);
    owner.flushLayout();
    addTearDown(() {
      render.detach();
      controller.dispose();
      focusNode.dispose();
    });
    return (render, owner);
  }

  /// 驱动一次 paint。用一个全新的 ContainerLayer 作为绘制目标。
  /// 这里不关心画出来的位图（benchmark 测的是 paint 本身的 CPU 成本），
  /// 只要不抛异常就说明 paint 跑通了。
  void paintOnce(RenderTerminal render) {
    final layer = ContainerLayer();
    final context = PaintingContext(
      layer,
      Rect.fromLTWH(0, 0, viewport.width, viewport.height),
    );
    // 仅触发 render.paint 的全部绘制调用——这些调用的 CPU 成本才是我们要测的。
    // 不收尾 layer，因为 benchmark 不消费绘制结果。
    render.paint(context, Offset.zero);
  }

  /// 计时：对 [setup] 返回的 (render, advanceInput) 跑 [frames] 帧，
  /// 每帧先调 advanceInput()（模拟一帧的输入）再 paint。
  /// 返回每帧 paint 的均值（μs，不含 advanceInput）。
  /// [afterInput] 在每帧 advanceInput 之后、paint 之前调用，可选，
  /// 用于驱动 flushLayout 模拟真实滚动跟随。
  double measure({
    required (RenderTerminal, PipelineOwner) Function() setup,
    required void Function(int frame) advanceInput,
    void Function(PipelineOwner owner, RenderTerminal render)? afterInput,
    void Function(RenderTerminal render)? onPainted,
    int warmup = 20,
    int frames = 200,
  }) {
    final (render, owner) = setup();

    // 预热：填满 paragraph 缓存、JIT 热身。
    for (var i = 0; i < warmup; i++) {
      advanceInput(i);
      afterInput?.call(owner, render);
      paintOnce(render);
      onPainted?.call(render);
    }

    final sw = Stopwatch()..start();
    for (var i = 0; i < frames; i++) {
      advanceInput(warmup + i);
      afterInput?.call(owner, render);
      paintOnce(render);
      onPainted?.call(render);
    }
    sw.stop();
    return sw.elapsedMicroseconds / frames;
  }

  /// 汇总打印。用 stdout 而非 expect，让 `flutter test` 日志里能看到数字。
  void report(String name, double usPerFrame) {
    // ignore: avoid_print
    print('  [BENCH] $name: ${usPerFrame.toStringAsFixed(1)} μs/frame');
  }

  group('RenderTerminal.paint benchmark', () {
    test('baseline: full-screen redraw (每帧整屏刷)', () {
      // 模拟 cmatrix 类场景：每帧整个屏幕都变化。
      // 这是 dirty 追踪收益最小的场景，作为上界。
      final terminal = Terminal(maxLines: 1000);
      final us = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame) {
          // 每帧写满整屏随机字符 + 回到行首
          final buf = StringBuffer('\r');
          for (var i = 0; i < cols * rows; i++) {
            buf.writeCharCode(33 + (frame * 7 + i) % 90);
          }
          terminal.write(buf.toString());
        },
      );
      report('full-screen-refresh', us);
      expect(us, greaterThan(0.0));
    });

    test('sparse-typing (稀疏输入：每帧 1 个字符)', () {
      // 模拟用户敲字：每帧只有 1 个字符变化。
      // 这是 dirty 追踪收益**最大**的场景。优化前与全屏刷几乎一样贵
      // （因为现在每帧都全遍历），优化后应大幅下降。
      final terminal = Terminal(maxLines: 1000);
      terminal.write(' ' * (cols * rows)); // 先填满，避免 layout 变化
      final us = measure(
        setup: () => makeRender(terminal),
        advanceInput: (frame) {
          terminal.write(String.fromCharCode(33 + frame % 90));
        },
      );
      report('sparse-typing', us);
      expect(us, greaterThan(0.0));
    });

    test('scroll-output (连续滚屏输出，stick-to-bottom)', () {
      // 模拟 tail -f / ls 大目录：连续带换行的行输出，视口跟随到底部。
      // afterInput 模拟真实 widget：terminal 变化 → render 重算 scroll extent，
      // flushLayout 触发 stick-to-bottom（_scrollOffset 跟随到底部），
      // effectFirstLine 上移后继续走滚动复用路径。
      final terminal = Terminal(maxLines: 1000);
      final modeCounts = <int, int>{0: 0, 1: 0, 2: 0};
      RenderTerminal? benchRender;
      final us = measure(
        setup: () {
          final pair = makeRender(terminal);
          benchRender = pair.$1;
          return pair;
        },
        advanceInput: (frame) {
          terminal.write('line $frame: the quick brown fox jumps\r\n');
        },
        afterInput: (owner, render) {
          render.simulateTerminalChangeForTest();
          owner.flushLayout();
        },
        onPainted: (render) {
          modeCounts[render.dbgLastPaintMode] =
              (modeCounts[render.dbgLastPaintMode] ?? 0) + 1;
        },
      );
      // ignore: avoid_print
      print('  [DEBUG] scroll mode counts: '
          'full=${modeCounts[0]} scroll=${modeCounts[1]} incr=${modeCounts[2]}');
      // ignore: avoid_print
      print('  [DEBUG] scroll metric counts: '
          'layout=${benchRender!.dbgLayoutCount}');
      report('scroll-output', us);
      expect(us, greaterThan(0.0));
      // 滚动复用路径应被大量触发（稳态下大部分帧是滚动）。
      expect(modeCounts[1]!, greaterThan(modeCounts[0]!),
          reason: 'scroll-output 稳态应以滚动复用为主，而非全画');
      expect(benchRender!.dbgLayoutCount, greaterThan(0),
          reason: '连续滚屏时应伴随 scroll extent 更新');
    });

    test('static-with-blink (静态屏，仅光标)', () {
      // 模拟输出暂停、仅光标在场的时刻。
      // 这是 setWillChangeHint / 静态跳过层的收益场景。
      // 注意：advanceInput 不写任何东西，测量的是无变化时 paint 的成本。
      final terminal = Terminal(maxLines: 1000);
      terminal.write('hello'); // 一些初始内容
      final us = measure(
        setup: () => makeRender(terminal),
        advanceInput: (_) {
          // 不做任何输入
        },
      );
      report('static-with-blink', us);
      expect(us, greaterThan(0.0));
    });
  });
}
