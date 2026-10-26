import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:xterm/core.dart';
import 'package:xterm/src/utils/escape_sanitizer.dart';

/// Stress and fuzz tests for the core.
///
/// Random byte streams, edge-case escape sequences and pty-style chunk splits
/// must never crash the parser, leave the cursor out of bounds, or leak a split
/// sequence as literal text.
///
/// Run: `flutter test test/stress/`

void main() {
  group('random fuzz', () {
    String randomText(Random rng, int length) {
      final buf = StringBuffer();
      for (var i = 0; i < length; i++) {
        final v = rng.nextInt(100);
        if (v < 80) {
          buf.writeCharCode(rng.nextInt(0x5e) + 0x21); // 0x21-0x7e
        } else if (v < 90) {
          buf.writeCharCode(rng.nextInt(0x1f) + 0x01); // 0x01-0x1f
        } else {
          buf.writeCharCode(rng.nextInt(0x80)); // 0x00-0x7f
        }
      }
      return buf.toString();
    }

    for (final seed in [0, 7, 42, 9999]) {
      test('random text (seed=$seed, 50k chars)', () {
        final terminal = Terminal();
        terminal.write(randomText(Random(seed), 50000));

        expect(terminal.buffer.lines.length, greaterThan(0));
        expect(terminal.buffer.cursorX,
            inInclusiveRange(0, terminal.viewWidth - 1));
        expect(terminal.buffer.cursorY,
            inInclusiveRange(0, terminal.viewHeight - 1));
      });
    }

    test('random full byte range (0-255)', () {
      final rng = Random(7);
      final terminal = Terminal();
      final buf = StringBuffer();
      for (var i = 0; i < 30000; i++) {
        buf.writeCharCode(rng.nextInt(256));
      }

      terminal.write(buf.toString());

      expect(terminal.buffer.lines.length, greaterThan(0));
    });
  });

  group('escape fuzz', () {
    test('random CSI sequences', () {
      final rng = Random(42);
      final terminal = Terminal();
      final buf = StringBuffer();
      for (var i = 0; i < 10000; i++) {
        buf.write('\x1b[');
        if (rng.nextBool()) {
          final paramLen = rng.nextInt(3) + 1;
          for (var p = 0; p < paramLen; p++) {
            if (p > 0 && rng.nextBool()) buf.write(';');
            buf.write(rng.nextInt(50).toString());
          }
        }
        buf.writeCharCode(rng.nextBool() ? 0x6d : 0x48); // m / H
      }

      terminal.write(buf.toString());

      expect(terminal.buffer.lines.length, greaterThan(0));
    });

    test('random OSC sequences, BEL and ST terminated', () {
      final rng = Random(42);
      final terminal = Terminal();
      final buf = StringBuffer();
      for (var i = 0; i < 5000; i++) {
        buf.write('\x1b]${rng.nextInt(200)};');
        final textLen = rng.nextInt(50) + 1;
        for (var t = 0; t < textLen; t++) {
          buf.writeCharCode(rng.nextInt(0x5e) + 0x21);
        }
        if (rng.nextBool()) {
          buf.writeCharCode(0x07); // BEL
        } else {
          buf.write('\x1b\\'); // ST
        }
      }

      terminal.write(buf.toString());

      expect(terminal.buffer.lines.length, greaterThan(0));
    });

    test('mixed text and real sequences', () {
      final rng = Random(42);
      final terminal = Terminal();
      final sequences = <String Function()>[
        () => 'Hello World\n',
        () => '\x1b[${rng.nextInt(108)}m',
        () => '\x1b[${rng.nextInt(24) + 1};${rng.nextInt(80) + 1}H',
        () => rng.nextBool() ? '\x1b[s' : '\x1b[u',
        () => '\x1b[${rng.nextInt(5) + 1}S',
        () => rng.nextBool() ? '\x1b[?1049h' : '\x1b[?1049l',
        () => '\x1b[?2026h' 'paint' '\x1b[?2026l',
        () => '\x1b]8;;https://example.com/\x1b\\link\x1b]8;;\x07',
        () => '\x1b]7501;state=working:app=fuzz\x07',
        () => '\x1b]133;D;${rng.nextInt(3)}\x1b\\',
      ];
      final buf = StringBuffer();
      for (var i = 0; i < 20000; i++) {
        buf.write(sequences[rng.nextInt(sequences.length)]());
      }

      terminal.write(buf.toString());

      expect(terminal.buffer.lines.length, greaterThan(0));
    });

    test('nested / incomplete escape sequences', () {
      final rng = Random(42);
      final terminal = Terminal();
      const partial = [
        '\x1b[',
        '\x1b]',
        '\x1bP',
        '\x1b[0;',
        '\x1b]0;',
        '\x1b[?',
        '\x1b[{}]',
        '\x1b[0;0;0;0;',
      ];
      final buf = StringBuffer();
      for (var i = 0; i < 20000; i++) {
        buf.write(partial[rng.nextInt(partial.length)]);
      }

      terminal.write(buf.toString());

      expect(terminal.buffer.lines.length, greaterThan(0));
    });

    test('rapid SGR switching', () {
      final terminal = Terminal();
      final buf = StringBuffer();
      for (var c = 0; c < 1000; c++) {
        buf.write('\x1b[${c % 256}m\x1b[4${c % 8}mX');
      }
      buf.write('\x1b[0m');

      terminal.write(buf.toString());

      expect(terminal.buffer.lines.length, greaterThan(0));
    });
  });

  group('rapid writes', () {
    test('100,000 single-character writes', () {
      final terminal = Terminal();
      for (var i = 0; i < 100000; i++) {
        terminal.write('a');
      }
      expect(terminal.buffer.cursorX, greaterThan(0));
    });

    test('10,000 colored lines', () {
      final terminal = Terminal();
      for (var i = 0; i < 10000; i++) {
        terminal.write('\x1b[${31 + i % 7}mline$i\x1b[0m\n');
      }
      expect(terminal.buffer.getText(), contains('line9999'));
    });

    test('interleaved text and erases', () {
      final terminal = Terminal();
      for (var i = 0; i < 5000; i++) {
        terminal.write('normal text\n');
        terminal.write('\x1b[1m\x1b[31mbold red\x1b[0m \x1b[32mgreen\x1b[0m\n');
        terminal.write('\x1b[${i % 10 + 1}J');
      }
      expect(terminal.buffer.lines.length, greaterThan(0));
    });
  });

  group('resize stress', () {
    test('resize during writes keeps the cursor in bounds', () {
      final terminal = Terminal();
      final rng = Random(42);
      for (var i = 0; i < 500; i++) {
        terminal.write('line $i with some content\n');
        if (i % 20 == 0) {
          terminal.resize(rng.nextInt(30) + 40, rng.nextInt(20) + 10);
        }
      }
      terminal.resize(80, 24);

      expect(terminal.buffer.lines.length, greaterThan(0));
    });

    test('extreme aspect ratios, including 1000x1000', () {
      final terminal = Terminal();
      terminal.write('Hello\nWorld\n');
      for (final cols in [1, 2, 5, 200, 500, 1000]) {
        for (final rows in [1, 2, 5, 200, 500, 1000]) {
          terminal.resize(cols, rows);
        }
      }
      terminal.resize(80, 24);

      expect(terminal.buffer.lines.length, greaterThan(0));
    });

    test('cursor and line count stay consistent through resizes', () {
      final terminal = Terminal();
      for (var i = 0; i < 200; i++) {
        terminal.write('Line $i with some content to wrap\n');
      }

      final rng = Random(42);
      for (var i = 0; i < 100; i++) {
        final cols = rng.nextInt(60) + 20;
        final rows = rng.nextInt(30) + 5;
        terminal.resize(cols, rows);

        expect(terminal.buffer.cursorX, inInclusiveRange(0, cols - 1),
            reason: 'cursorX out of bounds after resize($cols,$rows)');
        expect(terminal.buffer.cursorY, inInclusiveRange(0, rows - 1),
            reason: 'cursorY out of bounds after resize($cols,$rows)');
        expect(terminal.buffer.lines.length, greaterThanOrEqualTo(rows),
            reason: 'lines.length < rows after resize($cols,$rows)');
      }
    });
  });

  group('chunk-split fuzz', () {
    String buildPayload(Random rng, int units) {
      final buf = StringBuffer();
      for (var i = 0; i < units; i++) {
        switch (rng.nextInt(10)) {
          case 0:
            buf.write('\x1b[${rng.nextInt(108)}mtext$i');
          case 1:
            buf.write('\x1b[${rng.nextInt(24) + 1};${rng.nextInt(80) + 1}H');
          case 2:
            buf.write('\x1b]0;title $i\x07');
          case 3:
            buf.write('\x1b[?2026h${'x' * rng.nextInt(5)}\x1b[?2026l');
          case 4:
            buf.write('plain-$i ');
          case 5:
            buf.write('\x1b[${rng.nextInt(5) + 1}J');
          case 6:
            buf.write('\x1b[!p\x1bc');
          case 7:
            buf.write(
                '\x1b]7501;state=working:progress=${rng.nextInt(101)}\x07');
          case 8:
            buf.write(
                '\x1b]8;;https://example.com/$i\x1b\\link-$i\x1b]8;;\x07');
          default:
            buf.write('\x1b[38;5;${rng.nextInt(256)}mC$i\x1b[0m');
        }
      }
      return buf.toString();
    }

    void writeInChunks(Terminal terminal, Random rng, String payload) {
      var pos = 0;
      while (pos < payload.length) {
        // 1-7 character chunks force splits inside ESC, CSI parameters and
        // OSC bodies.
        final size = rng.nextInt(7) + 1;
        final end = pos + size < payload.length ? pos + size : payload.length;
        terminal.write(payload.substring(pos, end));
        pos = end;
      }
    }

    for (final seed in [7, 2026]) {
      test('escape stream in 1-7 character chunks (seed=$seed)', () {
        final rng = Random(seed);
        final terminal = Terminal();
        writeInChunks(terminal, rng, buildPayload(rng, 3000));

        expect(terminal.buffer.lines.length, greaterThan(0));
        expect(terminal.buffer.cursorX,
            inInclusiveRange(0, terminal.viewWidth - 1));
      });
    }

    test('split writes equal one-shot write', () {
      final payload = buildPayload(Random(99), 500);
      final whole = Terminal()..write(payload);
      final chunked = Terminal();
      writeInChunks(chunked, Random(99), payload);

      expect(chunked.buffer.getText(), equals(whole.buffer.getText()));
    });

    test('wide characters split mid-sequence', () {
      final rng = Random(13);
      final terminal = Terminal();
      const wide = '床前明月光疑是地上霜🌍🌎🌏';
      final runes = wide.runes.toList();
      final buf = StringBuffer();
      for (var i = 0; i < 400; i++) {
        buf.write('\x1b[${31 + i % 7}m');
        buf.writeCharCode(runes[i % runes.length]);
      }
      buf.write('\x1b[0m');

      writeInChunks(terminal, rng, buf.toString());

      expect(terminal.buffer.lines.length, greaterThan(0));
    });

    test('writeBytes split at arbitrary byte boundaries equals write', () {
      const text = 'a床前明月光🌍\x1b[31mred\x1b[0m done\n';
      final bytes = utf8.encode(text);

      final whole = Terminal()..write(text);
      final chunked = Terminal();
      final rng = Random(5);
      var pos = 0;
      while (pos < bytes.length) {
        final size = rng.nextInt(4) + 1;
        final end = pos + size < bytes.length ? pos + size : bytes.length;
        chunked.writeBytes(bytes.sublist(pos, end));
        pos = end;
      }
      chunked.flushBytes();

      expect(chunked.buffer.getText(), equals(whole.buffer.getText()));
    });
  });

  group('paste sanitizer fuzz', () {
    test('never leaves an escape byte in the output', () {
      final rng = Random(31);
      for (var round = 0; round < 200; round++) {
        final buf = StringBuffer();
        for (var i = 0; i < 200; i++) {
          buf.writeCharCode(rng.nextInt(128));
        }
        final input = buf.toString();
        final output = stripEscapeSequences(input);

        expect(output.contains('\x1b'), isFalse,
            reason: 'round=$round input=${input.codeUnits}');
      }
    });

    test('plain text is preserved exactly', () {
      final rng = Random(32);
      for (var round = 0; round < 100; round++) {
        final buf = StringBuffer();
        for (var i = 0; i < 100; i++) {
          // Printable ASCII, tab and newline only: no sequences to strip.
          final v = rng.nextInt(0x60);
          buf.writeCharCode(v < 0x20 ? (v == 0x09 || v == 0x0a ? v : 0x41) : v);
        }
        final text = buf.toString();
        expect(stripEscapeSequences(text), text);
      }
    });
  });
}
