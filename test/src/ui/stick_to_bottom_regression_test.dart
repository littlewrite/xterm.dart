import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

/// 回归：高速连续输出时视口必须 stick 到底部，且最新行在 buffer 中完整可读。
/// Windows 上曾出现 scroll 跟丢 + 残影叠字，看起来像输出和 prompt 混在一起。
void main() {
  testWidgets('rapid multi-chunk writes keep viewport at bottom', (tester) async {
    final terminal = Terminal(maxLines: 2000);
    final scrollController = ScrollController();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 640,
            height: 360,
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

    // 模拟 Windows 上大量小 chunk 连续输出（如 git help）。
    for (var chunk = 0; chunk < 40; chunk++) {
      final lines = List.generate(
        5,
        (i) => 'chunk-$chunk line-$i ${'x' * 40}',
      ).join('\r\n');
      terminal.write('$lines\r\n');
    }
    terminal.write('PS D:\\dart\\FaTerm> ');
    await tester.pump();

    expect(
      scrollController.position.pixels,
      closeTo(scrollController.position.maxScrollExtent, 1.0),
      reason: '高频输出后视口应 stick 到底部',
    );

    final bottomText = terminal.buffer.getText(
      BufferRangeLine(
        CellOffset(0, terminal.buffer.absoluteCursorY),
        CellOffset(terminal.viewWidth, terminal.buffer.absoluteCursorY),
      ),
    );
    expect(
      bottomText,
      contains('PS D:\\dart\\FaTerm>'),
      reason: '最新 prompt 应完整落在光标行，而不是和其他输出混行',
    );
  });

  testWidgets('geometry change still schedules paint for latest content',
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

    terminal.write(List.generate(20, (i) => 'fill $i').join('\r\n'));
    await tester.pump();

    terminal.write('\r\nTHE NEW LINE');
    await tester.pump();

    expect(
      scrollController.position.pixels,
      closeTo(scrollController.position.maxScrollExtent, 1.0),
    );

    final render = tester.allRenderObjects.whereType<RenderTerminal>().first;
    expect(render.debugNeedsPaint, isFalse);
    expect(terminal.buffer.getText(), contains('THE NEW LINE'));
  });
}
