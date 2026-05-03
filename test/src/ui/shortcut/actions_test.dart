import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/shortcut/actions.dart';
import 'package:xterm/src/ui/shortcut/intents.dart';

void main() {
  testWidgets('search intent triggers terminal search callback', (
    tester,
  ) async {
    final terminal = Terminal();
    final controller = TerminalController();
    var invoked = false;
    BuildContext? context;

    terminal.onSearch = () {
      invoked = true;
    };

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: TerminalActions(
          terminal: terminal,
          controller: controller,
          child: Builder(
            builder: (buildContext) {
              context = buildContext;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    Actions.invoke(context!, const ShowSearchIntent());

    expect(invoked, isTrue);
  });
}
