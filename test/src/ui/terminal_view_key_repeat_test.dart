import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/terminal_view.dart';

void main() {
  testWidgets('Windows Ctrl+C and Ctrl+V are sent to the terminal', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final outputs = <String>[];
    final logs = <String>[];
    final terminal = Terminal(onOutput: outputs.add);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            autofocus: true,
            hardwareKeyboardOnly: true,
            onDebugLog: logs.add,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;

    expect(outputs, ['\x03', '\x16']);
    expect(
      logs,
      contains(contains('terminalKey=TerminalKey.keyC handled=true')),
    );
    expect(
      logs,
      contains(contains('terminalKey=TerminalKey.keyV handled=true')),
    );
  });

  testWidgets('backspace repeats when holding key', (tester) async {
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
    await tester.pump();
    expect(outputs.length, 1);

    await tester.pump(const Duration(milliseconds: 350));
    expect(outputs.length, greaterThan(1));

    final repeatsBeforeRelease = outputs.length;

    await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
    await tester.pump(const Duration(milliseconds: 100));
    expect(outputs.length, repeatsBeforeRelease);
  });
}
