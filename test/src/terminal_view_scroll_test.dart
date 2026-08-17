import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('reports wheel scroll events when scroll input is enabled',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1006;1000h');

    final controller = TerminalController(
      pointerInputs: PointerInputs.all(),
      vsync: tester,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
          ),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(0, 1),
      ),
    );
    await tester.pump();

    expect(output, hasLength(1));
    expect(output.first, '\x1B[<65;1;1M');
  });

  testWidgets('can invert wheel scroll reports', (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1006;1000h');

    final controller = TerminalController(
      pointerInputs: PointerInputs.all(),
      vsync: tester,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
            invertWheelScroll: true,
          ),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(0, 1),
      ),
    );
    await tester.pump();

    expect(output, hasLength(1));
    expect(output.first, '\x1B[<64;1;1M');
  });

  testWidgets('can slow wheel scroll reports', (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1006;1000h');

    final controller = TerminalController(
      pointerInputs: PointerInputs.all(),
      vsync: tester,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
            textStyle: const TerminalStyle(fontSize: 20),
            wheelScrollLinesPerEvent: 0.5,
          ),
        ),
      ),
    );

    for (var index = 0; index < 2; index++) {
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(8, 8),
          scrollDelta: Offset(0, 40),
        ),
      );
    }
    await tester.pump();

    expect(output, hasLength(1));
    expect(output.first, '\x1B[<65;1;1M');
  });

  testWidgets('accumulates low-speed wheel scroll reports', (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1006;1000h');

    final controller = TerminalController(
      pointerInputs: PointerInputs.all(),
      vsync: tester,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
            textStyle: const TerminalStyle(fontSize: 20),
            wheelScrollLinesPerEvent: 0.05,
          ),
        ),
      ),
    );

    for (var index = 0; index < 30; index++) {
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(8, 8),
          scrollDelta: Offset(0, 20),
        ),
      );
    }
    await tester.pump();

    expect(output, hasLength(1));
    expect(output.single, '\x1B[<65;1;1M');
  });

  testWidgets('can disable terminal wheel scroll reports', (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1006;1000h');

    final controller = TerminalController(
      pointerInputs: PointerInputs.all(),
      vsync: tester,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
            wheelScrollLinesPerEvent: 0,
          ),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(0, 40),
      ),
    );
    await tester.pump();

    expect(output, isEmpty);
  });

  testWidgets(
      'simulates alternate buffer scroll when wheel reports are disabled',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1049h');

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: TerminalView(
            terminal,
            wheelScrollLinesPerEvent: 0,
          ),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(0, 20),
      ),
    );
    await tester.pump();

    expect(output, contains('\x1B[B'));
  });

  testWidgets('alternate buffer scroll uses local pointer coordinates',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1006;1000h\x1b[?1049h');

    await tester.pumpWidget(
      MaterialApp(
        home: Padding(
          padding: const EdgeInsets.only(left: 120, top: 80),
          child: SizedBox(
            width: 300,
            height: 200,
            child: TerminalView(terminal),
          ),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(128, 88),
        scrollDelta: Offset(0, 20),
      ),
    );
    await tester.pump();

    expect(output, hasLength(1));
    expect(output.single, '\x1B[<65;1;1M');
  });

  testWidgets('main buffer wheel scrolls viewport when reports are disabled',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);
    final scrollController = ScrollController();

    terminal.write('\x1b[?1006;1000h');

    final controller = TerminalController(
      pointerInputs: PointerInputs.all(),
      vsync: tester,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 120,
            child: TerminalView(
              terminal,
              controller: controller,
              scrollController: scrollController,
              textStyle: const TerminalStyle(fontSize: 12),
              wheelScrollLinesPerEvent: 0,
            ),
          ),
        ),
      ),
    );

    final text = List.generate(40, (index) => 'line $index').join('\r\n');
    terminal.write(text);
    await tester.pump();

    expect(scrollController.position.maxScrollExtent, greaterThan(0));
    final initialOffset = scrollController.position.pixels;

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(0, -60),
      ),
    );
    await tester.pump();

    expect(output, isEmpty);
    expect(scrollController.position.pixels, lessThan(initialOffset));
  });

  testWidgets('alternate buffer mouse wheel reports like trackpad',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1006;1000h\x1b[?1049h');

    final controller = TerminalController(
      pointerInputs: PointerInputs.all(),
      vsync: tester,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: TerminalView(
            terminal,
            controller: controller,
            textStyle: const TerminalStyle(fontSize: 20),
          ),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(0, 4),
      ),
    );
    await tester.pump();

    expect(output, isNotEmpty);
    expect(output.first, '\x1B[<65;1;1M');
  });

  testWidgets('alternate buffer reports both axes of diagonal wheel scroll',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1006;1000h\x1b[?1049h');

    final controller = TerminalController(
      pointerInputs: PointerInputs.all(),
      vsync: tester,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: TerminalView(terminal, controller: controller),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(30, 20),
      ),
    );
    await tester.pump();

    expect(output, contains('\x1B[<65;1;1M'));
    expect(output, contains('\x1B[<67;1;1M'));
  });

  testWidgets('clears fractional wheel steps when wheel direction changes',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1006;1000h');

    final controller = TerminalController(
      pointerInputs: PointerInputs.all(),
      vsync: tester,
    );

    Widget buildTerminal({required bool invertWheelScroll}) {
      return MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
            invertWheelScroll: invertWheelScroll,
            textStyle: const TerminalStyle(fontSize: 20),
            wheelScrollLinesPerEvent: 0.5,
          ),
        ),
      );
    }

    await tester.pumpWidget(buildTerminal(invertWheelScroll: false));
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(0, 40),
      ),
    );
    await tester.pump();
    expect(output, isEmpty);

    await tester.pumpWidget(buildTerminal(invertWheelScroll: true));
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(0, -40),
      ),
    );
    await tester.pump();

    expect(output, isEmpty);
  });

  testWidgets('does not queue capped fractional wheel reports', (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1006;1000h');

    final controller = TerminalController(
      pointerInputs: PointerInputs.all(),
      vsync: tester,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
            textStyle: const TerminalStyle(fontSize: 20),
            wheelScrollLinesPerEvent: 0.5,
          ),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(0, 8080),
      ),
    );
    await tester.pump();
    expect(output, hasLength(50));

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(0, 1),
      ),
    );
    await tester.pump();

    expect(output, hasLength(50));
  });

  testWidgets('alternate buffer mouse wheel falls back to arrow keys',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1049h');

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: TerminalView(terminal),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(8, 8),
        scrollDelta: Offset(0, 20),
      ),
    );
    await tester.pump();

    expect(output.join(), contains('\x1B[B'));
  });

  testWidgets('alternate buffer selection auto-scroll reports wheel events',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add, maxLines: 200);

    terminal.write('\x1b[?1006;1000h\x1b[?1049h');
    terminal.write(List.generate(80, (index) => 'line $index').join('\r\n'));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 140,
            child: TerminalView(
              terminal,
              textStyle: const TerminalStyle(fontSize: 12),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final rect = tester.getRect(find.byType(TerminalView));
    final start = rect.topLeft + const Offset(8, 8);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: start);
    await tester.pump();
    await gesture.down(start);
    await tester.pump();
    await gesture.moveTo(rect.bottomLeft - const Offset(-8, 4));
    await tester.pump(const Duration(milliseconds: 220));
    await gesture.up();
    await tester.pump();

    expect(output.where((item) => item.contains('[<65;')), isNotEmpty);
  });

  testWidgets(
    'alternate buffer selection auto-scroll falls back to arrow keys when wheel reporting is unavailable',
    (tester) async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add, maxLines: 200);

      terminal.write('\x1b[?1049h\x1b[?1007h');
      terminal.write(List.generate(80, (index) => 'line $index').join('\r\n'));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 140,
              child: TerminalView(
                terminal,
                textStyle: const TerminalStyle(fontSize: 12),
                wheelScrollLinesPerEvent: 0,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final rect = tester.getRect(find.byType(TerminalView));
      final start = rect.topLeft + const Offset(8, 8);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: start);
      await tester.pump();
      await gesture.down(start);
      await tester.pump();
      await gesture.moveTo(rect.bottomLeft - const Offset(-8, 4));
      await tester.pump(const Duration(milliseconds: 220));
      await gesture.up();
      await tester.pump();

      expect(output.join(), contains('\x1B[B'));
    },
  );

  testWidgets('reports trackpad pan-zoom scroll as wheel events',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal(onOutput: output.add);

    terminal.write('\x1b[?1006;1000h');

    final controller = TerminalController(
      pointerInputs: PointerInputs.all(),
      vsync: tester,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
          ),
        ),
      ),
    );

    await tester.sendEventToBinding(
      const PointerPanZoomStartEvent(
        position: Offset(8, 8),
      ),
    );
    await tester.sendEventToBinding(
      const PointerPanZoomUpdateEvent(
        position: Offset(8, 8),
        pan: Offset(0, 20),
        panDelta: Offset(0, 20),
      ),
    );
    await tester.sendEventToBinding(
      const PointerPanZoomEndEvent(
        position: Offset(8, 8),
      ),
    );
    await tester.pump();

    expect(output, isNotEmpty);
    expect(output.first, '\x1B[<65;1;1M');
  });
}
