import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/themes.dart';

/// 针对"逐行段落 run 化"优化的定向 benchmark。
///
/// 背景：真机日志显示 mode=2 每帧只画 1 行（painted={9999}）仍占 CPU。
/// 怀疑瓶颈不在"画几行"，而在画的方式——painter.dart 的 _paintLineCells 是
/// **逐 cell canvas.drawParagraph**，且整屏缓存 Picture 每帧 drawPicture 重放
/// ~4500 条 drawParagraph 命令。
///
/// 本 benchmark 用数据确认两件事：
/// 1. drawPicture(整屏缓存) 单帧成本有多大（确认重放是不是大头）；
/// 2. 逐 cell drawParagraph vs 逐行 ParagraphBuilder 合成，单行差多少
///    （确认 run 化的收益上限）。
///
/// 运行：flutter test test/src/ui/painter_run_benchmark_test.dart

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const cols = 80;
  const rows = 24;
  const cellW = 9.0;
  const cellH = 18.0;
  final viewport = Size(cols * cellW, rows * cellH);

  /// 构造 attach 好、layout 完的 RenderTerminal（同 render_benchmark 的工厂）。
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

  void report(String name, double us) {
    // ignore: avoid_print
    print('  [BENCH-RUN] $name: ${us.toStringAsFixed(2)} μs');
  }

  group('drawPicture 重放成本', () {
    // 目标：测量"每帧 drawPicture(整屏缓存 Picture)"本身的开销。
    // 现状：mode=1/2/3 每帧都 drawPicture(_contentPicture) 当底，重放整屏命令。

    test('drawPicture(整屏 Picture) 单次成本 vs 画 1 行成本', () {
      final terminal = Terminal(maxLines: 1000);
      // 填满整屏普通文本，建立整屏缓存 Picture。
      for (var r = 0; r < rows; r++) {
        terminal.write('line $r: the quick brown fox jumps over the lazy dog. ${'x' * 20}\n');
      }
      final (render, _) = makeRender(terminal);

      // 先 paint 一次，让 _contentPicture 录好（mode=0 全画）。
      final buildCtx = PaintingContext(
        ContainerLayer(),
        Rect.fromLTWH(0, 0, viewport.width, viewport.height),
      );
      render.paint(buildCtx, Offset.zero);

      // 取出整屏缓存 Picture（通过私有字段无法直接拿，用反射）。
      // 这里不依赖内部字段：改成测量"一帧完整 paint"里 drawPicture 占比——
      // 用控制变量：A=完整 paint（含 drawPicture + dirty 行），B=只重建缓存
      // Picture 的耗时。两者差≈ drawPicture 重放 + dirty 行画。
      // 但更直接：测"连续多次 drawPicture 同一 Picture"的单次成本。

      // 重新录一个典型整屏 Picture（模拟 _contentPicture 的内容量）。
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final painter = TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );
      // 画满 rows 行（模拟整屏缓存）。
      final lines = terminal.buffer.lines;
      for (var r = 0; r < rows; r++) {
        painter.paintLine(
          canvas,
          Offset(0, r * cellH),
          lines[r],
        );
      }
      final picture = recorder.endRecording();

      // 目标 canvas（重放到这里）。
      final targetLayer = ContainerLayer();
      const N = 200;
      const warmup = 30;

      double measureDrawPicture() {
        for (var i = 0; i < warmup; i++) {
          final ctx = PaintingContext(
            targetLayer,
            Rect.fromLTWH(0, 0, viewport.width, viewport.height),
          );
          ctx.canvas.drawPicture(picture);
        }
        final sw = Stopwatch()..start();
        for (var i = 0; i < N; i++) {
          final ctx = PaintingContext(
            targetLayer,
            Rect.fromLTWH(0, 0, viewport.width, viewport.height),
          );
          ctx.canvas.drawPicture(picture);
        }
        sw.stop();
        return sw.elapsedMicroseconds / N;
      }

      final drawPicUs = measureDrawPicture();
      report('drawPicture(整屏 ~$rows 行缓存) x1', drawPicUs);

      // 对照：画 1 行（模拟 dirty=1 那一帧的增量成本）。
      double measurePaintOneLine() {
        for (var i = 0; i < warmup; i++) {
          final ctx = PaintingContext(
            targetLayer,
            Rect.fromLTWH(0, 0, viewport.width, viewport.height),
          );
          painter.paintLine(ctx.canvas, Offset(0, (rows - 1) * cellH), lines[rows - 1]);
        }
        final sw = Stopwatch()..start();
        for (var i = 0; i < N; i++) {
          final ctx = PaintingContext(
            targetLayer,
            Rect.fromLTWH(0, 0, viewport.width, viewport.height),
          );
          painter.paintLine(ctx.canvas, Offset(0, (rows - 1) * cellH), lines[rows - 1]);
        }
        sw.stop();
        return sw.elapsedMicroseconds / N;
      }

      final oneLineUs = measurePaintOneLine();
      report('paintLine(单行 ~$cols cell) x1', oneLineUs);

      // ignore: avoid_print
      print('  [BENCH-RUN] 比值 drawPicture/paintLine = '
          '${(drawPicUs / oneLineUs).toStringAsFixed(1)}x'
          '${drawPicUs > oneLineUs ? "  ← drawPicture 是大头" : "  ← 单行画更贵"}');
      expect(drawPicUs, greaterThan(0.0));
    });
  });

  group('逐 cell vs 逐行段落 run', () {
    // 目标：同一行内容，对比两种画法的单行成本。
    // A: 现状——逐 cell drawParagraph（_paintLineCells 路径）
    // B: 优化目标——用 ParagraphBuilder 把同色连续文字合成 1 个段落，1 次 draw。

    test('单行：逐 cell vs 逐行合成（纯文本，单色）', () {
      final terminal = Terminal(maxLines: 1000);
      // 写一行 80 个字符的纯文本（单色、单 style）。
      terminal.write('the quick brown fox jumps over the lazy dog 1234567890');
      final line = terminal.buffer.lines[0];

      final painter = TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: const TerminalStyle(fontSize: 14),
        textScaler: TextScaler.noScaling,
      );

      const N = 500;
      const warmup = 50;

      // A: 现状逐 cell。
      double measurePerCell() {
        for (var i = 0; i < warmup; i++) {
          final layer = ContainerLayer();
          final ctx = PaintingContext(layer, Rect.fromLTWH(0, 0, 800, 20));
          painter.paintLine(ctx.canvas, Offset.zero, line);
        }
        final sw = Stopwatch()..start();
        for (var i = 0; i < N; i++) {
          final layer = ContainerLayer();
          final ctx = PaintingContext(layer, Rect.fromLTWH(0, 0, 800, 20));
          painter.paintLine(ctx.canvas, Offset.zero, line);
        }
        sw.stop();
        return sw.elapsedMicroseconds / N;
      }

      // B: 逐行合成（模拟优化后的画法）。
      // 把整行字符拼成一个字符串，用 ParagraphBuilder 一次 layout+draw。
      double measurePerRow() {
        final cellData = CellData.empty();
        final buf = StringBuffer();
        for (var x = 0; x < line.length; x++) {
          line.getCellData(x, cellData);
          final cp = cellData.content & 0x1FFFFF; // codepoint mask 近似
          buf.writeCharCode(cp == 0 ? 0x20 : cp);
        }
        final text = buf.toString();
        // ParagraphBuilder.pushStyle 需要 dart:ui 的 TextStyle（不是 painting 的）。
        final style = ui.TextStyle(
          fontSize: 14,
          color: TerminalThemes.defaultTheme.foreground,
          fontFamily: 'Monospace',
        );

        for (var i = 0; i < warmup; i++) {
          final layer = ContainerLayer();
          final ctx = PaintingContext(layer, Rect.fromLTWH(0, 0, 800, 20));
          final pb = ui.ParagraphBuilder(ui.ParagraphStyle());
          pb.pushStyle(style);
          pb.addText(text);
          final p = pb.build();
          p.layout(ui.ParagraphConstraints(width: 800));
          ctx.canvas.drawParagraph(p, Offset.zero);
        }
        final sw = Stopwatch()..start();
        for (var i = 0; i < N; i++) {
          final layer = ContainerLayer();
          final ctx = PaintingContext(layer, Rect.fromLTWH(0, 0, 800, 20));
          final pb = ui.ParagraphBuilder(ui.ParagraphStyle());
          pb.pushStyle(style);
          pb.addText(text);
          final p = pb.build();
          p.layout(ui.ParagraphConstraints(width: 800));
          ctx.canvas.drawParagraph(p, Offset.zero);
        }
        sw.stop();
        return sw.elapsedMicroseconds / N;
      }

      final perCell = measurePerCell();
      final perRow = measurePerRow();
      report('A 逐 cell (现状) 单行', perCell);
      report('B 逐行合成 (目标) 单行', perRow);
      // ignore: avoid_print
      print('  [BENCH-RUN] 单行加速比 = ${(perCell / perRow).toStringAsFixed(1)}x'
          '（越大说明 run 化收益越高）');
      expect(perCell, greaterThan(0.0));
    });
  });
}
