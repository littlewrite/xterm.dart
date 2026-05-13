import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';

void main() {
  testWidgets('IME delete command emits a single backspace', (tester) async {
    final focusNode = FocusNode();
    var deleteCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: CustomTextEdit(
            focusNode: focusNode,
            onInsert: (_) {},
            onDelete: () => deleteCount++,
            onComposing: (_) {},
            onAction: (_) {},
            onKeyEvent: (node, event) => KeyEventResult.ignored,
            onInputConnectionChange: (connected) {},
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );

    state.performPrivateCommand('deleteSurroundingText', {'beforeLength': 128});
    await tester.pump();

    expect(deleteCount, 1);

    focusNode.dispose();
  });

  testWidgets('deleteDetection placeholder ignores follow-up IME updates', (
    tester,
  ) async {
    final focusNode = FocusNode();
    var deleteCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: CustomTextEdit(
            focusNode: focusNode,
            deleteDetection: true,
            onInsert: (_) {},
            onDelete: () => deleteCount++,
            onComposing: (_) {},
            onAction: (_) {},
            onKeyEvent: (node, event) => KeyEventResult.ignored,
            onInputConnectionChange: (connected) {},
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );

    state.performPrivateCommand('deleteSurroundingText', {'beforeLength': 64});
    await tester.pump();

    // Simulate the IME reporting that one of the placeholder characters was removed.
    state.updateEditingValue(
      const TextEditingValue(
        text: ' ',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );

    expect(deleteCount, 1);

    focusNode.dispose();
  });

  testWidgets('commits composing text when IME collapses composition in place', (
    tester,
  ) async {
    final focusNode = FocusNode();
    final inserted = <String>[];
    final composing = <String?>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: CustomTextEdit(
            focusNode: focusNode,
            onInsert: inserted.add,
            onDelete: () {},
            onComposing: composing.add,
            onAction: (_) {},
            onKeyEvent: (node, event) => KeyEventResult.ignored,
            onInputConnectionChange: (connected) {},
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );

    state.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    state.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange.collapsed(-1),
      ),
    );

    expect(inserted, ['你好']);
    expect(composing, ['你好', null]);

    focusNode.dispose();
  });

  testWidgets('commits final text when IME replaces composing text on commit', (
    tester,
  ) async {
    final focusNode = FocusNode();
    final inserted = <String>[];
    final composing = <String?>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: CustomTextEdit(
            focusNode: focusNode,
            onInsert: inserted.add,
            onDelete: () {},
            onComposing: composing.add,
            onAction: (_) {},
            onKeyEvent: (node, event) => KeyEventResult.ignored,
            onInputConnectionChange: (connected) {},
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );

    state.updateEditingValue(
      const TextEditingValue(
        text: 'ni hao',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 0, end: 6),
      ),
    );
    state.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange.collapsed(-1),
      ),
    );

    expect(inserted, ['你好']);
    expect(composing, ['ni hao', null]);

    focusNode.dispose();
  });

  testWidgets('exposes setText semantics action for accessibility text input', (
    tester,
  ) async {
    final focusNode = FocusNode();
    final inserted = <String>[];
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: CustomTextEdit(
            focusNode: focusNode,
            onInsert: inserted.add,
            onDelete: () {},
            onComposing: (_) {},
            onAction: (_) {},
            onKeyEvent: (node, event) => KeyEventResult.ignored,
            onInputConnectionChange: (connected) {},
            child: const SizedBox.shrink(),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final node = tester.getSemantics(find.byType(CustomTextEdit));
    expect(
      node,
      matchesSemantics(
        isTextField: true,
        isFocusable: true,
        hasSetTextAction: true,
        textDirection: TextDirection.ltr,
      ),
    );

    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(
      node.id,
      SemanticsAction.setText,
      '你好，辅助输入',
    );
    await tester.pump();

    expect(inserted, ['你好，辅助输入']);

    semantics.dispose();
    focusNode.dispose();
  });
}
