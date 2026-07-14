import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TerminalRenderDebug.enabled = false;
    TerminalRenderDebug.sink = null;
    TerminalRenderDebug.resetCounters();
  });

  testWidgets('renderDebug emits paint/flush diagnostics only when enabled',
      (tester) async {
    final logs = <String>[];
    TerminalRenderDebug.resetCounters();

    final terminal = Terminal(maxLines: 500);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 240,
            child: TerminalView(
              terminal,
              textStyle: const TerminalStyle(fontSize: 12),
              onDebugLog: logs.add,
              renderDebug: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      logs,
      anyElement(contains('renderDebug enabled')),
      reason: '显式打开 renderDebug 后应记录初始化日志',
    );
    expect(logs, anyElement(contains('[xterm.render] paint#')));

    terminal.write('hello\r\n');
    terminal.write('world\r\n');
    await tester.pump();

    expect(logs, anyElement(contains('[xterm.render] flush#')));
    expect(logs, anyElement(contains('[xterm.render] change#')));
  });

  test('TerminalRenderDebug.enabled defaults to false', () {
    expect(TerminalRenderDebug.enabled, isFalse);
  });
}
