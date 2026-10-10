import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';
import 'package:xterm/src/ui/gesture/gesture_handler.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

import '../_fixture/_fixture.dart';

@GenerateNiceMocks([MockSpec<TerminalInputHandler>()])
import 'terminal_view_test.mocks.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('resolves a composing rect at the end of wrapped preedit text', () {
    expect(
      RenderTerminal.resolveComposingEndOffset(
        startOffset: const Offset(80, 0),
        text: 'abc',
        viewWidth: 10,
        cellSize: const Size(10, 20),
      ),
      const Offset(10, 20),
    );
  });

  testWidgets(
    'htop golden test',
    (tester) async {
      final terminal = Terminal();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal),
        ),
      ));

      terminal.write(TestFixtures.htop_80x25_3s());
      await tester.pump();

      await expectLater(
        find.byType(TerminalView),
        matchesGoldenFile('_goldens/htop_80x25_3s.png'),
      );
    },
    skip: !Platform.isMacOS,
  );

  testWidgets(
    'color golden test',
    (tester) async {
      final terminal = Terminal();

      // terminal.lineFeedMode = true;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            textStyle: TerminalStyle(fontSize: 8),
          ),
        ),
      ));

      terminal.write(TestFixtures.colors().replaceAll('\n', '\r\n'));
      await tester.pump();

      await expectLater(
        find.byType(TerminalView),
        matchesGoldenFile('_goldens/colors.png'),
      );
    },
    skip: !Platform.isMacOS,
  );

  group('TerminalView.readOnly', () {
    testWidgets('works', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal, readOnly: true, autofocus: true),
        ),
      ));

      // https://github.com/flutter/flutter/issues/11181#issuecomment-314936646
      await tester.tap(find.byType(TerminalView));
      await tester.pump(Duration(seconds: 1));

      binding.testTextInput.enterText('ls -al');
      await binding.idle();

      expect(terminalOutput.join(), isEmpty);
    });

    testWidgets('does not block input when false', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal, readOnly: false, autofocus: true),
        ),
      ));

      // https://github.com/flutter/flutter/issues/11181#issuecomment-314936646
      await tester.tap(find.byType(TerminalView));
      await tester.pump(Duration(seconds: 1));

      binding.testTextInput.enterText('ls -al');
      await binding.idle();

      expect(terminalOutput.join(), 'ls -al');
    });

    testWidgets('forwards hardware keys when false', (tester) async {
      final inputHandler = MockTerminalInputHandler();
      when(inputHandler.call(any)).thenAnswer((_) => 'AAA');

      final terminalOutput = <String>[];
      final terminal = Terminal(
        inputHandler: inputHandler,
        onOutput: terminalOutput.add,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            hardwareKeyboardOnly: true,
            autofocus: true,
          ),
        ),
      ));

      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(seconds: 1));

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();

      expect(terminalOutput.join(), 'AAA');
    });

    testWidgets('does not forward hardware keys when true', (tester) async {
      // hardwareKeyboardOnly attaches CustomTextEdit for the toolbar, which used
      // to leave its hardware-key path (and the character-insert fallback)
      // writing to the PTY even though readOnly means "no input".
      final inputHandler = MockTerminalInputHandler();
      when(inputHandler.call(any)).thenAnswer((_) => 'AAA');

      final terminalOutput = <String>[];
      final terminal = Terminal(
        inputHandler: inputHandler,
        onOutput: terminalOutput.add,
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            readOnly: true,
            hardwareKeyboardOnly: true,
            autofocus: true,
          ),
        ),
      ));

      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(seconds: 1));

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pump();

      expect(terminalOutput.join(), isEmpty);
    });
  });

  group('TerminalView.focusNode', () {
    testWidgets('is not listened when terminal is disposed', (tester) async {
      final terminal = Terminal();

      final focusNode = FocusNode();

      final isActive = ValueNotifier(true);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: isActive,
            builder: (context, isActive, child) {
              if (!isActive) {
                return Container();
              }
              return TerminalView(
                terminal,
                focusNode: focusNode,
                autofocus: true,
              );
            },
          ),
        ),
      ));

      // ignore: invalid_use_of_protected_member
      expect(focusNode.hasListeners, isTrue);

      isActive.value = false;
      await tester.pumpAndSettle();

      // ignore: invalid_use_of_protected_member
      expect(focusNode.hasListeners, isFalse);
    });

    testWidgets('does not dispose external focus node', (tester) async {
      final terminal = Terminal();

      final focusNode = FocusNode();

      final isActive = ValueNotifier(true);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: isActive,
            builder: (context, isActive, child) {
              if (!isActive) {
                return Container();
              }
              return TerminalView(
                terminal,
                focusNode: focusNode,
                autofocus: true,
              );
            },
          ),
        ),
      ));

      isActive.value = false;
      await tester.pumpAndSettle();

      expect(() => focusNode.addListener(() {}), returnsNormally);
    });
  });

  group('TerminalController.pointerInputs', () {
    testWidgets('works', (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      // enable mouse reporting
      terminal.write('\x1b[?1000h');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.all(),
      );
      addTearDown(terminalView.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              controller: terminalView,
            ),
          ),
        ),
      );

      final pointer = TestPointer(1, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(pointer.down(Offset(1, 1)));

      await tester.pumpAndSettle();

      expect(output, isNotEmpty);
    });

    // The up-event path is tested at the terminal level in
    // terminal_test.dart: 'reports up events in normal tracking mode'.

    // The onTapUp callback always-fires guarantee is enforced by the
    // forceCallback: true parameter in the _tapUp call inside onTapUp.
    // It is verified by code review: the path is
    //   onTapUp → _tapUp(..., forceCallback: true)
    //   → callback?.call(details)  (always reached when forceCallback is true)
    //
    // Integration testing of the full GestureDetector → onTapUp → _tapUp
    // → callback chain requires reliable tap gesture recognition in widget
    // tests, which is impractical with the Listener+GestureDetector setup.

    testWidgets('does not respond when disabled', (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      // enable mouse reporting
      terminal.write('\x1b[?1000h');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.none(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              controller: terminalView,
            ),
          ),
        ),
      );

      final pointer = TestPointer(1, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(pointer.down(Offset(1, 1)));

      await tester.pumpAndSettle();

      expect(output, isEmpty);
    });

    testWidgets('reports mouse drag when drag input is enabled',
        (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1006;1002h');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.all(),
      );
      addTearDown(terminalView.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              controller: terminalView,
            ),
          ),
        ),
      );

      final renderTerminal = tester
          .state<TerminalViewState>(
            find.byType(TerminalView),
          )
          .renderTerminal;
      final cellSize = renderTerminal.cellSize;
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      final downOffset = Offset(cellSize.width / 2, cellSize.height / 2);
      final dragOffset = Offset(cellSize.width * 1.5, cellSize.height / 2);

      await tester.sendEventToBinding(pointer.down(downOffset));
      await tester.sendEventToBinding(pointer.move(dragOffset));
      await tester.pumpAndSettle();

      expect(output, contains('\x1B[<32;2;1M'));
    });

    testWidgets(
      'falls back to local selection when drag reporting is enabled but motion is unsupported',
      (tester) async {
        final output = <String>[];
        final terminal = Terminal(onOutput: output.add);

        terminal.write('\x1b[?1000h');
        terminal.write('hello world');

        final terminalView = TerminalController(
          pointerInputs: PointerInputs.all(),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalView(
                terminal,
                controller: terminalView,
              ),
            ),
          ),
        );
        await tester.pump();

        final rect = tester.getRect(find.byType(TerminalView));
        final start = rect.topLeft + const Offset(8, 8);
        final end = rect.topLeft + const Offset(80, 8);
        final pointer = TestPointer(1, PointerDeviceKind.mouse);

        await tester.sendEventToBinding(pointer.down(start));
        await tester.sendEventToBinding(pointer.move(end));
        await tester.pump();

        expect(output, isNotEmpty);
        expect(output.any((item) => item.contains('[<32;')), isFalse);
        expect(terminalView.selection, isNotNull);
        expect(terminal.buffer.getText(terminalView.selection!), isNotEmpty);
        // The pointer never goes up, so let the 40ms double-tap tracker expire.
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'allows local selection with PointerInputs.all when mouse mode is off',
      (tester) async {
        final output = <String>[];
        final terminal = Terminal(onOutput: output.add);
        terminal.write('hello world');

        final terminalView = TerminalController(
          pointerInputs: PointerInputs.all(),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalView(
                terminal,
                controller: terminalView,
              ),
            ),
          ),
        );
        await tester.pump();

        final rect = tester.getRect(find.byType(TerminalView));
        final start = rect.topLeft + const Offset(8, 8);
        final end = rect.topLeft + const Offset(80, 8);
        final pointer = TestPointer(1, PointerDeviceKind.mouse);

        await tester.sendEventToBinding(pointer.down(start));
        await tester.sendEventToBinding(pointer.move(end));
        await tester.pump();

        expect(output, isEmpty);
        expect(terminalView.selection, isNotNull);
        expect(terminal.buffer.getText(terminalView.selection!), isNotEmpty);
        // The pointer never goes up, so let the 40ms double-tap tracker expire.
        await tester.pumpAndSettle();
      },
    );

    testWidgets('reports mouse up after drag when drag input is enabled',
        (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1006;1002h');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.all(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              controller: terminalView,
            ),
          ),
        ),
      );

      final renderTerminal = tester
          .state<TerminalViewState>(
            find.byType(TerminalView),
          )
          .renderTerminal;
      final cellSize = renderTerminal.cellSize;
      final rect = tester.getRect(find.byType(TerminalView));
      final downOffset =
          rect.topLeft + Offset(cellSize.width / 2, cellSize.height / 2);
      final dragOffset =
          rect.topLeft + Offset(cellSize.width * 1.5, cellSize.height / 2);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: downOffset);
      await tester.pump();
      await gesture.down(downOffset);
      await tester.pump();
      await gesture.moveTo(dragOffset);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      // Order matters: a fast drag must not reach the program as motion and a
      // release for a button it was never told was down.
      expect(output, ['\x1B[<0;1;1M', '\x1B[<32;2;1M', '\x1B[<0;2;1m']);
      // Let the double-tap recognizer's 40ms tracker expire.
      await tester.pumpAndSettle();
    });

    testWidgets(
      'still reports mouse up after drag when Shift is pressed before release',
      (tester) async {
        final output = <String>[];

        final terminal = Terminal(onOutput: output.add);
        terminal.write('\x1b[?1006;1002h');

        final terminalView = TerminalController(
          pointerInputs: PointerInputs.all(),
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalView(
                terminal,
                controller: terminalView,
              ),
            ),
          ),
        );
        await tester.pump();

        final renderTerminal = tester
            .state<TerminalViewState>(
              find.byType(TerminalView),
            )
            .renderTerminal;
        final cellSize = renderTerminal.cellSize;
        final rect = tester.getRect(find.byType(TerminalView));
        final downOffset =
            rect.topLeft + Offset(cellSize.width / 2, cellSize.height / 2);
        final dragOffset =
            rect.topLeft + Offset(cellSize.width * 1.5, cellSize.height / 2);

        final gesture =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: downOffset);
        await tester.pump();
        await gesture.down(downOffset);
        await tester.pump();
        await gesture.moveTo(dragOffset);
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        await gesture.up();
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

        // Order matters: a fast drag must not reach the program as motion and a
        // release for a button it was never told was down.
        expect(output, ['\x1B[<0;1;1M', '\x1B[<32;2;1M', '\x1B[<0;2;1m']);
        // Let the double-tap recognizer's 40ms tracker expire.
        await tester.pumpAndSettle();
      },
    );

    testWidgets('Shift pressed mid-drag starts local selection',
        (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);
      terminal.write('\x1b[?1006;1002h');
      terminal.write('hello world');
      final key = GlobalKey<TerminalViewState>();

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.all(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: terminalView,
            ),
          ),
        ),
      );
      await tester.pump();

      final renderTerminal = key.currentState!.renderTerminal;
      final cellSize = renderTerminal.cellSize;
      final rect = tester.getRect(find.byType(TerminalView));
      final downOffset =
          rect.topLeft + Offset(cellSize.width / 2, cellSize.height / 2);
      final appDragOffset =
          rect.topLeft + Offset(cellSize.width * 1.5, cellSize.height / 2);
      final localDragOffset =
          rect.topLeft + Offset(cellSize.width * 4.5, cellSize.height / 2);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: downOffset);
      await tester.pump();
      await gesture.down(downOffset);
      await tester.pump();
      await gesture.moveTo(appDragOffset);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await gesture.moveTo(localDragOffset);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 50));

      expect(output, contains('\x1B[<32;2;1M'));
      expect(output, contains('\x1B[<0;5;1m'));
      expect(terminalView.selection, isNotNull);
      expect(terminal.buffer.getText(terminalView.selection!), isNotEmpty);
      terminalView.dispose();
    });

    testWidgets('falls back to local selection if drag handling stops mid-drag',
        (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);
      terminal.write('\x1b[?1006;1002h');
      terminal.write('hello world');
      final key = GlobalKey<TerminalViewState>();

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.all(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: terminalView,
            ),
          ),
        ),
      );
      await tester.pump();

      final renderTerminal = key.currentState!.renderTerminal;
      final cellSize = renderTerminal.cellSize;
      final rect = tester.getRect(find.byType(TerminalView));
      final downOffset =
          rect.topLeft + Offset(cellSize.width / 2, cellSize.height / 2);
      final appDragOffset =
          rect.topLeft + Offset(cellSize.width * 1.5, cellSize.height / 2);
      final localDragOffset =
          rect.topLeft + Offset(cellSize.width * 4.5, cellSize.height / 2);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: downOffset);
      await tester.pump();
      await gesture.down(downOffset);
      await tester.pump();
      await gesture.moveTo(appDragOffset);
      await tester.pump();
      terminal.write('\x1b[?1002l');
      await gesture.moveTo(localDragOffset);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(output, contains('\x1B[<32;2;1M'));
      expect(terminalView.selection, isNotNull);
      expect(terminal.buffer.getText(terminalView.selection!), isNotEmpty);
      terminalView.dispose();
    });

    testWidgets('reports mouse up when tap-only input becomes local selection',
        (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);
      terminal.write('\x1b[?1006;1002h');
      terminal.write('hello world');
      final key = GlobalKey<TerminalViewState>();

      final terminalView = TerminalController(
        pointerInputs: const PointerInputs({PointerInput.tap}),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: terminalView,
            ),
          ),
        ),
      );
      await tester.pump();

      final renderTerminal = key.currentState!.renderTerminal;
      final cellSize = renderTerminal.cellSize;
      final rect = tester.getRect(find.byType(TerminalView));
      final downOffset =
          rect.topLeft + Offset(cellSize.width / 2, cellSize.height / 2);
      final dragOffset =
          rect.topLeft + Offset(cellSize.width * 1.5, cellSize.height / 2);

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.down(downOffset));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendEventToBinding(pointer.move(dragOffset));
      await tester.pump();
      await tester.sendEventToBinding(pointer.up());
      await tester.pump();

      expect(output, contains('\x1B[<0;1;1M'));
      expect(output, contains('\x1B[<0;2;1m'));
      expect(terminalView.selection, isNotNull);
      expect(terminal.buffer.getText(terminalView.selection!), isNotEmpty);
      terminalView.dispose();
    });

    testWidgets(
        'reports mouse up for a fast local drag that misses the tap deadline',
        (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);
      terminal.write('\x1b[?1006;1002h');
      terminal.write('hello world');
      final key = GlobalKey<TerminalViewState>();

      final terminalView = TerminalController(
        pointerInputs: const PointerInputs({PointerInput.tap}),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: terminalView,
            ),
          ),
        ),
      );
      await tester.pump();

      final renderTerminal = key.currentState!.renderTerminal;
      final cellSize = renderTerminal.cellSize;
      final rect = tester.getRect(find.byType(TerminalView));
      final downOffset =
          rect.topLeft + Offset(cellSize.width / 2, cellSize.height / 2);
      final dragOffset =
          rect.topLeft + Offset(cellSize.width * 4.5, cellSize.height / 2);

      // Drag before the tap recognizer's deadline, so onTapDown never runs and
      // only the pointer-down press was sent. The release must still follow.
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.down(downOffset));
      await tester.pump();
      await tester.sendEventToBinding(pointer.move(dragOffset));
      await tester.pump();
      await tester.sendEventToBinding(pointer.up());
      await tester.pump();

      expect(output, contains('\x1B[<0;1;1M'));
      expect(output, contains('\x1B[<0;5;1m'));
      expect(terminalView.selection, isNotNull);
      // Let the double-tap recognizer's 40ms tracker expire.
      await tester.pumpAndSettle();
      terminalView.dispose();
    });

    testWidgets('releases the mouse button when the gesture is cancelled',
        (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);
      terminal.write('\x1b[?1006;1002h');

      final controller = TerminalController(pointerInputs: PointerInputs.all());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal, controller: controller),
          ),
        ),
      );
      await tester.pump();

      final renderTerminal = tester
          .state<TerminalViewState>(find.byType(TerminalView))
          .renderTerminal;
      final cellSize = renderTerminal.cellSize;
      final rect = tester.getRect(find.byType(TerminalView));
      final downOffset =
          rect.topLeft + Offset(cellSize.width / 2, cellSize.height / 2);

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.down(downOffset));
      await tester.pump();
      await tester.sendEventToBinding(pointer.cancel());
      await tester.pump();

      // A cancelled gesture never delivers an up, so the release must be sent
      // here or the PTY keeps the button pressed.
      expect(output, contains('\x1B[<0;1;1M'));
      expect(output, contains('\x1B[<0;1;1m'));
      // Let the double-tap recognizer's 40ms tracker expire.
      await tester.pumpAndSettle();
      controller.dispose();
    });

    testWidgets('Shift+mouse drag prefers local selection over mouse reporting',
        (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1006;1002h');
      terminal.write('hello world');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.all(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              controller: terminalView,
            ),
          ),
        ),
      );
      await tester.pump();

      final rect = tester.getRect(find.byType(TerminalView));
      final start = rect.topLeft + const Offset(8, 8);
      final end = rect.topLeft + const Offset(80, 8);
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(pointer.down(start));
      await tester.sendEventToBinding(pointer.move(end));
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(output, isEmpty);
      expect(terminalView.selection, isNotNull);
      expect(terminal.buffer.getText(terminalView.selection!), isNotEmpty);
      // The pointer never goes up, so let the 40ms double-tap tracker expire.
      await tester.pumpAndSettle();
    });
  });

  group('TerminalView.autofocus', () {
    testWidgets('works', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              autofocus: true,
              focusNode: focusNode,
            ),
          ),
        ),
      );

      expect(focusNode.hasFocus, isTrue);
    });

    testWidgets('works in hardwareKeyboardOnly mode', (tester) async {
      final terminal = Terminal();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              autofocus: true,
              focusNode: focusNode,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );

      expect(focusNode.hasFocus, isTrue);
    });
  });

  group('TerminalView.hardwareKeyboardOnly', () {
    testWidgets('works', (tester) async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              autofocus: true,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);

      expect(output.join(), 'abc');
    });

    testWidgets('keeps the text-editing widget but never opens a connection', (
      tester,
    ) async {
      // The flag means "no soft keyboard", not "no text-editing widget". The
      // selection toolbar lives in that widget, so it has to stay in the tree —
      // and the widget must not open an input connection on its own.
      final terminal = Terminal();
      final key = GlobalKey<TerminalViewState>();

      Future<void> pump({required bool hardwareKeyboardOnly}) {
        return tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalView(
                terminal,
                key: key,
                autofocus: true,
                hardwareKeyboardOnly: hardwareKeyboardOnly,
              ),
            ),
          ),
        );
      }

      await pump(hardwareKeyboardOnly: true);
      await tester.pumpAndSettle();

      expect(key.currentState?.hasInputConnection, isFalse);

      // Turning the flag back off has to bring the connection back on its own,
      // not just leave whatever the host remembers to ask for.
      await pump(hardwareKeyboardOnly: false);
      await tester.pumpAndSettle();

      expect(key.currentState?.hasInputConnection, isTrue);

      await pump(hardwareKeyboardOnly: true);
      await tester.pumpAndSettle();

      expect(key.currentState?.hasInputConnection, isFalse);
    });
  });

  group('TerminalView.selection toolbar', () {
    testWidgets('double click with mouse selects the whole word',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: controller,
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final render = key.currentState!.renderTerminal;
      final gestureState =
          tester.state(find.byType(TerminalGestureHandler)) as dynamic;
      final localPosition = render.getOffset(const CellOffset(1, 0)) +
          Offset(render.cellSize.width / 2, render.cellSize.height / 2);
      final globalPosition =
          tester.getTopLeft(find.byType(TerminalView)) + localPosition;

      gestureState.onDoubleTapDown(
        TapDownDetails(
          globalPosition: globalPosition,
          localPosition: localPosition,
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        controller.selection,
        BufferRangeLine(
          CellOffset(0, 0),
          CellOffset(5, 0),
        ),
      );
      expect(terminal.buffer.getText(controller.selection!), equals('hello'));

      controller.dispose();
    });

    testWidgets('double click on separator falls back to a single character',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: controller,
            ),
          ),
        ),
      );

      terminal.write('foo,bar');
      await tester.pump();

      final render = key.currentState!.renderTerminal;
      final gestureState =
          tester.state(find.byType(TerminalGestureHandler)) as dynamic;
      final localPosition = render.getOffset(const CellOffset(3, 0)) +
          Offset(render.cellSize.width / 2, render.cellSize.height / 2);
      final globalPosition =
          tester.getTopLeft(find.byType(TerminalView)) + localPosition;

      gestureState.onDoubleTapDown(
        TapDownDetails(
          globalPosition: globalPosition,
          localPosition: localPosition,
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        controller.selection,
        BufferRangeLine(
          CellOffset(3, 0),
          CellOffset(4, 0),
        ),
      );
      expect(terminal.buffer.getText(controller.selection!), equals(','));

      controller.dispose();
    });

    testWidgets('double click stops at a separator after a soft wrap', (
      tester,
    ) async {
      final terminal = Terminal()..resize(5, 6);
      final controller = TerminalController();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: controller,
              autoResize: false,
            ),
          ),
        ),
      );

      terminal.write('abcde bar');
      await tester.pump();

      final render = key.currentState!.renderTerminal;
      final gestureState =
          tester.state(find.byType(TerminalGestureHandler)) as dynamic;
      final localPosition = render.getOffset(const CellOffset(2, 0)) +
          Offset(render.cellSize.width / 2, render.cellSize.height / 2);
      final globalPosition =
          tester.getTopLeft(find.byType(TerminalView)) + localPosition;

      gestureState.onDoubleTapDown(
        TapDownDetails(
          globalPosition: globalPosition,
          localPosition: localPosition,
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        controller.selection,
        BufferRangeLine(
          CellOffset(0, 0),
          CellOffset(5, 0),
        ),
      );
      expect(terminal.buffer.getText(controller.selection!), equals('abcde'));

      controller.dispose();
    });

    testWidgets(
      'touch long press selects on hold but only shows the toolbar on release',
      (tester) async {
        final terminal = Terminal();
        final key = GlobalKey<TerminalViewState>();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalView(
                terminal,
                key: key,
              ),
            ),
          ),
        );

        terminal.write('hello world');
        await tester.pump();

        final gestureState =
            tester.state(find.byType(TerminalGestureHandler)) as dynamic;
        final rect = tester.getRect(find.byType(TerminalView));
        final position = rect.topLeft + const Offset(16, 16);

        final gesture = await tester.startGesture(position);
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

        expect(gestureState.debugShowsSelectionHandles, isTrue);
        expect(find.byType(RawMagnifier), findsOneWidget);
        expect(key.currentState?.debugSelectionToolbarRequested, isFalse);

        await gesture.up();
        await tester.pumpAndSettle();

        expect(find.byType(RawMagnifier), findsNothing);
        expect(key.currentState?.debugSelectionToolbarRequested, isTrue);
      },
    );

    /// Answers `Clipboard.hasStrings` the way a platform would.
    ///
    /// Without an answer `ClipboardStatusNotifier` stays
    /// `ClipboardStatus.unknown`, and `EditableText.getEditableButtonItems`
    /// builds no buttons at all while it is unknown, so the toolbar can never
    /// open. Pass [pending] to hold the answer back and drive that race on
    /// purpose.
    void mockClipboardHasStrings(WidgetTester tester, {Future<bool>? pending}) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method != 'Clipboard.hasStrings') {
            return null;
          }
          return {'value': pending == null ? true : await pending};
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
    }

    Future<void> longPressAndRelease(WidgetTester tester) async {
      final rect = tester.getRect(find.byType(TerminalView));
      final gesture = await tester.startGesture(
        rect.topLeft + const Offset(16, 16),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('opens the menu on release, not merely asks for it', (
      tester,
    ) async {
      mockClipboardHasStrings(tester);
      final terminal = Terminal();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pumpAndSettle();

      await longPressAndRelease(tester);

      // The request flag on its own proves nothing: it is set before the
      // toolbar is built, and every way of dropping the request leaves it true.
      expect(key.currentState?.isSelectionToolbarShown, isTrue);
    });

    testWidgets('a tap on the selection dismisses it', (tester) async {
      // The handle touch target used to be inflated by a fixed 32px on every
      // side, so a single handle claimed a big blob of "blank" area around the
      // selection. A tap landing in that blob counted as grabbing a handle, and
      // grabbing a handle deliberately does nothing on tap-up — so the
      // selection could not be dismissed by tapping at all.
      mockClipboardHasStrings(tester);
      final terminal = Terminal();
      final controller = TerminalController();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: controller,
            ),
          ),
        ),
      );

      terminal.write('alpha beta gamma delta');
      await tester.pumpAndSettle();

      final origin = tester.getTopLeft(find.byType(TerminalView));
      final render = key.currentState!.renderTerminal;
      Offset cellCenter(int column) =>
          origin +
          render.getOffset(CellOffset(column, 0)) +
          Offset(render.cellSize.width / 2, render.cellSize.height / 2);

      final gesture = await tester.startGesture(cellCenter(1));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(terminal.buffer.getText(controller.selection!), 'alpha');
      expect(key.currentState?.isSelectionToolbarShown, isTrue);

      await tester.tapAt(cellCenter(1));
      // The double-tap recognizer holds the gesture arena for this long before
      // a single tap is accepted.
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(controller.selection, isNull);
      expect(key.currentState?.isSelectionToolbarShown, isFalse);

      controller.dispose();
    });

    testWidgets('replays a dropped request once the clipboard status arrives', (
      tester,
    ) async {
      final answer = Completer<bool>();
      mockClipboardHasStrings(tester, pending: answer.future);
      final terminal = Terminal();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      await longPressAndRelease(tester);

      // The status never arrived, so there were no buttons to build and the
      // request was dropped.
      expect(key.currentState?.debugSelectionToolbarRequested, isTrue);
      expect(key.currentState?.isSelectionToolbarShown, isFalse);

      answer.complete(true);
      await tester.pumpAndSettle();

      expect(key.currentState?.isSelectionToolbarShown, isTrue);
    });

    testWidgets('does not replay a dropped request after focus is lost', (
      tester,
    ) async {
      final answer = Completer<bool>();
      mockClipboardHasStrings(tester, pending: answer.future);
      final terminal = Terminal();
      final key = GlobalKey<TerminalViewState>();
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal, key: key, focusNode: focusNode),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      focusNode.requestFocus();
      await tester.pump();

      await longPressAndRelease(tester);

      // The status never arrived, so there were no buttons to build and the
      // request was dropped, parked on _pendingToolbarRect.
      expect(key.currentState?.debugSelectionToolbarRequested, isTrue);
      expect(key.currentState?.isSelectionToolbarShown, isFalse);

      // Focus leaves before the clipboard answers. The parked request must go
      // with it instead of popping the menu on an unfocused widget.
      focusNode.unfocus();
      await tester.pump();

      answer.complete(true);
      await tester.pumpAndSettle();

      expect(key.currentState?.isSelectionToolbarShown, isFalse);
    });

    testWidgets('opens the menu even when the soft keyboard is off', (
      tester,
    ) async {
      // hardwareKeyboardOnly used to drop CustomTextEdit, which is where the
      // toolbar lives, so showToolbar silently did nothing.
      mockClipboardHasStrings(tester);
      final terminal = Terminal();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pumpAndSettle();

      await longPressAndRelease(tester);

      expect(key.currentState?.isSelectionToolbarShown, isTrue);
    });

    testWidgets('touch long press drag extends the selection', (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: controller,
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final render = key.currentState!.renderTerminal;
      final origin = tester.getTopLeft(find.byType(TerminalView));
      Offset cellCenter(int column) =>
          origin +
          render.getOffset(CellOffset(column, 0)) +
          Offset(render.cellSize.width / 2, render.cellSize.height / 2);

      final gesture = await tester.startGesture(cellCenter(1));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

      expect(terminal.buffer.getText(controller.selection!), equals('hello'));

      await gesture.moveTo(cellCenter(8));
      await tester.pump();

      final dragged = terminal.buffer.getText(controller.selection!);
      expect(dragged.startsWith('hello'), isTrue);
      expect(dragged.length, greaterThan('hello'.length));

      await gesture.moveTo(cellCenter(2));
      await tester.pump();

      expect(terminal.buffer.getText(controller.selection!), equals('hello'));

      await gesture.up();
      await tester.pumpAndSettle();

      controller.dispose();
    });

    testWidgets(
      'touch long press drag includes the first cell past the selection',
      (tester) async {
        final terminal = Terminal();
        final controller = TerminalController();
        final key = GlobalKey<TerminalViewState>();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalView(terminal, key: key, controller: controller),
            ),
          ),
        );

        terminal.write('hello world');
        await tester.pump();

        final render = key.currentState!.renderTerminal;
        final origin = tester.getTopLeft(find.byType(TerminalView));
        Offset cellCenter(int column) =>
            origin +
            render.getOffset(CellOffset(column, 0)) +
            Offset(render.cellSize.width / 2, render.cellSize.height / 2);

        final gesture = await tester.startGesture(cellCenter(1));
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        expect(terminal.buffer.getText(controller.selection!), equals('hello'));

        // Cell 5 is the first cell past the exclusive end. It must be added
        // immediately; the old isAfter(end) left a one-cell dead zone.
        await gesture.moveTo(cellCenter(5));
        await tester.pump();
        expect(
          terminal.buffer.getText(controller.selection!),
          equals('hello '),
        );

        await gesture.up();
        await tester.pumpAndSettle();
        controller.dispose();
      },
    );

    testWidgets(
      'drops the drag handle when the selection is cleared mid-drag',
      (tester) async {
        final terminal = Terminal();
        final controller = TerminalController();
        final key = GlobalKey<TerminalViewState>();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalView(terminal, key: key, controller: controller),
            ),
          ),
        );

        terminal.write('hello world');
        await tester.pump();

        final render = key.currentState!.renderTerminal;
        final origin = tester.getTopLeft(find.byType(TerminalView));
        final cellSize = render.cellSize;
        Offset cellCenter(int column) =>
            origin +
            render.getOffset(CellOffset(column, 0)) +
            Offset(cellSize.width / 2, cellSize.height / 2);

        // Select the word and show the handles.
        final select = await tester.startGesture(cellCenter(1));
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        await select.up();
        await tester.pumpAndSettle();
        expect(terminal.buffer.getText(controller.selection!), 'hello');

        // The end handle sits on the last selected cell (exclusive end - 1).
        final controls = MaterialTextSelectionControls();
        final endAnchor = render.getOffset(const CellOffset(4, 0)) +
            Offset(cellSize.width, cellSize.height);
        final handleTopLeft = endAnchor -
            controls.getHandleAnchor(
              TextSelectionHandleType.right,
              cellSize.height,
            );

        final drag = await tester.startGesture(
          origin + handleTopLeft + const Offset(6, 6),
        );
        await tester.pump();
        // Prove the handle engaged before invalidating the selection.
        await drag.moveTo(cellCenter(8));
        await tester.pump();
        expect(
          terminal.buffer.getText(controller.selection!).length,
          greaterThan('hello'.length),
        );

        // The selection vanishes underneath the drag.
        controller.clearSelection();
        await tester.pump();

        // Must not throw: the drag state is dropped with the selection.
        await drag.moveTo(cellCenter(10));
        await tester.pump();
        expect(tester.takeException(), isNull);

        await drag.up();
        await tester.pumpAndSettle();
        controller.dispose();
      },
    );

    testWidgets('selection handles hug the selected cells', (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: controller,
            ),
          ),
        ),
      );

      terminal.write('git status');
      await tester.pump();

      final render = key.currentState!.renderTerminal;
      final origin = tester.getTopLeft(find.byType(TerminalView));
      final cellSize = render.cellSize;

      final gesture = await tester.startGesture(
        origin +
            render.getOffset(const CellOffset(1, 0)) +
            Offset(cellSize.width / 2, cellSize.height / 2),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

      expect(terminal.buffer.getText(controller.selection!), 'git');

      final controls = MaterialTextSelectionControls();
      Finder handleAt(Offset anchor, TextSelectionHandleType type) {
        final handleAnchor = controls.getHandleAnchor(type, cellSize.height);
        final position = anchor - handleAnchor;
        return find.byWidgetPredicate(
          (widget) =>
              widget is Positioned &&
              widget.left == position.dx &&
              widget.top == position.dy,
        );
      }

      final boundary = render.getOffset(const CellOffset(3, 0));
      expect(
        handleAt(
          boundary + Offset(0, cellSize.height),
          TextSelectionHandleType.right,
        ),
        findsOneWidget,
      );
      // Regression: the end handle used to sit one cell past the selection.
      expect(
        handleAt(
          boundary + Offset(cellSize.width, cellSize.height),
          TextSelectionHandleType.right,
        ),
        findsNothing,
      );
      expect(
        handleAt(
          render.getOffset(const CellOffset(0, 0)) + Offset(0, cellSize.height),
          TextSelectionHandleType.left,
        ),
        findsOneWidget,
      );

      await gesture.up();
      await tester.pumpAndSettle();

      controller.dispose();
    });

    testWidgets('keeps a single-cell selection usable', (tester) async {
      final terminal = Terminal();
      final controller = TerminalController();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: controller,
            ),
          ),
        ),
      );

      terminal.write('a bc');
      await tester.pump();

      final render = key.currentState!.renderTerminal;
      final origin = tester.getTopLeft(find.byType(TerminalView));
      final gesture = await tester.startGesture(
        origin +
            render.getOffset(const CellOffset(0, 0)) +
            Offset(render.cellSize.width / 2, render.cellSize.height / 2),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

      expect(terminal.buffer.getText(controller.selection!), 'a');

      // A one-cell selection is still non-empty: handles and menu must both show.
      final state =
          tester.state(find.byType(TerminalGestureHandler)) as dynamic;
      expect(state.debugShowsSelectionHandles as bool, isTrue);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(key.currentState?.debugSelectionToolbarRequested, isTrue);

      controller.dispose();
    });

    testWidgets('stops selection auto-scroll when the finger lifts', (
      tester,
    ) async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);
      final controller = TerminalController();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: controller,
              simulateScroll: true,
            ),
          ),
        ),
      );

      terminal.write('\x1b[?1049h');
      terminal.write('hello world');
      await tester.pump();

      final render = key.currentState!.renderTerminal;
      final origin = tester.getTopLeft(find.byType(TerminalView));

      final gesture = await tester.startGesture(
        origin +
            render.getOffset(const CellOffset(1, 0)) +
            Offset(render.cellSize.width / 2, render.cellSize.height / 2),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

      await gesture.moveTo(origin + const Offset(2, 0));
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.up();
      await tester.pump();

      // The timer must stop on release; nothing else stops it.
      output.clear();
      await tester.pump(const Duration(milliseconds: 700));
      expect(output, isEmpty);

      controller.dispose();
    });

    testWidgets('mouse long press selects the word and nothing else', (
      tester,
    ) async {
      final terminal = Terminal();
      final controller = TerminalController();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal, key: key, controller: controller),
          ),
        ),
      );

      terminal.write('git status');
      await tester.pump();

      final render = key.currentState!.renderTerminal;
      final origin = tester.getTopLeft(find.byType(TerminalView));
      final position = origin +
          render.getOffset(const CellOffset(1, 0)) +
          Offset(render.cellSize.width / 2, render.cellSize.height / 2);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: position);
      await tester.pump();
      await gesture.down(position);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

      expect(terminal.buffer.getText(controller.selection!), 'git');
      expect(key.currentState?.debugSelectionToolbarRequested, isFalse);
      final state =
          tester.state(find.byType(TerminalGestureHandler)) as dynamic;
      expect(state.debugShowsSelectionHandles as bool, isFalse);
      expect(find.byType(RawMagnifier), findsNothing);

      await gesture.up();
      await tester.pumpAndSettle();
      expect(key.currentState?.debugSelectionToolbarRequested, isFalse);

      controller.dispose();
    });

    testWidgets('a second pointer cancel does not abort the touch drag', (
      tester,
    ) async {
      final terminal = Terminal();
      final controller = TerminalController();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: controller,
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final render = key.currentState!.renderTerminal;
      final origin = tester.getTopLeft(find.byType(TerminalView));
      Offset cellCenter(int column) =>
          origin +
          render.getOffset(CellOffset(column, 0)) +
          Offset(render.cellSize.width / 2, render.cellSize.height / 2);

      final fingerA = await tester.startGesture(cellCenter(1), pointer: 1);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await fingerA.moveTo(cellCenter(7));
      await tester.pump();
      final extended = terminal.buffer.getText(controller.selection!);
      expect(extended.length, greaterThan('hello'.length));

      final fingerB = await tester.startGesture(cellCenter(15), pointer: 2);
      await tester.pump();
      await fingerB.cancel();
      await tester.pump();

      await fingerA.moveTo(cellCenter(8));
      await tester.pump();
      expect(terminal.buffer.getText(controller.selection!), isNot(extended));

      await fingerA.up();
      await tester.pumpAndSettle();

      controller.dispose();
    });

    testWidgets('does not show toolbar for mouse drag selection by default', (
      tester,
    ) async {
      final terminal = Terminal();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final rect = tester.getRect(find.byType(TerminalView));
      final start = rect.topLeft + const Offset(8, 8);
      final end = rect.topLeft + const Offset(80, 8);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: start);
      await tester.pump();
      await gesture.down(start);
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      final gestureState =
          tester.state(find.byType(TerminalGestureHandler)) as dynamic;
      expect(key.currentState?.debugSelectionToolbarRequested, isFalse);
      expect(gestureState.debugShowsSelectionHandles, isFalse);
    });
  });

  group('TerminalView.selection magnifier', () {
    TerminalTheme lightTerminalTheme() {
      final base = TerminalThemes.defaultTheme;
      return TerminalTheme(
        cursor: base.cursor,
        selectionCursor: base.selectionCursor,
        selection: base.selection,
        foreground: base.foreground,
        background: const Color(0xFFF5F5F5),
        black: base.black,
        white: base.white,
        red: base.red,
        green: base.green,
        yellow: base.yellow,
        blue: base.blue,
        magenta: base.magenta,
        cyan: base.cyan,
        brightBlack: base.brightBlack,
        brightRed: base.brightRed,
        brightGreen: base.brightGreen,
        brightYellow: base.brightYellow,
        brightBlue: base.brightBlue,
        brightMagenta: base.brightMagenta,
        brightCyan: base.brightCyan,
        brightWhite: base.brightWhite,
        searchHitBackground: base.searchHitBackground,
        searchHitBackgroundCurrent: base.searchHitBackgroundCurrent,
        searchHitForeground: base.searchHitForeground,
      );
    }

    Future<GlobalKey<TerminalViewState>> pumpTerminal(
      WidgetTester tester, {
      bool showMagnifier = true,
      int rows = 1,
      TerminalController? controller,
      TerminalTheme? theme,
      Brightness appBrightness = Brightness.light,
    }) async {
      final terminal = Terminal();
      final key = GlobalKey<TerminalViewState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: appBrightness),
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              controller: controller,
              theme: theme ?? TerminalThemes.defaultTheme,
              showMagnifier: showMagnifier,
            ),
          ),
        ),
      );
      terminal
          .write(List<String>.generate(rows, (i) => 'line $i').join('\r\n'));
      await tester.pump();
      return key;
    }

    testWidgets('uses the same lens widget on every touch platform', (
      tester,
    ) async {
      // Must clear before the body ends: the framework asserts at teardown that
      // foundation debug overrides are reset, and addTearDown runs too late.
      try {
        // Touch platforms only. A Mac reports mouse or trackpad and never
        // touch, so no platform setting can reach the lens there.
        for (final platform in <TargetPlatform>[
          TargetPlatform.android,
          TargetPlatform.iOS,
        ]) {
          debugDefaultTargetPlatformOverride = platform;

          await pumpTerminal(tester);
          final rect = tester.getRect(find.byType(TerminalView));

          final gesture = await tester.startGesture(
            rect.topLeft + const Offset(40, 40),
          );
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 50),
          );

          expect(find.byType(Magnifier), findsOneWidget);
          expect(find.byType(CupertinoMagnifier), findsNothing);

          final raw = tester.widget<RawMagnifier>(find.byType(RawMagnifier));
          expect(raw.size, Magnifier.kDefaultMagnifierSize);
          expect(raw.magnificationScale, 1.25);

          expect(raw.decoration.shadows, isNotEmpty);

          await gesture.up();
          await tester.pumpAndSettle();
          expect(find.byType(RawMagnifier), findsNothing);
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('lens still samples the terminal through its RepaintBoundary', (
      tester,
    ) async {
      final rootKey = GlobalKey();
      final terminal = Terminal();
      final viewKey = GlobalKey<TerminalViewState>();

      // Pins the scene so the lens pixels can be read back.
      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            home: Scaffold(
              body: TerminalView(
                terminal,
                key: viewKey,
                theme: TerminalThemes.defaultTheme,
              ),
            ),
          ),
        ),
      );
      // Text in the lens, cursor far below it: the cursor blinks, and a blink
      // between the two captures below would read as a difference.
      terminal.write(
        'ABCDEFGHIJKLMNOP\r\n0123456789abcdef\r\n\r\n\r\n\r\nX',
      );
      await tester.pump();

      final render = viewKey.currentState!.renderTerminal;
      final origin = tester.getTopLeft(find.byType(TerminalView));
      final position = Offset(
        origin.dx + render.getOffset(const CellOffset(8, 1)).dx + 2,
        origin.dy +
            render.getOffset(const CellOffset(0, 1)).dy +
            render.cellSize.height / 2,
      );

      var width = 0;
      Future<Uint8List> capture() async {
        final bytes = await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(rootKey),
          );
          final image = await boundary.toImage();
          width = image.width;
          final data = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          return Uint8List.fromList(data!.buffer.asUint8List());
        });
        return bytes!;
      }

      int changedPixels(Uint8List a, Uint8List b, Rect region) {
        var changed = 0;
        for (var y = region.top.round(); y < region.bottom.round(); y++) {
          for (var x = region.left.round(); x < region.right.round(); x++) {
            final i = (y * width + x) * 4;
            for (var channel = 0; channel < 3; channel++) {
              if ((a[i + channel] - b[i + channel]).abs() > 20) {
                changed++;
                break;
              }
            }
          }
        }
        return changed;
      }

      final gesture = await tester.startGesture(position);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(find.byType(RawMagnifier), findsOneWidget);
      final lens = tester.getRect(find.byType(RawMagnifier));
      final withLens = await capture();

      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byType(RawMagnifier), findsNothing);
      final withoutLens = await capture();

      // The lens redraws the glyphs under it at a different scale, so those
      // pixels must move. Starved of its backdrop -- which is what wrapping the
      // lens in a RepaintBoundary risks -- it would paint nothing and leave the
      // terminal underneath untouched.
      expect(
        changedPixels(withLens, withoutLens, lens.deflate(4)),
        greaterThan(0),
      );
      // Control: away from the lens the two captures are the same picture.
      expect(
        changedPixels(
            withLens, withoutLens, const Rect.fromLTWH(600, 500, 120, 60)),
        0,
      );
    });

    testWidgets('tinges the lens halo with the terminal background', (
      tester,
    ) async {
      Future<RawMagnifier> longPress(
        TerminalTheme theme,
        Brightness appBrightness,
      ) async {
        await pumpTerminal(
          tester,
          rows: 8,
          theme: theme,
          appBrightness: appBrightness,
        );
        final rect = tester.getRect(find.byType(TerminalView));
        final gesture = await tester.startGesture(
          rect.topLeft + const Offset(40, 40),
        );
        await tester.pump(
          kLongPressTimeout + const Duration(milliseconds: 50),
        );
        final lens = tester.widget<RawMagnifier>(find.byType(RawMagnifier));
        await gesture.up();
        await tester.pumpAndSettle();
        return lens;
      }

      final darkLens = await longPress(
        TerminalThemes.defaultTheme,
        Brightness.light,
      );
      final lightLens = await longPress(
        lightTerminalTheme(),
        Brightness.dark,
      );

      Color haloOf(RawMagnifier lens) => lens.decoration.shadows!.single.color;

      expect(haloOf(darkLens).computeLuminance(), greaterThan(0.5));
      expect(haloOf(lightLens).computeLuminance(), lessThan(0.5));
    });

    testWidgets('sits clear of the finger and still points at its row', (
      tester,
    ) async {
      final key = await pumpTerminal(tester, rows: 8);
      final render = key.currentState!.renderTerminal;
      final origin = tester.getTopLeft(find.byType(TerminalView));

      const row = 8;
      final rowCenterY = origin.dy +
          render.getOffset(const CellOffset(0, row)).dy +
          render.cellSize.height / 2;
      final position = Offset(
        origin.dx + render.getOffset(const CellOffset(3, row)).dx + 2,
        rowCenterY,
      );

      final gesture = await tester.startGesture(position);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

      final lens = tester.getRect(find.byType(RawMagnifier));
      expect(lens.bottom, lessThanOrEqualTo(rowCenterY - 40));

      final raw = tester.widget<RawMagnifier>(find.byType(RawMagnifier));
      expect(
        lens.center + raw.focalPointOffset,
        offsetMoreOrLessEquals(Offset(position.dx, rowCenterY), epsilon: 0.5),
      );

      final moved = position + const Offset(60, 0);
      await gesture.moveTo(moved);
      await tester.pump();

      final movedLens = tester.getRect(find.byType(RawMagnifier));
      final movedRaw = tester.widget<RawMagnifier>(find.byType(RawMagnifier));
      expect(movedLens.center.dx, greaterThan(lens.center.dx));
      expect(
        movedLens.center + movedRaw.focalPointOffset,
        offsetMoreOrLessEquals(Offset(moved.dx, rowCenterY), epsilon: 0.5),
      );

      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byType(RawMagnifier), findsNothing);
    });

    testWidgets('flips below the row when there is no room above', (
      tester,
    ) async {
      final key = await pumpTerminal(tester, rows: 8);
      final render = key.currentState!.renderTerminal;
      final origin = tester.getTopLeft(find.byType(TerminalView));

      final rowCenterY = origin.dy +
          render.getOffset(const CellOffset(0, 0)).dy +
          render.cellSize.height / 2;
      final position = Offset(
        origin.dx + render.getOffset(const CellOffset(3, 0)).dx + 2,
        rowCenterY,
      );

      final gesture = await tester.startGesture(position);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

      final lens = tester.getRect(find.byType(RawMagnifier));
      expect(lens.top, greaterThan(rowCenterY));
      expect(lens.top, greaterThanOrEqualTo(0));

      final raw = tester.widget<RawMagnifier>(find.byType(RawMagnifier));
      expect(
        lens.center + raw.focalPointOffset,
        offsetMoreOrLessEquals(Offset(position.dx, rowCenterY), epsilon: 0.5),
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('shows while dragging a selection handle', (tester) async {
      final controller = TerminalController();
      final key = await pumpTerminal(tester, rows: 8, controller: controller);
      final render = key.currentState!.renderTerminal;
      final origin = tester.getTopLeft(find.byType(TerminalView));

      Offset cellPoint(int column, int row) => Offset(
            origin.dx + render.getOffset(CellOffset(column, row)).dx + 2,
            origin.dy +
                render.getOffset(CellOffset(0, row)).dy +
                render.cellSize.height / 2,
          );

      final longPress = await tester.startGesture(cellPoint(2, 3));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await longPress.up();
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
      expect(find.byType(RawMagnifier), findsNothing);

      final end = controller.selection!.end;
      final handle = Offset(
        origin.dx + render.getOffset(end).dx + render.cellSize.width / 2,
        origin.dy +
            render.getOffset(CellOffset(0, end.y)).dy +
            render.cellSize.height / 2,
      );

      final drag = await tester.startGesture(handle);
      await tester.pump();
      await drag.moveTo(handle + Offset(0, render.cellSize.height * 3));
      await tester.pump();

      expect(find.byType(RawMagnifier), findsOneWidget);

      await drag.up();
      await tester.pumpAndSettle();
      expect(find.byType(RawMagnifier), findsNothing);

      controller.dispose();
    });

    testWidgets('does not appear for a mouse long press', (tester) async {
      await pumpTerminal(tester);

      final rect = tester.getRect(find.byType(TerminalView));
      final position = rect.topLeft + const Offset(40, 40);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: position);
      await tester.pump();
      await gesture.down(position);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

      expect(find.byType(RawMagnifier), findsNothing);

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('is out of reach on macOS, where the pointer is never touch', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      try {
        await pumpTerminal(tester, rows: 8);

        final position = tester.getRect(find.byType(TerminalView)).topLeft +
            const Offset(40, 40);
        final gesture =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: position);
        await tester.pump();
        await gesture.down(position);
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

        // Neither the lens nor the handles the lens rides with are reachable.
        expect(find.byType(RawMagnifier), findsNothing);
        final state =
            tester.state(find.byType(TerminalGestureHandler)) as dynamic;
        expect(state.debugShowsSelectionHandles, isFalse);

        await gesture.up();
        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('can be disabled', (tester) async {
      await pumpTerminal(tester, showMagnifier: false);

      final rect = tester.getRect(find.byType(TerminalView));
      final position = rect.topLeft + const Offset(40, 40);

      final gesture = await tester.startGesture(position);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));

      expect(find.byType(RawMagnifier), findsNothing);

      await gesture.up();
      await tester.pumpAndSettle();
    });
  });

  group('TerminalView.textScaler', () {
    testWidgets('works', (tester) async {
      final terminal = Terminal();

      final textScaler = ValueNotifier(TextScaler.linear(1.0));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<TextScaler>(
              valueListenable: textScaler,
              builder: (context, textScaler, child) {
                return TerminalView(
                  terminal,
                  textScaler: textScaler,
                );
              },
            ),
          ),
        ),
      );

      terminal.write('Hello World');
      await tester.pump();

      await expectLater(
        find.byType(TerminalView),
        matchesGoldenFile('_goldens/text_scale_factor@1x.png'),
      );

      textScaler.value = TextScaler.linear(2.0);
      await tester.pump();

      await expectLater(
        find.byType(TerminalView),
        matchesGoldenFile('_goldens/text_scale_factor@2x.png'),
      );
    });

    testWidgets('can obtain textScaler from parent', (tester) async {
      final terminal = Terminal();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
              child: TerminalView(
                terminal,
              ),
            ),
          ),
        ),
      );

      terminal.write('Hello World');
      await tester.pump();

      await expectLater(
        find.byType(TerminalView),
        matchesGoldenFile('_goldens/text_scale_factor@2x.png'),
      );
    });
  });

  group('TerminalView.inputHandler', () {
    testWidgets('reports IME composition state transitions', (tester) async {
      final composingStates = <bool>[];
      final terminal = Terminal();

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(
          terminal,
          autofocus: true,
          onImeComposingChanged: composingStates.add,
        ),
      ));

      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(milliseconds: 50));

      binding.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'pin',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 0, end: 3),
        ),
      );
      await tester.pump();

      binding.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '拼',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();

      expect(composingStates, [true, false]);
    });

    testWidgets('works', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(terminal, autofocus: true),
      ));

      await tester.tap(find.byType(TerminalView));
      await tester.pump(Duration(seconds: 1));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);

      await tester.pumpAndSettle();

      expect(terminalOutput.join(), '\x04');
    });

    testWidgets('can convert text input to key events', (tester) async {
      final inputHandler = MockTerminalInputHandler();
      when(inputHandler.call(any)).thenAnswer((invocation) => 'AAA');

      final terminalOutput = <String>[];
      final terminal = Terminal(
        inputHandler: inputHandler,
        onOutput: terminalOutput.add,
      );

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(terminal, autofocus: true),
      ));

      await tester.tap(find.byType(TerminalView));
      await tester.pump(Duration(seconds: 1));

      binding.testTextInput.enterText('c');
      await binding.idle();

      await tester.pumpAndSettle();

      verify(inputHandler.call(any));
      expect(terminalOutput.join(), 'AAA');
    });

    testWidgets('keeps plain space input intact', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(terminal, autofocus: true),
      ));

      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(seconds: 1));

      final state = tester.state<CustomTextEditState>(
        find.byType(CustomTextEdit),
      );

      state.widget.onInsert(' ');
      await tester.pump();

      expect(terminalOutput.join(), ' ');
    });

    testWidgets('paste shortcut uses host onPaste callback when provided', (
      tester,
    ) async {
      var pasteCount = 0;
      final terminal = Terminal();

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(
          terminal,
          autofocus: true,
          onPaste: () {
            pasteCount++;
          },
        ),
      ));

      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(seconds: 1));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
      await tester.pumpAndSettle();

      expect(pasteCount, 1);
    });
  });

  group('TerminalView.shiftEnterMode', () {
    testWidgets('keeps Shift+Enter as carriage return by default',
        (tester) async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(terminal, autofocus: true),
      ));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(output, ['\r']);
    });

    testWidgets('can report Shift+Enter as CSI-u', (tester) async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(
          terminal,
          autofocus: true,
          shiftEnterMode: TerminalShiftEnterMode.csiU,
        ),
      ));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(output, ['\x1b[13;2u']);
    });

    testWidgets('can report Shift+Enter as modifyOtherKeys sequence',
        (tester) async {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(
          terminal,
          autofocus: true,
          shiftEnterMode: TerminalShiftEnterMode.modifyOtherKeys,
        ),
      ));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      expect(output, ['\x1b[27;2;13~']);
    });
  });

  group('TerminalView.simulateScroll', () {
    testWidgets('works', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      terminal.useAltBuffer();

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(terminal, autofocus: true, simulateScroll: true),
      ));

      await tester.drag(find.byType(TerminalView), const Offset(0, -100));
      // Let the double-tap recognizer's 40ms tracker expire.
      await tester.pumpAndSettle();

      expect(terminalOutput.join(), contains('\x1B[B'));
    });

    testWidgets('does nothing when disabled', (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      terminal.useAltBuffer();

      await tester.pumpWidget(MaterialApp(
        home: TerminalView(terminal, autofocus: true, simulateScroll: false),
      ));

      await tester.drag(find.byType(TerminalView), const Offset(0, -100));
      // Let the double-tap recognizer's 40ms tracker expire.
      await tester.pumpAndSettle();

      expect(terminalOutput.join(), isEmpty);
    });
  });

  group('RenderTerminal update mode', () {
    testWidgets('updates scroll extent when line count grows', (tester) async {
      final terminal = Terminal();
      final scrollController = ScrollController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                scrollController: scrollController,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );

      final text = List.generate(40, (index) => 'line $index').join('\r\n');
      terminal.write(text);
      await tester.pump();

      expect(scrollController.position.maxScrollExtent, greaterThan(0));
    });

    testWidgets('updates scroll extent when switching buffer', (tester) async {
      final terminal = Terminal();
      final scrollController = ScrollController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                scrollController: scrollController,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );

      final text = List.generate(40, (index) => 'line $index').join('\r\n');
      terminal.write(text);
      await tester.pump();
      expect(scrollController.position.maxScrollExtent, greaterThan(0));

      terminal.write('\x1b[?1049h');
      await tester.pump();

      expect(scrollController.position.maxScrollExtent, 0);
    });
  });
}
