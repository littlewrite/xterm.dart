import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

/// 复现用户反馈的 bug：
/// "输入命令、执行后，不显示最新行，需手动 scroll 才显示"
///
/// 验证：① stick-to-bottom 让光标行进入视口；② paint 实际重画了最新行。
/// 若 paint 没重画最新行（即使它在视口内），用户就看不到——正是 bug 现象。
void main() {
  testWidgets('最新输出行在视口内时 paint 必须重画它', (tester) async {
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

    // 填满视口（~17 行可见）再多写，确保触发滚动（scrollBack > 0）。
    terminal.write(List.generate(20, (i) => 'fill $i').join('\r\n'));
    await tester.pump();

    // 再输出一行新内容（模拟命令执行输出最后一行）。
    terminal.write('THE NEW LINE');
    await tester.pump();

    // ① 视口应在底部（stick-to-bottom 生效）。
    expect(scrollController.position.pixels,
        closeTo(scrollController.position.maxScrollExtent, 1.0),
        reason: '持续输出后视口应跟随到底部');

    // ② 找到 RenderTerminal（RenderObject，非 Widget），验证最新行被 paint 重画。
    final render = tester.allRenderObjects.whereType<RenderTerminal>().first;

    // ignore: avoid_print
    print('  [DIAG] height=${terminal.buffer.height} '
        'viewHeight=${terminal.viewHeight} '
        'scrollBack=${terminal.buffer.scrollBack} '
        'cursorAbsY=${terminal.buffer.absoluteCursorY} '
        'mode=${render.dbgLastPaintMode} '
        'painted=${render.dbgLastPaintedLines}');

    // 最新内容行（光标所在行，'THE NEW LINE' 写在这里）必须被画。
    final cursorAbsY = terminal.buffer.absoluteCursorY;
    expect(render.dbgLastPaintedLines, isNotNull);
    expect(render.dbgLastPaintedLines!, contains(cursorAbsY),
        reason: '最新内容行（光标行）必须被 paint 重画，否则用户看不到最新输出。'
            'cursorAbsY=$cursorAbsY 但 painted=${render.dbgLastPaintedLines}');
  });

  // 专门针对 scroll 平移复用路径（mode=1）的场景：
  // 缓存已建立后，来一个换行（光标在底部）触发 insert + 视口下移，
  // 此时走 scroll 复用，新露出的底部行必须被画。
  testWidgets('scroll 平移复用：新露出的底部行必须被重画', (tester) async {
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

    // 填满视口，光标到底部，建立缓存。
    terminal.write(List.generate(20, (i) => 'fill $i').join('\r\n'));
    await tester.pump();

    final render = tester.allRenderObjects.whereType<RenderTerminal>().first;

    // 现在光标在底部。写一行新内容 + 换行 → 触发 insert + 视口下移。
    // 这帧应该走 scroll 复用（mode=1）。
    terminal.write('SCROLL TEST\r\n');
    await tester.pump();

    // ignore: avoid_print
    print('  [DIAG2] height=${terminal.buffer.height} '
        'viewHeight=${terminal.viewHeight} '
        'scrollBack=${terminal.buffer.scrollBack} '
        'cursorAbsY=${terminal.buffer.absoluteCursorY} '
        'mode=${render.dbgLastPaintMode} '
        'painted=${render.dbgLastPaintedLines}');

    // SCROLL TEST 写在的光标行（写之前的 cursorAbsY）必须被画。
    // 以及 \n 后新露出的底部行。
    // 视口最后一行（底部）必须被画——它是最新可见内容。
    final scrollBack = terminal.buffer.scrollBack;
    final viewHeight = terminal.viewHeight;
    final bottomVisibleLine = scrollBack + viewHeight - 1;
    expect(render.dbgLastPaintedLines, isNotNull);
    // 至少，最新写入的内容行（在 \n 之前的光标行）应在画过的集合里。
    // 该行索引 = 当前 cursorAbsY - 1（\n 后光标下移）—— 但若 insert，索引语义复杂。
    // 简化断言：画过的行数应 >= 1，且包含底部可见行附近。
    expect(render.dbgLastPaintedLines!.isNotEmpty, isTrue,
        reason: 'scroll 复用帧应至少画了新露出的行');
    expect(render.dbgLastPaintedLines!, anyOf(contains(bottomVisibleLine),
            contains(bottomVisibleLine - 1)),
        reason: '底部可见行区域必须被重画');
  });

  // 逐字符输入 + 输出（最贴近真实交互），验证最终最新行可见。
  testWidgets('逐字符交互：命令执行后最新输出行可见', (tester) async {
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

    final render = tester.allRenderObjects.whereType<RenderTerminal>().first;

    // 先填满，让光标到底部、缓存建立。
    terminal.write(List.generate(20, (i) => 'fill $i').join('\r\n'));
    await tester.pump();

    // 模拟用户输入命令 + 回车 + 程序输出（逐段 write，每段 pump）。
    for (final ch in 'cmd'.split('')) {
      terminal.write(ch);
      await tester.pump();
    }
    terminal.write('\r\n');
    await tester.pump();

    for (var i = 0; i < 5; i++) {
      terminal.write('output line $i\r\n');
      await tester.pump();
    }
    terminal.write('\$ '); // 新提示符（最新可见内容）
    await tester.pump();

    // ignore: avoid_print
    print('  [DIAG3] height=${terminal.buffer.height} '
        'viewHeight=${terminal.viewHeight} '
        'scrollBack=${terminal.buffer.scrollBack} '
        'cursorAbsY=${terminal.buffer.absoluteCursorY} '
        'mode=${render.dbgLastPaintMode} '
        'painted=${render.dbgLastPaintedLines}');

    expect(scrollController.position.pixels,
        closeTo(scrollController.position.maxScrollExtent, 1.0),
        reason: '交互后视口应在底部');
    expect(render.dbgLastPaintedLines!,
        contains(terminal.buffer.absoluteCursorY),
        reason: '最新提示符行必须被画');
  });
}
