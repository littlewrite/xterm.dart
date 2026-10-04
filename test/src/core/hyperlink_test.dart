import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('OSC 8 links written cells and OSC 8;; closes it', () {
    final terminal = Terminal();
    terminal.write('\x1b]8;;https://example.com/a\x1b\\link\x1b]8;;\x1b\\plain');

    final line = terminal.buffer.lines[0];
    expect(line.getLink(0)?.uri, 'https://example.com/a');
    expect(line.getLink(3)?.uri, 'https://example.com/a');
    expect(line.getLink(4), isNull);
    expect(terminal.hyperlinkAt(const CellOffset(1, 0))?.uri,
        'https://example.com/a');
    expect(terminal.hyperlinkAt(const CellOffset(4, 0)), isNull);
  });

  test('keeps semicolons inside the OSC 8 URI', () {
    final terminal = Terminal();
    terminal.write('\x1b]8;;https://example.com/a;b;c\x1b\\x\x1b]8;;\x1b\\');

    expect(
      terminal.buffer.lines[0].getLink(0)?.uri,
      'https://example.com/a;b;c',
    );
  });

  test('reuses one hyperlink instance for rows sharing an id', () {
    final terminal = Terminal();
    terminal.write(
      '\x1b]8;id=logo;https://example.com\x1b\\x\x1b]8;;\x1b\\\r\n'
      '\x1b]8;id=logo;https://example.com\x1b\\y\x1b]8;;\x1b\\',
    );

    final first = terminal.buffer.lines[0].getLink(0);
    final second = terminal.buffer.lines[1].getLink(0);
    expect(first, isNotNull);
    expect(identical(first, second), isTrue);
  });

  test('ignores in-progress or oversized OSC 8 payloads', () {
    final terminal = Terminal();
    // Missing the URI field: malformed, must not open a link.
    terminal.write('\x1b]8;id=x\x1b\\a');
    expect(terminal.buffer.lines[0].getLink(0), isNull);

    // Over the URI cap: dropped instead of attached to the cell.
    terminal.write('\r\n\x1b]8;;https://example.com/${'a' * 9000}\x1b\\b\x1b]8;;\x1b\\');
    expect(terminal.buffer.lines[1].getLink(0), isNull);
  });

  test('link ids follow insert/remove/erase on the line', () {
    final terminal = Terminal();
    terminal.write('\x1b]8;;https://example.com\x1b\\abcd\x1b]8;;\x1b\\');
    final line = terminal.buffer.lines[0];

    line.insertCells(0, 1, CursorStyle.empty);
    expect(line.getLink(0), isNull);
    expect(line.getLink(1)?.uri, 'https://example.com');
    expect(line.getLink(4)?.uri, 'https://example.com');

    line.removeCells(0, 1);
    expect(line.getLink(0)?.uri, 'https://example.com');
    expect(line.getLink(3)?.uri, 'https://example.com');
    expect(line.getLink(4), isNull);

    line.eraseCell(0, CursorStyle.empty);
    expect(line.getLink(0), isNull);
  });

  test('erase clears the link instead of stamping it on blank cells', () {
    final terminal = Terminal();
    terminal.write('\x1b]8;;https://example.com\x1b\\ab');
    final line = terminal.buffer.lines[0];
    expect(line.getLink(0), isNotNull);

    // 擦除保留颜色 / 属性，但不留链接：空白格带链接会让整行变成可点 / 会下划线
    // 的区域（EL 之后悬停就会命中）。
    line.eraseRange(0, 2, terminal.cursor);
    expect(line.getLink(0), isNull);
    expect(line.getLink(1), isNull);

    // 打开中的链接还在游标样式里：擦掉之后接着写进去的字照样挂链接。
    line.setCell(0, 0x63, 1, terminal.cursor);
    expect(line.getLink(0)?.uri, 'https://example.com');
  });

  test('copyFrom copies the link side channel', () {
    final terminal = Terminal();
    terminal.write('\x1b]8;;https://example.com\x1b\\abcd\x1b]8;;\x1b\\');
    final source = terminal.buffer.lines[0];
    final target = BufferLine(8);

    target.copyFrom(source, 0, 0, 4);
    expect(target.getLink(0)?.uri, 'https://example.com');
    expect(target.getLink(3)?.uri, 'https://example.com');
  });

  test('detects plain-text URLs in dev-server output', () {
    final terminal = Terminal();
    terminal.write('  ➜  Local:   http://localhost:5173/\r\n');
    final line = terminal.buffer.lines[0];

    final matches = findTerminalUrlsInLine(line);
    expect(matches, hasLength(1));
    expect(matches.single.uri, 'http://localhost:5173/');

    var urlColumn = -1;
    for (var column = 0; column < line.length; column++) {
      if (line.getCodePoint(column) == 'h'.codeUnitAt(0)) {
        urlColumn = column;
        break;
      }
    }
    expect(urlColumn, greaterThan(0));
    expect(matches.single.startColumn, urlColumn);
    expect(
      terminal.hyperlinkAt(CellOffset(urlColumn + 5, 0))?.uri,
      'http://localhost:5173/',
    );
    // The decoration in front of the URL is not part of the link.
    expect(terminal.hyperlinkAt(const CellOffset(0, 0)), isNull);
  });

  test('trims trailing prose punctuation from plain URLs', () {
    final terminal = Terminal();
    terminal.write('see https://example.com/docs, or not.');

    final matches = findTerminalUrlsInLine(terminal.buffer.lines[0]);
    expect(matches.single.uri, 'https://example.com/docs');
  });

  test('plain-text detection ignores non-http schemes', () {
    final terminal = Terminal();
    terminal.write('file:///tmp/report.txt');

    expect(findTerminalUrlsInLine(terminal.buffer.lines[0]), isEmpty);
  });
}
