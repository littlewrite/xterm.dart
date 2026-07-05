import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

/// 验证"mode=2 原地编辑不擦掉之前内容"——修复用户报告的 bug：
///   "刚开始按回车，光换行，之前的内容没了；scroll 一下又好了。"
///
/// 根因（见 docs/perf-optimization.md "缓存 stale 修复"）：
/// mode=2（原地编辑、不平移）每帧 drawPicture(缓存) 当底，缓存画的是
/// "录制时的旧内容"。若只重画本帧 dirty，上一帧画过的 delta 行会被缓存里
/// 的旧内容擦掉，表现为内容逐帧从上往下消失。
///
/// 修复：维护 _dirtySinceCache（自缓存以来编辑过的行）。mode=2 每帧重画
/// dirty ∪ (stale ∩ 视口)，并把本帧 dirty 累加进 stale。
///
/// 本测试复现：每帧只 dirty 一行（在不同可见行写一个字，不滚动 → mode=2），
/// 验证 painted 集合**逐帧累积**（修复版），而不是每帧只剩本帧 dirty（bug 版）。
void main() {
  testWidgets('连续原地编辑（mode=2）每帧重画累积 stale 行，不擦掉之前行',
      (tester) async {
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

    // 视口约 17 行。写 15 行短内容填满视口但**不超出**（不产生 scrollback、
    // 不触发 mode=1 滚动），让缓存稳定在 mode=0 全画后停在该视口。
    terminal.write(List.generate(15, (i) => 'L$i').join('\r\n'));
    await tester.pump();

    final render = tester.allRenderObjects.whereType<RenderTerminal>().first;

    // 在不同可见行各写一个字。terminal.write 走批量 flush → notifyListeners
    // 触发真实重绘。setCursor 不触发 geometry 变化，单字符只 dirty 一行，
    // 不滚动 → 走 mode=2（原地编辑）。
    final paintedPerFrame = <Set<int>>[];
    final modes = <int>[];
    for (var i = 0; i < 4; i++) {
      terminal.setCursor(0, i); // 可见行 i
      terminal.write(String.fromCharCode(0x41 + i)); // A/B/C/D
      await tester.pump();
      paintedPerFrame.add(Set<int>.from(render.dbgLastPaintedLines ?? const {}));
      modes.add(render.dbgLastPaintMode);
    }

    // 过滤掉首帧可能的 mode=0 全画，只看后续 mode=2 帧。
    final mode2Frames = <Set<int>>[];
    for (var i = 0; i < paintedPerFrame.length; i++) {
      if (modes[i] == 2) mode2Frames.add(paintedPerFrame[i]);
    }
    expect(mode2Frames.length, greaterThanOrEqualTo(3),
        reason: '应至少有 3 帧 mode=2 才能验证 stale 累积；实际 modes=$modes');

    // 关键断言：mode=2 帧的 painted 必须**逐帧累积**——
    // 第 N+1 帧 painted ⊇ 第 N 帧的 painted（之前编辑过的行作为 stale 仍被重画）。
    //
    // bug 版（只画本帧 dirty，不画 stale）：每帧 painted 互不包含、各自独立。
    // 修复版（画 dirty ∪ stale）：painted 逐帧增长。
    for (var i = 1; i < mode2Frames.length; i++) {
      final prev = mode2Frames[i - 1];
      final curr = mode2Frames[i];
      expect(curr.containsAll(prev), isTrue,
          reason: 'mode=2 第 $i 帧 painted=$curr 未包含上一帧 painted=$prev 的全部行——'
              '这些行被缓存里的旧内容擦掉了（内容逐帧消失 bug）。'
              '修复后每帧应重画 dirty ∪ stale，painted 必须逐帧累积。');
    }

    // 进一步：最后一帧 painted 必须比第一帧多（确实累积了 stale）。
    expect(mode2Frames.last.length, greaterThan(mode2Frames.first.length),
        reason: 'mode=2 各帧 painted 行数相同（${mode2Frames.first.length}）——'
            '说明没有累积 stale 行，之前编辑的内容会被缓存擦掉。');
  });
}
