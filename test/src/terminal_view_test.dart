import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
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

      expect(output, hasLength(1));

      await tester.sendEventToBinding(pointer.up());
      await tester.pumpAndSettle();

      expect(output, hasLength(2));
    });

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
    testWidgets('autoScrollDown steps immediately near viewport edges',
        (tester) async {
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

      terminal.write(List.generate(80, (index) => 'line $index').join('\r\n'));
      await tester.pump();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final middleOffset = scrollController.position.maxScrollExtent / 2;
      scrollController.jumpTo(middleOffset);
      await tester.pump();

      final beforeDown = scrollController.offset;
      state.autoScrollDown(
        Offset(0, state.renderTerminal.size.height - 1),
      );
      expect(scrollController.offset, greaterThan(beforeDown));

      final beforeUp = scrollController.offset;
      state.autoScrollDown(const Offset(0, 0));
      expect(scrollController.offset, lessThan(beforeUp));
    });

    testWidgets('text input scrolls to bottom in the next frame',
        (tester) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
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
                autofocus: true,
              ),
            ),
          ),
        ),
      );

      terminal.write(List.generate(40, (index) => 'line $index').join('\r\n'));
      await tester.pump();

      expect(scrollController.position.maxScrollExtent, greaterThan(0));

      scrollController.jumpTo(0);
      await tester.pump();
      expect(scrollController.offset, 0);

      await tester.tap(find.byType(TerminalView));
      await tester.pump(const Duration(seconds: 1));

      binding.testTextInput.enterText('x');
      await binding.idle();
      expect(terminalOutput.join(), 'x');
      await tester.pump();
      await tester.pump();

      expect(
        scrollController.offset,
        scrollController.position.maxScrollExtent,
      );
    });

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

  group('TerminalView selection UX', () {
    testWidgets('touch long press creates selection', (tester) async {
      final terminal = Terminal();
      final controller = TerminalController(vsync: tester);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                controller: controller,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final cellOffset = state.renderTerminal.getOffset(const CellOffset(1, 0));
      final touchPoint = cellOffset +
          Offset(
            state.renderTerminal.cellSize.width / 2,
            state.renderTerminal.cellSize.height / 2,
          );

      await tester.longPressAt(touchPoint);
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
      expect(state.isSelectionToolbarShown, isTrue);
    });

    testWidgets('touch tap inside selection reopens selection toolbar', (
      tester,
    ) async {
      final terminal = Terminal();
      final controller = TerminalController(vsync: tester);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                controller: controller,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final cellOffset = state.renderTerminal.getOffset(const CellOffset(1, 0));
      final touchPoint = cellOffset +
          Offset(
            state.renderTerminal.cellSize.width / 2,
            state.renderTerminal.cellSize.height / 2,
          );

      await tester.longPressAt(touchPoint);
      await tester.pumpAndSettle();

      expect(state.isSelectionToolbarShown, isTrue);

      state.hideSelectionToolbar();
      await tester.pumpAndSettle();

      expect(state.isSelectionToolbarShown, isFalse);

      await tester.tapAt(touchPoint);
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
      expect(state.isSelectionToolbarShown, isTrue);
    });

    testWidgets('mouse selection does not show selection toolbar', (
      tester,
    ) async {
      final terminal = Terminal();
      final controller = TerminalController(vsync: tester);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                controller: controller,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final startCell = state.renderTerminal.getOffset(const CellOffset(0, 0));
      final endCell = state.renderTerminal.getOffset(const CellOffset(4, 0));
      final startPoint = startCell +
          Offset(
            state.renderTerminal.cellSize.width / 2,
            state.renderTerminal.cellSize.height / 2,
          );
      final endPoint = endCell +
          Offset(
            state.renderTerminal.cellSize.width / 2,
            state.renderTerminal.cellSize.height / 2,
          );

      final gesture = await tester.startGesture(
        startPoint,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(endPoint);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
      expect(controller.selection!.isCollapsed, isFalse);
      expect(state.isSelectionToolbarShown, isFalse);
    });

    testWidgets('escape clears local selection before reaching terminal', (
      tester,
    ) async {
      final terminalOutput = <String>[];
      final terminal = Terminal(onOutput: terminalOutput.add);
      final controller = TerminalController(vsync: tester);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                controller: controller,
                textStyle: const TerminalStyle(fontSize: 12),
                autofocus: true,
              ),
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));

      controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(5, 0),
      );
      await tester.pump();

      expect(controller.selection, isNotNull);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(controller.selection, isNull);
      expect(state.isSelectionToolbarShown, isFalse);
      expect(terminalOutput, isEmpty);
    });

    testWidgets('secondary click keeps selection', (
      tester,
    ) async {
      final terminal = Terminal();
      final controller = TerminalController(vsync: tester);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                controller: controller,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      controller.setSelection(
        terminal.buffer.createAnchor(0, 0),
        terminal.buffer.createAnchor(5, 0),
      );
      await tester.pump();

      final clickPoint =
          state.renderTerminal.getOffset(const CellOffset(2, 0)) +
              Offset(
                state.renderTerminal.cellSize.width / 2,
                state.renderTerminal.cellSize.height / 2,
              );
      final pointer = TestPointer(7, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(
        pointer.down(clickPoint, buttons: kSecondaryMouseButton),
      );
      await tester.pump();
      await tester.sendEventToBinding(pointer.up());
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
    });

    testWidgets('secondary click without selection opens terminal context menu',
        (
      tester,
    ) async {
      final terminal = Terminal();
      final controller = TerminalController(vsync: tester);
      TerminalContextMenu? menuRequest;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                controller: controller,
                textStyle: const TerminalStyle(fontSize: 12),
                contextMenuBuilder: (context, menu) {
                  menuRequest = menu;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );

      terminal.write('hello');
      await tester.pump();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final clickPoint =
          state.renderTerminal.getOffset(const CellOffset(10, 0)) +
              Offset(
                state.renderTerminal.cellSize.width / 2,
                state.renderTerminal.cellSize.height / 2,
              );
      final pointer = TestPointer(8, PointerDeviceKind.mouse);

      await tester.sendEventToBinding(
        pointer.down(clickPoint, buttons: kSecondaryMouseButton),
      );
      await tester.pump();
      await tester.sendEventToBinding(pointer.up());
      await tester.pumpAndSettle();

      expect(menuRequest, isNotNull);
      expect(menuRequest!.kind, TerminalContextMenuKind.terminal);
      expect(
        menuRequest!.triggerKind,
        TerminalContextMenuTriggerKind.secondaryTap,
      );
      expect(menuRequest!.cellOffset, const CellOffset(10, 0));
      expect(
        menuRequest!.actions.map((action) => action.type),
        orderedEquals(<TerminalContextMenuActionType>[
          TerminalContextMenuActionType.paste,
          TerminalContextMenuActionType.selectAll,
        ]),
      );
      expect(controller.selection, isNull);
    });

    testWidgets('touch tap inside selection keeps selection', (tester) async {
      final terminal = Terminal();
      final controller = TerminalController(vsync: tester);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                controller: controller,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final start = state.renderTerminal.getOffset(const CellOffset(1, 0)) +
          Offset(
            state.renderTerminal.cellSize.width / 2,
            state.renderTerminal.cellSize.height / 2,
          );

      await tester.longPressAt(start);
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);

      await tester.tapAt(start);
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);
    });

    testWidgets('touch tap outside selection clears selection', (tester) async {
      final terminal = Terminal();
      final controller = TerminalController(vsync: tester);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                controller: controller,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );

      terminal.write('hello world');
      await tester.pump();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final selectionPoint =
          state.renderTerminal.getOffset(const CellOffset(1, 0)) +
              Offset(
                state.renderTerminal.cellSize.width / 2,
                state.renderTerminal.cellSize.height / 2,
              );
      final outsidePoint =
          state.renderTerminal.getOffset(const CellOffset(10, 0)) +
              Offset(
                state.renderTerminal.cellSize.width / 2,
                state.renderTerminal.cellSize.height / 2,
              );

      await tester.longPressAt(selectionPoint);
      await tester.pumpAndSettle();

      expect(controller.selection, isNotNull);

      await tester.tapAt(outsidePoint);
      await tester.pumpAndSettle();

      expect(controller.selection, isNull);
    });

    testWidgets('blank-area long press opens terminal context menu', (
      tester,
    ) async {
      final terminal = Terminal();
      final controller = TerminalController(vsync: tester);
      TerminalContextMenu? menuRequest;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                controller: controller,
                textStyle: const TerminalStyle(fontSize: 12),
                contextMenuBuilder: (context, menu) {
                  menuRequest = menu;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );

      terminal.write('hello');
      await tester.pump();

      final state = tester.state<TerminalViewState>(find.byType(TerminalView));
      final touchPoint =
          state.renderTerminal.getOffset(const CellOffset(10, 0)) +
              Offset(
                state.renderTerminal.cellSize.width / 2,
                state.renderTerminal.cellSize.height / 2,
              );

      await tester.longPressAt(touchPoint);
      await tester.pumpAndSettle();

      expect(menuRequest, isNotNull);
      expect(menuRequest!.kind, TerminalContextMenuKind.terminal);
      expect(
        menuRequest!.triggerKind,
        TerminalContextMenuTriggerKind.blankAreaLongPress,
      );
      expect(menuRequest!.cellOffset, const CellOffset(10, 0));
      expect(
        menuRequest!.actions.map((action) => action.type),
        orderedEquals(<TerminalContextMenuActionType>[
          TerminalContextMenuActionType.paste,
          TerminalContextMenuActionType.selectAll,
        ]),
      );
      expect(controller.selection, isNull);
      expect(state.isSelectionToolbarShown, isTrue);
    });
  });

  group('TerminalView search UX', () {
    testWidgets('default search box works without Material ancestor', (
      tester,
    ) async {
      final terminal = Terminal();

      await tester.pumpWidget(
        CupertinoApp(
          home: CupertinoPageScaffold(
            child: SizedBox(
              width: 320,
              height: 120,
              child: TerminalView(
                terminal,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );

      terminal.showSearch();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsOneWidget);
    });
  });
}
