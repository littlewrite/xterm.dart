import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

@GenerateNiceMocks([MockSpec<EscapeHandler>()])
import 'parser_test.mocks.dart';

void main() {
  group('EscapeParser', () {
    test('can parse window manipulation', () {
      final parser = EscapeParser(MockEscapeHandler());
      parser.write('\x1b[8;24;80t');
      verify(parser.handler.resize(80, 24));
    });

    test('maps ESC = to application keypad mode', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b=');

      verify(handler.setAppKeypadMode(true));
    });

    test('maps ESC > to normal keypad mode', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b>');

      verify(handler.setAppKeypadMode(false));
    });

    test('designates G2 charset via ESC *', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b*B');

      verify(handler.designateCharset(2, 'B'.codeUnitAt(0)));
    });

    test('designates G3 charset via ESC +', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b+B');

      verify(handler.designateCharset(3, 'B'.codeUnitAt(0)));
    });

    test('does not treat prefixed CSI m as SGR', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[>4;2m');

      verify(handler.unknownCSI('m'.codeUnitAt(0)));
      verifyNever(handler.setCursorUnderline());
      verifyNever(handler.setCursorFaint());
    });

    test('treats VPA parameter 0 as row 1', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      parser.write('\x1b[0d');

      verify(handler.setCursorY(0));
      verifyNever(handler.setCursorY(-1));
    });

    test('ignores incomplete semicolon RGB foreground SGR sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      expect(() => parser.write('\x1b[38;2m'), returnsNormally);
      verifyNever(handler.setForegroundColorRgb(any, any, any));
    });

    test('ignores incomplete semicolon background SGR sequences', () {
      final handler = MockEscapeHandler();
      final parser = EscapeParser(handler);

      expect(() => parser.write('\x1b[48m'), returnsNormally);
      verifyNever(handler.setBackgroundColorRgb(any, any, any));
      verifyNever(handler.setBackgroundColor256(any));
    });
  });
}
