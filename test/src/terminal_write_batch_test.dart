import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Terminal.write batching', () {
    testWidgets('coalesces multiple writes into one frame flush', (tester) async {
      final terminal = Terminal();
      var notifyCount = 0;

      terminal.addListener(() {
        notifyCount++;
      });

      terminal.write('hello');
      terminal.write(' world');

      expect(notifyCount, 0);

      await tester.pump();

      expect(notifyCount, 1);
    });

    testWidgets('flushes again for a later frame', (tester) async {
      final terminal = Terminal();
      var notifyCount = 0;

      terminal.addListener(() {
        notifyCount++;
      });

      terminal.write('hello');
      await tester.pump();

      terminal.write(' world');
      await tester.pump();

      expect(notifyCount, 2);
    });
  });
}
