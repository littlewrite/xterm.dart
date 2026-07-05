import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void report(String name, Terminal terminal, int writes, double usPerWrite) {
    // ignore: avoid_print
    print('  [BENCH-FRAME] $name: ${usPerWrite.toStringAsFixed(1)} μs/write '
        'writes=$writes engineRequests=${terminal.dbgEngineFrameRequestCount} '
        'reused=${terminal.dbgReusedPendingFrameCount} '
        'flushes=${terminal.dbgListenerFlushCount}');
  }

  group('Terminal frame scheduling benchmark', () {
    testWidgets('idle writes request frames', (tester) async {
      final terminal = Terminal();
      const writes = 100;
      terminal.debugResetFrameFlushCounters();

      final sw = Stopwatch()..start();
      for (var i = 0; i < writes; i++) {
        terminal.write('x');
        await tester.pump();
      }
      sw.stop();

      report(
        'idle-writes',
        terminal,
        writes,
        sw.elapsedMicroseconds / writes,
      );
      expect(terminal.dbgEngineFrameRequestCount, writes);
      expect(terminal.dbgReusedPendingFrameCount, 0);
    });

    testWidgets('writes reuse existing scheduled frames', (tester) async {
      final terminal = Terminal();
      const writes = 100;
      terminal.debugResetFrameFlushCounters();

      final sw = Stopwatch()..start();
      for (var i = 0; i < writes; i++) {
        tester.binding.scheduleFrame();
        terminal.write('x');
        await tester.pump();
      }
      sw.stop();

      report(
        'reuse-pending-frame',
        terminal,
        writes,
        sw.elapsedMicroseconds / writes,
      );
      expect(terminal.dbgEngineFrameRequestCount, 0);
      expect(terminal.dbgReusedPendingFrameCount, writes);
    });
  });
}
