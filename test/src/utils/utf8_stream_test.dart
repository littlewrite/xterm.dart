import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/utils/utf8_stream.dart';

/// A reader hands over whatever it read, so a character can be cut in half
/// between two chunks. These tests feed the same text in every split that a
/// reader could produce and expect it back whole.
void main() {
  const samples = [
    'hello, world',
    '墙角数枝梅，凌寒独自开。', // three-byte characters
    'café naïve résumé', // two-byte characters
    'emoji 👨‍👩‍👧‍👦 and 🎉 work', // four-byte and combining sequences
    'mixed 中文 with ascii and émoji 🚀',
  ];

  group('chunk boundaries', () {
    for (final sample in samples) {
      test('splits ${sample.runes.length} characters anywhere', () {
        final bytes = utf8.encode(sample);

        // Every single split point: two chunks, cut anywhere.
        for (var cut = 0; cut <= bytes.length; cut++) {
          final decoder = Utf8StreamDecoder();
          final out = StringBuffer()
            ..write(decoder.decode(bytes.sublist(0, cut)))
            ..write(decoder.decode(bytes.sublist(cut)));
          expect(out.toString(), sample, reason: 'split at byte $cut');
        }
      });

      test('byte at a time: ${sample.runes.length} characters', () {
        final decoder = Utf8StreamDecoder();
        final out = StringBuffer();
        for (final byte in utf8.encode(sample)) {
          out.write(decoder.decode([byte]));
        }
        expect(out.toString(), sample);
      });
    }
  });

  group('state', () {
    test('holds back the bytes of a character that is still arriving', () {
      final decoder = Utf8StreamDecoder();
      // '中' is E4 B8 AD.
      expect(decoder.decode([0xE4]), '');
      expect(decoder.hasPending, isTrue);
      expect(decoder.decode([0xB8]), '');
      expect(decoder.decode([0xAD]), '中');
      expect(decoder.hasPending, isFalse);
    });

    test('emits what is complete before the part that is not', () {
      final decoder = Utf8StreamDecoder();
      expect(decoder.decode([0x41, 0xE4, 0xB8]), 'A');
      expect(decoder.decode([0xAD, 0x42]), '中B');
    });

    test('an empty chunk changes nothing', () {
      final decoder = Utf8StreamDecoder();
      expect(decoder.decode(const []), '');
      expect(decoder.decode([0xE4]), '');
      expect(decoder.decode(const []), '');
      expect(decoder.decode([0xB8, 0xAD]), '中');
    });

    test('a four-byte character split after its lead byte', () {
      final decoder = Utf8StreamDecoder();
      final bytes = utf8.encode('🚀');
      expect(bytes, hasLength(4));
      expect(decoder.decode(bytes.sublist(0, 1)), '');
      expect(decoder.decode(bytes.sublist(1, 3)), '');
      expect(decoder.decode(bytes.sublist(3)), '🚀');
    });

    test('flush emits held bytes as malformed data', () {
      final decoder = Utf8StreamDecoder();
      expect(decoder.decode([0xE4, 0xB8]), '');
      expect(decoder.hasPending, isTrue);

      expect(decoder.flush(), contains('�'));
      expect(decoder.hasPending, isFalse);
      expect(decoder.flush(), '');
    });
  });

  group('malformed input', () {
    /// Malformed bytes must not throw and must not swallow the good text around
    /// them. How many U+FFFD a run of bad bytes becomes is Dart's
    /// `utf8.decode(allowMalformed: true)`'s business, not this decoder's.
    void expectMalformed(String result, {required String textAroundIt}) {
      expect(result, contains('�'));
      expect(result.replaceAll('�', ''), textAroundIt);
    }

    test('a stray continuation byte', () {
      expectMalformed(
        Utf8StreamDecoder().decode([0x41, 0x80, 0x42]),
        textAroundIt: 'AB',
      );
    });

    test('an overlong lead', () {
      // 0xC0 and 0xC1 can only start an overlong encoding.
      expectMalformed(
        Utf8StreamDecoder().decode([0xC0, 0x80, 0x41]),
        textAroundIt: 'A',
      );
    });

    test('a character the stream ends in the middle of', () {
      final decoder = Utf8StreamDecoder();
      expect(decoder.decode([0xE4, 0xB8]), '');
      // The reader stopped here for good, so the bytes it did send never make a
      // character; the 'A' that follows still arrives.
      expectMalformed(decoder.decode([0x41]), textAroundIt: 'A');
    });

    test('a surrogate encoded in UTF-8', () {
      // ED A0 80 encodes U+D800, which UTF-8 forbids.
      expectMalformed(
        Utf8StreamDecoder().decode([0xED, 0xA0, 0x80]),
        textAroundIt: '',
      );
    });

    test('a continuation byte where a lead was expected', () {
      expectMalformed(
        Utf8StreamDecoder().decode([0xE4, 0x41]),
        textAroundIt: 'A',
      );
    });

    test('nothing after a bad byte is lost', () {
      final decoder = Utf8StreamDecoder();
      final out = StringBuffer();
      for (final byte in [0xFF, 0x80, ...utf8.encode('中文')]) {
        out.write(decoder.decode([byte]));
      }
      expect(out.toString().replaceAll('�', ''), '中文');
    });
  });

  test('matches utf8.decode for whole input', () {
    for (final sample in samples) {
      expect(Utf8StreamDecoder().decode(utf8.encode(sample)), sample);
    }
  });
}
