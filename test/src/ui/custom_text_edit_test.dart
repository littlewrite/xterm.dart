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

  testWidgets('does not resend unchanged IME geometry', (tester) async {
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
    const editableSize = Size(640, 480);
    const caretRect = Rect.fromLTWH(24, 36, 8, 16);
    state.setEditableRect(editableSize, Matrix4.identity(), caretRect);

    tester.testTextInput.log.clear();
    state.setEditableRect(editableSize, Matrix4.identity(), caretRect);

    expect(tester.testTextInput.log, isEmpty);

    focusNode.dispose();
  });

  testWidgets('updates the IME rect while composing', (tester) async {
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

    focusNode.dispose();
  });

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

  testWidgets('does not reopen input connection on inherited rebuild', (
    tester,
  ) async {
    final focusNode = FocusNode();

    Widget buildEditor(MediaQueryData mediaQuery) {
      return MediaQuery(
        data: mediaQuery,
        child: MaterialApp(
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
    }

    await tester.pumpWidget(buildEditor(const MediaQueryData()));
    focusNode.requestFocus();
    await tester.pump();

    tester.testTextInput.log.clear();
    await tester.pumpWidget(
      buildEditor(const MediaQueryData(textScaler: TextScaler.linear(1.1))),
    );
    await tester.pump();

    expect(
      tester.testTextInput.log.where((call) => call.method == 'TextInput.show'),
      isEmpty,
    );
    expect(
      tester.testTextInput.log.where(
        (call) => call.method == 'TextInput.setEditingState',
      ),
      isEmpty,
    );

    focusNode.dispose();
  });

  testWidgets('shows an existing input connection on request', (tester) async {
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

    tester.testTextInput.log.clear();
    state.requestKeyboard();

    expect(
      tester.testTextInput.log.map((call) => call.method),
      ['TextInput.show'],
    );

    await tester.pumpWidget(const SizedBox.shrink());
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

  testWidgets('paste prefers onPasteText over onInsert', (tester) async {
    final focusNode = FocusNode();
    final inserted = <String>[];
    final pasted = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': 'a\x1b[2Jb'};
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
            onPasteText: pasted.add,
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

    // Raw clipboard text goes to the host so Terminal.paste can sanitize it
    // and apply bracketed-paste wrapping.
    expect(pasted, ['a\x1b[2Jb']);
    expect(inserted, isEmpty);

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

  testWidgets('does not write characters twice for one batch of updates', (
    tester,
  ) async {
    final mounted = await _mount(tester);

    // GTK computes each value from the text before the reset took effect.
    for (final text in ['g', 'gi', 'gi', 'git']) {
      mounted.state.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
    }

    expect(mounted.inserted, ['g', 'i', 't']);

    mounted.focusNode.dispose();
  });

  testWidgets('a repeated or shortened burst value is not written again', (
    tester,
  ) async {
    final mounted = await _mount(tester);

    for (final text in ['ab', 'ab', 'a']) {
      mounted.state.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
    }

    // The shrink is a backspace this layer does not mirror, but it must not
    // insert the already-delivered text a second time.
    expect(mounted.inserted, ['ab']);

    mounted.focusNode.dispose();
  });

  testWidgets('inserts an IME commit that extends the composition whole', (
    tester,
  ) async {
    final mounted = await _mount(tester);

    mounted.state.updateEditingValue(
      const TextEditingValue(
        text: 'hel',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ),
    );
    mounted.state.updateEditingValue(
      const TextEditingValue(
        text: 'hello',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );

    // The composition was only previewed, so all of it is new input.
    expect(mounted.inserted, ['hello']);

    mounted.focusNode.dispose();
  });

  testWidgets('an IME write over the placeholder inserts all it wrote', (
    tester,
  ) async {
    final mounted = await _mount(tester, deleteDetection: true);

    // The IME replaced the placeholder instead of appending after it.
    mounted.state.updateEditingValue(
      const TextEditingValue(
        text: 'x',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );

    expect(mounted.inserted, ['x']);

    mounted.focusNode.dispose();
  });

  testWidgets('a composition starts a new batch of input', (tester) async {
    final mounted = await _mount(tester);

    mounted.state.updateEditingValue(
      const TextEditingValue(
        text: 'a',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    // Composition clears the batch state, so this commit is not trimmed
    // against the unrelated `a` typed before it.
    mounted.state.updateEditingValue(
      const TextEditingValue(
        text: 'abc',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 0, end: 3),
      ),
    );
    mounted.state.updateEditingValue(
      const TextEditingValue(
        text: 'abc',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );

    expect(mounted.inserted, ['a', 'abc']);

    mounted.focusNode.dispose();
  });

  testWidgets('a commit that replaces the placeholder keeps a leading space', (
    tester,
  ) async {
    final mounted = await _mount(tester, deleteDetection: true);

    // The IME replaced the two-space placeholder instead of appending to it.
    // Matching the placeholder's first space must not eat the typed space.
    mounted.state.updateEditingValue(
      const TextEditingValue(
        text: ' x',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );

    expect(mounted.inserted, [' x']);

    mounted.focusNode.dispose();
  });

  testWidgets('an edit after the burst frame is inserted whole', (
    tester,
  ) async {
    final mounted = await _mount(tester);

    mounted.state.updateEditingValue(
      const TextEditingValue(
        text: 'a',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    // The frame boundary ends the burst: what follows starts with the same
    // text by coincidence, not because it belongs to the same edit.
    await tester.pump();
    mounted.state.updateEditingValue(
      const TextEditingValue(
        text: 'ab',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );

    expect(mounted.inserted, ['a', 'ab']);

    mounted.focusNode.dispose();
  });

  testWidgets('an unrelated value in the same frame is not trimmed', (
    tester,
  ) async {
    final mounted = await _mount(tester);

    mounted.state.updateEditingValue(
      const TextEditingValue(
        text: 'a',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    mounted.state.updateEditingValue(
      const TextEditingValue(
        text: 'xyz',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );

    expect(mounted.inserted, ['a', 'xyz']);

    mounted.focusNode.dispose();
  });
}

Future<
    ({
      CustomTextEditState state,
      List<String> inserted,
      FocusNode focusNode,
    })> _mount(WidgetTester tester, {bool deleteDetection = false}) async {
  final focusNode = FocusNode();
  final inserted = <String>[];

  await tester.pumpWidget(
    MaterialApp(
      home: Material(
        child: CustomTextEdit(
          focusNode: focusNode,
          deleteDetection: deleteDetection,
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

  final state = tester.state<CustomTextEditState>(
    find.byType(CustomTextEdit),
  );

  return (state: state, inserted: inserted, focusNode: focusNode);
}
