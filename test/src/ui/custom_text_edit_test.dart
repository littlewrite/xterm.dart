import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
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

  testWidgets('toolbar exposes cancel action when clear callback is provided', (
    tester,
  ) async {
    final focusNode = FocusNode();
    var cleared = false;

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
            hasSelection: () => true,
            getSelectedText: () => 'hello',
            onClearSelection: () {
              cleared = true;
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );

    state.showToolbar(globalSelectionRect: const Rect.fromLTWH(20, 20, 40, 20));
    await tester.pumpAndSettle();

    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(cleared, isTrue);

    focusNode.dispose();
  });

  testWidgets('toolbar works without MaterialLocalizations', (tester) async {
    final focusNode = FocusNode();

    await tester.pumpWidget(
      CupertinoApp(
        home: CupertinoPageScaffold(
          child: CustomTextEdit(
            focusNode: focusNode,
            onInsert: (_) {},
            onDelete: () {},
            onComposing: (_) {},
            onAction: (_) {},
            onKeyEvent: (node, event) => KeyEventResult.ignored,
            onInputConnectionChange: (connected) {},
            hasSelection: () => true,
            getSelectedText: () => 'hello',
            onClearSelection: () {},
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );

    state.showToolbar(globalSelectionRect: const Rect.fromLTWH(20, 20, 40, 20));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    focusNode.dispose();
  });

  testWidgets('contextMenuBuilder receives semantic actions', (tester) async {
    final focusNode = FocusNode();
    var cleared = false;
    var customTapped = false;
    TerminalContextMenu? menuRequest;

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
            hasSelection: () => true,
            getSelectedText: () => 'hello',
            onClearSelection: () {
              cleared = true;
            },
            toolbarBuilder: (context, state, defaultItems) {
              return <ContextMenuButtonItem>[
                ...defaultItems,
                ContextMenuButtonItem(
                  label: 'Inspect',
                  onPressed: () {
                    customTapped = true;
                    state.hideToolbar();
                  },
                ),
              ];
            },
            contextMenuBuilder: (context, menu) {
              menuRequest = menu;
              return Material(
                child: Column(
                  children: [
                    for (final action in menu.actions)
                      TextButton(
                        onPressed: action.onSelected,
                        child: Text(action.label ?? 'unnamed'),
                      ),
                  ],
                ),
              );
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );

    state.showToolbar(
      globalSelectionRect: const Rect.fromLTWH(20, 20, 40, 20),
      triggerKind: TerminalContextMenuTriggerKind.secondaryTap,
    );
    await tester.pumpAndSettle();

    expect(menuRequest, isNotNull);
    expect(
        menuRequest!.triggerKind, TerminalContextMenuTriggerKind.secondaryTap);
    expect(
      menuRequest!.actions.any(
        (action) => action.type == TerminalContextMenuActionType.clearSelection,
      ),
      isTrue,
    );
    expect(find.text('Inspect'), findsOneWidget);

    await tester.tap(find.text('Inspect'));
    await tester.pumpAndSettle();

    expect(customTapped, isTrue);

    state.showToolbar(
      globalSelectionRect: const Rect.fromLTWH(20, 20, 40, 20),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(cleared, isTrue);

    focusNode.dispose();
  });

  testWidgets('terminal menu select all does not rebuild a hidden menu', (
    tester,
  ) async {
    final focusNode = FocusNode();
    var selectAllCount = 0;

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
            onSelectAll: () {
              selectAllCount++;
            },
            contextMenuBuilder: (context, menu) {
              return Material(
                child: Column(
                  children: [
                    for (final action in menu.actions)
                      TextButton(
                        onPressed: action.enabled
                            ? () {
                                action.onSelected();
                                menu.hide();
                              }
                            : null,
                        child: Text(action.type.name),
                      ),
                  ],
                ),
              );
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );

    focusNode.requestFocus();
    await tester.pump();

    final state = tester.state<CustomTextEditState>(
      find.byType(CustomTextEdit),
    );

    state.showContextMenu(
      globalAnchorRect: const Rect.fromLTWH(20, 20, 40, 20),
      menuKind: TerminalContextMenuKind.terminal,
    );
    await tester.pumpAndSettle();

    expect(find.text('selectAll'), findsOneWidget);

    await tester.tap(find.text('selectAll'));
    await tester.pumpAndSettle();

    expect(selectAllCount, 1);
    expect(state.isToolbarShown, isFalse);
    expect(tester.takeException(), isNull);

    focusNode.dispose();
  });
}
