import 'package:test/test.dart';
import 'package:xterm/src/utils/escape_sanitizer.dart';

void main() {
  group('stripEscapeSequences', () {
    test('keeps plain text, tabs and newlines', () {
      expect(stripEscapeSequences('a\tb\nc'), 'a\tb\nc');
    });

    test('drops CSI sequences including private parameters', () {
      expect(stripEscapeSequences('a\x1b[?25lb'), 'ab');
      expect(stripEscapeSequences('a\x1b[38:2:1:2:3mb'), 'ab');
    });

    test('drops OSC terminated by BEL', () {
      expect(stripEscapeSequences('a\x1b]0;title\x07b'), 'ab');
    });

    test('drops OSC terminated by ST', () {
      expect(stripEscapeSequences('a\x1b]8;;https://x\x1b\\b'), 'ab');
    });

    test('drops DCS, SOS, PM and APC strings', () {
      expect(stripEscapeSequences('a\x1bPpayload\x1b\\b'), 'ab');
      expect(stripEscapeSequences('a\x1bXpayload\x1b\\b'), 'ab');
      expect(stripEscapeSequences('a\x1b^payload\x1b\\b'), 'ab');
      expect(stripEscapeSequences('a\x1b_payload\x1b\\b'), 'ab');
    });

    test('drops SS2/SS3 and their final byte', () {
      expect(stripEscapeSequences('a\x1bOPb'), 'ab');
      expect(stripEscapeSequences('a\x1bNxb'), 'ab');
    });

    test('drops charset designation', () {
      expect(stripEscapeSequences('a\x1b(Bb'), 'ab');
    });

    test('drops a lone ESC', () {
      // `ESC b` is itself a two-byte escape (Fe final byte), so both go.
      expect(stripEscapeSequences('a\x1bb'), 'a');
      expect(stripEscapeSequences('a\x1b'), 'a');
    });

    test('an unterminated string stops at the next control character', () {
      // The OSC never ends; the newline must not be swallowed with it.
      expect(stripEscapeSequences('a\x1b]8;;https://x\nb'), 'a\nb');
    });

    test('drops 8-bit C1 sequences', () {
      expect(stripEscapeSequences('a\u009b2Jb'), 'ab');
      expect(stripEscapeSequences('a\u009d0;title\u0007b'), 'ab');
      expect(stripEscapeSequences('a\u009d0;title\u009cb'), 'ab');
      expect(stripEscapeSequences('a\u0085b'), 'ab');
    });

    test('a charset designation does not split a surrogate pair', () {
      final out = stripEscapeSequences('a\x1b(😀b');
      expect(out, 'ab');
      expect(
        out.codeUnits.any((unit) => unit >= 0xd800 && unit <= 0xdfff),
        isFalse,
      );
    });
  });
}
