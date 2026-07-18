import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/terminal_view.dart';
import 'package:xterm/src/ui/controller.dart';

void main() {
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows Ctrl+C without selection is sent to the terminal', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final outputs = <String>[];
    final terminal = Terminal(onOutput: outputs.add);

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
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
    expect(outputs, ['\x03']);
  });

  testWidgets('Windows Ctrl+C copies an active selection', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final outputs = <String>[];
    final clipboardText = <String>[];
    final terminal = Terminal(onOutput: outputs.add);
    final controller = TerminalController(vsync: const TestVSync());
    terminal.write('copy');
    controller.setSelection(
      terminal.buffer.createAnchor(0, 0),
      terminal.buffer.createAnchor(4, 0),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final arguments = call.arguments as Map<dynamic, dynamic>;
          clipboardText.add(arguments['text'] as String);
        }
        return null;
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            controller: controller,
            autofocus: true,
            hardwareKeyboardOnly: true,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(outputs, isEmpty);
    expect(clipboardText, ['copy']);

    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    controller.dispose();
  });

  testWidgets('Windows Ctrl+V pastes clipboard text', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final outputs = <String>[];
    final terminal = Terminal(onOutput: outputs.add);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': 'paste'};
        }
        return null;
      },
    );

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
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(outputs, ['paste']);

    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('backspace handles platform key repeat events', (tester) async {
    final outputs = <String>[];
    final terminal = Terminal(onOutput: outputs.add);

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

    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
    expect(outputs.length, 1);

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.backspace);
    expect(outputs.length, 2);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    expect(outputs.length, 2);
  });
}
