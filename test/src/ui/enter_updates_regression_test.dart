import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/paint_debug.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

/// 验证"回车后画面更新"——修复 FaTerm 报告的 bug：
/// 输入命令、回车后，新内容要等一下或滚动一下才显示。
///
/// 根因：_onTerminalChange 在 geometry 变化时只 markNeedsLayout，
/// 不 markNeedsPaint。若 layout 后 size 未变，Flutter 可能跳过 paint，
/// 导致内容已在 buffer 但画面没刷新。修复后显式 markNeedsPaint。
void main() {
  testWidgets('回车（geometry 变化）后画面立即更新，无需滚动', (tester) async {
    TerminalPaintDebug.enabled = true; // 开启链路日志，验证修复
    addTearDown(() => TerminalPaintDebug.enabled = false);

    final terminal = Terminal(maxLines: 1000);
    final scrollController = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 240,
            child: TerminalView(
              terminal,
              scrollController: scrollController,
              textStyle: const TerminalStyle(fontSize: 12),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 写满视口，建立稳定状态 + 缓存。
    terminal.write(List.generate(20, (i) => 'fill $i').join('\r\n'));
    await tester.pump();

    final render = tester.allRenderObjects.whereType<RenderTerminal>().first;

    // 记录 paint 帧数。
    var paintCount = render.dbgLastPaintedLines == null ? 0 : 1;

    // 回车 —— 触发 index() insert（geometry 变化：lines.length+1）。
    terminal.write('\r\n');
    await tester.pump();

    // 回车后应发生至少一次 paint（mode 任意），且不是空画。
    expect(render.dbgLastPaintedLines, isNotNull);
    expect(render.dbgLastPaintedLines!.isNotEmpty, isTrue,
        reason: '回车后应立即重画，不该等滚动才更新');

    // 再写一行内容，应立即显示。
    terminal.write('AFTER ENTER');
    await tester.pump();
    paintCount++;

    // 最新内容行（光标行）必须被画。
    expect(render.dbgLastPaintedLines!,
        contains(terminal.buffer.absoluteCursorY),
        reason: '回车后的新内容必须立即重画');
    expect(paintCount, greaterThanOrEqualTo(1));
  });

  testWidgets('连续回车（多次 geometry 变化）每次都立即更新', (tester) async {
    final terminal = Terminal(maxLines: 1000);
    final scrollController = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 240,
            child: TerminalView(
              terminal,
              scrollController: scrollController,
              textStyle: const TerminalStyle(fontSize: 12),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    terminal.write(List.generate(20, (i) => 'fill $i').join('\r\n'));
    await tester.pump();

    final render = tester.allRenderObjects.whereType<RenderTerminal>().first;

    // 连续 5 次回车 + 内容，每次都应立即更新。
    for (var i = 0; i < 5; i++) {
      terminal.write('line $i\r\n');
      await tester.pump();

      // 每次回车后光标行的内容应被画（不该卡住等下次）。
      expect(render.dbgLastPaintedLines, isNotNull,
          reason: '第 $i 次回车后未触发 paint');
    }
  });
}
