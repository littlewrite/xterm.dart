import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/terminal.dart';
import 'package:xterm/src/ui/controller.dart';
import 'package:xterm/src/ui/cursor_type.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/themes.dart';

/// Synchronized output (DEC private mode 2026): a program brackets a redraw
/// with `CSI ? 2026 h` … `CSI ? 2026 l`, and the view keeps showing the frame
/// it has until the program says the redraw is done.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const viewport = Size(80 * 9.0, 24 * 18.0);

  /// Content that stays on the lines already in the buffer, so the terminal's
  /// geometry does not change and only the content channel is involved.
  const inPlaceWrite = '\x1b[1;1Hredrawn';

  (RenderTerminal, Terminal) make() {
    final terminal = Terminal(maxLines: 200);
    terminal.write('hello\r\n');
    final controller = TerminalController();
    final focusNode = FocusNode();
    final render = RenderTerminal(
      terminal: terminal,
      controller: controller,
      offset: ViewportOffset.fixed(0),
      padding: EdgeInsets.zero,
      autoResize: false,
      textStyle: const TerminalStyle(),
      textScaler: TextScaler.noScaling,
      theme: TerminalThemes.defaultTheme,
      focusNode: focusNode,
      cursorType: TerminalCursorType.block,
      cursorBlinkEnabled: false,
      cursorBlinkVisible: true,
      alwaysShowCursor: false,
      paintCursor: false,
    );
    final owner = PipelineOwner();
    render.attach(owner);
    render.layout(BoxConstraints.tight(viewport), parentUsesSize: true);
    owner.flushLayout();
    render.debugMarkNeedsPaintCount = 0;

    addTearDown(() {
      render.detach();
      controller.dispose();
      focusNode.dispose();
    });
    return (render, terminal);
  }

  /// The terminal flushes its notifications on a frame, so a write only reaches
  /// the render object once a frame has run.
  Future<void> feed(
    WidgetTester tester,
    Terminal terminal,
    String data,
  ) async {
    terminal.write(data);
    await tester.pump();
  }

  group('the terminal parses the mode', () {
    test('set and cleared by the private mode sequences', () {
      final terminal = Terminal();
      expect(terminal.synchronizedOutput, isFalse);

      terminal.write('\x1b[?2026h');
      expect(terminal.synchronizedOutput, isTrue);

      terminal.write('\x1b[?2026l');
      expect(terminal.synchronizedOutput, isFalse);
    });

    test('set and cleared in one write leaves it cleared', () {
      final terminal = Terminal();
      terminal.write('\x1b[?2026hredrawn\x1b[?2026l');
      expect(terminal.synchronizedOutput, isFalse);
    });

    test('a neighbouring private mode is untouched', () {
      final terminal = Terminal();
      terminal.write('\x1b[?2004h');
      expect(terminal.bracketedPasteMode, isTrue);
      expect(terminal.synchronizedOutput, isFalse);
    });
  });

  group('while the program holds the frame', () {
    testWidgets('a plain write paints, so the gate below means something',
        (tester) async {
      final (render, terminal) = make();
      await feed(tester, terminal, inPlaceWrite);
      expect(render.debugMarkNeedsPaintCount, greaterThan(0));
    });

    testWidgets('a redraw on the held frame does not paint', (tester) async {
      final (render, terminal) = make();

      await feed(tester, terminal, '\x1b[?2026h');
      expect(
        render.debugMarkNeedsPaintCount,
        0,
        reason: 'setting the mode is not itself something to show',
      );

      await feed(tester, terminal, inPlaceWrite);
      await feed(tester, terminal, '\x1b[2;1Hmore of the redraw');
      expect(
        render.debugMarkNeedsPaintCount,
        0,
        reason: 'the frame is held until the program releases it',
      );

      // Let the watchdog fire so no timer outlives the test.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('releasing paints what the buffer holds', (tester) async {
      final (render, terminal) = make();

      await feed(tester, terminal, '\x1b[?2026h');
      await feed(tester, terminal, inPlaceWrite);
      expect(render.debugMarkNeedsPaintCount, 0);

      await feed(tester, terminal, '\x1b[?2026l');
      expect(render.debugMarkNeedsPaintCount, greaterThan(0));
    });

    testWidgets('a burst of many writes paints once, at the end',
        (tester) async {
      final (render, terminal) = make();

      await feed(tester, terminal, '\x1b[?2026h');
      for (var i = 0; i < 20; i++) {
        await feed(tester, terminal, '\x1b[1;${1 + i}H${i % 10}');
      }
      expect(render.debugMarkNeedsPaintCount, 0);

      await feed(tester, terminal, '\x1b[?2026l');
      expect(render.debugMarkNeedsPaintCount, greaterThan(0));
    });

    testWidgets('a program that never releases it paints after a second',
        (tester) async {
      final (render, terminal) = make();

      await feed(tester, terminal, '\x1b[?2026h');
      await feed(tester, terminal, inPlaceWrite);
      expect(render.debugMarkNeedsPaintCount, 0);

      await tester.pump(const Duration(seconds: 1));
      expect(
        render.debugMarkNeedsPaintCount,
        greaterThan(0),
        reason: 'a stuck program must not freeze the view',
      );
    });

    testWidgets('the watchdog is not restarted by later output',
        (tester) async {
      final (render, terminal) = make();

      await feed(tester, terminal, '\x1b[?2026h');
      await feed(tester, terminal, inPlaceWrite);
      await tester.pump(const Duration(seconds: 1));
      final paintsAfterTimeout = render.debugMarkNeedsPaintCount;
      expect(paintsAfterTimeout, greaterThan(0));

      // The mode is still set, but the watchdog has already opened the gate.
      // A program that keeps writing must not get another free second.
      await feed(tester, terminal, '\x1b[2;1Hmore');
      expect(
        render.debugMarkNeedsPaintCount,
        greaterThan(paintsAfterTimeout),
      );
    });

    testWidgets('the held Picture survives an unrelated repaint request',
        (tester) async {
      final (render, terminal) = make();

      await feed(tester, terminal, '\x1b[?2026h');
      await feed(tester, terminal, inPlaceWrite);
      expect(render.isHoldingSynchronizedOutput, isTrue);
      expect(render.hasHeldFrame, isTrue);

      final layer = ContainerLayer();
      render.paint(
        PaintingContext(layer, Offset.zero & viewport),
        Offset.zero,
      );

      expect(render.debugHeldFramePaintCount, 1);
      expect(
        render.isHoldingSynchronizedOutput,
        isTrue,
        reason: 'a pending repaint must not replace the held Picture',
      );
      layer.dispose();

      await feed(tester, terminal, '\x1b[?2026l');
      expect(render.isHoldingSynchronizedOutput, isFalse);
    });

    testWidgets('the hold is measured from the mode being set', (tester) async {
      final (render, terminal) = make();

      await feed(tester, terminal, '\x1b[?2026h');
      // A program still redrawing has not earned more time: upstream counts the
      // second from when the mode was set, not from the last write.
      await tester.pump(const Duration(milliseconds: 900));
      await feed(tester, terminal, inPlaceWrite);
      expect(render.debugMarkNeedsPaintCount, 0);

      await tester.pump(const Duration(milliseconds: 200));
      expect(render.debugMarkNeedsPaintCount, greaterThan(0));
    });

    testWidgets('releasing before the timeout cancels it', (tester) async {
      final (render, terminal) = make();

      await feed(tester, terminal, '\x1b[?2026h');
      await feed(tester, terminal, '\x1b[?2026l');
      final paintsAtRelease = render.debugMarkNeedsPaintCount;
      expect(paintsAtRelease, greaterThan(0));

      await tester.pump(const Duration(seconds: 2));
      expect(
        render.debugMarkNeedsPaintCount,
        paintsAtRelease,
        reason: 'the cancelled timer must not paint again',
      );
    });

    testWidgets('a later redraw can take the frame again', (tester) async {
      final (render, terminal) = make();

      await feed(tester, terminal, '\x1b[?2026h');
      await feed(tester, terminal, inPlaceWrite);
      await feed(tester, terminal, '\x1b[?2026l');
      expect(render.debugMarkNeedsPaintCount, greaterThan(0));

      render.debugMarkNeedsPaintCount = 0;
      await feed(tester, terminal, '\x1b[?2026h');
      await feed(tester, terminal, inPlaceWrite);
      expect(render.debugMarkNeedsPaintCount, 0);

      // Let the watchdog fire so no timer outlives the test.
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
