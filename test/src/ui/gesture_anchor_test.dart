import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('mouse selection base anchor is released after pointer up',
      (tester) async {
    final terminal = Terminal();
    terminal.resize(20, 5, 10, 16);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 200,
          child: TerminalView(
            terminal,
            autoResize: false,
            showToolbar: false,
          ),
        ),
      ),
    );

    int anchorCount() {
      var count = 0;
      for (var i = 0; i < terminal.buffer.lines.length; i++) {
        count += terminal.buffer.lines[i].anchors.length;
      }
      return count;
    }

    final initialAnchorCount = anchorCount();
    final position = tester.getCenter(find.byType(TerminalView));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: position);

    await gesture.down(position);
    expect(anchorCount(), initialAnchorCount + 1);

    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));

    expect(anchorCount(), initialAnchorCount);

    await gesture.removePointer();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));
  });

  testWidgets('mouse selection base anchor is released on widget disposal',
      (tester) async {
    final terminal = Terminal();
    terminal.resize(20, 5, 10, 16);

    await tester.pumpWidget(
      MaterialApp(
        home: TerminalView(
          terminal,
          autoResize: false,
          showToolbar: false,
        ),
      ),
    );

    final position = tester.getCenter(find.byType(TerminalView));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: position);
    await gesture.down(position);

    expect(
      List.generate(
        terminal.buffer.lines.length,
        (index) => terminal.buffer.lines[index].anchors.length,
      ).reduce((total, count) => total + count),
      1,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 100));

    for (var i = 0; i < terminal.buffer.lines.length; i++) {
      expect(terminal.buffer.lines[i].anchors, isEmpty);
    }

    await gesture.removePointer();
  });
}
