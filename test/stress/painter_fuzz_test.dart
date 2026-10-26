import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/buffer/cell_flags.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/themes.dart';

/// Randomised coverage for the coalesced paint path.
///
/// Every combination of content, attributes and blink phase must paint without
/// throwing, and must never issue more cell draws than there are cells (a run
/// only ever merges cells, never duplicates them).
///
/// Run: `flutter test test/stress/painter_fuzz_test.dart`

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TerminalPainter makePainter() => TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );

  int randomColor(Random rng) {
    switch (rng.nextInt(4)) {
      case 0:
        return CellColor.normal;
      case 1:
        return CellColor.named | rng.nextInt(8);
      case 2:
        return CellColor.palette | rng.nextInt(256);
      default:
        return CellColor.rgb | rng.nextInt(0x1000000);
    }
  }

  int randomCodePoint(Random rng) {
    switch (rng.nextInt(10)) {
      case 0:
      case 1:
      case 2:
      case 3:
      case 4:
        return 0x20 + rng.nextInt(0x5F);
      case 5:
      case 6:
        return 0x4E00 + rng.nextInt(0x1000); // CJK, two columns
      case 7:
        return 0x2580 + rng.nextInt(0x20); // blocks, custom glyphs
      case 8:
        return 0x1F600 + rng.nextInt(0x50); // emoji, two columns
      default:
        return 0x0300 + rng.nextInt(0x70); // combining, zero columns
    }
  }

  BufferLine randomLine(Random rng, int length) {
    final line = BufferLine(length);
    var i = 0;
    while (i < length) {
      line.setCodePoint(i, randomCodePoint(rng));
      i += line.getWidth(i) == 2 ? 2 : 1;
    }

    final cell = CellData.empty();
    for (var c = 0; c < length; c++) {
      line.setForeground(c, randomColor(rng));
      line.setBackground(c, randomColor(rng));
      var flags = 0;
      if (rng.nextBool()) flags |= CellFlags.bold;
      if (rng.nextBool()) flags |= CellFlags.faint;
      if (rng.nextBool()) flags |= CellFlags.italic;
      if (rng.nextBool()) flags |= CellFlags.underline;
      if (rng.nextBool()) flags |= CellFlags.blink;
      if (rng.nextBool()) flags |= CellFlags.inverse;
      if (rng.nextInt(10) == 0) flags |= CellFlags.invisible;
      line.setAttributes(c, flags);

      line.getCellData(c, cell);
      cell.underlineStyle = rng.nextInt(6);
      cell.underlineColor = rng.nextBool() ? randomColor(rng) : 0;
      line.setCellData(c, cell);
    }
    return line;
  }

  void paintLine(
    TerminalPainter painter,
    BufferLine line,
    Offset offset,
  ) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.resetDebugDrawCounts();
    painter.paintLine(canvas, offset, line);
    final picture = recorder.endRecording();
    picture.dispose();

    expect(
      painter.debugDrawParagraphCount,
      lessThanOrEqualTo(line.length),
      reason: 'a run merges cells, it never draws one twice',
    );
    expect(
      painter.debugDrawBackgroundRectCount,
      lessThanOrEqualTo(line.length),
    );
  }

  for (final seed in [1, 7, 42, 2026]) {
    test('random lines paint and coalesce (seed=$seed)', () {
      final rng = Random(seed);
      final painter = makePainter();

      for (var round = 0; round < 120; round++) {
        final line = randomLine(rng, rng.nextInt(160) + 1);
        final offset = Offset(rng.nextDouble() * 4, rng.nextDouble() * 4);
        painter.blinkVisible = rng.nextBool();
        painter.coalesceRuns = rng.nextBool();

        // Paint twice: the second pass goes through the line picture cache.
        paintLine(painter, line, offset);
        paintLine(painter, line, offset);
      }
    });
  }

  test('backgrounds and foregrounds can be painted separately', () {
    final rng = Random(99);
    final painter = makePainter();

    for (var round = 0; round < 40; round++) {
      final line = randomLine(rng, rng.nextInt(80) + 1);
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);

      painter.resetDebugDrawCounts();
      painter.paintLineBackgrounds(canvas, Offset.zero, line);
      expect(
        painter.debugDrawBackgroundRectCount,
        lessThanOrEqualTo(line.length),
      );
      expect(painter.debugDrawParagraphCount, 0);

      painter.resetDebugDrawCounts();
      painter.paintLineForegrounds(canvas, Offset.zero, line);
      expect(
        painter.debugDrawParagraphCount,
        lessThanOrEqualTo(line.length),
      );

      recorder.endRecording().dispose();
    }
  });
}
