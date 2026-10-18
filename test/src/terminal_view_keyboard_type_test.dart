import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';
import 'package:xterm/xterm.dart';

void main() {
  testWidgets('TerminalView asks for plain text input by default',
      (tester) async {
    final terminal = Terminal();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TerminalView(terminal)),
      ),
    );
    await tester.pump();

    final edit = tester.widget<CustomTextEdit>(find.byType(CustomTextEdit));
    expect(
      edit.inputType,
      TextInputType.text,
      reason: 'a terminal should not request an email keyboard or disable IME '
          'composition',
    );
  });

  testWidgets('an explicit keyboard type is preserved', (tester) async {
    final terminal = Terminal();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(
            terminal,
            keyboardType: TextInputType.emailAddress,
          ),
        ),
      ),
    );
    await tester.pump();

    final edit = tester.widget<CustomTextEdit>(find.byType(CustomTextEdit));
    expect(edit.inputType, TextInputType.emailAddress);
  });
}
