import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/ui/painter.dart';
import 'package:xterm/xterm.dart';

/// Regression tests for the "paint the same thing twice, record it once"
/// contract of the line picture cache:
///
/// * [TerminalStyle] is compared by value, so the style that `TerminalView`
///   rebuilds on every frame (`widget.textStyle.copyWith(...)`, always a fresh
///   instance) no longer drops the caches.
/// * A style that really changed must still drop them, otherwise stale glyphs
///   would be reused.
///
/// The companion property — one picture recorded at the origin being reused for
/// every sub-pixel offset — is covered in `render_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalStyle equality', () {
    test('value-equal instances are equal', () {
      // Deliberately not `const`: const instances would be canonicalized into
      // the same object and the test would not exercise `==` at all.
      final a = TerminalStyle(fontFamilyFallback: ['mono']);
      final b = TerminalStyle(fontFamilyFallback: ['mono']);

      expect(identical(a, b), isFalse);
      expect(identical(a.fontFamilyFallback, b.fontFamilyFallback), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('copyWith without changes preserves equality', () {
      // This is the exact object TerminalView hands to the render object on
      // every rebuild: `widget.textStyle.copyWith(fontSize: textSize)`.
      const style = TerminalStyle();
      final rebuilt = style.copyWith(fontSize: style.fontSize);

      expect(identical(style, rebuilt), isFalse);
      expect(rebuilt, equals(style));
      expect(rebuilt.hashCode, equals(style.hashCode));
    });

    test('fontFamilyFallback compares element-wise, not by identity', () {
      final base = TerminalStyle(fontFamilyFallback: const ['a', 'b', 'c']);

      expect(base.copyWith(fontFamilyFallback: ['a', 'b', 'c']), equals(base));
      expect(
        base.copyWith(fontFamilyFallback: ['a', 'b']),
        isNot(equals(base)),
      );
      expect(
        base.copyWith(fontFamilyFallback: ['a', 'b', 'd']),
        isNot(equals(base)),
      );
      expect(
        base.copyWith(fontFamilyFallback: ['a', 'b', 'c', 'd']),
        isNot(equals(base)),
      );
      expect(
        base.copyWith(fontFamilyFallback: null),
        equals(base),
        reason: 'null means "keep the current fallback list"',
      );
    });

    test('every field participates in equality and hashCode', () {
      const base = TerminalStyle();
      final variants = <String, TerminalStyle>{
        'fontSize': base.copyWith(fontSize: base.fontSize + 1),
        'height': base.copyWith(height: base.height + 0.1),
        'fontFamily': base.copyWith(fontFamily: 'Some Other Mono'),
        'fontFamilyFallback':
            base.copyWith(fontFamilyFallback: const ['Other Mono']),
        'letterSpacing': base.copyWith(letterSpacing: 1.5),
      };

      expect(variants, hasLength(5), reason: 'keep in sync with TerminalStyle');

      variants.forEach((name, variant) {
        expect(variant, isNot(equals(base)), reason: '$name must affect ==');
        expect(
          variant.hashCode,
          isNot(base.hashCode),
          reason: '$name must affect hashCode',
        );
      });
    });
  });

  group('TerminalPainter line picture invalidation', () {
    TerminalStyle variantFor(String name) {
      const base = TerminalStyle();
      return switch (name) {
        'fontSize' => base.copyWith(fontSize: base.fontSize + 1),
        'height' => base.copyWith(height: base.height + 0.1),
        'fontFamily' => base.copyWith(fontFamily: 'Some Other Mono'),
        'fontFamilyFallback' =>
          base.copyWith(fontFamilyFallback: const ['Other Mono']),
        'letterSpacing' => base.copyWith(letterSpacing: 1.5),
        _ => throw ArgumentError('unknown style field: $name'),
      };
    }

    const styleFields = [
      'fontSize',
      'height',
      'fontFamily',
      'fontFamilyFallback',
      'letterSpacing',
    ];

    test('an equal style does not drop cached pictures', () {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final painter = TerminalPainter(
        theme: TerminalThemes.defaultTheme,
        textStyle: const TerminalStyle(),
        textScaler: TextScaler.noScaling,
      );
      final line = BufferLine(8)..setCodePoint(0, 65);

      painter.paintLine(canvas, Offset.zero, line);
      expect(painter.linePictureBuildCount, 1);

      // Fresh instance, same values.
      const rebuilt = TerminalStyle();
      painter.textStyle = rebuilt.copyWith(fontSize: rebuilt.fontSize);
      painter.paintLine(canvas, Offset.zero, line);

      expect(
        painter.linePictureBuildCount,
        1,
        reason: 'an equal style must not invalidate the picture cache',
      );
      recorder.endRecording().dispose();
    });

    for (final field in styleFields) {
      test('changing $field does drop cached pictures', () {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final painter = TerminalPainter(
          theme: TerminalThemes.defaultTheme,
          textStyle: const TerminalStyle(),
          textScaler: TextScaler.noScaling,
        );
        final line = BufferLine(8)..setCodePoint(0, 65);

        painter.paintLine(canvas, Offset.zero, line);
        expect(painter.linePictureBuildCount, 1);

        painter.textStyle = variantFor(field);
        painter.paintLine(canvas, Offset.zero, line);

        expect(
          painter.linePictureBuildCount,
          2,
          reason: 'changing $field must invalidate the picture cache',
        );
        recorder.endRecording().dispose();
      });
    }
  });

  group('TerminalView rebuild', () {
    testWidgets('a rebuild without a style change re-records nothing',
        (tester) async {
      final terminal = Terminal();
      for (var i = 0; i < 40; i++) {
        terminal.write('line $i of some terminal text\r\n');
      }

      final key = GlobalKey<TerminalViewState>();
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return TerminalView(terminal, key: key);
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final painter = key.currentState!.renderTerminal.debugPainter;
      expect(
        painter.linePictureBuildCount,
        greaterThan(0),
        reason: 'the first paint records the visible lines',
      );

      painter.resetLinePictureBuildCount();
      rebuild(() {});
      await tester.pump();

      expect(
        painter.linePictureBuildCount,
        0,
        reason: 'TerminalView passes a fresh TerminalStyle instance on every '
            'rebuild (cursor blink rebuilds it ~2x/second); that must not '
            'invalidate the line picture cache',
      );
    });

    testWidgets('a rebuild with a changed style re-records the lines',
        (tester) async {
      final terminal = Terminal();
      for (var i = 0; i < 40; i++) {
        terminal.write('line $i of some terminal text\r\n');
      }

      final key = GlobalKey<TerminalViewState>();
      late StateSetter rebuild;
      var style = const TerminalStyle();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return TerminalView(terminal, key: key, textStyle: style);
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final painter = key.currentState!.renderTerminal.debugPainter;
      painter.resetLinePictureBuildCount();

      style = style.copyWith(fontSize: style.fontSize + 4);
      rebuild(() {});
      await tester.pump();

      expect(
        painter.linePictureBuildCount,
        greaterThan(0),
        reason: 'a real style change must drop the line picture cache',
      );
    });
  });
}
