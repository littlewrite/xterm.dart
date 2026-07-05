import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('idle write requests an engine frame and flushes once',
      (tester) async {
    final terminal = Terminal();
    var notifications = 0;
    terminal.addListener(() {
      notifications++;
    });
    terminal.debugResetFrameFlushCounters();

    terminal.write('hello');

    expect(terminal.dbgEngineFrameRequestCount, 1);
    expect(terminal.dbgReusedPendingFrameCount, 0);
    expect(terminal.dbgListenerFlushCount, 0);

    await tester.pump();

    expect(terminal.dbgListenerFlushCount, 1);
    expect(notifications, 1);
  });

  testWidgets('write reuses an already scheduled frame', (tester) async {
    final terminal = Terminal();
    var notifications = 0;
    terminal.addListener(() {
      notifications++;
    });
    terminal.debugResetFrameFlushCounters();

    tester.binding.scheduleFrame();
    terminal.write('hello');

    expect(terminal.dbgEngineFrameRequestCount, 0);
    expect(terminal.dbgReusedPendingFrameCount, 1);

    await tester.pump();

    expect(terminal.dbgListenerFlushCount, 1);
    expect(notifications, 1);
  });
}
