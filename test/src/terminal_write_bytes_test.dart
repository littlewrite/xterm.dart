import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

/// A reader hands the terminal whatever it read, so a multi-byte character can
/// straddle two chunks. [Terminal.writeBytes] must decode across calls; the
/// per-chunk `utf8.decode` an application would otherwise reach for cannot.
void main() {
  String bufferText(Terminal terminal) {
    final lines = terminal.buffer.lines;
    final out = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      out
        ..write(lines[i].getText())
        ..write('\n');
    }
    return out.toString();
  }

  /// Feeds [text] to a fresh terminal as UTF-8 in chunks of [chunkSize] bytes.
  Terminal feed(List<int> bytes, int chunkSize) {
    final terminal = Terminal();
    for (var at = 0; at < bytes.length; at += chunkSize) {
      terminal.writeBytes(
        bytes.sublist(at, (at + chunkSize).clamp(0, bytes.length)),
      );
    }
    return terminal;
  }

  const samples = {
    'ascii': 'a plain line of ascii text',
    'cjk': '墙角数枝梅，凌寒独自开。遥知不是雪，为有暗香来。',
    'accented': 'café naïve résumé',
    'emoji': 'ship it 🚀 and family 👨‍👩‍👧‍👦',
    'color': '\x1b[31mred\x1b[0m 中文 \x1b[1mbold\x1b[0m',
    'cursor motion': 'one\rtwo\x1b[2Cthree',
  };

  group('writeBytes matches write', () {
    samples.forEach((name, sample) {
      test(name, () {
        final expected = Terminal()..write(sample);
        final actual = feed(utf8.encode(sample), 1 << 20);
        expect(bufferText(actual), bufferText(expected));
      });
    });
  });

  group('characters split across chunks', () {
    samples.forEach((name, sample) {
      test('$name, byte at a time', () {
        final expected = Terminal()..write(sample);
        // The worst case a reader can produce: one byte per read.
        final actual = feed(utf8.encode(sample), 1);
        expect(bufferText(actual), bufferText(expected));
      });

      test('$name, every chunk size that can cut a character', () {
        final bytes = utf8.encode(sample);
        final expected = bufferText(Terminal()..write(sample));
        for (var size = 1; size <= 8; size++) {
          expect(
            bufferText(feed(bytes, size)),
            expected,
            reason: 'chunk size $size',
          );
        }
      });
    });

    test('a reader sized chunk over a stream of three-byte characters', () {
      final text = '中' * 500;
      final bytes = utf8.encode(text);
      final expected = bufferText(Terminal()..write(text));

      // 65536 - 1 and 65536 + 1 both cut a character in half, since a character
      // is three bytes and the chunk size is not a multiple of three.
      for (final size in [65535, 65536, 65537, 4096, 4097]) {
        expect(
          bufferText(feed(bytes, size)),
          expected,
          reason: 'chunk size $size',
        );
      }
    });

    test('a character split over the escape sequence after it', () {
      // The ESC of the sequence lands in the same chunk as the tail of 中.
      final bytes = utf8.encode('中文\x1b[31mred');
      final expected = bufferText(Terminal()..write('中文\x1b[31mred'));
      for (var size = 1; size <= 12; size++) {
        expect(
          bufferText(feed(bytes, size)),
          expected,
          reason: 'chunk size $size',
        );
      }
    });
  });

  group('why the decoder is needed', () {
    test('decoding each chunk on its own loses the character', () {
      // This is what an application had to do before writeBytes: it received
      // bytes and had to turn each chunk into a string itself.
      final bytes = utf8.encode('中文');
      final split = [bytes.sublist(0, 2), bytes.sublist(2)];

      final perChunk = StringBuffer();
      for (final chunk in split) {
        perChunk.write(utf8.decode(chunk, allowMalformed: true));
      }

      expect(perChunk.toString(), isNot('中文'));
      expect(perChunk.toString(), contains('�'));

      // The terminal's own decoder keeps the two bytes until the third arrives.
      final terminal = Terminal();
      for (final chunk in split) {
        terminal.writeBytes(chunk);
      }
      expect(terminal.buffer.lines[0].getText().trimRight(), '中文');
    });
  });

  group('end of stream', () {
    test('flushBytes turns a trailing incomplete character into U+FFFD', () {
      final terminal = Terminal();
      terminal.writeBytes([0xE4, 0xB8]);
      expect(bufferText(terminal).trimRight(), '');

      terminal.flushBytes();
      expect(bufferText(terminal).trimRight(), contains('�'));

      terminal.flushBytes();
      expect(bufferText(terminal).trimRight(), contains('�'));
    });

    test('write emits pending bytes before its text', () {
      final terminal = Terminal();
      terminal.writeBytes([0xE4, 0xB8]);
      terminal.write('A');

      final text = bufferText(terminal).trimRight();
      expect(text, contains('�A'));
      expect(text.indexOf('�'), lessThan(text.indexOf('A')));
    });
  });
}
