import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
        vsync: tester,
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
        vsync: tester,
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
        vsync: tester,
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

      final renderTerminal = tester.renderObject<RenderTerminal>(
        find.byType(TerminalView),
      );
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
          vsync: tester,
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
      },
    );

    testWidgets('reports mouse up after drag when drag input is enabled',
        (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1006;1002h');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.all(),
        vsync: tester,
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

      final renderTerminal = tester.renderObject<RenderTerminal>(
        find.byType(TerminalView),
      );
      final cellSize = renderTerminal.cellSize;
      final rect = tester.getRect(find.byType(TerminalView));
      final downOffset = rect.topLeft + Offset(cellSize.width / 2, cellSize.height / 2);
      final dragOffset = rect.topLeft + Offset(cellSize.width * 1.5, cellSize.height / 2);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: downOffset);
      await tester.pump();
      await gesture.down(downOffset);
      await tester.pump();
      await gesture.moveTo(dragOffset);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(output, contains('\x1B[<0;1;1M'));
      expect(output, contains('\x1B[<32;2;1M'));
      expect(output, contains('\x1B[<0;2;1m'));
    });

    testWidgets(
      'still reports mouse up after drag when Shift is pressed before release',
      (tester) async {
        final output = <String>[];

        final terminal = Terminal(onOutput: output.add);
        terminal.write('\x1b[?1006;1002h');

        final terminalView = TerminalController(
          pointerInputs: PointerInputs.all(),
          vsync: tester,
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

        final renderTerminal = tester.renderObject<RenderTerminal>(
          find.byType(TerminalView),
        );
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
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        await gesture.up();
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

        expect(output, contains('\x1B[<0;1;1M'));
        expect(output, contains('\x1B[<32;2;1M'));
        expect(output, contains('\x1B[<0;2;1m'));
      },
    );

    testWidgets('Shift+mouse drag prefers local selection over mouse reporting',
        (tester) async {
      final output = <String>[];

      final terminal = Terminal(onOutput: output.add);

      terminal.write('\x1b[?1006;1002h');
      terminal.write('hello world');

      final terminalView = TerminalController(
        pointerInputs: PointerInputs.all(),
        vsync: tester,
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
  });

  group('TerminalView.selection toolbar', () {
    testWidgets('double click with mouse selects the whole word',
        (tester) async {
      final terminal = Terminal();
      final controller = TerminalController(vsync: tester);
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
      final controller = TerminalController(vsync: tester);
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

    testWidgets('shows toolbar for touch long press selection', (tester) async {
      final terminal = Terminal();
      final key = GlobalKey<TerminalViewState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(
              terminal,
              key: key,
              selectionInteractionMode:
                  TerminalSelectionInteractionMode.touchContextMenu,
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final rect = tester.getRect(find.byType(TerminalView));
      final position = rect.topLeft + const Offset(16, 16);
      await tester.longPressAt(position);
      await tester.pumpAndSettle();

      final gestureState =
          tester.state(find.byType(TerminalGestureHandler)) as dynamic;
      expect(key.currentState?.debugSelectionToolbarRequested, isTrue);
      expect(gestureState.debugShowsSelectionHandles, isTrue);
    });

    testWidgets(
      'does not show toolbar for mouse drag selection in touch context mode',
      (tester) async {
        final terminal = Terminal();
        final key = GlobalKey<TerminalViewState>();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TerminalView(
                terminal,
                key: key,
                selectionInteractionMode:
                    TerminalSelectionInteractionMode.touchContextMenu,
              ),
            ),
          ),
        );

        terminal.write('hello world');
        await tester.pump();

        final rect = tester.getRect(find.byType(TerminalView));
        final start = rect.topLeft + const Offset(8, 8);
        final end = rect.topLeft + const Offset(80, 8);
        final gesture =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
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
      },
    );

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
