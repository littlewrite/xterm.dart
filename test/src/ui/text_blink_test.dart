import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/render.dart';
import 'package:xterm/xterm.dart';

/// SGR 5 marks text that blinks. What matters for a terminal is not that the
/// glyph can vanish — that is one `if` — but that blinking costs the rows that
/// blink and nothing else: a row without the attribute is one picture whatever
/// the phase is, and a screen without the attribute runs no timer at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final open = <ui.Picture>[];

  (TerminalPainter, Canvas) newPainter() {
    final recorder = ui.PictureRecorder();
    addTearDown(() {
      for (final picture in open) {
        picture.dispose();
      }
      open.clear();
      recorder.endRecording().dispose();
    });
    return (
      TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      ),
      Canvas(recorder),
    );
  }

  /// A line as the terminal itself would build it, so the flags are the ones
  /// the escape parser really produced.
  BufferLine writtenLine(String text) {
    final terminal = Terminal();
    terminal.write(text);
    return terminal.buffer.currentLine;
  }

  /// Counts pixels the line actually put on the canvas. The default background
  /// is not drawn, so anything with alpha is a glyph.
  Future<int> inkPixels(TerminalPainter painter, BufferLine line) async {
    final recorder = ui.PictureRecorder();
    painter.paintLine(Canvas(recorder), Offset.zero, line);
    final picture = recorder.endRecording();
    final width = (painter.cellSize.width * line.length).ceil();
    final height = painter.cellSize.height.ceil();
    final image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    picture.dispose();
    image.dispose();

    final bytes = data!.buffer.asUint8List();
    var ink = 0;
    for (var i = 3; i < bytes.length; i += 4) {
      if (bytes[i] != 0) ink++;
    }
    return ink;
  }

  group('the attribute reaches the cell', () {
    CellData cellAt(Terminal terminal, int column) {
      final cell = CellData.empty();
      terminal.buffer.currentLine.getCellData(column, cell);
      return cell;
    }

    test('SGR 5 marks the cells written after it, and SGR 25 clears it', () {
      final terminal = Terminal();
      terminal.write('\x1b[5mA\x1b[25mB');
      expect(cellAt(terminal, 0).flags & CellFlags.blink, isNot(0));
      expect(cellAt(terminal, 1).flags & CellFlags.blink, 0);
    });

    test('SGR 0 clears it', () {
      final terminal = Terminal();
      terminal.write('\x1b[5mA\x1b[0mB');
      expect(cellAt(terminal, 0).flags & CellFlags.blink, isNot(0));
      expect(cellAt(terminal, 1).flags & CellFlags.blink, 0);
    });

    test('a row of ordinary text carries no blink at all', () {
      final line = writtenLine('plain text');
      final cell = CellData.empty();
      for (var i = 0; i < line.length; i++) {
        line.getCellData(i, cell);
        expect(cell.flags & CellFlags.blink, 0);
      }
    });
  });

  group('the glyph blinks', () {
    test('is drawn in one phase and gone in the other', () async {
      final (painter, _) = newPainter();
      final line = writtenLine('\x1b[5mA');

      expect(painter.blinkVisible, isTrue);
      final visible = await inkPixels(painter, line);

      painter.blinkVisible = false;
      final hidden = await inkPixels(painter, line);

      expect(visible, greaterThan(0));
      expect(hidden, 0, reason: 'the hidden half draws no glyph');
    });

    test('ordinary text is drawn in both phases', () async {
      final (painter, _) = newPainter();
      final line = writtenLine('A');

      final visible = await inkPixels(painter, line);
      painter.blinkVisible = false;
      final hidden = await inkPixels(painter, line);

      expect(visible, greaterThan(0));
      expect(hidden, visible);
    });

    test('only the blinking cells of a row go away', () async {
      final (painter, _) = newPainter();
      final line = writtenLine('A\x1b[5mB');

      final visible = await inkPixels(painter, line);
      painter.blinkVisible = false;
      final hidden = await inkPixels(painter, line);

      expect(hidden, greaterThan(0), reason: 'the plain cell still draws');
      expect(hidden, lessThan(visible));
    });
  });

  group('a blinking row costs one picture per phase', () {
    test('the second phase records once and every flip after is a hit', () {
      final (painter, canvas) = newPainter();
      final line = writtenLine('\x1b[5mhello');

      painter.paintLine(canvas, Offset.zero, line);
      expect(painter.linePictureBuildCount, 1);

      painter.blinkVisible = false;
      painter.paintLine(canvas, Offset.zero, line);
      expect(painter.linePictureBuildCount, 2, reason: 'the second picture');

      for (final phase in [true, false, true, false]) {
        painter.blinkVisible = phase;
        painter.paintLine(canvas, Offset.zero, line);
      }
      expect(painter.linePictureBuildCount, 2, reason: 'no flip re-records');
      expect(painter.linePictureCacheHitCount, 4);
    });

    test('a row without SGR 5 is one picture in both phases', () {
      final (painter, canvas) = newPainter();
      final line = writtenLine('hello');

      painter.paintLine(canvas, Offset.zero, line);
      painter.blinkVisible = false;
      painter.paintLine(canvas, Offset.zero, line);
      painter.blinkVisible = true;
      painter.paintLine(canvas, Offset.zero, line);

      expect(painter.linePictureBuildCount, 1);
      expect(painter.linePictureCacheHitCount, 2);
    });

    test('a screen of plain text records nothing when the phase flips', () {
      final (painter, canvas) = newPainter();
      final plain = writtenLine('an ordinary row');

      for (var row = 0; row < 24; row++) {
        painter.paintLine(canvas, Offset(row * 18, 0), plain);
      }
      final before = painter.linePictureBuildCount;

      painter.blinkVisible = false;
      for (var row = 0; row < 24; row++) {
        painter.paintLine(canvas, Offset(row * 18, 0), plain);
      }

      expect(painter.linePictureBuildCount, before);
    });
  });

  group('the viewport says whether anything blinks', () {
    test('a plain screen reports nothing', () {
      final (painter, canvas) = newPainter();

      painter.beginBlinkScan();
      painter.paintLine(canvas, Offset.zero, writtenLine('plain'));

      expect(painter.sawBlinkingText, isFalse);
    });

    test('one blinking row is enough', () {
      final (painter, canvas) = newPainter();

      painter.beginBlinkScan();
      painter.paintLine(canvas, Offset.zero, writtenLine('plain'));
      painter.paintLine(canvas, Offset(0, 18), writtenLine('\x1b[5mblink'));

      expect(painter.sawBlinkingText, isTrue);
    });

    test('the next scan starts over', () {
      final (painter, canvas) = newPainter();
      final blinking = writtenLine('\x1b[5mblink');

      painter.beginBlinkScan();
      painter.paintLine(canvas, Offset.zero, blinking);
      expect(painter.sawBlinkingText, isTrue);

      painter.beginBlinkScan();
      expect(painter.sawBlinkingText, isFalse);
    });
  });

  group('the view runs a timer only while something blinks', () {
    Future<RenderTerminal> pumpView(
      WidgetTester tester,
      Terminal terminal, {
      bool textBlink = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 480,
              height: 320,
              child: TerminalView(
                terminal,
                textBlink: textBlink,
                textStyle: const TerminalStyle(fontSize: 12),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final render = tester.allRenderObjects.whereType<RenderTerminal>().first;
      render.debugMarkNeedsPaintCount = 0;
      render.debugInvalidationCounts[TerminalInvalidation.textBlink] = 0;
      return render;
    }

    int blinkTicks(RenderTerminal render) =>
        render.debugInvalidationCounts[TerminalInvalidation.textBlink] ?? 0;

    testWidgets('blinking text is repainted on each half period',
        (tester) async {
      final terminal = Terminal(maxLines: 200);
      terminal.write('plain\r\n\x1b[5mblinking');
      final render = await pumpView(tester, terminal);
      expect(render.debugPainter.sawBlinkingText, isTrue);

      await tester.pump(const Duration(milliseconds: 600));
      expect(blinkTicks(render), 1);

      await tester.pump(const Duration(milliseconds: 600));
      expect(blinkTicks(render), 2);

      // Nothing else about the view changed, so the blink is all that dirtied.
      expect(render.debugMarkNeedsPaintCount, 2);
    });

    testWidgets('a blink tick re-records only the blinking row',
        (tester) async {
      final terminal = Terminal(maxLines: 200);
      const plainRows = 12;
      terminal.write('plain row\r\n' * plainRows);
      terminal.write('\x1b[5mblinking');
      final render = await pumpView(tester, terminal);
      final painter = render.debugPainter;
      painter.resetLinePictureBuildCount();

      await tester.pump(const Duration(milliseconds: 600));

      expect(
        painter.linePictureBuildCount,
        lessThan(plainRows),
        reason: 'plain rows must keep their Pictures while the blinking row '
            'switches phase',
      );
      expect(painter.linePictureCacheHitCount, greaterThan(0));
    });

    testWidgets('ordinary output runs no timer at all', (tester) async {
      final terminal = Terminal(maxLines: 200);
      terminal.write('plain text\r\nmore plain text');
      final render = await pumpView(tester, terminal);
      expect(render.debugPainter.sawBlinkingText, isFalse);

      await tester.pump(const Duration(seconds: 2));
      expect(blinkTicks(render), 0);
      expect(render.debugMarkNeedsPaintCount, 0);
    });

    testWidgets('the timer stops once the blinking row scrolls away',
        (tester) async {
      final terminal = Terminal(maxLines: 200);
      terminal.write('\x1b[5mblinking');
      final render = await pumpView(tester, terminal);
      expect(render.debugPainter.sawBlinkingText, isTrue);

      await tester.pump(const Duration(milliseconds: 600));
      expect(blinkTicks(render), 1);

      // Rewrite the line without the attribute; the next paint finds nothing
      // blinking and the timer goes away.
      terminal.write('\x1b[0m\r\x1b[Kno longer');
      await tester.pump();
      expect(render.debugPainter.sawBlinkingText, isFalse);

      final ticksAfterRewrite = blinkTicks(render);
      await tester.pump(const Duration(seconds: 2));
      expect(blinkTicks(render), ticksAfterRewrite);
    });

    testWidgets('turning textBlink off leaves the glyphs alone',
        (tester) async {
      final terminal = Terminal(maxLines: 200);
      terminal.write('\x1b[5mblinking');
      final render = await pumpView(tester, terminal, textBlink: false);
      expect(render.debugPainter.sawBlinkingText, isTrue);

      await tester.pump(const Duration(seconds: 2));
      expect(blinkTicks(render), 0);

      final cell = CellData.empty();
      terminal.buffer.currentLine.getCellData(0, cell);
      expect(
        cell.flags & CellFlags.blink,
        isNot(0),
        reason: 'the attribute is still parsed, it is just not animated',
      );
    });

    testWidgets('the timer is gone once the view is disposed', (tester) async {
      final terminal = Terminal(maxLines: 200);
      terminal.write('\x1b[5mblinking');
      final render = await pumpView(tester, terminal);
      await tester.pump(const Duration(milliseconds: 600));
      expect(blinkTicks(render), 1);

      await tester.pumpWidget(const SizedBox.shrink());
      // A live timer would keep marking the detached object paint dirty and
      // fail the test with a pending timer.
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
