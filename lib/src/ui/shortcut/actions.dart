import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/selection_mode.dart';

class CopyTerminalSelectionAction extends Action<CopySelectionTextIntent> {
  CopyTerminalSelectionAction({
    required this.isSelectionAvailable,
    required this.onCopy,
  });

  final bool Function() isSelectionAvailable;
  final Object? Function(CopySelectionTextIntent intent) onCopy;

  @override
  bool isEnabled(CopySelectionTextIntent intent) => isSelectionAvailable();

  @override
  Object? invoke(CopySelectionTextIntent intent) => onCopy(intent);
}

class TerminalActions extends StatelessWidget {
  const TerminalActions({
    super.key,
    required this.terminal,
    required this.controller,
    this.onPaste,
    required this.child,
  });

  final Terminal terminal;

  final TerminalController controller;

  final void Function()? onPaste;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Actions(
      actions: {
        PasteTextIntent: CallbackAction<PasteTextIntent>(
          onInvoke: (intent) async {
            if (onPaste != null) {
              onPaste!();
              controller.clearSelection();
              return null;
            }

            final data = await Clipboard.getData(Clipboard.kTextPlain);
            final text = data?.text;
            if (text != null) {
              terminal.paste(text);
              controller.clearSelection();
            }
            return null;
          },
        ),
        CopySelectionTextIntent: CopyTerminalSelectionAction(
          isSelectionAvailable: () =>
              controller.selection?.isCollapsed == false,
          onCopy: (intent) async {
            final selection = controller.selection;

            if (selection == null) {
              return;
            }

            final text = terminal.buffer.getText(selection);

            await Clipboard.setData(ClipboardData(text: text));

            return null;
          },
        ),
        SelectAllTextIntent: CallbackAction<SelectAllTextIntent>(
          onInvoke: (intent) {
            controller.setSelection(
              terminal.buffer.createAnchor(
                0,
                terminal.buffer.height - terminal.viewHeight,
              ),
              terminal.buffer.createAnchor(
                terminal.viewWidth,
                terminal.buffer.height - 1,
              ),
              mode: SelectionMode.line,
            );
            return null;
          },
        ),
      },
      child: child,
    );
  }
}
