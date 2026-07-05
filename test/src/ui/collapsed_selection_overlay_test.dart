import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('collapsed selection does not force full repaint on typing',
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

    terminal.write(List.generate(15, (i) => 'L$i').join('\r\n'));
    await tester.pump();

    final render = tester.allRenderObjects.whereType<RenderTerminal>().first;

    render.selectCharacters(const CellOffset(0, 0));
    await tester.pump();

    terminal.setCursor(0, 0);
    terminal.write('Z');
    await tester.pump();

    // ignore: avoid_print
    print('  [DIAG-COLLAPSED] mode=${render.dbgLastPaintMode} '
        'painted=${render.dbgLastPaintedLines}');

    expect(render.dbgLastPaintMode, isNot(0),
        reason: 'collapsed selection 不应被当作 overlay，否则单字符更新会退化成全画');
    expect(render.dbgLastPaintedLines, contains(0));
  });

  testWidgets('non-collapsed selection still forces full repaint',
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

    terminal.write(List.generate(15, (i) => 'L$i').join('\r\n'));
    await tester.pump();

    final render = tester.allRenderObjects.whereType<RenderTerminal>().first;

    render.selectBufferRange(
      BufferRangeLine(
        const CellOffset(0, 0),
        const CellOffset(2, 0),
      ),
    );
    await tester.pump();

    terminal.setCursor(0, 0);
    terminal.write('Z');
    await tester.pump();

    // ignore: avoid_print
    print('  [DIAG-SELECTION] mode=${render.dbgLastPaintMode} '
        'painted=${render.dbgLastPaintedLines}');

    expect(render.dbgLastPaintMode, 0, reason: '非空选区仍应强制全画，避免选区高亮和增量覆盖冲突');
  });
}
