import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/buffer/cell_flags.dart';
import 'package:xterm/src/core/buffer/line.dart';
import 'package:xterm/src/core/cell.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/src/ui/terminal_text_style.dart';
import 'package:xterm/src/ui/themes.dart';

/// Tests for the coalesced paint path:
///
/// * runs of same-style ASCII cells become one [Paragraph], background spans
///   become one rect;
/// * every cell a run cannot absorb keeps its own column;
/// * the coalesced output must be pixel-identical to the cell-by-cell path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TerminalPainter makePainter({
    bool coalesceRuns = true,
    TerminalStyle style = const TerminalStyle(),
    TextScaler scaler = TextScaler.noScaling,
  }) =>
      TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: style,
        textScaler: scaler,
      )..coalesceRuns = coalesceRuns;

  void setUnderline(
    BufferLine line,
    int index, {
    int style = 0,
    int color = 0,
  }) {
    final cell = CellData.empty();
    line.getCellData(index, cell);
    cell.underlineStyle = style;
    cell.underlineColor = color;
    line.setCellData(index, cell);
  }

  BufferLine textLine(String text) {
    final line = BufferLine(text.length);
    var i = 0;
    for (final rune in text.runes) {
      line.setCodePoint(i, rune);
      i += line.getWidth(i) == 2 ? 2 : 1;
    }
    return line;
  }

  ({int paragraphs, int rects}) paint(
    TerminalPainter painter,
    BufferLine line,
  ) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.resetDebugDrawCounts();
    painter.paintLine(canvas, Offset.zero, line);
    final picture = recorder.endRecording();
    picture.dispose();
    return (
      paragraphs: painter.debugDrawParagraphCount,
      rects: painter.debugDrawBackgroundRectCount,
    );
  }

  ui.Image rasterize(TerminalPainter painter, BufferLine line) {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    painter.paintLine(canvas, Offset.zero, line);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      (80 * painter.cellSize.width).ceil(),
      painter.cellSize.height.ceil(),
    );
    picture.dispose();
    return image;
  }

  Future<Uint8List> pixels(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  }

  group('foreground runs', () {
    test('plain ASCII becomes one paragraph', () {
      final counts = paint(
        makePainter(),
        textLine('hello world, this is a plain line of text'),
      );
      expect(counts.paragraphs, 1);
    });

    test('a colour change starts a new run', () {
      final line = textLine('abcdefghij');
      for (var i = 0; i < 5; i++) {
        line.setForeground(i, CellColor.named | 1);
      }
      expect(paint(makePainter(), line).paragraphs, 2);
    });

    test('inverse splits a run even when the raw background is normal', () {
      final line = textLine('abcd');
      line.setAttributes(0, CellFlags.inverse);
      line.setAttributes(1, CellFlags.inverse);
      expect(paint(makePainter(), line).paragraphs, 2);
    });

    test('faint and bold split runs', () {
      final line = textLine('abcdef');
      line.setAttributes(0, CellFlags.faint);
      line.setAttributes(1, CellFlags.faint);
      line.setAttributes(2, CellFlags.faint);
      line.setAttributes(3, CellFlags.bold);
      line.setAttributes(4, CellFlags.bold);
      line.setAttributes(5, CellFlags.bold);
      expect(paint(makePainter(), line).paragraphs, 2);
    });

    test('underline style and colour split runs', () {
      final line = textLine('abcdef');
      for (var i = 0; i < 6; i++) {
        line.setAttributes(i, CellFlags.underline);
      }
      for (var i = 0; i < 2; i++) {
        setUnderline(line, i, style: CellAttr.underlineStyleCurly);
      }
      for (var i = 2; i < 4; i++) {
        setUnderline(line, i, style: CellAttr.underlineStyleDotted);
      }
      for (var i = 4; i < 6; i++) {
        setUnderline(
          line,
          i,
          style: CellAttr.underlineStyleDotted,
          color: CellColor.rgb | 0x00FF00,
        );
      }
      expect(paint(makePainter(), line).paragraphs, 3);
    });

    test('underlined spaces are still coalesced', () {
      final line = textLine('      ');
      for (var i = 0; i < 6; i++) {
        line.setAttributes(i, CellFlags.underline);
      }
      expect(paint(makePainter(), line).paragraphs, 1);
    });

    test('wide characters break the run and keep their columns', () {
      expect(paint(makePainter(), textLine('ab你cd')).paragraphs, 3);
    });

    test('invisible cells are not drawn and break the run', () {
      final line = textLine('abcdef');
      for (var i = 2; i < 4; i++) {
        line.setAttributes(i, CellFlags.invisible);
      }
      expect(paint(makePainter(), line).paragraphs, 2);
    });

    test('custom glyphs keep the cell-by-cell path', () {
      // U+2588 is drawn geometrically, not as a paragraph.
      expect(paint(makePainter(), textLine('a█b')).paragraphs, 2);
    });

    test('blink phase hides every blinking glyph', () {
      final line = textLine('blinking');
      for (var i = 0; i < line.length; i++) {
        line.setAttributes(i, CellFlags.blink);
      }
      final painter = makePainter()..blinkVisible = false;
      expect(paint(painter, line).paragraphs, 0);
      painter.blinkVisible = true;
      expect(paint(painter, line).paragraphs, 1);
    });

    test('coalesceRuns=false draws one paragraph per cell', () {
      final counts =
          paint(makePainter(coalesceRuns: false), textLine('abcdef'));
      expect(counts.paragraphs, 6);
    });

    test('letter spacing keeps runs on the grid', () {
      final painter = makePainter(
        style: const TerminalStyle(letterSpacing: 1.5),
      );
      expect(paint(painter, textLine('abcdefghij')).paragraphs, 1);
    });

    test('a non-unit text scaler keeps runs on the grid', () {
      final painter = makePainter(scaler: const TextScaler.linear(1.5));
      expect(paint(painter, textLine('abcdefghij')).paragraphs, 1);
    });

    test('a run the font cannot keep on the grid falls back per cell', () {
      // Force the measurement to reject every run, as a proportional font
      // would. The style is then remembered as uncoalescable.
      final painter = makePainter()..debugGridTolerance = -1;
      final first = paint(painter, textLine('abcdef'));
      expect(first.paragraphs, 6);
      expect(painter.debugUncoalescableRunCount, 1);

      // A different text with the same style must not try to lay out a run
      // again, and must still paint every cell.
      final second = paint(painter, textLine('ghijkl'));
      expect(second.paragraphs, 6);
      expect(painter.debugUncoalescableRunCount, 1);

      // A font change clears the verdict.
      painter.debugGridTolerance = 0.5;
      painter.clearFontCache();
      expect(paint(painter, textLine('mnopqr')).paragraphs, 1);
    });
  });

  group('background spans', () {
    test('a solid span is one rect', () {
      final line = textLine('abcdefghij');
      for (var i = 0; i < 10; i++) {
        line.setBackground(i, CellColor.named | 4);
      }
      expect(paint(makePainter(), line).rects, 1);
    });

    test('separated spans are separate rects', () {
      final line = textLine('abcdefghij');
      for (var i = 0; i < 3; i++) {
        line.setBackground(i, CellColor.named | 4);
      }
      for (var i = 7; i < 10; i++) {
        line.setBackground(i, CellColor.named | 5);
      }
      expect(paint(makePainter(), line).rects, 2);
    });

    test('inverse fills the background with the foreground colour', () {
      final line = textLine('abcd');
      for (var i = 0; i < 4; i++) {
        line.setAttributes(i, CellFlags.inverse);
        line.setForeground(i, CellColor.named | 2);
      }
      expect(paint(makePainter(), line).rects, 1);
    });

    test('a wide character spans both of its columns', () {
      final line = textLine('a你b');
      for (var i = 0; i < line.length; i++) {
        line.setBackground(i, CellColor.named | 4);
      }
      expect(paint(makePainter(), line).rects, 1);
    });
  });

  group('line picture replay', () {
    test('a cache hit reports the same draw counts as the recording', () {
      final painter = makePainter();
      final line = textLine('the same line, painted twice');

      final first = paint(painter, line);
      final second = paint(painter, line);

      expect(painter.linePictureBuildCount, 1);
      expect(second, equals(first));
    });
  });

  group('pixel equivalence with the cell-by-cell path', () {
    final cases = <String, BufferLine Function()>{
      'plain': () => textLine('plain ascii text 1234'),
      'coloured': () {
        final line = textLine('red green blue');
        for (var i = 0; i < 3; i++) {
          line.setForeground(i, CellColor.named | 1);
        }
        for (var i = 4; i < 9; i++) {
          line.setForeground(i, CellColor.named | 2);
        }
        for (var i = 10; i < 14; i++) {
          line.setForeground(i, CellColor.named | 4);
        }
        return line;
      },
      'inverse and faint': () {
        final line = textLine('inverse faint normal');
        for (var i = 0; i < 7; i++) {
          line.setAttributes(i, CellFlags.inverse);
        }
        for (var i = 8; i < 13; i++) {
          line.setAttributes(i, CellFlags.faint);
        }
        return line;
      },
      'underlined spaces': () {
        final line = textLine('under lined words');
        for (var i = 0; i < line.length; i++) {
          line.setAttributes(i, CellFlags.underline);
        }
        return line;
      },
      'wide chars': () => textLine('ab你cd好ef'),
      'block glyph': () => textLine('a█░b'),
      'background': () {
        final line = textLine('background colours');
        for (var i = 0; i < 5; i++) {
          line.setBackground(i, CellColor.named | 1);
        }
        for (var i = 7; i < 14; i++) {
          line.setBackground(i, CellColor.rgb | 0x336699);
        }
        return line;
      },
    };

    cases.forEach((name, build) {
      test(name, () async {
        final line = build();
        final imageA = rasterize(makePainter(coalesceRuns: true), line);
        final imageB = rasterize(makePainter(coalesceRuns: false), line);
        addTearDown(() {
          imageA.dispose();
          imageB.dispose();
        });

        expect(imageA.width, imageB.width);
        expect(imageA.height, imageB.height);

        // A run draws its decoration as one line where the per-cell path draws
        // one segment per cell, so a seam may differ by one unit of coverage.
        // Anything larger would mean a glyph or column moved.
        final a = await pixels(imageA);
        final b = await pixels(imageB);
        var maxDifference = 0;
        for (var i = 0; i < a.length; i++) {
          final difference = (a[i] - b[i]).abs();
          if (difference > maxDifference) maxDifference = difference;
        }
        expect(
          maxDifference,
          lessThanOrEqualTo(2),
          reason: 'coalesced output must match the cell-by-cell path '
              '(max channel difference $maxDifference)',
        );
      });
    });
  });
}
