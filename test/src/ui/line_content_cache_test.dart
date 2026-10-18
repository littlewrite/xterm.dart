import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

/// The line picture cache is keyed by what a line draws, not by the
/// [BufferLine] object it is drawn from. These tests pin both halves of that
/// contract:
///
/// * lines that draw the same thing share one picture, however they got there;
/// * anything that changes what a line draws — its cells, its colors, the
///   highlight overlay, the theme, the font, the device pixel ratio — is a
///   different picture.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final open = <ui.Picture>[];

  /// A painter and the canvas its pictures are drawn on. The recorder is kept
  /// open for the length of the test: a picture must stay alive while the
  /// canvas that received it may still replay it.
  (TerminalPainter, Canvas) newPainter({double devicePixelRatio = 1.0}) {
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
        devicePixelRatio: devicePixelRatio,
      ),
      Canvas(recorder),
    );
  }

  BufferLine textLine(String text, {int? length}) {
    final line = BufferLine(length ?? text.length);
    for (var i = 0; i < text.length; i++) {
      line.setCodePoint(i, text.codeUnitAt(i));
    }
    return line;
  }

  /// Paints [line] the way `RenderTerminal._paint` does — the source is asked
  /// for its revision per row, and that revision is what reaches the painter.
  /// Tests that hand a painter a source without it are not exercising the call
  /// site the app uses.
  void paintOverlaid(
    TerminalPainter painter,
    Canvas canvas,
    BufferLine line,
    TerminalHighlightSource source, {
    int lineIndex = 0,
    double y = 0,
  }) {
    painter.paintLine(
      canvas,
      Offset(0, y),
      line,
      highlightRevision: source.revisionForLine(line, lineIndex),
      highlightSource: source,
      highlightLineIndex: lineIndex,
    );
  }

  group('contents share a picture', () {
    test('two lines that draw the same thing record one picture', () {
      final (painter, canvas) = newPainter();

      painter.paintLine(canvas, Offset.zero, textLine('hello'));
      painter.paintLine(canvas, Offset.zero, textLine('hello'));

      expect(painter.linePictureBuildCount, 1);
      expect(painter.linePictureCacheHitCount, 1);
    });

    test('a screenful of blank rows records a single picture', () {
      final (painter, canvas) = newPainter();

      for (var row = 0; row < 24; row++) {
        painter.paintLine(canvas, Offset(row * 18, 0), BufferLine(80));
      }

      expect(painter.linePictureBuildCount, 1);
    });

    test('a line erased and written back the same way keeps its picture', () {
      final (painter, canvas) = newPainter();
      final line = textLine('hello');

      painter.paintLine(canvas, Offset.zero, line);
      expect(painter.linePictureBuildCount, 1);

      // Erasing and rewriting bumps the revision twice, so an identity-keyed
      // cache would record the same picture again.
      line.setCodePoint(0, 0);
      painter.paintLine(canvas, Offset.zero, line);
      expect(painter.linePictureBuildCount, 2);

      line.setCodePoint(0, 'h'.codeUnitAt(0));
      painter.paintLine(canvas, Offset.zero, line);
      expect(
        painter.linePictureBuildCount,
        2,
        reason: 'the restored content draws what the first picture drew',
      );
      expect(painter.linePictureCacheHitCount, 1);
    });

    test('an unchanged line is hashed once, however many frames paint it', () {
      final (painter, canvas) = newPainter();
      final line = textLine('hello');

      for (var frame = 0; frame < 60; frame++) {
        painter.paintLine(canvas, Offset.zero, line);
      }

      expect(
        painter.lineHashCount,
        1,
        reason: 'the content hash is memoised until the line revision moves',
      );
      expect(painter.linePictureBuildCount, 1);
    });

    test('scrolling a line away and back reuses its picture', () {
      final (painter, canvas) = newPainter();
      final line = textLine('hello');
      painter.paintLine(canvas, Offset.zero, line);
      expect(painter.linePictureBuildCount, 1);

      // The buffer drops the line and builds an equal one later.
      painter.paintLine(canvas, Offset.zero, textLine('hello'));

      expect(painter.linePictureBuildCount, 1);
    });
  });

  group('different pictures do not share', () {
    test('different text does not share', () {
      final (painter, canvas) = newPainter();

      painter.paintLine(canvas, Offset.zero, textLine('hello'));
      painter.paintLine(canvas, Offset.zero, textLine('world'));

      expect(painter.linePictureBuildCount, 2);
    });

    test('one changed cell is a different picture', () {
      final (painter, canvas) = newPainter();

      painter.paintLine(canvas, Offset.zero, textLine('hello'));
      painter.paintLine(canvas, Offset.zero, textLine('hellp'));

      expect(painter.linePictureBuildCount, 2);
    });

    test('the same text in a different color is a different picture', () {
      final (painter, canvas) = newPainter();

      painter.paintLine(canvas, Offset.zero, textLine('hello'));

      final colored = textLine('hello')
        ..setBackground(0, CellColor.palette | 4);
      painter.paintLine(canvas, Offset.zero, colored);

      expect(painter.linePictureBuildCount, 2);
    });

    test('a row index alone is not a different picture', () {
      // `RenderTerminal` hands every line its own index, and a source it has
      // not attached draws nothing: the index must not reach the key, or no
      // two rows would ever share a picture.
      final (painter, canvas) = newPainter();

      painter.paintLine(canvas, Offset.zero, textLine('hello'));
      painter.paintLine(
        canvas,
        Offset(0, 18),
        textLine('hello'),
        highlightLineIndex: 7,
      );

      expect(painter.linePictureBuildCount, 1);
    });

    test('the same text with a different attribute is a different picture', () {
      final (painter, canvas) = newPainter();

      painter.paintLine(canvas, Offset.zero, textLine('hello'));

      final bold = textLine('hello')..setAttributes(0, CellAttr.bold);
      painter.paintLine(canvas, Offset.zero, bold);

      expect(painter.linePictureBuildCount, 2);
    });

    test('the same cells at a different length is a different picture', () {
      final (painter, canvas) = newPainter();

      painter.paintLine(canvas, Offset.zero, textLine('hi'));
      painter.paintLine(canvas, Offset.zero, textLine('hi', length: 8));

      expect(painter.linePictureBuildCount, 2);
    });

    test('an overlay that draws something else re-records the line', () {
      final (painter, canvas) = newPainter();
      final line = textLine('hello');
      final source = _FixedSource(
        const [TerminalHighlightSpan(startColumn: 0, endColumn: 2)],
      );

      paintOverlaid(painter, canvas, line, source);
      expect(painter.linePictureBuildCount, 1);

      // The cells are untouched; only what the overlay draws changed.
      source.spans = const [
        TerminalHighlightSpan(startColumn: 3, endColumn: 5)
      ];
      source.lineRevision = 1;
      paintOverlaid(painter, canvas, line, source);

      expect(
        painter.linePictureBuildCount,
        2,
        reason: 'a stale overlay must not be served once it draws differently',
      );
    });

    test('a revision that redraws the same overlay keeps the picture', () {
      final (painter, canvas) = newPainter();
      final line = textLine('hello');
      final source = _FixedSource(
        const [TerminalHighlightSpan(startColumn: 0, endColumn: 2)],
      );

      paintOverlaid(painter, canvas, line, source);
      expect(painter.linePictureBuildCount, 1);

      // A search that ran again and found the same matches: a new revision,
      // the same pixels.
      source.lineRevision = 1;
      paintOverlaid(painter, canvas, line, source);

      expect(
        painter.linePictureBuildCount,
        1,
        reason: 'the key follows what the overlay draws, not its revision',
      );
    });

    test('rows overlaid the same way share a picture at any row index', () {
      final (painter, canvas) = newPainter();
      final source = _FixedSource(
        const [TerminalHighlightSpan(startColumn: 1, endColumn: 3)],
      );

      paintOverlaid(painter, canvas, textLine('hello'), source);
      paintOverlaid(
        painter,
        canvas,
        textLine('hello'),
        source,
        lineIndex: 9,
        y: 18,
      );

      expect(painter.linePictureBuildCount, 1);
    });

    test('empty overlays all share, however their revisions differ', () {
      final (painter, canvas) = newPainter();
      final source = _FixedSource(const []);

      paintOverlaid(painter, canvas, textLine('hello'), source);
      source.lineRevision = 7;
      paintOverlaid(
        painter,
        canvas,
        textLine('hello'),
        source,
        lineIndex: 9,
        y: 18,
      );

      expect(
        painter.linePictureBuildCount,
        1,
        reason: 'a highlighter that matched nothing draws nothing',
      );
    });

    test('the same cells with an explicit span list are never cached', () {
      final (painter, canvas) = newPainter();
      final line = textLine('hello');
      const spans = [
        TerminalHighlightSpan(startColumn: 0, endColumn: 2),
      ];

      painter.paintLine(canvas, Offset.zero, line, highlights: spans);
      painter.paintLine(canvas, Offset.zero, line, highlights: spans);

      expect(
        painter.linePictureBuildCount,
        2,
        reason: 'an explicit span list has no revision to invalidate on',
      );
      expect(painter.linePictureCacheHitCount, 0);
    });
  });

  group('highlight off, on, and custom', () {
    test('off: rows that draw the same thing share', () {
      final (painter, canvas) = newPainter();

      for (var row = 0; row < 5; row++) {
        painter.paintLine(
          canvas,
          Offset(0, row * 18),
          textLine('same row'),
          highlightLineIndex: row,
        );
      }

      expect(painter.linePictureBuildCount, 1);
    });

    test('on: rows the source overlays the same way share', () {
      final (painter, canvas) = newPainter();
      final source = _FixedSource(
        const [TerminalHighlightSpan(startColumn: 0, endColumn: 4)],
      );

      for (var row = 0; row < 5; row++) {
        paintOverlaid(
          painter,
          canvas,
          textLine('same row'),
          source,
          lineIndex: row,
          y: row * 18,
        );
      }

      expect(painter.linePictureBuildCount, 1);
    });

    test('custom: rows the source overlays differently do not share', () {
      final (painter, canvas) = newPainter();
      final source = _FixedSource(
        const [TerminalHighlightSpan(startColumn: 0, endColumn: 2)],
      );

      // Row 0 matches "sa"; row 1 matches "me" instead.
      paintOverlaid(painter, canvas, textLine('same row'), source);
      source.spans = const [
        TerminalHighlightSpan(startColumn: 5, endColumn: 8),
      ];
      source.lineRevision = 1;
      paintOverlaid(
        painter,
        canvas,
        textLine('same row'),
        source,
        lineIndex: 1,
        y: 18,
      );

      expect(painter.linePictureBuildCount, 2);
    });

    test('custom: a row keeps its picture while other rows change', () {
      final (painter, canvas) = newPainter();
      final source = _FixedSource(
        const [TerminalHighlightSpan(startColumn: 0, endColumn: 2)],
      );
      final steady = textLine('same row');

      paintOverlaid(painter, canvas, steady, source);
      expect(painter.linePictureBuildCount, 1);

      // Another row picks up a different overlay, and the source's revision
      // moves for every row because of it.
      final other = textLine('same row');
      source.spans = const [
        TerminalHighlightSpan(startColumn: 5, endColumn: 8),
      ];
      source.lineRevision = 1;
      paintOverlaid(painter, canvas, other, source, lineIndex: 1, y: 18);
      expect(painter.linePictureBuildCount, 2);

      // The steady row is painted again at the new revision; its own overlay
      // never changed, so its picture is still the one it had.
      paintOverlaid(painter, canvas, steady, source);
      expect(painter.linePictureBuildCount, 2);
    });

    test('two sources with the same revision do not share an overlay', () {
      final (painter, canvas) = newPainter();
      final line = textLine('same row');
      final first = _FixedSource(
        const [TerminalHighlightSpan(startColumn: 0, endColumn: 2)],
      );
      final second = _FixedSource(
        const [TerminalHighlightSpan(startColumn: 5, endColumn: 8)],
      );

      paintOverlaid(painter, canvas, line, first);
      paintOverlaid(painter, canvas, line, second);
      expect(
        painter.linePictureBuildCount,
        2,
        reason: 'a source identity is part of the resolved-overlay key',
      );

      paintOverlaid(painter, canvas, line, first);
      expect(
        painter.linePictureBuildCount,
        2,
        reason: 'switching back must reuse the first source picture',
      );
    });

    test('switching the source off and back on reuses the pictures', () {
      final (painter, canvas) = newPainter();
      final source = _FixedSource(
        const [TerminalHighlightSpan(startColumn: 0, endColumn: 2)],
      );
      final line = textLine('same row');

      paintOverlaid(painter, canvas, line, source);
      expect(painter.linePictureBuildCount, 1);

      // Highlighting off: the row draws without the overlay, which is a
      // different picture.
      painter.paintLine(canvas, Offset.zero, line);
      expect(painter.linePictureBuildCount, 2);

      // On again, unchanged: the picture from before is still there.
      paintOverlaid(painter, canvas, line, source);
      expect(
        painter.linePictureBuildCount,
        2,
        reason:
            'an overlay that draws the same thing must not thrash the cache',
      );
    });
  });

  group('drops what it must', () {
    test('a theme change drops the pictures but keeps the hashes', () {
      final (painter, canvas) = newPainter();
      final line = textLine('hello');
      painter.paintLine(canvas, Offset.zero, line);
      expect(painter.linePictureBuildCount, 1);

      painter.theme = TerminalThemes.whiteOnBlack;
      painter.paintLine(canvas, Offset.zero, line);

      expect(painter.linePictureBuildCount, 2);
      expect(
        painter.lineHashCount,
        1,
        reason: 'the cells did not change, so the hash is still the old one',
      );
    });

    test('a style change drops the pictures', () {
      final (painter, canvas) = newPainter();
      final line = textLine('hello');
      painter.paintLine(canvas, Offset.zero, line);
      expect(painter.linePictureBuildCount, 1);

      painter.textStyle = const TerminalStyle(fontSize: 18);
      painter.paintLine(canvas, Offset.zero, line);

      expect(painter.linePictureBuildCount, 2);
    });

    test('a device pixel ratio change drops the pictures', () {
      final (painter, canvas) = newPainter(devicePixelRatio: 1.0);
      final line = textLine('hello');
      painter.paintLine(canvas, Offset.zero, line);
      expect(painter.linePictureBuildCount, 1);

      painter.devicePixelRatio = 1.5;
      painter.paintLine(canvas, Offset.zero, line);

      expect(painter.linePictureBuildCount, 2);
    });

    test('a line changed back and forth does not grow the cache', () {
      final (painter, canvas) = newPainter();
      final line = textLine('hello');

      for (var frame = 0; frame < 200; frame++) {
        painter.paintLine(canvas, Offset.zero, line);
        line.setCodePoint(0, 0);
        painter.paintLine(canvas, Offset.zero, line);
        line.setCodePoint(0, 'h'.codeUnitAt(0));
      }

      expect(
        painter.linePictureBuildCount,
        2,
        reason: 'two distinct contents alternate, so two pictures suffice',
      );
      expect(painter.lineHashCount, 400, reason: 'the line changes each frame');
    });

    test('contents past the cap are recorded again when they come back', () {
      final (painter, canvas) = newPainter();

      BufferLine content(int i) => BufferLine(4)
        ..setCodePoint(0, 0x41 + (i % 26))
        ..setCodePoint(1, 0x30 + (i ~/ 26));

      // 513 distinct contents, one past the 512-entry cap.
      for (var i = 0; i < 513; i++) {
        painter.paintLine(canvas, Offset.zero, content(i));
      }
      expect(painter.linePictureBuildCount, 513);

      painter.paintLine(canvas, Offset.zero, content(0));

      expect(
        painter.linePictureBuildCount,
        514,
        reason: 'the oldest content fell out of the bounded cache',
      );
    });
  });

  group('through the widget', () {
    testWidgets('a screenful of blank rows records one picture',
        (tester) async {
      final terminal = Terminal();
      terminal.write('\r\n' * 20);

      final key = GlobalKey<TerminalViewState>();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TerminalView(terminal, key: key))),
      );
      await tester.pump();

      final painter = key.currentState!.renderTerminal.debugPainter;

      expect(
        painter.linePictureBuildCount,
        1,
        reason: 'every blank row draws the same thing, whatever its index',
      );
      expect(painter.linePictureCacheHitCount, greaterThan(0));
    });

    testWidgets('a screenful of identical rows records one picture',
        (tester) async {
      final terminal = Terminal();
      terminal.write(('the same row\r\n' * 20));

      final key = GlobalKey<TerminalViewState>();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TerminalView(terminal, key: key))),
      );
      await tester.pump();

      final painter = key.currentState!.renderTerminal.debugPainter;

      // The repeated rows share one picture; the row the cursor sits on, still
      // blank, is a second one.
      expect(painter.linePictureBuildCount, 2);
    });

    testWidgets('redrawing the same screen records no more pictures',
        (tester) async {
      final terminal = Terminal(maxLines: 1000);
      final key = GlobalKey<TerminalViewState>();
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TerminalView(terminal, key: key))),
      );
      await tester.pump();

      final screen = StringBuffer();
      final width = terminal.viewWidth;
      for (var row = 0; row < terminal.viewHeight; row++) {
        if (row > 0) screen.write('\r\n');
        screen.write('row $row'.padRight(width - 1));
      }
      terminal.write('\x1b[H\x1b[2J${screen.toString()}');

      await tester.pump();

      final painter = key.currentState!.renderTerminal.debugPainter;
      painter.resetLinePictureBuildCount();

      terminal.write('\x1b[H\x1b[2J${screen.toString()}');
      await tester.pump();

      expect(
        painter.linePictureBuildCount,
        0,
        reason: 'the cells changed revision but the visible screen did not',
      );
      expect(painter.linePictureCacheHitCount, greaterThan(0));
    });
  });

  group('with a highlight overlay attached', () {
    testWidgets('rows that highlight the same way share a picture',
        (tester) async {
      final terminal = Terminal();
      terminal.write('the same xrow\r\n' * 20);
      final source = _MarkSource('x');

      final key = GlobalKey<TerminalViewState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal, key: key, highlightSource: source),
          ),
        ),
      );
      await tester.pump();

      final painter = key.currentState!.renderTerminal.debugPainter;

      // The overlay draws the same thing on every repeated row, so the rows
      // still share: an overlay must not be a reason to record each row again.
      expect(painter.linePictureBuildCount, lessThanOrEqualTo(3));
    });

    testWidgets('a trimming scrollback does not re-record the whole viewport',
        (tester) async {
      // A line's index in the buffer moves whenever the full scrollback drops
      // its oldest line, so an index that reaches the picture key would make
      // every row a miss on every frame of sustained output.
      //
      // maxLines has to clear the test surface's row count; below it the
      // terminal's own resize breaks (a separate bug).
      final terminal = Terminal(maxLines: 200);
      final source = _MarkSource('x');

      final key = GlobalKey<TerminalViewState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TerminalView(terminal, key: key, highlightSource: source),
          ),
        ),
      );

      // Fill past the scrollback limit so the buffer starts trimming.
      for (var i = 0; i < 230; i++) {
        terminal.write('line $i has an x\r\n');
        await tester.pump();
      }

      final painter = key.currentState!.renderTerminal.debugPainter;
      painter.resetLinePictureBuildCount();

      const frames = 10;
      for (var i = 0; i < frames; i++) {
        terminal.write('more $i has an x\r\n');
        await tester.pump();
      }

      // One appended line dirties one row, so a handful of records per frame
      // is all this may cost; a viewport-wide re-record would be far more.
      expect(
        painter.linePictureBuildCount,
        lessThan(frames * 4),
        reason: 'the buffer index must not reach the picture key',
      );
    });
  });
}

/// Highlights every occurrence of [needle] in a row, as a search highlighter
/// would. Deliberately ignores `lineIndex`, like the highlighter in FaTerm.
class _MarkSource extends TerminalHighlightSource {
  _MarkSource(this.needle);

  final String needle;

  @override
  int get revision => 0;

  @override
  int revisionForLine(BufferLine line, int lineIndex) =>
      Object.hash(line.revision, line.getText().hashCode);

  @override
  List<TerminalHighlightSpan> spansForLine(BufferLine line, int lineIndex) {
    final text = line.getText();
    final spans = <TerminalHighlightSpan>[];
    var from = 0;
    while (true) {
      final at = text.indexOf(needle, from);
      if (at < 0) break;
      spans.add(
        TerminalHighlightSpan(
          startColumn: at,
          endColumn: at + needle.length,
          foreground: const Color(0xFFFF0000),
        ),
      );
      from = at + needle.length;
    }
    return spans;
  }
}

/// A source whose overlay the test sets outright, so a test can say exactly
/// what a row draws under it and when the source claims it changed.
class _FixedSource extends TerminalHighlightSource {
  _FixedSource(this.spans);

  List<TerminalHighlightSpan> spans;
  int lineRevision = 0;

  @override
  int get revision => 0;

  @override
  int revisionForLine(BufferLine line, int lineIndex) => lineRevision;

  @override
  List<TerminalHighlightSpan> spansForLine(BufferLine line, int lineIndex) =>
      spans;
}
