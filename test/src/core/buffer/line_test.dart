import 'package:test/test.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('BufferLine.getText()', () {
    test('should return the text', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(), 'Hello World');
    });

    test('getText() should support wide characters', () {
      final text = '😀😁😂🤣😃';
      final terminal = Terminal();
      terminal.write(text);
      expect(terminal.buffer.lines[0].getText(), equals(text));
    });

    test('getText() should support cjk wide characters without spacer cells', () {
      final text = '切换分支';
      final terminal = Terminal();
      terminal.write(text);
      expect(terminal.buffer.lines[0].getText(), equals(text));
    });

    test('can specify a range', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(0, 5), 'Hello');
    });

    test('can handle invalid ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(0, 100), 'Hello World');
    });

    test('can handle negative ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(-100, 100), 'Hello World');
    });

    test('can handle reversed ranges', () {
      final terminal = Terminal();
      terminal.write('Hello World');
      expect(terminal.buffer.lines[0].getText(5, 0), '');
    });
  });

  group('BufferLine.getTrimmedLength()', () {
    test('can get trimmed length', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(), equals(text.length));
    });

    test('can get trimmed length with wide characters', () {
      final terminal = Terminal();
      final text = '😀😁😂🤣😃';

      terminal.write(text);

      expect(terminal.buffer.lines[0].getTrimmedLength(), equals(text.length));
    });

    test('can handle length larger than the line', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(1000), equals(text.length));
    });

    test('can handle negative start', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      expect(line.getTrimmedLength(-1000), equals(0));
    });
  });

  group('BufferLine.resize', () {
    test('can resize', () {
      final line = BufferLine(10);

      final text = 'ABCDEF';

      for (var i = 0; i < text.length; i++) {
        line.setCodePoint(i, text.codeUnitAt(i));
      }

      line.resize(20);

      expect(line.length, equals(20));
    });
  });

  group('Buffer.createAnchor', () {
    test('works', () {
      final terminal = Terminal();
      final line = terminal.buffer.lines[3];
      final anchor = line.createAnchor(5);

      terminal.insertLines(5);
      expect(anchor.x, 5);
      expect(anchor.y, 8);

      terminal.buffer.clear();
      expect(line.attached, false);
      expect(anchor.attached, false);
    });
  });

  group('BufferLine wide character helpers', () {
    test('isWideCharContinuationCell detects continuation cell', () {
      final terminal = Terminal();
      terminal.write('😀'); // U+1F600, width 2
      final line = terminal.buffer.lines[0];

      expect(line.getCodePoint(0), 0x1F600);
      expect(line.getWidth(0), 2);
      expect(line.getCodePoint(1), 0);
      expect(line.isWideCharContinuationCell(0), isFalse);
      expect(line.isWideCharContinuationCell(1), isTrue);
    });

    test('isWideCharContinuationCell returns false for normal chars', () {
      final terminal = Terminal();
      terminal.write('ABC');

      final line = terminal.buffer.lines[0];
      expect(line.isWideCharContinuationCell(0), isFalse);
      expect(line.isWideCharContinuationCell(1), isFalse);
      expect(line.isWideCharContinuationCell(2), isFalse);
    });

    test('isWideCharContinuationCell returns false at boundaries', () {
      final line = BufferLine(10);
      expect(line.isWideCharContinuationCell(-1), isFalse);
      expect(line.isWideCharContinuationCell(0), isFalse);
      expect(line.isWideCharContinuationCell(10), isFalse);
    });

    test('getCharacterStart returns self for normal chars', () {
      final terminal = Terminal();
      terminal.write('ABC');

      final line = terminal.buffer.lines[0];
      expect(line.getCharacterStart(0), 0);
      expect(line.getCharacterStart(1), 1);
      expect(line.getCharacterStart(2), 2);
    });

    test('getCharacterStart backs up from continuation cell', () {
      final terminal = Terminal();
      terminal.write('😀');

      final line = terminal.buffer.lines[0];
      expect(line.getCharacterStart(0), 0);
      expect(line.getCharacterStart(1), 0); // continuation cell → start
    });

    test('getCharacterStart handles CJK wide characters', () {
      final terminal = Terminal();
      terminal.write('中文');

      final line = terminal.buffer.lines[0];
      // '中' is a wide char (width 2) at index 0
      expect(line.getCharacterStart(0), 0);
      expect(line.getCharacterStart(1), 0); // continuation cell of '中'
      // '文' is a wide char (width 2) at index 2
      expect(line.getCharacterStart(2), 2);
      expect(line.getCharacterStart(3), 2); // continuation cell of '文'
    });

    test('getCharacterEnd returns exclusive end for normal chars', () {
      final terminal = Terminal();
      terminal.write('ABC');

      final line = terminal.buffer.lines[0];
      expect(line.getCharacterEnd(0), 1);
      expect(line.getCharacterEnd(1), 2);
      expect(line.getCharacterEnd(2), 3);
    });

    test('getCharacterEnd expands to include full wide character', () {
      final terminal = Terminal();
      terminal.write('😀');

      final line = terminal.buffer.lines[0];
      expect(line.getCharacterEnd(0), 2); // wide char spans cells 0-1
      expect(line.getCharacterEnd(1), 2); // from continuation, still get end
    });

    test('getCharacterEnd at boundaries', () {
      final line = BufferLine(10);
      expect(line.getCharacterEnd(-1), 0);
      expect(line.getCharacterEnd(10), 10);
    });
  });
}
