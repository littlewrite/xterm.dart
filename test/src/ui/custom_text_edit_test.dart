import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/custom_text_edit.dart';

void main() {
  testWidgets('sends cached IME geometry when the input connection opens', (
    tester,
  ) async {
    final focusNode = FocusNode();

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: CustomTextEdit(
            focusNode: focusNode,
            onInsert: (_) {},
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

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );
    const caretRect = Rect.fromLTWH(40, 60, 10, 20);
    state.setEditableRect(
      const Size(800, 600),
      Matrix4.identity(),
      caretRect,
    );

    tester.testTextInput.log.clear();
    focusNode.requestFocus();
    await tester.pump();

    final composingRectCall = tester.testTextInput.log.singleWhere(
      (call) => call.method == 'TextInput.setMarkedTextRect',
    );
    expect(composingRectCall.arguments, <String, dynamic>{
      'width': caretRect.width,
      'height': caretRect.height,
      'x': caretRect.left,
      'y': caretRect.top,
    });

    focusNode.dispose();
  });

  testWidgets('reports terminal cursor rect as the IME composing rect', (
    tester,
  ) async {
    final focusNode = FocusNode();

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: CustomTextEdit(
            focusNode: focusNode,
            onInsert: (_) {},
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

    tester.testTextInput.log.clear();

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );
    const caretRect = Rect.fromLTWH(24, 36, 8, 16);
    state.setEditableRect(
      const Size(640, 480),
      Matrix4.identity(),
      caretRect,
    );

    final composingRectCall = tester.testTextInput.log.singleWhere(
      (call) => call.method == 'TextInput.setMarkedTextRect',
    );
    expect(
      composingRectCall.arguments,
      <String, dynamic>{
        'width': caretRect.width,
        'height': caretRect.height,
        'x': caretRect.left,
        'y': caretRect.top,
      },
    );

    focusNode.dispose();
  });

  testWidgets('keeps the IME rect stable while composing on macOS', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final focusNode = FocusNode();

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: CustomTextEdit(
            focusNode: focusNode,
            onInsert: (_) {},
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

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );
    const initialRect = Rect.fromLTWH(24, 36, 8, 16);
    state.setEditableRect(
      const Size(640, 480),
      Matrix4.identity(),
      initialRect,
    );

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'pin',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ),
    );
    await tester.pump();

    state.setEditableRect(
      const Size(640, 480),
      Matrix4.identity(),
      const Rect.fromLTWH(160, 180, 8, 16),
    );

    expect(state.caretRect, initialRect);

    debugDefaultTargetPlatformOverride = null;
    focusNode.dispose();
  });

  for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
    testWidgets('updates the IME rect while composing on ${platform.name}', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final focusNode = FocusNode();

      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: CustomTextEdit(
              focusNode: focusNode,
              onInsert: (_) {},
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

      final state = tester.state<CustomTextEditState>(
        find.byType(CustomTextEdit),
      );
      state.setEditableRect(
        const Size(640, 480),
        Matrix4.identity(),
        const Rect.fromLTWH(24, 36, 8, 16),
      );

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'pin',
          selection: TextSelection.collapsed(offset: 3),
          composing: TextRange(start: 0, end: 3),
        ),
      );
      await tester.pump();

      tester.testTextInput.log.clear();
      const updatedRect = Rect.fromLTWH(48, 36, 0, 16);
      state.setEditableRect(
        const Size(640, 480),
        Matrix4.identity(),
        updatedRect,
      );

      expect(state.caretRect, updatedRect);
      final composingRectCall = tester.testTextInput.log.singleWhere(
        (call) => call.method == 'TextInput.setMarkedTextRect',
      );
      expect(composingRectCall.arguments, <String, dynamic>{
        'width': updatedRect.width,
        'height': updatedRect.height,
        'x': updatedRect.left,
        'y': updatedRect.top,
      });

      debugDefaultTargetPlatformOverride = null;
      focusNode.dispose();
    });
  }

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

  testWidgets('commits composing text when IME collapses composition in place',
      (
    tester,
  ) async {
    final focusNode = FocusNode();
    final inserted = <String>[];
    final composing = <String?>[];
    final events = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: CustomTextEdit(
            focusNode: focusNode,
            onInsert: (text) {
              inserted.add(text);
              events.add('insert:$text');
            },
            onDelete: () {},
            onComposing: (text) {
              composing.add(text);
              events.add('composing:$text');
            },
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
    expect(events, ['composing:你好', 'insert:你好', 'composing:null']);

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

  testWidgets('paste sends text to terminal via onInsert', (
    tester,
  ) async {
    final focusNode = FocusNode();
    final inserted = <String>[];
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

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );

    await state.pasteText(SelectionChangedCause.toolbar);
    await tester.pump();

    // Paste now sends text directly via onInsert, not through textEditingValue.
    expect(inserted, ['paste']);
    expect(state.textEditingValue.text, isEmpty);

    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
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
